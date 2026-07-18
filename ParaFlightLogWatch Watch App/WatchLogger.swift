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
/// nonisolated : utilisable depuis n'importe quel contexte d'isolation
nonisolated enum WatchLogCategory: String {
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
/// nonisolated : appelable depuis n'importe quelle queue (delegates WCSession,
/// queue de FlightOutbox...) ; l'état interne est synchronisé via sa propre queue.
nonisolated final class WatchLogger {
    static let shared = WatchLogger()

    private let subsystem = Bundle.main.bundleIdentifier ?? "com.xavierkain.Soarx.watchkitapp"

    // Cache des loggers par catégorie pour éviter de les recréer
    private var loggers: [WatchLogCategory: Logger] = [:]
    private let queue = DispatchQueue(label: "com.paraflightlog.watchlogger")

    /// Mode développeur : si false, seuls les logs warning/error sont émis
    /// Lecture depuis UserDefaults pour éviter une dépendance circulaire avec WatchSettings
    private var isDeveloperModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "developerModeEnabled")
    }

    private init() {}

    /// Gets or creates a logger for a given category.
    /// Both reads and writes go through the queue to avoid a data race
    /// on the loggers dictionary.
    private func logger(for category: WatchLogCategory) -> Logger {
        return queue.sync {
            if let existing = loggers[category] {
                return existing
            }
            let newLogger = Logger(subsystem: subsystem, category: category.rawValue)
            loggers[category] = newLogger
            return newLogger
        }
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
// nonisolated pour être appelables depuis n'importe quel contexte
// (le projet applique l'isolation MainActor par défaut).

nonisolated func watchLogDebug(_ message: String, category: WatchLogCategory = .general) {
    WatchLogger.shared.debug(message, category: category)
}

nonisolated func watchLogInfo(_ message: String, category: WatchLogCategory = .general) {
    WatchLogger.shared.info(message, category: category)
}

nonisolated func watchLogWarning(_ message: String, category: WatchLogCategory = .general) {
    WatchLogger.shared.warning(message, category: category)
}

nonisolated func watchLogError(_ message: String, category: WatchLogCategory = .general) {
    WatchLogger.shared.error(message, category: category)
}
