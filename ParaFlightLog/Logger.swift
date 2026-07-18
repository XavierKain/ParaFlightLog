//
//  Logger.swift
//  ParaFlightLog
//
//  Centralized OSLog-based logging.
//  Nonisolated on purpose: log calls happen from background queues
//  (WatchConnectivity callbacks, backup parsing, image resize) as well as
//  the main actor, and os.Logger is thread-safe.
//  Target: iOS
//

import Foundation
import os.log

// MARK: - Log Categories

/// Log categories for filtering in Console.app
nonisolated enum LogCategory: String {
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
    case weather = "Weather"
    case community = "Community"
}

// MARK: - App Logger

/// Centralized application logger.
/// Usage: AppLogger.shared.info("Message", category: .watchSync)
nonisolated final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    private let subsystem = AppConstants.bundleIdentifier

    // Logger cache, guarded by `queue` for both reads and writes.
    private var loggers: [LogCategory: Logger] = [:]
    private let queue = DispatchQueue(label: "com.xavierkain.Soarx.logger")

    /// Developer mode: when false, only warning/error/critical logs are emitted.
    var isDeveloperModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.developerModeEnabled)
    }

    private init() {}

    /// Gets or creates the logger for a category (thread-safe).
    private func logger(for category: LogCategory) -> Logger {
        queue.sync {
            if let existing = loggers[category] {
                return existing
            }
            let newLogger = Logger(subsystem: subsystem, category: category.rawValue)
            loggers[category] = newLogger
            return newLogger
        }
    }

    // MARK: - Log Methods

    /// Debug level (developer mode only)
    func debug(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled else { return }
        logger(for: category).debug("\(message, privacy: .public)")
    }

    /// Info level (developer mode only)
    func info(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled else { return }
        logger(for: category).info("\(message, privacy: .public)")
    }

    /// Notice level (developer mode only)
    func notice(_ message: String, category: LogCategory = .general) {
        guard isDeveloperModeEnabled else { return }
        logger(for: category).notice("\(message, privacy: .public)")
    }

    /// Warning level (always on — potential problems)
    func warning(_ message: String, category: LogCategory = .general) {
        logger(for: category).warning("\(message, privacy: .public)")
    }

    /// Error level (always on — recoverable errors)
    func error(_ message: String, category: LogCategory = .general) {
        logger(for: category).error("\(message, privacy: .public)")
    }

    /// Critical level (always on — critical failures)
    func critical(_ message: String, category: LogCategory = .general) {
        logger(for: category).critical("\(message, privacy: .public)")
    }
}

// MARK: - Global Convenience Functions

nonisolated func logDebug(_ message: String, category: LogCategory = .general) {
    AppLogger.shared.debug(message, category: category)
}

nonisolated func logInfo(_ message: String, category: LogCategory = .general) {
    AppLogger.shared.info(message, category: category)
}

nonisolated func logWarning(_ message: String, category: LogCategory = .general) {
    AppLogger.shared.warning(message, category: category)
}

nonisolated func logError(_ message: String, category: LogCategory = .general) {
    AppLogger.shared.error(message, category: category)
}
