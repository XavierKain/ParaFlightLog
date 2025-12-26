//
//  WatchSettings.swift
//  ParaFlightLogWatch Watch App
//
//  Gestion des paramètres de l'Apple Watch synchronisés depuis l'iPhone
//  Target: Watch only
//

import Foundation
import WatchKit

/// Singleton pour gérer les paramètres de la Watch
@Observable
final class WatchSettings {
    static let shared = WatchSettings()

    // MARK: - Settings Properties

    /// Active le waterlock automatiquement pendant un vol
    /// Empêche les touches accidentelles sur l'écran
    var autoWaterLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoWaterLockEnabled, forKey: "autoWaterLockEnabled")
        }
    }

    /// Permet d'annuler/dismiss une session de vol
    /// Si false, l'utilisateur ne peut que sauvegarder le vol
    var allowSessionDismiss: Bool {
        didSet {
            UserDefaults.standard.set(allowSessionDismiss, forKey: "allowSessionDismiss")
        }
    }

    /// Mode développeur : active les logs détaillés
    /// Désactivé par défaut pour de meilleures performances
    var developerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(developerModeEnabled, forKey: "developerModeEnabled")
        }
    }

    // MARK: - Initialization

    private init() {
        // Charger les valeurs sauvegardées ou utiliser les valeurs par défaut
        self.autoWaterLockEnabled = UserDefaults.standard.object(forKey: "autoWaterLockEnabled") as? Bool ?? false
        self.allowSessionDismiss = UserDefaults.standard.object(forKey: "allowSessionDismiss") as? Bool ?? true
        self.developerModeEnabled = UserDefaults.standard.object(forKey: "developerModeEnabled") as? Bool ?? false
    }

    // MARK: - Update from iPhone

    /// Met à jour les paramètres depuis un contexte reçu de l'iPhone
    func updateFromContext(_ context: [String: Any]) {
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
            watchLogDebug("Settings updated: autoWaterLock=\(autoWaterLockEnabled), allowDismiss=\(allowSessionDismiss), devMode=\(developerModeEnabled)", category: .settings)
        }
    }

    // MARK: - Water Lock Control

    /// Active le water lock sur l'Apple Watch
    func enableWaterLock() {
        #if os(watchOS)
        WKInterfaceDevice.current().enableWaterLock()
        #endif
    }
}
