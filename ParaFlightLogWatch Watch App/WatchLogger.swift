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
enum WatchLogCategory: String, Sendable {
    case general = "General"
    case watchSync = "WatchSync"
    case location = "Location"
    case flight = "Flight"
    case session = "Session"
    case workout = "Workout"
    case settings = "Settings"
}

// MARK: - WatchLog Enum (Thread-safe, accessible depuis n'importe quel contexte)

/// API de logging principale pour Watch - utilisable depuis n'importe quel contexte de concurrence
/// Usage: WatchLog.info("Message", category: .watchSync)
/// Toute la logique est encapsulée pour éviter l'inférence MainActor
enum WatchLog: Sendable {
    /// Cache thread-safe des loggers OSLog par catégorie
    nonisolated(unsafe) private static var loggerLock = NSLock()
    nonisolated(unsafe) private static var loggerCache: [WatchLogCategory: Logger] = [:]
    nonisolated(unsafe) private static var subsystem = "com.xavierkain.SoarX.watchkitapp"
    /// Clé UserDefaults - copie locale pour éviter l'inférence MainActor
    nonisolated(unsafe) private static var developerModeKey = "developerModeEnabled"

    /// Récupère ou crée un logger OSLog pour une catégorie (thread-safe)
    nonisolated private static func getOSLogger(for category: WatchLogCategory) -> Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }

        if let existing = loggerCache[category] {
            return existing
        }

        let newLogger = Logger(subsystem: subsystem, category: category.rawValue)
        loggerCache[category] = newLogger
        return newLogger
    }

    /// Vérifie si le mode développeur est activé
    nonisolated private static func isDeveloperModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: developerModeKey)
    }

    nonisolated static func debug(_ message: String, category: WatchLogCategory = .general) {
        guard isDeveloperModeEnabled() else { return }
        getOSLogger(for: category).debug("\(message, privacy: .public)")
    }

    nonisolated static func info(_ message: String, category: WatchLogCategory = .general) {
        guard isDeveloperModeEnabled() else { return }
        getOSLogger(for: category).info("\(message, privacy: .public)")
    }

    nonisolated static func warning(_ message: String, category: WatchLogCategory = .general) {
        getOSLogger(for: category).warning("\(message, privacy: .public)")
    }

    nonisolated static func error(_ message: String, category: WatchLogCategory = .general) {
        getOSLogger(for: category).error("\(message, privacy: .public)")
    }
}

// MARK: - Legacy Global Convenience Functions (MainActor only)

/// Fonctions globales pour la compatibilité avec le code existant
/// Pour du code hors MainActor, utiliser WatchLog.info(), etc.

@MainActor func watchLogDebug(_ message: String, category: WatchLogCategory = .general) {
    WatchLog.debug(message, category: category)
}

@MainActor func watchLogInfo(_ message: String, category: WatchLogCategory = .general) {
    WatchLog.info(message, category: category)
}

@MainActor func watchLogWarning(_ message: String, category: WatchLogCategory = .general) {
    WatchLog.warning(message, category: category)
}

@MainActor func watchLogError(_ message: String, category: WatchLogCategory = .general) {
    WatchLog.error(message, category: category)
}
