//
//  WatchConnectivityManager.swift
//  ParaFlightLogWatch Watch App
//
//  Gestion de WatchConnectivity côté Apple Watch
//  - Reçoit la liste des Wings depuis l'iPhone
//  - Envoie les FlightDTO vers l'iPhone
//  Target: Watch only
//

import Foundation
import WatchConnectivity

@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    // Liste des voiles reçues de l'iPhone
    var wings: [WingDTO] = []

    // État de la connexion
    var isPhoneReachable: Bool = false
    var sessionActivated: Bool = false

    private override init() {
        super.init()
        let initStart = Date()
        print("⏱️ [PERF] WatchConnectivityManager.init() START")

        // Charger les voiles de manière asynchrone pour ne pas bloquer l'UI
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.loadWingsAsync()
        }
        // Activer la session WatchConnectivity en arrière-plan
        Task.detached(priority: .background) { [weak self] in
            self?.activateSession()
        }

        let initTime = Date().timeIntervalSince(initStart) * 1000
        print("⏱️ [PERF] WatchConnectivityManager.init() DONE (\(String(format: "%.1f", initTime))ms)")
    }

    // MARK: - Local Persistence

    private func saveWingsLocally() {
        // Sauvegarder en arrière-plan
        let wingsToSave = wings
        Task.detached(priority: .background) {
            if let encoded = try? JSONEncoder().encode(wingsToSave) {
                UserDefaults.standard.set(encoded, forKey: "savedWings")
                print("💾 Saved \(wingsToSave.count) wings to local storage")
            }
        }
    }
    
    @MainActor
    private func loadWingsAsync() async {
        let loadStart = Date()
        print("⏱️ [PERF] loadWingsAsync() START")

        if let data = UserDefaults.standard.data(forKey: "savedWings"),
           let decoded = try? JSONDecoder().decode([WingDTO].self, from: data) {
            // Mettre à jour les wings sur le main thread
            wings = decoded
            let loadTime = Date().timeIntervalSince(loadStart) * 1000
            print("⏱️ [PERF] loadWingsAsync() DONE (\(String(format: "%.1f", loadTime))ms) - Loaded \(wings.count) wings")
        } else {
            let loadTime = Date().timeIntervalSince(loadStart) * 1000
            print("⏱️ [PERF] loadWingsAsync() DONE (\(String(format: "%.1f", loadTime))ms) - No wings found")
        }
    }

    private func loadWingsFromLocal() {
        if let data = UserDefaults.standard.data(forKey: "savedWings"),
           let decoded = try? JSONDecoder().decode([WingDTO].self, from: data) {
            wings = decoded
            print("📂 Loaded \(wings.count) wings from local storage")
        }
    }

    // MARK: - Session Activation

    /// Active la session WatchConnectivity
    func activateSession() {
        let activateStart = Date()
        print("⏱️ [PERF] activateSession() START")

        guard WCSession.isSupported() else {
            print("⚠️ WatchConnectivity not supported")
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()

        let activateTime = Date().timeIntervalSince(activateStart) * 1000
        print("⏱️ [PERF] activateSession() DONE (\(String(format: "%.1f", activateTime))ms) - Session activating...")
    }

    // MARK: - Send Flight to iPhone

    /// Envoie un vol terminé vers l'iPhone
    func sendFlightToPhone(_ flight: FlightDTO) {
        guard sessionActivated else {
            print("❌ WCSession not activated")
            return
        }

        // Encoder le FlightDTO en dictionnaire
        guard let data = try? JSONEncoder().encode(flight),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Failed to encode flight")
            return
        }

        let userInfo = ["flight": json]

        // Utiliser transferUserInfo pour envoyer en arrière-plan
        WCSession.default.transferUserInfo(userInfo)
        print("✅ Flight sent to iPhone: \(flight.durationSeconds)s with wing \(flight.wingId)")
    }

    /// Envoie un vol avec réponse instantanée (nécessite que l'iPhone soit joignable)
    func sendFlightWithReply(_ flight: FlightDTO, completion: @escaping (Bool, String?) -> Void) {
        guard sessionActivated else {
            print("❌ WCSession not activated")
            completion(false, nil)
            return
        }

        guard isPhoneReachable else {
            print("⚠️ iPhone not reachable, using background transfer instead")
            sendFlightToPhone(flight)
            completion(true, nil)
            return
        }

        // Encoder le FlightDTO
        guard let data = try? JSONEncoder().encode(flight),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("❌ Failed to encode flight")
            completion(false, nil)
            return
        }

        let message = ["flight": json]

        // Envoyer avec réponse
        WCSession.default.sendMessage(message, replyHandler: { reply in
            let status = reply["status"] as? String
            let spotName = reply["spotName"] as? String
            print("✅ Flight sent with reply - spot: \(spotName ?? "Unknown")")
            completion(status == "success", spotName)
        }, errorHandler: { error in
            print("❌ Failed to send flight with reply: \(error.localizedDescription)")
            // Fallback sur transferUserInfo
            WCSession.default.transferUserInfo(message)
            completion(false, nil)
        })
    }

    /// Demande à l'iPhone d'envoyer les Wings (utile si on n'a rien reçu au démarrage)
    func requestWingsFromPhone() {
        guard sessionActivated else {
            print("❌ WCSession not activated")
            return
        }

        // Envoyer un message simple pour demander les Wings
        let message = ["action": "requestWings"]

        if isPhoneReachable {
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { error in
                print("❌ Failed to request wings: \(error.localizedDescription)")
            })
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("❌ WCSession activation failed: \(error.localizedDescription)")
            return
        }

        sessionActivated = (activationState == .activated)
        isPhoneReachable = session.isReachable
        print("✅ WCSession activated (state: \(activationState.rawValue))")

        // Essayer de récupérer le dernier contexte disponible
        if activationState == .activated {
            let context = session.applicationContext
            if !context.isEmpty {
                processReceivedContext(context)
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        isPhoneReachable = session.isReachable
        print("📡 iPhone reachability changed: \(isPhoneReachable)")
    }

    // MARK: - Receive Wings from iPhone

    /// Reçoit le contexte mis à jour depuis l'iPhone (liste des Wings)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        print("📥 Received application context from iPhone")
        processReceivedContext(applicationContext)
    }

    /// Reçoit des données via transferUserInfo (alternative)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        print("📥 Received user info from iPhone")
        processReceivedContext(userInfo)
    }

    /// Traite le contexte reçu (extraction des Wings et langue)
    private func processReceivedContext(_ context: [String: Any]) {
        print("🔍 Processing received context: \(context.keys)")

        // Extraire la langue si présente
        if context.keys.contains("language") {
            let languageCode = context["language"] as? String
            WatchLocalizationManager.shared.updateLanguage(from: languageCode)
        }

        // Nouveau format : wingsData en Base64
        if let base64String = context["wingsData"] as? String,
           let jsonData = Data(base64Encoded: base64String) {

            let dataSizeKB = Double(jsonData.count) / 1024.0
            print("📊 Received data size: \(String(format: "%.2f", dataSizeKB)) KB")

            guard let decodedWings = try? JSONDecoder().decode([WingDTO].self, from: jsonData) else {
                print("❌ Failed to decode WingDTO array from Base64")
                return
            }

            DispatchQueue.main.async {
                self.wings = decodedWings.sorted { $0.displayOrder < $1.displayOrder }
                self.saveWingsLocally()
                // OPTIMISATION: Images désactivées pour améliorer les performances
                // WatchImageCache.shared.preloadImages(for: self.wings)
                print("✅ Successfully received and stored \(self.wings.count) wings from iPhone (sorted by displayOrder)")
            }
            return
        }

        // Ancien format (compatibilité) : wings en [[String: Any]]
        if let wingsData = context["wings"] as? [[String: Any]] {
            print("🔍 Found \(wingsData.count) wings in context (legacy format)")

            guard let jsonData = try? JSONSerialization.data(withJSONObject: wingsData) else {
                print("❌ Failed to convert wings to JSON data")
                return
            }

            guard let decodedWings = try? JSONDecoder().decode([WingDTO].self, from: jsonData) else {
                print("❌ Failed to decode WingDTO array")
                return
            }

            DispatchQueue.main.async {
                self.wings = decodedWings.sorted { $0.displayOrder < $1.displayOrder }
                self.saveWingsLocally()
                // OPTIMISATION: Images désactivées pour améliorer les performances
                // WatchImageCache.shared.preloadImages(for: self.wings)
                print("✅ Successfully received and stored \(self.wings.count) wings from iPhone (legacy, sorted by displayOrder)")
            }
            return
        }

        print("⚠️ No valid wings data found in context")
    }

    #if os(watchOS)
    // Pas besoin d'implémenter sessionDidBecomeInactive/sessionDidDeactivate sur watchOS
    #endif
}
