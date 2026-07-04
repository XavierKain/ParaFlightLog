//
//  WatchConnectivityManager.swift
//  ParaFlightLogWatch Watch App
//
//  WatchConnectivity on the Apple Watch side
//  - Receives the Wings list from the iPhone
//  - Delivers FlightDTOs to the iPhone through a persistent outbox:
//    a flight is written to FlightOutbox first and only removed once the
//    iPhone acknowledged it, so flights are never lost.
//  Target: Watch only
//

import Foundation
import WatchConnectivity

@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    // Wings received from the iPhone
    var wings: [WingDTO] = []

    // Connection state
    var isPhoneReachable: Bool = false
    var sessionActivated: Bool = false

    // Loading state to avoid re-renders while decoding
    var isLoading: Bool = true

    private override init() {
        super.init()
        // Load locally saved wings synchronously for immediate display at launch
        loadWingsSync()

        // Activate the WatchConnectivity session in the background
        Task { @MainActor [weak self] in
            self?.activateSession()
        }
    }

    // MARK: - Local Persistence

    private func saveWingsLocally() {
        // Save in the background
        let wingsToSave = wings
        Task.detached(priority: .background) {
            if let encoded = try? JSONEncoder().encode(wingsToSave) {
                UserDefaults.standard.set(encoded, forKey: "savedWings")
            }
        }
    }

    /// Loads wings synchronously at launch (local data is small, so it's fast)
    private func loadWingsSync() {
        if let data = UserDefaults.standard.data(forKey: "savedWings"),
           let decoded = try? JSONDecoder().decode([WingDTO].self, from: data) {
            wings = decoded
        }
        isLoading = false
    }

    // MARK: - Session Activation

    /// Activates the WatchConnectivity session
    func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Send Flight to iPhone (persistent outbox)

    /// Persists the flight to the outbox (synchronously, so it can never be
    /// lost) and then attempts delivery of every pending flight.
    /// The iPhone deduplicates by flight id, so redundant delivery is safe.
    func sendFlightToPhone(_ flight: FlightDTO) {
        FlightOutbox.shared.add(flight)
        retryPendingFlights()
    }

    /// Attempts delivery of every flight still in the outbox.
    /// Called on: new flight send, session activation, app becoming active,
    /// and when the iPhone becomes reachable.
    func retryPendingFlights() {
        guard sessionActivated else {
            watchLogInfo("Session not activated - flights stay in outbox for later delivery", category: .watchSync)
            return
        }

        let pending = FlightOutbox.shared.pending()
        guard !pending.isEmpty else { return }

        // Skip flights that already have a userInfo transfer queued
        // (the system retries those on its own).
        let queuedIds = Set(WCSession.default.outstandingUserInfoTransfers.compactMap {
            $0.userInfo[WatchSyncKeys.flightId] as? String
        })

        for flight in pending where !queuedIds.contains(flight.id.uuidString) {
            deliver(flight)
        }
    }

    /// Delivers one flight: sendMessage with reply when the iPhone is
    /// reachable, transferUserInfo otherwise (or on sendMessage failure).
    private func deliver(_ flight: FlightDTO) {
        guard let data = try? JSONEncoder().encode(flight) else {
            watchLogError("Failed to encode flight \(flight.id.uuidString) for delivery", category: .watchSync)
            return
        }

        let payload: [String: Any] = [
            WatchSyncKeys.flightData: data,
            WatchSyncKeys.flightId: flight.id.uuidString
        ]

        if isPhoneReachable {
            WCSession.default.sendMessage(payload, replyHandler: { reply in
                if reply[WatchSyncKeys.flightSaved] as? Bool == true {
                    FlightOutbox.shared.remove(id: flight.id)
                } else {
                    watchLogWarning("iPhone reply did not confirm save for flight \(flight.id.uuidString) - kept in outbox", category: .watchSync)
                }
            }, errorHandler: { error in
                watchLogWarning("sendMessage failed for flight \(flight.id.uuidString): \(error.localizedDescription) - falling back to transferUserInfo", category: .watchSync)
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            // Not reachable: queue a background transfer, confirmed (and
            // removed from the outbox) in didFinish userInfoTransfer.
            WCSession.default.transferUserInfo(payload)
        }
    }

    /// Called when a queued userInfo transfer completes (or fails).
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let idString = userInfoTransfer.userInfo[WatchSyncKeys.flightId] as? String,
              let id = UUID(uuidString: idString) else {
            return
        }

        if let error = error {
            // Keep the flight in the outbox; it will be retried later.
            watchLogWarning("userInfo transfer failed for flight \(idString): \(error.localizedDescription) - kept in outbox", category: .watchSync)
        } else {
            FlightOutbox.shared.remove(id: id)
        }
    }

    /// Asks the iPhone to send the Wings (useful if nothing was received at launch)
    func requestWingsFromPhone() {
        guard sessionActivated, isPhoneReachable else { return }
        let message = ["action": "requestWings"]
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            watchLogWarning("requestWingsFromPhone failed: \(error.localizedDescription)", category: .watchSync)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            watchLogError("WCSession activation failed: \(error.localizedDescription)", category: .watchSync)
            return
        }

        sessionActivated = (activationState == .activated)
        isPhoneReachable = session.isReachable

        if activationState == .activated {
            // Try to process the last available context
            let context = session.applicationContext
            if !context.isEmpty {
                watchLogInfo("Processing applicationContext on activation (\(context.keys.count) keys)", category: .watchSync)
                processReceivedContext(context)
            }

            // Always ask the iPhone for a fresh update to catch deletions etc.
            if isPhoneReachable {
                watchLogInfo("Requesting fresh wings from iPhone", category: .watchSync)
                requestWingsFromPhone()
            }

            // Deliver any flight left over from a previous run
            retryPendingFlights()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let wasReachable = isPhoneReachable
        isPhoneReachable = session.isReachable

        // When the iPhone becomes reachable, refresh the wings and flush the outbox
        if !wasReachable && isPhoneReachable {
            watchLogInfo("iPhone became reachable, requesting wings sync", category: .watchSync)
            requestWingsFromPhone()
            retryPendingFlights()
        }
    }

    // MARK: - Receive Wings from iPhone

    /// Receives the updated context from the iPhone (Wings list)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        processReceivedContext(applicationContext)
    }

    /// Receives data via transferUserInfo (alternative path)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        processReceivedContext(userInfo)
    }

    /// Processes a received context (Wings and settings extraction)
    private func processReceivedContext(_ context: [String: Any]) {
        // Extract Watch settings if present
        WatchSettings.shared.updateFromContext(context)

        // New format: wingsData as Base64 - decode in the background
        if let base64String = context[WatchSyncKeys.wingsData] as? String,
           let jsonData = Data(base64Encoded: base64String) {

            // Decode in the background to avoid blocking the UI
            Task.detached(priority: .userInitiated) {
                guard let decodedWings = try? JSONDecoder().decode([WingDTO].self, from: jsonData) else {
                    return
                }
                let sortedWings = decodedWings.sorted { $0.displayOrder < $1.displayOrder }

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    // Only update if the data actually changed, to avoid re-renders
                    guard self.wingsHaveChanged(sortedWings) else { return }
                    // Clear the image cache since the data changed
                    WatchImageCache.shared.clearCache()
                    self.wings = sortedWings
                    self.saveWingsLocally()
                }
            }
            return
        }

        // Legacy format (compatibility): wings as [[String: Any]]
        if let wingsData = context["wings"] as? [[String: Any]] {
            Task.detached(priority: .userInitiated) {
                guard let jsonData = try? JSONSerialization.data(withJSONObject: wingsData),
                      let decodedWings = try? JSONDecoder().decode([WingDTO].self, from: jsonData) else {
                    return
                }
                let sortedWings = decodedWings.sorted { $0.displayOrder < $1.displayOrder }

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    guard self.wingsHaveChanged(sortedWings) else { return }
                    // Clear the image cache since the data changed
                    WatchImageCache.shared.clearCache()
                    self.wings = sortedWings
                    self.saveWingsLocally()
                }
            }
        }
    }

    /// Compares new wings with the current ones to avoid useless re-renders
    private func wingsHaveChanged(_ newWings: [WingDTO]) -> Bool {
        guard wings.count == newWings.count else { return true }
        for (index, wing) in wings.enumerated() {
            let newWing = newWings[index]
            if wing.id != newWing.id ||
               wing.name != newWing.name ||
               wing.size != newWing.size ||
               wing.displayOrder != newWing.displayOrder ||
               wing.photoData != newWing.photoData {
                return true
            }
        }
        return false
    }

    #if os(watchOS)
    // sessionDidBecomeInactive/sessionDidDeactivate are not needed on watchOS
    #endif
}
