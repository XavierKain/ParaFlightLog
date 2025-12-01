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
        }
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
    }

    // MARK: - Persistence

    private let languageKey = "app_language"

    private func saveLanguagePreference() {
        if let language = currentLanguage {
            UserDefaults.standard.set(language.rawValue, forKey: languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: languageKey)
        }
    }

    private func loadLanguagePreference() {
        if let languageCode = UserDefaults.standard.string(forKey: languageKey),
           let language = Language(rawValue: languageCode) {
            currentLanguage = language
        } else {
            currentLanguage = nil
        }
    }

    // MARK: - Localization

    /// Récupère une chaîne localisée
    func localized(_ key: String) -> String {
        guard let language = currentLanguage else {
            // Utiliser la langue du système
            return NSLocalizedString(key, comment: "")
        }

        // Utiliser la langue sélectionnée manuellement
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
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
