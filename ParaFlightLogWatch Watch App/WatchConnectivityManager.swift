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

    // État de chargement pour éviter les re-renders pendant le décodage
    var isLoading: Bool = true

    private override init() {
        super.init()
        // Charger les voiles sauvegardées localement de manière synchrone
        // pour un affichage immédiat au lancement
        loadWingsSync()

        // Activer la session WatchConnectivity en arrière-plan
        Task.detached(priority: .background) { [weak self] in
            self?.activateSession()
        }
    }

    // MARK: - Local Persistence

    private func saveWingsLocally() {
        // Sauvegarder en arrière-plan
        let wingsToSave = wings
        Task.detached(priority: .background) {
            if let encoded = try? JSONEncoder().encode(wingsToSave) {
                UserDefaults.standard.set(encoded, forKey: "savedWings")
            }
        }
    }

    /// Charge les voiles de façon synchrone au démarrage
    /// Les données locales sont petites donc c'est rapide
    private func loadWingsSync() {
        if let data = UserDefaults.standard.data(forKey: "savedWings"),
           let decoded = try? JSONDecoder().decode([WingDTO].self, from: data) {
            wings = decoded
        }
        isLoading = false
    }

    // MARK: - Session Activation

    /// Active la session WatchConnectivity
    func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Send Flight to iPhone

    /// Envoie un vol terminé vers l'iPhone
    func sendFlightToPhone(_ flight: FlightDTO) {
        guard sessionActivated else { return }

        // Encoder le FlightDTO en dictionnaire
        guard let data = try? JSONEncoder().encode(flight),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let userInfo = ["flight": json]
        // Utiliser transferUserInfo pour envoyer en arrière-plan
        WCSession.default.transferUserInfo(userInfo)
    }

    /// Envoie un vol avec réponse instantanée (nécessite que l'iPhone soit joignable)
    func sendFlightWithReply(_ flight: FlightDTO, completion: @escaping (Bool, String?) -> Void) {
        guard sessionActivated else {
            completion(false, nil)
            return
        }

        guard isPhoneReachable else {
            sendFlightToPhone(flight)
            completion(true, nil)
            return
        }

        // Encoder le FlightDTO
        guard let data = try? JSONEncoder().encode(flight),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(false, nil)
            return
        }

        let message = ["flight": json]

        // Envoyer avec réponse
        WCSession.default.sendMessage(message, replyHandler: { reply in
            let status = reply["status"] as? String
            let spotName = reply["spotName"] as? String
            completion(status == "success", spotName)
        }, errorHandler: { [weak self] _ in
            // Fallback sur transferUserInfo
            self?.sendFlightToPhone(flight)
            completion(false, nil)
        })
    }

    /// Demande à l'iPhone d'envoyer les Wings (utile si on n'a rien reçu au démarrage)
    func requestWingsFromPhone() {
        guard sessionActivated, isPhoneReachable else { return }
        let message = ["action": "requestWings"]
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard error == nil else { return }

        sessionActivated = (activationState == .activated)
        isPhoneReachable = session.isReachable

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
    }

    // MARK: - Receive Wings from iPhone

    /// Reçoit le contexte mis à jour depuis l'iPhone (liste des Wings)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        processReceivedContext(applicationContext)
    }

    /// Reçoit des données via transferUserInfo (alternative)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        processReceivedContext(userInfo)
    }

    /// Traite le contexte reçu (extraction des Wings, langue et settings)
    private func processReceivedContext(_ context: [String: Any]) {
        // Extraire la langue si présente
        if context.keys.contains("language") {
            let languageCode = context["language"] as? String
            WatchLocalizationManager.shared.updateLanguage(from: languageCode)
        }

        // Extraire les paramètres Watch si présents
        WatchSettings.shared.updateFromContext(context)

        // Nouveau format : wingsData en Base64 - Décoder en background
        if let base64String = context["wingsData"] as? String,
           let jsonData = Data(base64Encoded: base64String) {

            // Décoder en background pour ne pas bloquer l'UI
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let decodedWings = try? JSONDecoder().decode([WingDTO].self, from: jsonData) else {
                    return
                }
                let sortedWings = decodedWings.sorted { $0.displayOrder < $1.displayOrder }

                await MainActor.run {
                    // Ne mettre à jour que si les données ont changé
                    // pour éviter les re-renders inutiles
                    guard self?.wingsHaveChanged(sortedWings) == true else { return }
                    // Vider le cache d'images car les photos peuvent avoir changé
                    self?.clearImageCache()
                    self?.wings = sortedWings
                    self?.saveWingsLocally()
                }
            }
            return
        }

        // Ancien format (compatibilité) : wings en [[String: Any]]
        if let wingsData = context["wings"] as? [[String: Any]] {
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let jsonData = try? JSONSerialization.data(withJSONObject: wingsData),
                      let decodedWings = try? JSONDecoder().decode([WingDTO].self, from: jsonData) else {
                    return
                }
                let sortedWings = decodedWings.sorted { $0.displayOrder < $1.displayOrder }

                await MainActor.run {
                    guard self?.wingsHaveChanged(sortedWings) == true else { return }
                    // Vider le cache d'images car les photos peuvent avoir changé
                    self?.clearImageCache()
                    self?.wings = sortedWings
                    self?.saveWingsLocally()
                }
            }
        }
    }

    /// Compare les nouvelles wings avec les existantes pour éviter les re-renders inutiles
    private func wingsHaveChanged(_ newWings: [WingDTO]) -> Bool {
        guard wings.count == newWings.count else { return true }
        for (index, wing) in wings.enumerated() {
            let newWing = newWings[index]
            if wing.id != newWing.id ||
               wing.name != newWing.name ||
               wing.size != newWing.size ||
               wing.displayOrder != newWing.displayOrder ||
               wing.photoData?.count != newWing.photoData?.count {
                return true
            }
        }
        return false
    }

    /// Vide le cache d'images (à appeler quand les voiles changent)
    private func clearImageCache() {
        WatchImageCache.shared.clearCache()
    }

    #if os(watchOS)
    // Pas besoin d'implémenter sessionDidBecomeInactive/sessionDidDeactivate sur watchOS
    #endif
}
