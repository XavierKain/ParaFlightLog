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
            stampIfLocalEdit()
        }
    }

    /// Allows cancelling/dismissing a flight session
    /// If false, the user can only save the flight
    var allowSessionDismiss: Bool {
        didSet {
            UserDefaults.standard.set(allowSessionDismiss, forKey: "allowSessionDismiss")
            stampIfLocalEdit()
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
            stampIfLocalEdit()
        }
    }

    // MARK: - Last-write-wins version stamp

    /// When the iPhone-synced settings above were last changed ON THIS WATCH
    /// (seconds since 1970). Sent with every push to the iPhone and compared
    /// against the iPhone's own stamp, so whoever edited last wins instead of
    /// whoever spoke last. See WatchSyncKeys.settingsUpdatedAt.
    private(set) var settingsUpdatedAt: Double {
        get { UserDefaults.standard.double(forKey: "settingsUpdatedAt") }
        set { UserDefaults.standard.set(newValue, forKey: "settingsUpdatedAt") }
    }

    /// Set only while applying a payload from the iPhone, so those writes are
    /// not mistaken for a pilot edit on the Watch (which would bump the stamp
    /// and bounce the value straight back).
    private var isApplyingRemote = false

    private func stampIfLocalEdit() {
        guard !isApplyingRemote else { return }
        settingsUpdatedAt = Date().timeIntervalSince1970
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
        // Last write wins: the iPhone re-publishes its settings on every session
        // activation, so without this an app launch would overwrite a setting the
        // pilot had just changed here. A context with no stamp comes from a build
        // that predates this and is still accepted.
        let remoteStamp = context[WatchSyncKeys.settingsUpdatedAt] as? Double
        guard SettingsSyncPolicy.shouldApply(incomingStamp: remoteStamp, localStamp: settingsUpdatedAt) else {
            watchLogInfo("Ignoring settings from the iPhone: older than ours (\(remoteStamp ?? 0) <= \(settingsUpdatedAt))", category: .settings)
            return
        }

        isApplyingRemote = true
        defer {
            isApplyingRemote = false
            // Agree with the iPhone on "when", so a re-send of the same context
            // is rejected above instead of being reapplied.
            settingsUpdatedAt = remoteStamp ?? Date().timeIntervalSince1970
        }

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
