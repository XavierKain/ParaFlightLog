//
//  WatchSettings.swift
//  ParaFlightLogWatch Watch App
//
//  Gestion des paramètres de l'Apple Watch synchronisés avec l'iPhone
//  Target: Watch only
//

import Foundation

/// Singleton pour gérer les paramètres de la Watch
@Observable
final class WatchSettings {
    static let shared = WatchSettings()

    // MARK: - Settings Properties

    /// Flag pour éviter les boucles de sync (ne pas renvoyer les settings reçus de l'iPhone)
    private var isUpdatingFromPhone = false

    /// Active le waterlock automatiquement pendant un vol
    /// Empêche les touches accidentelles sur l'écran
    var autoWaterLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoWaterLockEnabled, forKey: "autoWaterLockEnabled")
            notifySettingsChanged()
        }
    }

    /// Permet d'annuler/dismiss une session de vol
    /// Si false, l'utilisateur ne peut que sauvegarder le vol
    var allowSessionDismiss: Bool {
        didSet {
            UserDefaults.standard.set(allowSessionDismiss, forKey: "allowSessionDismiss")
            notifySettingsChanged()
        }
    }

    /// Mode développeur : active les logs détaillés
    /// Désactivé par défaut pour de meilleures performances
    var developerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(developerModeEnabled, forKey: "developerModeEnabled")
            notifySettingsChanged()
        }
    }

    // MARK: - Initialization

    private init() {
        // Charger les valeurs sauvegardées ou utiliser les valeurs par défaut
        self.autoWaterLockEnabled = UserDefaults.standard.object(forKey: "autoWaterLockEnabled") as? Bool ?? false
        self.allowSessionDismiss = UserDefaults.standard.object(forKey: "allowSessionDismiss") as? Bool ?? true
        self.developerModeEnabled = UserDefaults.standard.object(forKey: "developerModeEnabled") as? Bool ?? false
    }

    // MARK: - Sync to iPhone

    /// Envoie les paramètres modifiés vers l'iPhone
    /// Ne fait rien si on est en train de recevoir des settings de l'iPhone (évite les boucles)
    private func notifySettingsChanged() {
        guard !isUpdatingFromPhone else { return }

        WatchConnectivityManager.shared.sendSettingsToPhone(
            autoWaterLock: autoWaterLockEnabled,
            allowSessionDismiss: allowSessionDismiss,
            developerMode: developerModeEnabled
        )
    }

    // MARK: - Update from iPhone

    /// Met à jour les paramètres depuis un contexte reçu de l'iPhone
    func updateFromContext(_ context: [String: Any]) {
        // Marquer qu'on reçoit depuis l'iPhone pour ne pas renvoyer les mêmes settings
        isUpdatingFromPhone = true
        defer { isUpdatingFromPhone = false }

        if let autoWaterLock = context["watchAutoWaterLock"] as? Bool {
            autoWaterLockEnabled = autoWaterLock
        }

        if let allowDismiss = context["watchAllowSessionDismiss"] as? Bool {
            allowSessionDismiss = allowDismiss
        }

        if let devMode = context["developerModeEnabled"] as? Bool {
            developerModeEnabled = devMode
        }

        // Log uniquement si mode dev activé (évite le log au démarrage si désactivé)
        if developerModeEnabled {
            watchLogDebug("Settings updated from iPhone: autoWaterLock=\(autoWaterLockEnabled), allowDismiss=\(allowSessionDismiss), devMode=\(developerModeEnabled)", category: .settings)
        }
    }

    // MARK: - Water Lock Control

    /// Active le water lock sur l'Apple Watch
    /// Note: WKInterfaceDevice.enableWaterLock() est déprécié sur watchOS 10+
    /// L'utilisateur doit activer Water Lock manuellement
    func enableWaterLock() {
        // Water Lock doit être activé manuellement par l'utilisateur sur watchOS 10+
        watchLogInfo("Water Lock should be enabled manually by user (WKInterfaceDevice deprecated)", category: .workout)
    }
}
