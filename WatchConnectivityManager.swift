//
//  WatchConnectivityManager.swift
//  ParaFlightLog
//
//  WatchConnectivity on the iPhone side.
//  - Sends the wing list to the Watch (applicationContext, thumbnails first).
//  - Receives FlightDTOs from the Watch and persists them IMMEDIATELY.
//
//  Flight receive contract (Watch -> iPhone):
//  - The Watch sends each flight through BOTH sendMessage-with-reply and
//    transferUserInfo (persistent outbox with retries on the Watch side).
//  - Payload key: WatchSyncKeys.flightData = JSON-encoded FlightDTO (Data).
//  - Deduplication happens here by flight UUID: an already-saved flight is a
//    SUCCESS and is acknowledged with [WatchSyncKeys.flightSaved: true].
//  - The reply [WatchSyncKeys.flightSaved: true] is only sent after the
//    SwiftData context save succeeded. Reverse geocoding runs afterwards in
//    the background and updates spotName/latitude/longitude - the flight is
//    already safe either way.
//  Target: iOS only
//

import Foundation
import WatchConnectivity
import CoreLocation

@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    var isWatchAppInstalled: Bool = false
    var isWatchReachable: Bool = false

    // Services (injected from the App)
    weak var dataController: DataController?
    weak var locationService: LocationService?

    // Debouncing to avoid overly frequent wing syncs
    private var pendingSyncWorkItem: DispatchWorkItem?
    private let syncDebounceInterval: TimeInterval = 0.5

    private override init() {
        super.init()
        // Note: the session is activated after the dataController is injected
    }

    // MARK: - Session Activation

    /// Activates the WatchConnectivity session
    func activateSession() {
        guard WCSession.isSupported() else {
            logWarning("WatchConnectivity not supported on this device", category: .watchSync)
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        logInfo("WatchConnectivity session activating...", category: .watchSync)
    }

    // MARK: - Send Watch Settings

    /// Sends the Watch settings via applicationContext
    func sendWatchSettings(autoWaterLock: Bool, allowSessionDismiss: Bool, developerMode: Bool? = nil, simulateFlight: Bool? = nil) {
        guard WCSession.default.activationState == .activated else {
            logWarning("WCSession not activated, cannot send watch settings", category: .watchSync)
            return
        }

        var context = WCSession.default.applicationContext
        context[UserDefaultsKeys.watchAutoWaterLock] = autoWaterLock
        context[UserDefaultsKeys.watchAllowSessionDismiss] = allowSessionDismiss

        // Include developer mode if specified, otherwise read from UserDefaults
        let devMode = developerMode ?? UserDefaults.standard.bool(forKey: UserDefaultsKeys.developerModeEnabled)
        context[UserDefaultsKeys.developerModeEnabled] = devMode

        // Watch flight simulator flag (developer tool)
        let simulate = simulateFlight ?? UserDefaults.standard.bool(forKey: UserDefaultsKeys.simulateFlightEnabled)
        context[UserDefaultsKeys.simulateFlightEnabled] = simulate

        do {
            try WCSession.default.updateApplicationContext(context)
            logInfo("Sent watch settings: autoWaterLock=\(autoWaterLock), allowDismiss=\(allowSessionDismiss), devMode=\(devMode), simulate=\(simulate)", category: .watchSync)
        } catch {
            logError("Failed to send watch settings: \(error.localizedDescription)", category: .watchSync)
        }
    }

    // MARK: - Send Wings to Watch

    /// Sends the wing list to the Watch, debounced.
    /// Two paths only:
    /// 1. applicationContext with compressed thumbnails
    /// 2. if the payload is too large or updateApplicationContext throws:
    ///    applicationContext without photos + transferUserInfo with thumbnails
    /// If the session is not activated yet, the activation callback resyncs.
    func sendWingsToWatch() {
        pendingSyncWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performWingsSync()
        }

        pendingSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + syncDebounceInterval, execute: workItem)
    }

    /// Actually performs the wing sync (must run on the main queue)
    private func performWingsSync() {
        guard let dataController = dataController else {
            logWarning("DataController not available for wing sync", category: .watchSync)
            return
        }

        guard WCSession.default.activationState == .activated else {
            // No retry machinery: activationDidCompleteWith triggers a resync
            logDebug("WCSession not activated yet, wing sync deferred to activation", category: .watchSync)
            return
        }

        // Snapshot the models on the main queue (SwiftData access must stay here),
        // then resize the images off the main thread (expensive).
        let snapshots: [(dto: WingDTO, photoData: Data?)] = dataController.fetchWings()
            .map { ($0.toDTOWithoutPhoto(), $0.photoData) }
        let maxSizeKB = WatchSyncConstants.maxContextSizeKB

        Task.detached(priority: .userInitiated) {
            let withThumbnails = snapshots.map { Wing.thumbnailDTO(from: $0.dto, photoData: $0.photoData) }
            let withoutPhotos = snapshots.map(\.dto)

            let encoder = JSONEncoder()
            let thumbnailData = try? encoder.encode(withThumbnails)
            let noPhotoData = try? encoder.encode(withoutPhotos)

            await MainActor.run { [weak self] in
                self?.deliverWings(thumbnailData: thumbnailData, noPhotoData: noPhotoData, maxSizeKB: maxSizeKB)
            }
        }
    }

    /// Delivers encoded wings to the Watch (main queue).
    private func deliverWings(thumbnailData: Data?, noPhotoData: Data?, maxSizeKB: Double) {
        // Path 1: applicationContext with thumbnails (when it fits)
        if let thumbnailData = thumbnailData,
           Double(thumbnailData.count) / 1024.0 <= maxSizeKB,
           updateWingsContext(with: thumbnailData) {
            logInfo("Wings synced to Watch with thumbnails (\(String(format: "%.1f", Double(thumbnailData.count) / 1024.0))KB)", category: .watchSync)
            return
        }

        // Path 2: applicationContext without photos + thumbnails via transferUserInfo
        logWarning("Wings payload too large or context update failed - falling back to no-photo context + userInfo transfer", category: .watchSync)

        if let noPhotoData = noPhotoData {
            if updateWingsContext(with: noPhotoData) {
                logInfo("Wings synced to Watch without photos", category: .watchSync)
            } else {
                logError("Failed to sync wings without photos", category: .watchSync)
            }
        }

        if let thumbnailData = thumbnailData {
            let userInfo = [WatchSyncKeys.wingsData: thumbnailData.base64EncodedString()]
            WCSession.default.transferUserInfo(userInfo)
            logInfo("Wing thumbnails queued via transferUserInfo", category: .watchSync)
        }
    }

    /// Writes the wings payload into the applicationContext, preserving other keys.
    /// - Returns: true on success
    private func updateWingsContext(with jsonData: Data) -> Bool {
        var context = WCSession.default.applicationContext
        context[WatchSyncKeys.wingsData] = jsonData.base64EncodedString()

        do {
            try WCSession.default.updateApplicationContext(context)
            return true
        } catch {
            logError("updateApplicationContext failed: \(error.localizedDescription)", category: .watchSync)
            return false
        }
    }

    /// Syncs a specific wing list to the Watch (used after reordering).
    /// Fast path: no photos.
    func syncWingsToWatch(wings: [Wing]) {
        guard WCSession.default.activationState == .activated else {
            logWarning("WCSession not activated, cannot sync wings", category: .watchSync)
            return
        }

        let wingsDTONoPhotos = wings.map { $0.toDTOWithoutPhoto() }

        guard let jsonData = try? JSONEncoder().encode(wingsDTONoPhotos) else {
            logError("Failed to encode wings for sync", category: .watchSync)
            return
        }

        if updateWingsContext(with: jsonData) {
            logInfo("Synced \(wingsDTONoPhotos.count) wings to Watch (reordered)", category: .watchSync)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            logError("WCSession activation failed: \(error.localizedDescription)", category: .watchSync)
            return
        }

        logInfo("WCSession activated (state: \(activationState.rawValue))", category: .watchSync)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable

            // Automatically resync wings and settings on activation
            if activationState == .activated {
                self.sendWingsToWatch()

                let autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
                let allowDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
                self.sendWatchSettings(autoWaterLock: autoWaterLock, allowSessionDismiss: allowDismiss)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        logDebug("WCSession became inactive", category: .watchSync)
    }

    func sessionDidDeactivate(_ session: WCSession) {
        logInfo("WCSession deactivated - reactivating...", category: .watchSync)
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.isWatchReachable = session.isReachable
            logDebug("Watch reachability changed: \(session.isReachable)", category: .watchSync)
        }
    }

    /// isWatchAppInstalled was only ever read once, at activation — so a Watch
    /// app installed (or a watch paired) after the iPhone app launched left
    /// Settings claiming "Watch App: Not installed" until the next cold start,
    /// sending the user to debug a setup that actually works. This is the
    /// callback Apple provides for exactly those transitions.
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.isWatchAppInstalled = session.isWatchAppInstalled
            self?.isWatchReachable = session.isReachable
            logDebug(
                "Watch state changed: paired=\(session.isPaired) installed=\(session.isWatchAppInstalled)",
                category: .watchSync
            )
        }
    }

    // MARK: - Receive Flight from Watch

    /// Instant message with reply handler (fast path when the iPhone is reachable)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        logDebug("Received instant message from Watch: \(message.keys)", category: .watchSync)

        // Settings changed on the Watch?
        if message[WatchSyncKeys.watchSettingsUpdate] as? Bool == true {
            applyWatchSettings(message)
            replyHandler(["status": "success"])
            return
        }

        // Wings sync request?
        if let action = message["action"] as? String, action == "requestWings" {
            logInfo("Watch requested wings sync", category: .watchSync)
            DispatchQueue.main.async { [weak self] in
                self?.sendWingsToWatch()
            }
            replyHandler(["status": "success"])
            return
        }

        // Flight started on the Watch? Best-effort live presence (Step C2).
        if message[WatchSyncKeys.flightStarted] as? Bool == true {
            handleFlightStarted(message)
            replyHandler(["status": "success"])
            return
        }

        // Otherwise it should be a flight
        guard let dto = Self.decodeFlightDTO(from: message) else {
            logWarning("Received message is not a valid flight payload", category: .watchSync)
            replyHandler([WatchSyncKeys.flightSaved: false, "error": "Invalid flight data"])
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleIncomingFlight(dto, replyHandler: replyHandler)
        }
    }

    /// Message without reply handler
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        logDebug("Received message from Watch (no reply): \(message.keys)", category: .watchSync)

        if message[WatchSyncKeys.watchSettingsUpdate] as? Bool == true {
            applyWatchSettings(message)
            return
        }

        if let action = message["action"] as? String, action == "requestWings" {
            logInfo("Watch requested wings sync", category: .watchSync)
            DispatchQueue.main.async { [weak self] in
                self?.sendWingsToWatch()
            }
            return
        }

        // Flight started on the Watch? Best-effort live presence (Step C2).
        if message[WatchSyncKeys.flightStarted] as? Bool == true {
            handleFlightStarted(message)
            return
        }

        if let dto = Self.decodeFlightDTO(from: message) {
            DispatchQueue.main.async { [weak self] in
                self?.handleIncomingFlight(dto, replyHandler: nil)
            }
        }
    }

    /// Persistent delivery path (transferUserInfo, survives unreachability).
    /// The same flight may also have arrived via sendMessage - dedup by UUID.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        logInfo("Received userInfo from Watch", category: .watchSync)

        if userInfo[WatchSyncKeys.watchSettingsUpdate] as? Bool == true {
            applyWatchSettings(userInfo)
            return
        }

        guard let dto = Self.decodeFlightDTO(from: userInfo) else {
            logWarning("Received userInfo is not a flight - ignoring", category: .watchSync)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleIncomingFlight(dto, replyHandler: nil)
        }
    }

    // MARK: - Pull-to-refresh support

    /// Asks the Watch to re-attempt delivery of any flights still in its outbox.
    /// Used by pull-to-refresh on the Flights list. No-op when unreachable —
    /// the Watch retries on reconnection anyway.
    func requestWatchOutboxFlush() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["action": "flushOutbox"], replyHandler: nil) { error in
            logWarning("Outbox flush request failed: \(error.localizedDescription)", category: .watchSync)
        }
    }

    // MARK: - Settings from Watch (two-way sync)

    /// Set while a Watch-originated settings change is being applied locally.
    /// The Settings UI checks this to avoid echoing the change straight back
    /// to the Watch (anti-loop guard).
    private var lastRemoteSettingsApply: Date?

    /// True right after settings arrived FROM the Watch — used by the iPhone
    /// settings toggles to skip re-sending what the Watch just told us.
    var isApplyingRemoteSettings: Bool {
        guard let last = lastRemoteSettingsApply else { return false }
        return Date().timeIntervalSince(last) < 1.5
    }

    /// Applies settings changed on the Watch to the iPhone's UserDefaults so the
    /// iPhone UI (all @AppStorage-backed) reflects them. Only writes values that
    /// actually differ, so unchanged keys never trigger UI onChange handlers.
    private func applyWatchSettings(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            let defaults = UserDefaults.standard
            // UserDefaultsKeys.varioEnabled is deliberately absent: that key
            // drives the PHONE's timer vario, while the Watch payload's
            // "varioEnabled" described the watch-local vario. Older queued
            // payloads may still carry the key — it is ignored here.
            let keys = [
                UserDefaultsKeys.watchAutoWaterLock,
                UserDefaultsKeys.watchAllowSessionDismiss,
                UserDefaultsKeys.simulateFlightEnabled
            ]
            var changed = false
            for key in keys {
                if let v = payload[key] as? Bool, defaults.object(forKey: key) as? Bool != v {
                    self?.lastRemoteSettingsApply = Date()
                    defaults.set(v, forKey: key)
                    changed = true
                }
            }
            if changed {
                logInfo("Applied settings changed on the Watch", category: .watchSync)
            }
        }
    }

    // MARK: - Live Presence (Step C2)

    /// Handles the ephemeral "flight started" signal from the Watch:
    /// [WatchSyncKeys.flightStarted: true, "latitude": Double, "longitude": Double].
    /// Resolves the spot name from the takeoff coordinates (nearest known
    /// spot within 1.5 km, else "Unknown spot") and starts the opt-in
    /// presence heartbeat. Fully best-effort: presence is ephemeral, the
    /// signal is never retried and failures are only logged.
    private func handleFlightStarted(_ payload: [String: Any]) {
        let latitude = payload["latitude"] as? Double
        let longitude = payload["longitude"] as? Double

        DispatchQueue.main.async { [weak self] in
            guard let latitude, let longitude else {
                logDebug("Flight-started signal without coordinates - skipping presence", category: .community)
                return
            }

            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let spot = self?.dataController?.nearestSpot(to: coordinate, within: 1500)
            let spotName = spot?.name ?? "Unknown spot"
            // Prefer the spot's canonical community key (its own coordinates)
            // so presence and shared flights aggregate under the same key.
            let spotKey = spot.flatMap {
                $0.communitySpotKey ?? CommunitySpotKey.make(name: $0.name, latitude: $0.latitude, longitude: $0.longitude)
            }

            CommunityService.shared.startPresence(
                latitude: spot?.latitude ?? latitude,
                longitude: spot?.longitude ?? longitude,
                spotName: spotName,
                spotKey: spotKey
            )
        }
    }

    // MARK: - Flight Handling

    /// Decodes a FlightDTO from a Watch payload.
    /// Primary format: WatchSyncKeys.flightData = JSON Data (also accepts a
    /// base64 String). Legacy format: "flight" = dictionary.
    private static func decodeFlightDTO(from payload: [String: Any]) -> FlightDTO? {
        let decoder = JSONDecoder()

        if let data = payload[WatchSyncKeys.flightData] as? Data {
            return try? decoder.decode(FlightDTO.self, from: data)
        }

        if let base64 = payload[WatchSyncKeys.flightData] as? String,
           let data = Data(base64Encoded: base64) {
            return try? decoder.decode(FlightDTO.self, from: data)
        }

        // Legacy payload from older Watch app versions
        if let flightDict = payload["flight"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: flightDict) {
            return try? decoder.decode(FlightDTO.self, from: data)
        }

        return nil
    }

    /// Saves an incoming flight IMMEDIATELY, then resolves the location in the
    /// background. Must be called on the main queue.
    ///
    /// - An already-existing flight id is a success (the Watch retries until acked).
    /// - The reply is sent only after the SwiftData save succeeded.
    private func handleIncomingFlight(_ dto: FlightDTO, replyHandler: (([String: Any]) -> Void)?) {
        guard let dataController = dataController else {
            logError("DataController not available - cannot save flight", category: .flight)
            replyHandler?([WatchSyncKeys.flightSaved: false, "error": "Data store unavailable"])
            return
        }

        // Deduplication: already saved = success. Checked FIRST so a
        // re-delivered duplicate never touches presence.
        if dataController.flightExists(id: dto.id) {
            logInfo("Flight \(dto.id) already saved - acknowledging duplicate", category: .flight)
            replyHandler?([
                WatchSyncKeys.flightSaved: true,
                WatchSyncKeys.flightId: dto.id.uuidString
            ])
            return
        }

        // Receiving a FRESH flight means it just ENDED — clear any live
        // presence heartbeat (best-effort, no-op when signed out). A stale
        // outbox flight delivered hours later must NOT wipe the presence of
        // a flight that may be airborne right now, so only flights that
        // landed within the last 15 minutes end presence.
        if Date().timeIntervalSince(dto.endDate) < 15 * 60 {
            CommunityService.shared.endPresence()
        }

        // Save immediately, without waiting for any location fix
        let saved = dataController.addFlight(from: dto, location: nil, spotName: nil)

        if saved {
            // Remember the wing so pickers pre-select it next time
            UserDefaults.standard.set(dto.wingId.uuidString, forKey: UserDefaultsKeys.lastUsedWingId)
            replyHandler?([
                WatchSyncKeys.flightSaved: true,
                WatchSyncKeys.flightId: dto.id.uuidString
            ])
            // Location + spot name are best-effort and updated afterwards.
            // LocationService enforces a 10s timeout, the flight is already safe.
            resolveFlightLocation(flightId: dto.id)
        } else {
            logError("Failed to persist flight \(dto.id)", category: .flight)
            replyHandler?([WatchSyncKeys.flightSaved: false, "error": "Save failed"])
        }
    }

    /// Background reverse geocoding for a flight that is already persisted.
    /// Also triggers the best-effort takeoff weather snapshot once the
    /// deferred enrichment settled (the flight may carry coordinates from its
    /// GPS track even when no fresh location fix arrives).
    private func resolveFlightLocation(flightId: UUID) {
        guard let locationService = locationService else {
            captureTakeoffWeather(flightId: flightId)
            return
        }

        locationService.requestLocation { [weak self] location in
            guard let location = location else {
                logInfo("No location fix for flight \(flightId) - keeping it without a spot", category: .flight)
                DispatchQueue.main.async {
                    self?.captureTakeoffWeather(flightId: flightId)
                }
                return
            }

            self?.locationService?.reverseGeocode(location: location) { spotName in
                DispatchQueue.main.async {
                    self?.dataController?.updateFlightLocation(flightId: flightId, location: location, spotName: spotName)
                    self?.captureTakeoffWeather(flightId: flightId)
                }
            }
        }
    }

    /// Best-effort weather-at-takeoff snapshot for a flight that is already
    /// saved and ACKed. Fire-and-forget: it never blocks or fails the
    /// save/ACK path, skips flights without coordinates, and respects the
    /// "Record weather at takeoff" setting.
    private func captureTakeoffWeather(flightId: UUID) {
        guard let dataController = dataController else { return }
        // Only snapshot when the takeoff coordinates are trustworthy: the
        // flight carries a GPS track, whose first fix is the real takeoff
        // point (a track is also the only way a Watch DTO provides
        // coordinates). Without a track, the flight's coordinates were
        // back-filled from the phone's CURRENT location at sync time —
        // potentially hours late and kilometers away from the takeoff —
        // and a snapshot there would record wrong data, not missing data.
        guard let flight = dataController.findFlight(byId: flightId),
              flight.gpsTrackData != nil else {
            logDebug("Takeoff weather skipped for flight \(flightId): no GPS track, coordinates are sync-time only", category: .weather)
            return
        }
        WeatherService.shared.captureSnapshot(for: flightId, dataController: dataController)
    }
}
