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

    // État de synchronisation avec retry robuste
    private var syncRetryCount = 0
    private var isSyncing = false

    // Debouncing pour éviter les syncs trop fréquentes
    private var pendingSyncWorkItem: DispatchWorkItem?
    private let syncDebounceInterval: TimeInterval = 0.5

    private override init() {
        super.init()
        // Note: La session sera activée après injection du dataController
    }

    // MARK: - Session Activation

    /// Active la session WatchConnectivity
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

    // MARK: - Send Language to Watch

    /// Envoie la langue sélectionnée vers la Watch
    func sendLanguageToWatch(_ languageCode: String?) {
        guard WCSession.default.activationState == .activated else {
            logWarning("WCSession not activated, cannot send language", category: .watchSync)
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
            logInfo("Sent language to Watch: \(languageCode ?? "system")", category: .watchSync)
        } catch {
            logError("Failed to send language: \(error.localizedDescription)", category: .watchSync)
        }
    }

    // MARK: - Send Watch Settings

    /// Envoie les paramètres Watch vers la Watch
    func sendWatchSettings(autoWaterLock: Bool, allowSessionDismiss: Bool, developerMode: Bool? = nil) {
        guard WCSession.default.activationState == .activated else {
            logWarning("WCSession not activated, cannot send watch settings", category: .watchSync)
            return
        }

        var context = WCSession.default.applicationContext
        context[UserDefaultsKeys.watchAutoWaterLock] = autoWaterLock
        context[UserDefaultsKeys.watchAllowSessionDismiss] = allowSessionDismiss

        // Inclure le mode développeur si spécifié, sinon lire depuis UserDefaults
        let devMode = developerMode ?? UserDefaults.standard.bool(forKey: UserDefaultsKeys.developerModeEnabled)
        context[UserDefaultsKeys.developerModeEnabled] = devMode

        do {
            try WCSession.default.updateApplicationContext(context)
            logInfo("Sent watch settings: autoWaterLock=\(autoWaterLock), allowDismiss=\(allowSessionDismiss), devMode=\(devMode)", category: .watchSync)
        } catch {
            logError("Failed to send watch settings: \(error.localizedDescription)", category: .watchSync)
        }
    }

    // MARK: - Send Wings to Watch

    /// Envoie la liste des voiles vers la Watch avec debouncing
    /// Utilise des miniatures très compressées pour les icônes
    /// Implémente un système de retry avec backoff exponentiel
    func sendWingsToWatch() {
        // Annuler toute sync en attente (debouncing)
        pendingSyncWorkItem?.cancel()

        // Créer un nouveau work item avec délai
        let workItem = DispatchWorkItem { [weak self] in
            self?.performWingsSync()
        }

        pendingSyncWorkItem = workItem

        // Programmer la sync après le délai de debounce
        DispatchQueue.main.asyncAfter(deadline: .now() + syncDebounceInterval, execute: workItem)
    }

    /// Exécute réellement la synchronisation des voiles
    private func performWingsSync() {
        guard dataController != nil else {
            logWarning("DataController not available for wing sync", category: .watchSync)
            return
        }

        // Éviter les syncs multiples en parallèle
        guard !isSyncing else {
            logDebug("Wing sync already in progress, skipping", category: .watchSync)
            return
        }

        // Si la session n'est pas activée, réessayer avec backoff exponentiel
        guard WCSession.default.activationState == .activated else {
            scheduleRetry()
            return
        }

        // Reset du compteur de retry et lancement de la sync
        syncRetryCount = 0
        isSyncing = true

        // Envoyer avec miniatures très compressées (~0.5-1KB par image)
        sendWingsWithThumbnails()
    }

    /// Planifie un retry avec backoff exponentiel
    private func scheduleRetry() {
        guard syncRetryCount < WatchSyncConstants.maxRetryAttempts else {
            logError("Max retry attempts (\(WatchSyncConstants.maxRetryAttempts)) reached for wing sync", category: .watchSync)
            syncRetryCount = 0
            isSyncing = false
            return
        }

        syncRetryCount += 1
        let delay = WatchSyncConstants.retryDelay * pow(WatchSyncConstants.backoffMultiplier, Double(syncRetryCount - 1))

        logDebug("Scheduling wing sync retry #\(syncRetryCount) in \(String(format: "%.1f", delay))s", category: .watchSync)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendWingsToWatch()
        }
    }

    /// Envoie les voiles avec miniatures compressées (en background pour ne pas bloquer l'UI)
    private func sendWingsWithThumbnails() {
        guard let dataController = dataController else {
            isSyncing = false
            return
        }

        let wings = dataController.fetchWings()
        // Capturer la constante avant d'entrer dans le Task.detached (isolation MainActor)
        let maxSizeKB = WatchSyncConstants.maxContextSizeKB

        // Traiter les images en background pour ne pas bloquer le main thread
        Task.detached(priority: .userInitiated) { [weak self] in
            let wingsDTOWithThumbnails = wings.map { $0.toDTOWithThumbnail() }

            guard let jsonData = try? JSONEncoder().encode(wingsDTOWithThumbnails) else {
                await MainActor.run { [weak self] in
                    self?.sendWingsWithoutPhotos()
                }
                return
            }

            let dataSizeKB = Double(jsonData.count) / 1024.0

            // Si les données dépassent la limite, envoyer sans images
            if dataSizeKB > maxSizeKB {
                await MainActor.run { [weak self] in
                    logWarning("Wings data too large (\(String(format: "%.1f", dataSizeKB))KB), sending without photos", category: .watchSync)
                    self?.sendWingsWithoutPhotos()
                }
                return
            }

            await MainActor.run { [weak self] in
                self?.finishSendingWings(jsonData: jsonData, withPhotos: true)
            }
        }
    }

    /// Finalise l'envoi des voiles (doit être appelé sur le main thread)
    private func finishSendingWings(jsonData: Data, withPhotos: Bool) {
        let base64String = jsonData.base64EncodedString()
        // IMPORTANT: Préserver le contexte existant (settings, langue, etc.)
        var context = WCSession.default.applicationContext
        context["wingsData"] = base64String

        do {
            try WCSession.default.updateApplicationContext(context)
            let dataSizeKB = Double(jsonData.count) / 1024.0
            logInfo("Wings synced to Watch (\(String(format: "%.1f", dataSizeKB))KB, photos: \(withPhotos))", category: .watchSync)
            isSyncing = false
        } catch {
            logError("Failed to sync wings: \(error.localizedDescription)", category: .watchSync)
            if withPhotos {
                sendWingsWithoutPhotos()
            } else {
                // Dernier recours : transferUserInfo
                WCSession.default.transferUserInfo(context)
                logInfo("Wings sent via transferUserInfo as fallback", category: .watchSync)
                isSyncing = false
            }
        }
    }

    /// Envoie les voiles sans photos (fallback)
    private func sendWingsWithoutPhotos() {
        guard let dataController = dataController else {
            isSyncing = false
            return
        }

        let wings = dataController.fetchWings()
        let wingsDTONoPhotos = wings.map { $0.toDTOWithoutPhoto() }

        guard let jsonData = try? JSONEncoder().encode(wingsDTONoPhotos) else {
            logError("Failed to encode wings without photos", category: .watchSync)
            isSyncing = false
            return
        }

        finishSendingWings(jsonData: jsonData, withPhotos: false)
    }

    /// Synchronise les voiles avec la Watch (utilisé après réorganisation)
    func syncWingsToWatch(wings: [Wing]) {
        guard WCSession.default.activationState == .activated else {
            logWarning("WCSession not activated, cannot sync wings", category: .watchSync)
            return
        }

        // Convertir en DTO sans photos pour une synchronisation rapide
        let wingsDTONoPhotos = wings.map { $0.toDTOWithoutPhoto() }

        guard let jsonData = try? JSONEncoder().encode(wingsDTONoPhotos) else {
            logError("Failed to encode wings for sync", category: .watchSync)
            return
        }

        let base64String = jsonData.base64EncodedString()
        // IMPORTANT: Préserver le contexte existant (settings, langue, etc.)
        var context = WCSession.default.applicationContext
        context["wingsData"] = base64String

        do {
            try WCSession.default.updateApplicationContext(context)
            logInfo("Synced \(wingsDTONoPhotos.count) wings to Watch (reordered)", category: .watchSync)
        } catch {
            logError("Failed to sync wings: \(error.localizedDescription)", category: .watchSync)
        }
    }

    /// Envoie la liste des voiles via transferUserInfo (alternative si updateApplicationContext échoue)
    func sendWingsViaTransfer() {
        guard let dataController = dataController else {
            logError("DataController not available", category: .watchSync)
            return
        }

        // Si la session n'est pas activée, réessayer après 1 seconde
        guard WCSession.default.activationState == .activated else {
            logWarning("WCSession not activated yet for transfer, will retry...", category: .watchSync)
            DispatchQueue.main.asyncAfter(deadline: .now() + WatchSyncConstants.retryDelay) { [weak self] in
                self?.sendWingsViaTransfer()
            }
            return
        }

        let wings = dataController.fetchWings()
        // Sans photos pour le transfer
        let wingsDTO = wings.map { $0.toDTOWithoutPhoto() }

        logDebug("Attempting to transfer \(wingsDTO.count) wings to Watch (without photos)...", category: .watchSync)

        guard let jsonData = try? JSONEncoder().encode(wingsDTO) else {
            logError("Failed to encode wings", category: .watchSync)
            return
        }

        let base64String = jsonData.base64EncodedString()
        let userInfo = ["wingsData": base64String]

        WCSession.default.transferUserInfo(userInfo)
        logInfo("Transferred \(wingsDTO.count) wings to Watch via transferUserInfo", category: .watchSync)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            logError("WCSession activation failed: \(error.localizedDescription)", category: .watchSync)
            return
        }

        logInfo("WCSession activated (state: \(activationState.rawValue))", category: .watchSync)
        isWatchAppInstalled = session.isWatchAppInstalled
        isWatchReachable = session.isReachable

        // Envoyer automatiquement les voiles, la langue et les paramètres Watch à l'activation
        if activationState == .activated {
            sendWingsToWatch()

            // Envoyer la langue courante
            let languageCode = LocalizationManager.shared.currentLanguage?.rawValue
            sendLanguageToWatch(languageCode)

            // Envoyer les paramètres Watch
            let autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
            let allowDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
            sendWatchSettings(autoWaterLock: autoWaterLock, allowSessionDismiss: allowDismiss)
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
        isWatchReachable = session.isReachable
        logDebug("Watch reachability changed: \(isWatchReachable)", category: .watchSync)
    }

    // MARK: - Receive Flight from Watch

    /// Reçoit un vol depuis la Watch via transferUserInfo
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        logInfo("Received data from Watch", category: .watchSync)

        // Vérifier si c'est un vol
        if let flightData = userInfo["flight"] as? [String: Any],
           let jsonData = try? JSONSerialization.data(withJSONObject: flightData),
           let flightDTO = try? JSONDecoder().decode(FlightDTO.self, from: jsonData) {

            logInfo("Received flight: \(flightDTO.durationSeconds)s with wing \(flightDTO.wingId)", category: .flight)

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

        logWarning("Received userInfo is not a flight - ignoring", category: .watchSync)
    }

    /// Reçoit un message instantané depuis la Watch (alternative plus rapide)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        logDebug("Received instant message from Watch: \(message.keys)", category: .watchSync)

        // Vérifier si c'est une demande de synchronisation des voiles
        if let action = message["action"] as? String, action == "requestWings" {
            logInfo("Watch requested wings sync", category: .watchSync)
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
        logDebug("Received message from Watch (no reply): \(message.keys)", category: .watchSync)

        // Vérifier si c'est une demande de synchronisation des voiles
        if let action = message["action"] as? String, action == "requestWings" {
            logInfo("Watch requested wings sync", category: .watchSync)
            DispatchQueue.main.async { [weak self] in
                self?.sendWingsToWatch()
            }
        }
    }
}
