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
        Task { @MainActor [weak self] in
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
        }, errorHandler: { [weak self] error in
            // Fallback sur transferUserInfo
            watchLogWarning("sendMessage failed, using transferUserInfo: \(error.localizedDescription)", category: .watchSync)
            self?.sendFlightToPhone(flight)
            completion(false, nil)
        })
    }

    /// Demande à l'iPhone d'envoyer les Wings (utile si on n'a rien reçu au démarrage)
    func requestWingsFromPhone() {
        guard sessionActivated, isPhoneReachable else { return }
        let message = ["action": "requestWings"]
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            watchLogWarning("requestWingsFromPhone failed: \(error.localizedDescription)", category: .watchSync)
        }
    }

    // MARK: - Live Flight

    /// Notifie l'iPhone qu'un vol en direct démarre
    func notifyLiveFlightStart(
        wingName: String?,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        guard sessionActivated else {
            completion?(false, nil)
            return
        }

        var message: [String: Any] = ["action": "startLiveFlight"]
        if let wingName = wingName { message["wingName"] = wingName }
        if let lat = latitude { message["latitude"] = lat }
        if let lon = longitude { message["longitude"] = lon }
        if let alt = altitude { message["altitude"] = alt }

        if isPhoneReachable {
            WCSession.default.sendMessage(message, replyHandler: { reply in
                let status = reply["status"] as? String
                let spotName = reply["spotName"] as? String
                completion?(status == "success", spotName)
            }, errorHandler: { error in
                watchLogWarning("notifyLiveFlightStart failed: \(error.localizedDescription)", category: .watchSync)
                completion?(false, nil)
            })
        } else {
            // L'iPhone n'est pas joignable, on ne peut pas démarrer le live flight
            watchLogWarning("iPhone not reachable for live flight start", category: .watchSync)
            completion?(false, nil)
        }
    }

    /// Notifie l'iPhone qu'un vol en direct se termine
    func notifyLiveFlightEnd(completion: ((Bool) -> Void)? = nil) {
        guard sessionActivated else {
            completion?(false)
            return
        }

        let message: [String: Any] = ["action": "endLiveFlight"]

        if isPhoneReachable {
            WCSession.default.sendMessage(message, replyHandler: { reply in
                let status = reply["status"] as? String
                completion?(status == "success")
            }, errorHandler: { error in
                watchLogWarning("notifyLiveFlightEnd failed: \(error.localizedDescription)", category: .watchSync)
                completion?(false)
            })
        } else {
            watchLogWarning("iPhone not reachable for live flight end", category: .watchSync)
            completion?(false)
        }
    }

    /// Met à jour la position du vol en direct
    func updateLiveFlightLocation(
        latitude: Double,
        longitude: Double,
        altitude: Double?
    ) {
        guard sessionActivated, isPhoneReachable else { return }

        var message: [String: Any] = [
            "action": "updateLiveLocation",
            "latitude": latitude,
            "longitude": longitude
        ]
        if let alt = altitude { message["altitude"] = alt }

        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            // Silently fail - location updates are best effort
            watchLogDebug("updateLiveFlightLocation failed: \(error.localizedDescription)", category: .watchSync)
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

        // Essayer de récupérer le dernier contexte disponible
        if activationState == .activated {
            let context = session.applicationContext
            if !context.isEmpty {
                watchLogInfo("Processing applicationContext on activation (\(context.keys.count) keys)", category: .watchSync)
                processReceivedContext(context)
            }

            // Toujours demander une mise à jour fraîche à l'iPhone
            // pour s'assurer d'avoir les dernières données (voiles supprimées, etc.)
            if isPhoneReachable {
                watchLogInfo("Requesting fresh wings from iPhone", category: .watchSync)
                requestWingsFromPhone()
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let wasReachable = isPhoneReachable
        isPhoneReachable = session.isReachable

        // Si l'iPhone devient joignable, demander une mise à jour des voiles
        // pour s'assurer d'avoir les dernières données
        if !wasReachable && isPhoneReachable {
            watchLogInfo("iPhone became reachable, requesting wings sync", category: .watchSync)
            requestWingsFromPhone()
        }
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
            Task.detached(priority: .userInitiated) {
                guard let decodedWings = try? JSONDecoder().decode([WingDTO].self, from: jsonData) else {
                    return
                }
                let sortedWings = decodedWings.sorted { $0.displayOrder < $1.displayOrder }

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    // Ne mettre à jour que si les données ont changé
                    // pour éviter les re-renders inutiles
                    guard self.wingsHaveChanged(sortedWings) else { return }
                    // Vider le cache d'images car les données ont changé
                    WatchImageCache.shared.clearCache()
                    self.wings = sortedWings
                    self.saveWingsLocally()
                }
            }
            return
        }

        // Ancien format (compatibilité) : wings en [[String: Any]]
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
                    // Vider le cache d'images car les données ont changé
                    WatchImageCache.shared.clearCache()
                    self.wings = sortedWings
                    self.saveWingsLocally()
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
               wing.photoData != newWing.photoData {
                return true
            }
        }
        return false
    }

    #if os(watchOS)
    // Pas besoin d'implémenter sessionDidBecomeInactive/sessionDidDeactivate sur watchOS
    #endif
}
