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

    // MARK: - Initialization

    private init() {
        // Charger les valeurs sauvegardées ou utiliser les valeurs par défaut
        self.autoWaterLockEnabled = UserDefaults.standard.object(forKey: "autoWaterLockEnabled") as? Bool ?? false
        self.allowSessionDismiss = UserDefaults.standard.object(forKey: "allowSessionDismiss") as? Bool ?? true
    }

    // MARK: - Update from iPhone

    /// Met à jour les paramètres depuis un contexte reçu de l'iPhone
    func updateFromContext(_ context: [String: Any]) {
        print("📲 WatchSettings.updateFromContext called with: \(context)")

        if let autoWaterLock = context["watchAutoWaterLock"] as? Bool {
            print("   🔧 Setting autoWaterLockEnabled to: \(autoWaterLock)")
            autoWaterLockEnabled = autoWaterLock
        } else {
            print("   ⚠️ No watchAutoWaterLock found in context")
        }

        if let allowDismiss = context["watchAllowSessionDismiss"] as? Bool {
            print("   🔧 Setting allowSessionDismiss to: \(allowDismiss)")
            allowSessionDismiss = allowDismiss
        } else {
            print("   ⚠️ No watchAllowSessionDismiss found in context")
        }

        print("   ✅ Final values: autoWaterLock=\(autoWaterLockEnabled), allowDismiss=\(allowSessionDismiss)")
    }

    // MARK: - Water Lock Control

    /// Active le water lock sur l'Apple Watch
    func enableWaterLock() {
        #if os(watchOS)
        WKInterfaceDevice.current().enableWaterLock()
        #endif
    }
}
