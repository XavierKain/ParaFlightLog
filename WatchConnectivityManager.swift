//
//  WatchConnectivityManager.swift
//  ParaFlightLog
//
//  Gestion de WatchConnectivity côté iPhone
//  - Envoie la liste des Wings vers la Watch
//  - Reçoit les FlightDTO depuis la Watch
//  Target: iOS only
//

import Foundation
import WatchConnectivity

@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    var isWatchAppInstalled: Bool = false
    var isWatchReachable: Bool = false

    // Références aux services (injectées depuis l'App)
    weak var dataController: DataController?
    weak var locationService: LocationService?

    private override init() {
        super.init()
        // Note: La session sera activée après injection du dataController
    }

    // MARK: - Session Activation

    /// Active la session WatchConnectivity
    func activateSession() {
        guard WCSession.isSupported() else {
            print("⚠️ WatchConnectivity not supported on this device")
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        print("🔗 WatchConnectivity session activating...")
    }

    // MARK: - Send Language to Watch

    /// Envoie la langue sélectionnée vers la Watch
    func sendLanguageToWatch(_ languageCode: String?) {
        guard WCSession.default.activationState == .activated else {
            print("⚠️ WCSession not activated, cannot send language")
            return
        }

        var context = WCSession.default.applicationContext
        
        if let code = languageCode {
            context["language"] = code
        } else {
            context.removeValue(forKey: "language")
        }

        do {
            try WCSession.default.updateApplicationContext(context)
            print("🌐 Sent language to Watch: \(languageCode ?? "system")")
        } catch {
            print("❌ Failed to send language: \(error.localizedDescription)")
        }
    }

    // MARK: - Send Wings to Watch

    /// Envoie la liste des voiles vers la Watch
    /// Utilise des miniatures très compressées (24x24 JPEG) pour les icônes
    func sendWingsToWatch() {
        guard let dataController = dataController else {
            return
        }

        // Si la session n'est pas activée, réessayer après 1 seconde
        guard WCSession.default.activationState == .activated else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendWingsToWatch()
            }
            return
        }

        // Envoyer avec miniatures très compressées (~0.5-1KB par image)
        sendWingsWithThumbnails()
    }

    /// Envoie les voiles avec miniatures compressées
    private func sendWingsWithThumbnails() {
        guard let dataController = dataController else { return }

        let wings = dataController.fetchWings()
        let wingsDTOWithThumbnails = wings.map { $0.toDTOWithThumbnail() }

        guard let jsonData = try? JSONEncoder().encode(wingsDTOWithThumbnails) else {
            sendWingsWithoutPhotos()
            return
        }

        let dataSizeKB = Double(jsonData.count) / 1024.0

        // Si les données dépassent 50KB, envoyer sans images
        if dataSizeKB > 50 {
            sendWingsWithoutPhotos()
            return
        }

        let base64String = jsonData.base64EncodedString()
        let context = ["wingsData": base64String]

        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            sendWingsWithoutPhotos()
        }
    }

    /// Envoie les voiles sans photos (fallback)
    private func sendWingsWithoutPhotos() {
        guard let dataController = dataController else { return }

        let wings = dataController.fetchWings()
        let wingsDTONoPhotos = wings.map { $0.toDTOWithoutPhoto() }

        guard let jsonData = try? JSONEncoder().encode(wingsDTONoPhotos) else {
            return
        }

        let base64String = jsonData.base64EncodedString()
        let context = ["wingsData": base64String]

        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            WCSession.default.transferUserInfo(context)
        }
    }

    /// Synchronise les voiles avec la Watch (utilisé après réorganisation)
    func syncWingsToWatch(wings: [Wing]) {
        guard WCSession.default.activationState == .activated else {
            print("⚠️ WCSession not activated, cannot sync wings")
            return
        }

        // Convertir en DTO sans photos pour une synchronisation rapide
        let wingsDTONoPhotos = wings.map { $0.toDTOWithoutPhoto() }

        guard let jsonData = try? JSONEncoder().encode(wingsDTONoPhotos) else {
            print("❌ Failed to encode wings for sync")
            return
        }

        let base64String = jsonData.base64EncodedString()
        let context = ["wingsData": base64String]

        do {
            try WCSession.default.updateApplicationContext(context)
            print("✅ Synced \(wingsDTONoPhotos.count) wings to Watch (reordered)")
        } catch {
            print("❌ Failed to sync wings: \(error.localizedDescription)")
        }
    }

    /// Envoie la liste des voiles via transferUserInfo (alternative si updateApplicationContext échoue)
    func sendWingsViaTransfer() {
        guard let dataController = dataController else {
            print("❌ DataController not available")
            return
        }

        // Si la session n'est pas activée, réessayer après 1 seconde
        guard WCSession.default.activationState == .activated else {
            print("⚠️ WCSession not activated yet for transfer, will retry in 1 second...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendWingsViaTransfer()
            }
            return
        }

        let wings = dataController.fetchWings()
        // Sans photos pour le transfer
        let wingsDTO = wings.map { $0.toDTOWithoutPhoto() }

        print("📤 Attempting to transfer \(wingsDTO.count) wings to Watch (without photos)...")

        guard let jsonData = try? JSONEncoder().encode(wingsDTO) else {
            print("❌ Failed to encode wings")
            return
        }

        let base64String = jsonData.base64EncodedString()
        let userInfo = ["wingsData": base64String]

        WCSession.default.transferUserInfo(userInfo)
        print("✅ Transferred \(wingsDTO.count) wings to Watch via transferUserInfo")
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("❌ WCSession activation failed: \(error.localizedDescription)")
            return
        }

        print("✅ WCSession activated (state: \(activationState.rawValue))")
        isWatchAppInstalled = session.isWatchAppInstalled
        isWatchReachable = session.isReachable

        // Envoyer automatiquement les voiles et la langue à l'activation
        if activationState == .activated {
            sendWingsToWatch()
            
            // Envoyer la langue courante
            let languageCode = LocalizationManager.shared.currentLanguage?.rawValue
            sendLanguageToWatch(languageCode)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("⏸️ WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("🔌 WCSession deactivated - reactivating...")
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        isWatchReachable = session.isReachable
        print("📡 Watch reachability changed: \(isWatchReachable)")
    }

    // MARK: - Receive Flight from Watch

    /// Reçoit un vol depuis la Watch via transferUserInfo
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        print("📥 Received data from Watch")

        // Vérifier si c'est un vol
        if let flightData = userInfo["flight"] as? [String: Any],
           let jsonData = try? JSONSerialization.data(withJSONObject: flightData),
           let flightDTO = try? JSONDecoder().decode(FlightDTO.self, from: jsonData) {

            print("✅ Received flight: \(flightDTO.durationSeconds)s with wing \(flightDTO.wingId)")

            // Obtenir la position GPS + reverse geocoding
            locationService?.requestLocation { [weak self] location in
                var spotName: String?

                if let location = location {
                    // Faire le reverse geocoding
                    self?.locationService?.reverseGeocode(location: location) { spot in
                        spotName = spot

                        // Sauvegarder le vol
                        DispatchQueue.main.async {
                            self?.dataController?.addFlight(from: flightDTO, location: location, spotName: spotName)
                        }
                    }
                } else {
                    // Pas de localisation disponible, sauvegarder quand même
                    DispatchQueue.main.async {
                        self?.dataController?.addFlight(from: flightDTO, location: nil, spotName: nil)
                    }
                }
            }
            return
        }

        print("⚠️ Received userInfo is not a flight - ignoring")
    }

    /// Reçoit un message instantané depuis la Watch (alternative plus rapide)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        print("📨 Received instant message from Watch: \(message.keys)")

        // Vérifier si c'est une demande de synchronisation des voiles
        if let action = message["action"] as? String, action == "requestWings" {
            print("📥 Watch requested wings sync")
            DispatchQueue.main.async { [weak self] in
                self?.sendWingsToWatch()
            }
            replyHandler(["status": "success", "message": "Wings sync triggered"])
            return
        }

        // Sinon, c'est un vol
        guard let flightData = message["flight"] as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: flightData),
              let flightDTO = try? JSONDecoder().decode(FlightDTO.self, from: jsonData) else {
            replyHandler(["status": "error", "message": "Invalid flight data"])
            return
        }

        // Obtenir la position GPS
        locationService?.requestLocation { [weak self] location in
            var spotName: String?

            if let location = location {
                self?.locationService?.reverseGeocode(location: location) { spot in
                    spotName = spot

                    DispatchQueue.main.async {
                        self?.dataController?.addFlight(from: flightDTO, location: location, spotName: spotName)
                        replyHandler(["status": "success", "spotName": spotName ?? "Unknown"])
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self?.dataController?.addFlight(from: flightDTO, location: nil, spotName: nil)
                    replyHandler(["status": "success", "spotName": "Unknown"])
                }
            }
        }
    }

    /// Reçoit un message sans réponse attendue
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("📨 Received message from Watch (no reply): \(message.keys)")

        // Vérifier si c'est une demande de synchronisation des voiles
        if let action = message["action"] as? String, action == "requestWings" {
            print("📥 Watch requested wings sync")
            DispatchQueue.main.async { [weak self] in
                self?.sendWingsToWatch()
            }
        }
    }
}
