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

    // MARK: - Send Wings to Watch

    /// Envoie la liste des voiles vers la Watch
    func sendWingsToWatch() {
        guard let dataController = dataController else {
            print("❌ DataController not available")
            return
        }

        // Si la session n'est pas activée, réessayer après 1 seconde
        guard WCSession.default.activationState == .activated else {
            print("⚠️ WCSession not activated yet, will retry in 1 second...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendWingsToWatch()
            }
            return
        }

        let wings = dataController.fetchWings()
        let wingsDTO = wings.map { $0.toDTO() }

        print("📤 Attempting to send \(wingsDTO.count) wings to Watch...")

        // Encoder en dictionnaire pour WatchConnectivity
        guard let data = try? JSONEncoder().encode(wingsDTO) else {
            print("❌ Failed to encode wings to JSON data")
            return
        }

        // Vérifier la taille des données
        let dataSizeKB = Double(data.count) / 1024.0
        print("📊 Encoded data size: \(String(format: "%.2f", dataSizeKB)) KB")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("❌ Failed to convert data to JSON object")
            return
        }

        let context = ["wings": json]

        do {
            try WCSession.default.updateApplicationContext(context)
            print("✅ Sent \(wingsDTO.count) wings to Watch via updateApplicationContext")
        } catch {
            print("❌ Failed to send wings: \(error.localizedDescription)")
            print("   Error details: \(error)")
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
        let wingsDTO = wings.map { $0.toDTO() }

        print("📤 Attempting to transfer \(wingsDTO.count) wings to Watch...")

        guard let data = try? JSONEncoder().encode(wingsDTO),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("❌ Failed to encode wings")
            return
        }

        let userInfo = ["wings": json]
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

        // Envoyer automatiquement les voiles à l'activation
        if activationState == .activated {
            sendWingsToWatch()
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
        print("📨 Received instant message from Watch")

        // Même logique que didReceiveUserInfo mais avec réponse
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
}
