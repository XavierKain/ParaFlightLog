//
//  LocalizationManager.swift
//  ParaFlightLog
//
//  Gestionnaire de localisation avec changement manuel de langue
//  Target: iOS only
//

import Foundation
import SwiftUI

@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    // Langue actuelle (nil = utiliser la langue du système)
    var currentLanguage: Language? {
        didSet {
            saveLanguagePreference()
            applyLanguage()
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

        var flag: String {
            switch self {
            case .french: return "🇫🇷"
            case .english: return "🇬🇧"
            }
        }
    }

    private init() {
        loadLanguagePreference()
        applyLanguage()
    }

    // MARK: - Persistence

    private let languageKey = "app_language"

    private func saveLanguagePreference() {
        if let language = currentLanguage {
            UserDefaults.standard.set(language.rawValue, forKey: languageKey)
            // Définir également AppleLanguages pour que le système utilise cette langue
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: languageKey)
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    private func loadLanguagePreference() {
        if let languageCode = UserDefaults.standard.string(forKey: languageKey),
           let language = Language(rawValue: languageCode) {
            currentLanguage = language
        } else {
            currentLanguage = nil
        }
    }

    private func applyLanguage() {
        // Définir la langue au niveau du système pour les futures sessions
        if let language = currentLanguage {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        
        // Envoyer la langue à la Watch
        WatchConnectivityManager.shared.sendLanguageToWatch(currentLanguage?.rawValue)
    }

    // MARK: - Localization

    /// Récupère une chaîne localisée
    func localized(_ key: String) -> String {
        let language = currentLanguage ?? effectiveLanguage

        // Utiliser la langue sélectionnée manuellement
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return NSLocalizedString(key, comment: "")
        }

        return NSLocalizedString(key, bundle: bundle, comment: "")
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

// MARK: - LocalizedStringKey Extension

extension String {
    /// Récupère une chaîne localisée via le LocalizationManager
    var localized: String {
        LocalizationManager.shared.localized(self)
    }
}
