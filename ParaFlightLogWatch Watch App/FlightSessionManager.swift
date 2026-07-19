//
//  FlightSessionManager.swift
//  ParaFlightLogWatch Watch App
//
//  Persists the in-progress flight session so no data is lost on crash
//  - Automatic periodic save (every 30 seconds)
//  - Session recovery after a crash/restart
//  Target: Watch only
//

import Foundation

/// Serializable data of an in-progress flight session
struct FlightSession: Codable {
    let wingId: UUID
    let wingName: String
    let wingSize: String?
    let startDate: Date
    let spotName: String?

    // Tracking data
    var startAltitude: Double?
    var maxAltitude: Double?
    var currentAltitude: Double?
    var totalDistance: Double
    var maxSpeed: Double
    var maxGForce: Double

    // GPS track (compacted to GPSTrackCompaction.maxPoints to save memory)
    var gpsTrackPoints: [GPSTrackPoint]

    // Metadata
    /// Last time the session was persisted. Used as the recovered flight's
    /// end date so dead time after a crash is not counted as flight time.
    var lastSaveDate: Date
    var isActive: Bool

    init(wing: WingDTO, startDate: Date, spotName: String?) {
        self.wingId = wing.id
        self.wingName = wing.name
        self.wingSize = wing.size
        self.startDate = startDate
        self.spotName = spotName
        self.startAltitude = nil
        self.maxAltitude = nil
        self.currentAltitude = nil
        self.totalDistance = 0.0
        self.maxSpeed = 0.0
        self.maxGForce = 1.0
        self.gpsTrackPoints = []
        self.lastSaveDate = Date()
        self.isActive = true
    }
}

/// Singleton manager for flight session persistence
final class FlightSessionManager {
    static let shared = FlightSessionManager()

    private let sessionKey = "activeFlightSession"
    private let saveInterval: TimeInterval = 30.0  // Save every 30 seconds
    private var saveTimer: Timer?

    // Queue synchronizing access to activeSession (thread safety)
    private let sessionQueue = DispatchQueue(label: "com.paraflightlog.flightsession", qos: .userInitiated)

    // Current session - access synchronized via sessionQueue
    private var _activeSession: FlightSession?
    private(set) var activeSession: FlightSession? {
        get { sessionQueue.sync { _activeSession } }
        set { sessionQueue.sync { _activeSession = newValue } }
    }

    private init() {
        // Load a possibly recoverable session at launch
        loadSavedSession()
    }

    // MARK: - Session Lifecycle

    /// Starts a new flight session
    func startSession(wing: WingDTO, spotName: String?) {
        let session = FlightSession(wing: wing, startDate: Date(), spotName: spotName)
        activeSession = session

        // Save immediately
        saveSession()

        // Start the periodic save
        startPeriodicSave()

        watchLogInfo("Flight session started and saved", category: .session)
    }

    /// Updates the data of the in-progress session
    func updateSession(
        startAltitude: Double?,
        maxAltitude: Double?,
        currentAltitude: Double?,
        totalDistance: Double,
        maxSpeed: Double,
        maxGForce: Double,
        gpsTrackPoints: [GPSTrackPoint]
    ) {
        guard var session = activeSession else { return }

        session.startAltitude = startAltitude
        session.maxAltitude = maxAltitude
        session.currentAltitude = currentAltitude
        session.totalDistance = totalDistance
        session.maxSpeed = maxSpeed
        session.maxGForce = maxGForce

        // Shared compaction so the persisted track uses the same limit and
        // strategy as the in-memory track (see GPSTrackCompaction)
        session.gpsTrackPoints = GPSTrackCompaction.compact(gpsTrackPoints)

        activeSession = session
    }

    /// Resumes a recovered session after a crash: keeps the existing session
    /// (start date, stats, track) and just restarts the periodic save. The
    /// caller re-seeds the location service and restarts the workout.
    func resumeSession() {
        guard activeSession != nil else { return }
        saveSession()
        startPeriodicSave()
        watchLogInfo("Flight session resumed after recovery", category: .session)
    }

