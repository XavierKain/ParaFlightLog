//
//  WatchLogger.swift
//  ParaFlightLogWatch Watch App
//
//  Système de logging centralisé basé sur OSLog pour Apple Watch
//  Remplace les print() pour un meilleur contrôle et des performances optimales
//  Target: Watch only
//

import Foundation
import os.log

// MARK: - Log Categories

/// Catégories de log pour filtrer dans Console.app
enum WatchLogCategory: String {
    case general = "General"
    case watchSync = "WatchSync"
    case location = "Location"
    case flight = "Flight"
    case session = "Session"
    case workout = "Workout"
    case settings = "Settings"
}

// MARK: - Watch Logger

/// Logger centralisé pour l'Apple Watch
/// Les logs debug/info sont désactivés par défaut pour optimiser les performances
/// Activer le Mode Développeur dans les réglages iPhone pour les voir
final class WatchLogger {
    static let shared = WatchLogger()

    private let subsystem = "com.xavierkain.ParaFlightLog.watchkitapp"

    // Cache des loggers par catégorie pour éviter de les recréer
    private var loggers: [WatchLogCategory: Logger] = [:]
    private let queue = DispatchQueue(label: "com.paraflightlog.watchlogger")

    /// Mode développeur : si false, seuls les logs warning/error sont émis
    /// Lecture depuis UserDefaults pour éviter une dépendance circulaire avec WatchSettings
    private var isDeveloperModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "developerModeEnabled")
    }

    private init() {}

    /// Récupère ou crée un logger pour une catégorie donnée
    private func logger(for category: WatchLogCategory) -> Logger {
        if let existing = loggers[category] {
            return existing
        }

        let newLogger = Logger(subsystem: subsystem, category: category.rawValue)
        queue.sync {
            loggers[category] = newLogger
        }
        return newLogger
    }

    // MARK: - Log Methods

    /// Log de niveau debug (visible uniquement en mode développeur)
    func debug(_ message: String, category: WatchLogCategory = .general) {
        guard isDeveloperModeEnabled else { return }
        logger(for: category).debug("\(message, privacy: .public)")
    }

    /// Log de niveau info (visible uniquement en mode développeur)
    func info(_ message: String, category: WatchLogCategory = .general) {
        guard isDeveloperModeEnabled else { return }
        logger(for: category).info("\(message, privacy: .public)")
    }

    /// Log de niveau warning (toujours actif - problèmes potentiels)
    func warning(_ message: String, category: WatchLogCategory = .general) {
        logger(for: category).warning("\(message, privacy: .public)")
    }

    /// Log de niveau error (toujours actif - erreurs récupérables)
    func error(_ message: String, category: WatchLogCategory = .general) {
        logger(for: category).error("\(message, privacy: .public)")
    }
}

// MARK: - Global Convenience Functions

func watchLogDebug(_ message: String, category: WatchLogCategory = .general) {
    WatchLogger.shared.debug(message, category: category)
}

func watchLogInfo(_ message: String, category: WatchLogCategory = .general) {
    WatchLogger.shared.info(message, category: category)
}

func watchLogWarning(_ message: String, category: WatchLogCategory = .general) {
    WatchLogger.shared.warning(message, category: category)
}

func watchLogError(_ message: String, category: WatchLogCategory = .general) {
    WatchLogger.shared.error(message, category: category)
}
