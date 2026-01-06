//
//  Logger.swift
//  ParaFlightLog
//
//  Système de logging centralisé basé sur OSLog
//  Remplace les print() pour un meilleur contrôle et des performances optimales
//  Target: iOS + Watch (shared)
//

import Foundation
import os.log

// MARK: - Log Categories

/// Catégories de log pour filtrer dans Console.app
enum LogCategory: String, Sendable {
    case general = "General"
    case watchSync = "WatchSync"
    case dataController = "DataController"
    case location = "Location"
    case flight = "Flight"
    case stats = "Stats"
    case imageProcessing = "ImageProcessing"
    case ui = "UI"
    case dataImport = "DataImport"
    case wingLibrary = "WingLibrary"
    case auth = "Auth"
    case sync = "Sync"
    case notification = "Notification"
}

// MARK: - App Logger

/// Logger centralisé pour l'application - Thread-safe pour Swift 6
/// Usage: AppLogger.shared.info("Message", category: .watchSync)
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let subsystem = AppConstants.bundleIdentifier

    // Cache des loggers par catégorie pour éviter de les recréer
    private var loggers: [LogCategory: Logger] = [:]
    private let lock = NSLock()

    /// Mode développeur : si false, seuls les logs error/critical sont émis
    /// Ceci améliore les performances en production
    private var isDeveloperModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.developerModeEnabled)
    }

    private init() {}

    /// Récupère ou crée un logger pour une catégorie donnée (thread-safe)
    private func logger(for category: LogCategory) -> Logger {
        lock.lock()
        defer { lock.unlock() }

        if let existing = loggers[category] {
            return existing
        }

        let newLogger = Logger(subsystem: subsystem, category: category.rawValue)
        loggers[category] = newLogger
        return newLogger
    }

    // MARK: - Log Methods

    /// Log de niveau debug (visible uniquement en mode développeur)
    func debug(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled else { return }
        logger(for: category).debug("\(message, privacy: .public)")
    }

    /// Log de niveau info (visible uniquement en mode développeur)
    func info(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled else { return }
        logger(for: category).info("\(message, privacy: .public)")
    }

    /// Log de niveau notice (visible uniquement en mode développeur)
    func notice(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled else { return }
        logger(for: category).notice("\(message, privacy: .public)")
    }

    /// Log de niveau warning (toujours actif - problèmes potentiels)
    func warning(_ message: String, category: LogCategory = .general) {
        logger(for: category).warning("\(message, privacy: .public)")
    }

    /// Log de niveau error (toujours actif - erreurs récupérables)
    func error(_ message: String, category: LogCategory = .general) {
        logger(for: category).error("\(message, privacy: .public)")
    }

    /// Log de niveau critical (toujours actif - erreurs critiques)
    func critical(_ message: String, category: LogCategory = .general) {
        logger(for: category).critical("\(message, privacy: .public)")
    }

    // MARK: - Convenience Methods

    /// Log avec emoji pour compatibilité visuelle (à utiliser temporairement pendant la migration)
    func legacy(_ message: String, category: LogCategory = .general) {
        // En debug, on garde le comportement print pour la compatibilité
        #if DEBUG
        print(message)
        #endif
        // On log aussi dans OSLog pour la transition
        logger(for: category).info("\(message, privacy: .public)")
    }
}

// MARK: - Global Convenience Functions

/// Fonctions globales pour faciliter l'usage
/// Thread-safe grâce à AppLogger qui est @unchecked Sendable

func logDebug(_ message: String, category: LogCategory = .general) {
    AppLogger.shared.debug(message, category: category)
}

func logInfo(_ message: String, category: LogCategory = .general) {
    AppLogger.shared.info(message, category: category)
}

func logWarning(_ message: String, category: LogCategory = .general) {
    AppLogger.shared.warning(message, category: category)
}

func logError(_ message: String, category: LogCategory = .general) {
    AppLogger.shared.error(message, category: category)
}
