//
//  WatchSettings.swift
//  ParaFlightLogWatch Watch App
//
//  Apple Watch settings, partially synced from the iPhone
//  Target: Watch only
//

import Foundation

/// Singleton managing the Watch settings
@Observable
final class WatchSettings {
    static let shared = WatchSettings()

    // MARK: - Settings Properties

    /// Automatically enables Water Lock during a flight
    /// (prevents accidental screen touches)
    var autoWaterLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoWaterLockEnabled, forKey: "autoWaterLockEnabled")
        }
    }

    /// Allows cancelling/dismissing a flight session
    /// If false, the user can only save the flight
    var allowSessionDismiss: Bool {
        didSet {
            UserDefaults.standard.set(allowSessionDismiss, forKey: "allowSessionDismiss")
        }
    }

    /// Developer mode: enables detailed logging
    /// Off by default for better performance
    var developerModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(developerModeEnabled, forKey: "developerModeEnabled")
        }
    }

    /// Variometer (haptic climb/sink feedback) during a flight. Off by default.
    /// Toggled directly on the Watch from the active flight screen.
    var varioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(varioEnabled, forKey: "varioEnabled")
        }
    }

    /// Developer tool: when on, starting a flight feeds fake, changing
    /// altitude/speed/distance/G-force into the live flight screen instead of
    /// using the real GPS/barometer. Lets you judge on-watch readability
    /// without moving. Synced from the iPhone Developer settings. Off by default.
    var simulateFlightEnabled: Bool {
        didSet {
            UserDefaults.standard.set(simulateFlightEnabled, forKey: "simulateFlightEnabled")
        }
    }

    /// Last flight type chosen by the pilot when saving a flight.
    /// Used as the default selection for the next flight.
    var lastFlightType: FlightType {
        didSet {
            UserDefaults.standard.set(lastFlightType.rawValue, forKey: "lastFlightType")
        }
    }

    // MARK: - Initialization

    private init() {
        // Load saved values or fall back to defaults
        self.autoWaterLockEnabled = UserDefaults.standard.object(forKey: "autoWaterLockEnabled") as? Bool ?? false
        self.allowSessionDismiss = UserDefaults.standard.object(forKey: "allowSessionDismiss") as? Bool ?? true
        self.developerModeEnabled = UserDefaults.standard.object(forKey: "developerModeEnabled") as? Bool ?? false
        self.varioEnabled = UserDefaults.standard.object(forKey: "varioEnabled") as? Bool ?? false
        self.simulateFlightEnabled = UserDefaults.standard.object(forKey: "simulateFlightEnabled") as? Bool ?? false
        if let rawType = UserDefaults.standard.string(forKey: "lastFlightType"),
           let type = FlightType(rawValue: rawType) {
            self.lastFlightType = type
        } else {
            self.lastFlightType = .soaring
        }
    }

    // MARK: - Update from iPhone

    /// Updates the settings from a context received from the iPhone
    func updateFromContext(_ context: [String: Any]) {
        if let autoWaterLock = context["watchAutoWaterLock"] as? Bool {
            autoWaterLockEnabled = autoWaterLock
        }

        if let allowDismiss = context["watchAllowSessionDismiss"] as? Bool {
            allowSessionDismiss = allowDismiss
        }

        if let devMode = context["developerModeEnabled"] as? Bool {
            developerModeEnabled = devMode
        }

        if let simulate = context["simulateFlightEnabled"] as? Bool {
            simulateFlightEnabled = simulate
        }

        // Log only when developer mode is on (avoids the startup log otherwise)
        if developerModeEnabled {
            watchLogDebug("Settings updated: autoWaterLock=\(autoWaterLockEnabled), allowDismiss=\(allowSessionDismiss), devMode=\(developerModeEnabled)", category: .settings)
        }
    }
}
