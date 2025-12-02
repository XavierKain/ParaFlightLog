//
//  WatchLocalizationManager.swift
//  ParaFlightLogWatch Watch App
//
//  Gestionnaire de localisation pour Apple Watch
//  Reçoit la langue sélectionnée depuis l'iPhone
//  Target: Watch only
//

import Foundation
import SwiftUI
import WidgetKit

@Observable
final class WatchLocalizationManager {
    static let shared = WatchLocalizationManager()

    // Langue actuelle (nil = utiliser la langue du système)
    var currentLanguage: Language? {
        didSet {
            saveLanguagePreference()
            // Rafraîchir le widget pour qu'il utilise la nouvelle langue
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // Locale SwiftUI pour forcer le changement de langue dans l'interface
    var locale: Locale {
        if let language = currentLanguage {
            return Locale(identifier: language.rawValue)
        }
        return Locale.current
    }

    enum Language: String, CaseIterable {
        case french = "fr"
        case english = "en"

        var displayName: String {
            switch self {
            case .french: return "Français"
            case .english: return "English"
            }
        }
    }

    private init() {
        loadLanguagePreference()
    }

    // MARK: - Persistence

    private let languageKey = "watch_app_language"

    private func saveLanguagePreference() {
        if let language = currentLanguage {
            UserDefaults.standard.set(language.rawValue, forKey: languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: languageKey)
        }
        UserDefaults.standard.synchronize()
        print("💾 Watch: Saved language preference: \(currentLanguage?.rawValue ?? "system")")
    }

    private func loadLanguagePreference() {
        if let languageCode = UserDefaults.standard.string(forKey: languageKey),
           let language = Language(rawValue: languageCode) {
            currentLanguage = language
            print("📂 Watch: Loaded language preference: \(language.rawValue)")
        } else {
            currentLanguage = nil
            print("📂 Watch: No saved language, using system default")
        }
    }

    // MARK: - Sync from iPhone

    /// Met à jour la langue depuis l'iPhone
    func updateLanguage(from languageCode: String?) {
        if let code = languageCode, let language = Language(rawValue: code) {
            if currentLanguage != language {
                currentLanguage = language
                print("🌐 Watch: Language updated to \(language.displayName) from iPhone")
            }
        } else {
            if currentLanguage != nil {
                currentLanguage = nil
                print("🌐 Watch: Language reset to system default from iPhone")
            }
        }
    }

    /// Helper pour obtenir la langue courante (sélectionnée ou système)
    var effectiveLanguage: Language {
        if let current = currentLanguage {
            return current
        }

        // Détecter la langue du système
        let systemLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        return systemLanguage.hasPrefix("fr") ? .french : .english
    }
}
