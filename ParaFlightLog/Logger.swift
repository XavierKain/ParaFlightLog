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

// MARK: - Log Enum (Thread-safe, accessible depuis n'importe quel contexte)

/// API de logging principale - utilisable depuis n'importe quel contexte de concurrence
/// Usage: Log.info("Message", category: .watchSync)
/// Toute la logique est encapsulée pour éviter l'inférence MainActor
enum Log: Sendable {
    /// Cache thread-safe des loggers OSLog par catégorie
    nonisolated(unsafe) private static var loggerLock = NSLock()
    nonisolated(unsafe) private static var loggerCache: [LogCategory: Logger] = [:]
    /// Bundle identifier - copie locale pour éviter l'accès à AppConstants (MainActor)
    nonisolated(unsafe) private static var bundleId = "com.xavierkain.SoarX"
    /// Clé UserDefaults - copie locale pour éviter l'accès à UserDefaultsKeys (MainActor)
    nonisolated(unsafe) private static var developerModeKey = "developerModeEnabled"

    /// Récupère ou crée un logger OSLog pour une catégorie (thread-safe)
    nonisolated private static func getOSLogger(for category: LogCategory) -> Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }

        if let existing = loggerCache[category] {
            return existing
        }

        let newLogger = Logger(subsystem: bundleId, category: category.rawValue)
        loggerCache[category] = newLogger
        return newLogger
    }

    /// Vérifie si le mode développeur est activé
    nonisolated private static func isDeveloperModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: developerModeKey)
    }

    nonisolated static func debug(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled() else { return }
        getOSLogger(for: category).debug("\(message, privacy: .public)")
    }

    nonisolated static func info(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled() else { return }
        getOSLogger(for: category).info("\(message, privacy: .public)")
    }

    nonisolated static func notice(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled() else { return }
        getOSLogger(for: category).notice("\(message, privacy: .public)")
    }

    nonisolated static func warning(_ message: String, category: LogCategory = .general) {
        getOSLogger(for: category).warning("\(message, privacy: .public)")
    }

    nonisolated static func error(_ message: String, category: LogCategory = .general) {
        getOSLogger(for: category).error("\(message, privacy: .public)")
    }

    nonisolated static func critical(_ message: String, category: LogCategory = .general) {
        getOSLogger(for: category).critical("\(message, privacy: .public)")
    }
}

// MARK: - Legacy Global Functions (MainActor only)

/// Fonctions globales pour la compatibilité avec le code existant
/// Utilisent @MainActor - pour du code hors MainActor, utiliser Log.info(), etc.

@MainActor func logDebug(_ message: String, category: LogCategory = .general) {
    Log.debug(message, category: category)
}

@MainActor func logInfo(_ message: String, category: LogCategory = .general) {
    Log.info(message, category: category)
}

@MainActor func logWarning(_ message: String, category: LogCategory = .general) {
    Log.warning(message, category: category)
}

@MainActor func logError(_ message: String, category: LogCategory = .general) {
    Log.error(message, category: category)
}
