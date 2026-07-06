//
//  WatchConnectivityManager.swift
//  ParaFlightLogWatch Watch App
//
//  WatchConnectivity on the Apple Watch side
//  - Receives the Wings list from the iPhone
//  - Delivers FlightDTOs to the iPhone through a persistent outbox:
//    a flight is written to FlightOutbox first and only removed once the
//    iPhone confirmed the save (sendMessage reply with flightSaved == true),
//    so flights are never lost.
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

    /// Flight ids that currently have a userInfo transfer queued in WCSession.
    /// Only used to avoid queueing ANOTHER transferUserInfo for the same
    /// flight; it never blocks sendMessage retries. Cleared in
    /// session(_:didFinish:error:) whether the transfer succeeded or failed.
    /// MainActor state - only touch on the main queue.
    private var outstandingTransferIds: Set<UUID> = []

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
    /// - Returns: true when the flight is safely persisted in the outbox.
    ///   On false, the caller must keep the tracking session (recoverable).
    @discardableResult
    func sendFlightToPhone(_ flight: FlightDTO) -> Bool {
        let persisted = FlightOutbox.shared.add(flight)
        retryPendingFlights()
        return persisted
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

        for flight in pending {
            deliver(flight)
        }
    }

    /// Delivers one flight: sendMessage with reply when the iPhone is
    /// reachable, transferUserInfo otherwise (or on sendMessage failure).
    /// An outstanding userInfo transfer never blocks a sendMessage retry:
    /// only removal on flightSaved == true drains the outbox, and the iPhone
    /// deduplicates flights by id, so redundant delivery is safe.
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
                // Background queue: FlightOutbox is nonisolated and
                // internally synchronized, so this is safe here.
                if reply[WatchSyncKeys.flightSaved] as? Bool == true {
                    FlightOutbox.shared.remove(id: flight.id)
                } else {
                    watchLogWarning("iPhone reply did not confirm save for flight \(flight.id.uuidString) - kept in outbox", category: .watchSync)
                }
            }, errorHandler: { [weak self] error in
                watchLogWarning("sendMessage failed for flight \(flight.id.uuidString): \(error.localizedDescription) - falling back to transferUserInfo", category: .watchSync)
                DispatchQueue.main.async {
                    self?.queueTransferIfNeeded(id: flight.id, payload: payload)
                }
            })
        } else {
            // Not reachable: queue a background transfer. Completion of the
            // transfer only means WC delivered the payload - the flight stays
            // in the outbox until a sendMessage reply confirms the save.
            queueTransferIfNeeded(id: flight.id, payload: payload)
        }
    }

    /// Queues a transferUserInfo for the flight unless one is already
    /// outstanding (either tracked in this run or persisted by WCSession
    /// across relaunches). The system retries queued transfers on its own.
    private func queueTransferIfNeeded(id: UUID, payload: [String: Any]) {
        guard !outstandingTransferIds.contains(id) else { return }

        let alreadyQueued = WCSession.default.outstandingUserInfoTransfers.contains {
            $0.userInfo[WatchSyncKeys.flightId] as? String == id.uuidString
        }
        guard !alreadyQueued else {
            outstandingTransferIds.insert(id)
            return
        }

        outstandingTransferIds.insert(id)
        WCSession.default.transferUserInfo(payload)
    }

    /// Called when a queued userInfo transfer completes (or fails).
    /// Completion only means WatchConnectivity delivered the payload, NOT
    /// that the iPhone saved the flight - so the flight is never removed
    /// from the outbox here. We only clear the "outstanding transfer" flag
    /// (on success and on failure alike) so a later retryPendingFlights()
    /// can re-attempt delivery. Removal happens exclusively on a sendMessage
    /// reply with flightSaved == true (see deliver(_:)).
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let idString = userInfoTransfer.userInfo[WatchSyncKeys.flightId] as? String,
              let id = UUID(uuidString: idString) else {
            return
        }

        let errorDescription = error?.localizedDescription

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.outstandingTransferIds.remove(id)

            if let errorDescription = errorDescription {
                watchLogWarning("userInfo transfer failed for flight \(idString): \(errorDescription) - kept in outbox for retry", category: .watchSync)
            } else {
                watchLogInfo("userInfo transfer delivered for flight \(idString) - kept in outbox until the iPhone confirms the save", category: .watchSync)
            }
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

    /// Pushes the current on-watch settings back to the iPhone so the two stay in
    /// sync when the pilot changes them on the Watch (two-way sync). Uses
    /// transferUserInfo so the change survives the phone being unreachable.
    func sendSettingsToPhone() {
        guard sessionActivated else { return }
        // NOTE: UserDefaultsKeys (Constants.swift) is iOS-only; use literals here.
        // These string keys must match the iPhone's UserDefaultsKeys values.
        let s = WatchSettings.shared
        // varioEnabled is deliberately NOT sent: on the iPhone that key drives
        // the PHONE's timer vario, not a mirror of the Watch vario, and the
        // reverse direction never synced it. The watch vario stays watch-local.
        let payload: [String: Any] = [
            WatchSyncKeys.watchSettingsUpdate: true,
            "watchAutoWaterLock": s.autoWaterLockEnabled,
            "watchAllowSessionDismiss": s.allowSessionDismiss,
            "simulateFlightEnabled": s.simulateFlightEnabled
        ]
        WCSession.default.transferUserInfo(payload)
        watchLogInfo("Sent settings to iPhone (two-way sync)", category: .watchSync)
    }

    // MARK: - WCSessionDelegate

    // WCSession delegate callbacks arrive on a background queue, so they are
    // nonisolated and hop to the main queue before touching @Observable state.

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            watchLogError("WCSession activation failed: \(error.localizedDescription)", category: .watchSync)
            return
        }

        // receivedApplicationContext is the dict the iPhone last SENT to us
        // (applicationContext would be what this device sent - empty here),
        // so wings/settings pushed while the watch app was dead are restored.
        let reachable = session.isReachable
        let context = session.receivedApplicationContext

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sessionActivated = (activationState == .activated)
            self.isPhoneReachable = reachable

            if activationState == .activated {
                // Try to process the last received context
                if !context.isEmpty {
                    watchLogInfo("Processing receivedApplicationContext on activation (\(context.keys.count) keys)", category: .watchSync)
                    self.processReceivedContext(context)
                }

                // Always ask the iPhone for a fresh update to catch deletions etc.
                if self.isPhoneReachable {
                    watchLogInfo("Requesting fresh wings from iPhone", category: .watchSync)
                    self.requestWingsFromPhone()
                }

                // Deliver any flight left over from a previous run
                self.retryPendingFlights()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let wasReachable = self.isPhoneReachable
            self.isPhoneReachable = reachable

            // When the iPhone becomes reachable, refresh the wings and flush the outbox
            if !wasReachable && reachable {
                watchLogInfo("iPhone became reachable, requesting wings sync", category: .watchSync)
                self.requestWingsFromPhone()
                self.retryPendingFlights()
            }
        }
    }

    // MARK: - Receive Wings from iPhone

    /// Receives the updated context from the iPhone (Wings list)
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.processReceivedContext(applicationContext)
        }
    }

    /// Receives data via transferUserInfo (alternative path)
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.processReceivedContext(userInfo)
        }
    }

    /// Instant messages from the iPhone (e.g. pull-to-refresh asking the Watch
    /// to re-attempt delivery of any flights still in the outbox).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["action"] as? String == "flushOutbox" {
            DispatchQueue.main.async { [weak self] in
                watchLogInfo("iPhone requested an outbox flush", category: .watchSync)
                self?.retryPendingFlights()
            }
        }
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