    /// Ends the session cleanly (flight saved)
    func endSession() {
        stopPeriodicSave()
        clearSavedSession()
        activeSession = nil
        watchLogInfo("Flight session ended and cleared", category: .session)
    }

    /// Discards the session (flight cancelled by the user)
    func discardSession() {
        stopPeriodicSave()
        clearSavedSession()
        activeSession = nil
        watchLogInfo("Flight session discarded", category: .session)
    }

    // MARK: - Persistence

    /// Saves the current session to UserDefaults
    func saveSession() {
        guard var session = activeSession else { return }
        session.lastSaveDate = Date()
        activeSession = session

        do {
            let data = try JSONEncoder().encode(session)
            UserDefaults.standard.set(data, forKey: sessionKey)
            watchLogDebug("Flight session saved (\(session.gpsTrackPoints.count) GPS points)", category: .session)
        } catch {
            watchLogError("Failed to save flight session: \(error)", category: .session)
        }
    }

    /// Loads a saved session (crash recovery)
    private func loadSavedSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey) else {
            watchLogDebug("No saved flight session found", category: .session)
            return
        }

        do {
            let session = try JSONDecoder().decode(FlightSession.self, from: data)

            // A session is recoverable if it is less than 4 hours old
            let maxAge: TimeInterval = 4 * 60 * 60
            let sessionAge = Date().timeIntervalSince(session.lastSaveDate)

            if session.isActive && sessionAge < maxAge {
                activeSession = session
                watchLogInfo("Recovered flight session from \(session.lastSaveDate), duration: \(Int(sessionAge / 60)) min, GPS points: \(session.gpsTrackPoints.count)", category: .session)
            } else {
                // Session too old, remove it
                clearSavedSession()
                watchLogInfo("Cleared expired session (age: \(Int(sessionAge / 60)) min)", category: .session)
            }
        } catch {
            watchLogError("Failed to load flight session: \(error)", category: .session)
            clearSavedSession()
        }
    }

    /// Removes the saved session
    private func clearSavedSession() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    // MARK: - Periodic Save

    /// Starts the periodic save
    private func startPeriodicSave() {
        stopPeriodicSave()

        // The timer block is @Sendable and runs outside the main actor:
        // hop to main before calling saveSession() (MainActor-isolated).
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.saveSession()
            }
        }
    }

    /// Stops the periodic save
    private func stopPeriodicSave() {
        saveTimer?.invalidate()
        saveTimer = nil
    }

    // MARK: - Recovery Check

    /// True when there is a session to recover
    var hasRecoverableSession: Bool {
        return activeSession != nil
    }

    /// End date of the recovered flight: the last persisted update, NOT now.
    /// Dead time between the crash and the recovery must not count as flight time.
    var recoveredFlightEndDate: Date? {
        return activeSession?.lastSaveDate
    }

    /// Duration of the recovered flight, bounded by the last persisted update
    var recoveredFlightDuration: Int? {
        guard let session = activeSession else { return nil }
        return max(0, Int(session.lastSaveDate.timeIntervalSince(session.startDate)))
    }

    /// Returns the recovered session data to build a FlightDTO
    func getRecoveredFlightData() -> (
        wingId: UUID,
        startDate: Date,
        endDate: Date,
        spotName: String?,
        startAltitude: Double?,
        maxAltitude: Double?,
        endAltitude: Double?,
        totalDistance: Double,
        maxSpeed: Double,
        maxGForce: Double,
        gpsTrack: [GPSTrackPoint]
    )? {
        guard let session = activeSession else { return nil }

        return (
            wingId: session.wingId,
            startDate: session.startDate,
            endDate: session.lastSaveDate,
            spotName: session.spotName,
            startAltitude: session.startAltitude,
            maxAltitude: session.maxAltitude,
            endAltitude: session.currentAltitude,
            totalDistance: session.totalDistance,
            maxSpeed: session.maxSpeed,
            maxGForce: session.maxGForce,
            gpsTrack: session.gpsTrackPoints
        )
    }
}
