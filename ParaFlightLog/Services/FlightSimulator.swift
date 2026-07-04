//
//  FlightSimulator.swift
//  ParaFlightLog
//
//  Developer tool: generates a realistic fake flight feed so the whole
//  phone-tracking flow (timer, vario, GPS track capture, save, replay,
//  export) can be tested end-to-end in the Xcode simulator.
//
//  The simulated pilot soars figure-eights along a ridge near the base
//  coordinate, with alternating climb/sink phases (strong enough to
//  trigger the vario climb beeps and the strong-sink alarm) and a ground
//  speed oscillating between ~8 and ~15 m/s. Ticks every second and
//  appends a GPS track point every 5 seconds, mirroring the Watch cadence.
//  Target: iOS only
//

import Foundation
import CoreLocation

@Observable
final class FlightSimulator {

    // MARK: - Published state (same data the real flow consumes)

    private(set) var isRunning: Bool = false
    /// Current simulated position (never nil while running)
    private(set) var currentLocation: CLLocation?
    /// Current barometric-style altitude (m)
    private(set) var altitude: Double
    /// Smoothed vertical speed (m/s, positive = climbing)
    private(set) var verticalSpeed: Double = 0.0
    /// Current ground speed (m/s)
    private(set) var groundSpeed: Double = 0.0
    /// Accumulated GPS track (one point every 5 s)
    private(set) var trackPoints: [GPSTrackPoint] = []
    /// Seconds since the simulation started
    private(set) var elapsedSeconds: Int = 0

    // MARK: - Configuration

    /// Takeoff coordinate (ridge near Annecy)
    let baseCoordinate: CLLocationCoordinate2D
    /// Takeoff altitude (m)
    let baseAltitude: Double
    /// Optional total duration; nil = runs until stopped
    let maxDuration: TimeInterval?

    // MARK: - Tuning

    /// Interval between simulation ticks (s)
    private let tickInterval: TimeInterval = 1.0
    /// Interval between recorded GPS track points (s), mirrors GPSConstants.trackPointInterval
    private let trackPointInterval: Int = 5
    /// Altitude bounds: force a phase change when reached
    private let minAltitude: Double
    private let maxAltitude: Double
    /// Half-width of the figure-eight along the ridge (m, east-west)
    private let ridgeHalfLength: Double = 300.0
    /// Half-depth of the figure-eight across the ridge (m, north-south)
    private let ridgeHalfDepth: Double = 90.0

    // MARK: - Private state

    private var timer: Timer?
    private var pathParameter: Double = 0.0        // θ along the figure-eight
    private var targetVerticalSpeed: Double = 0.0  // current phase target (m/s)
    private var phaseSecondsRemaining: Int = 0
    private var isClimbPhase: Bool = true
    private var previousEast: Double = 0.0
    private var previousNorth: Double = 0.0

    // MARK: - Init

    init(baseCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
         baseAltitude: Double = 1200.0,
         maxDuration: TimeInterval? = nil) {
        self.baseCoordinate = baseCoordinate
        self.baseAltitude = baseAltitude
        self.maxDuration = maxDuration
        self.altitude = baseAltitude
        self.minAltitude = baseAltitude - 250.0
        self.maxAltitude = baseAltitude + 900.0
    }

    // MARK: - Lifecycle

    /// Starts the simulated feed. No-op if already running.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        elapsedSeconds = 0
        pathParameter = 0.0
        altitude = baseAltitude
        verticalSpeed = 0.0
        groundSpeed = 0.0
        trackPoints = []
        previousEast = 0.0
        previousNorth = 0.0
        startNewPhase(climb: true)

        // Initial fix at the takeoff
        currentLocation = makeLocation(east: 0, north: 0, course: 90, speed: 0)

        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }

        logInfo("Flight simulator started at \(baseCoordinate.latitude), \(baseCoordinate.longitude)", category: .flight)
    }

    /// Stops the simulated feed. The accumulated track stays available for saving.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        logInfo("Flight simulator stopped after \(elapsedSeconds)s, \(trackPoints.count) track points", category: .flight)
    }

    // MARK: - Simulation tick (1 Hz)

    private func tick() {
        guard isRunning else { return }
        elapsedSeconds += 1

        // --- Vertical: alternating climb/sink phases ---
        phaseSecondsRemaining -= 1
        if phaseSecondsRemaining <= 0 || altitude >= maxAltitude || altitude <= minAltitude {
            // Force climbing when low, sinking when high
            let nextIsClimb: Bool
            if altitude >= maxAltitude {
                nextIsClimb = false
            } else if altitude <= minAltitude {
                nextIsClimb = true
            } else {
                nextIsClimb = !isClimbPhase
            }
            startNewPhase(climb: nextIsClimb)
        }

        // Smoothly approach the phase target (like a real smoothed vario)
        verticalSpeed += 0.35 * (targetVerticalSpeed - verticalSpeed)
        altitude += verticalSpeed * tickInterval

        // --- Horizontal: figure-eight along the ridge at 8-15 m/s ---
        // Ground speed oscillates slowly between ~8 and ~15 m/s
        let targetSpeed = 11.5 + 3.5 * sin(Double(elapsedSeconds) / 23.0)

        // Advance θ so that the path speed matches the target speed
        let dEastDTheta = ridgeHalfLength * cos(pathParameter)
        let dNorthDTheta = 2.0 * ridgeHalfDepth * cos(2.0 * pathParameter)
        let pathDerivative = max(sqrt(dEastDTheta * dEastDTheta + dNorthDTheta * dNorthDTheta), 20.0)
        pathParameter += (targetSpeed * tickInterval) / pathDerivative

        let east = ridgeHalfLength * sin(pathParameter)
        let north = ridgeHalfDepth * sin(2.0 * pathParameter)

        // Actual speed and course from the position delta
        let dEast = east - previousEast
        let dNorth = north - previousNorth
        groundSpeed = sqrt(dEast * dEast + dNorth * dNorth) / tickInterval
        var course = atan2(dEast, dNorth) * 180.0 / .pi
        if course < 0 { course += 360.0 }
        previousEast = east
        previousNorth = north

        currentLocation = makeLocation(east: east, north: north, course: course, speed: groundSpeed)

        // --- Track point every 5 s (mirrors the Watch cadence) ---
        if elapsedSeconds % trackPointInterval == 0, let location = currentLocation {
            trackPoints.append(GPSTrackPoint(
                timestamp: location.timestamp,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: altitude,
                speed: groundSpeed
            ))
        }

        // --- Optional auto-stop ---
        if let maxDuration, Double(elapsedSeconds) >= maxDuration {
            stop()
        }
    }

    /// Starts a new climb or sink phase with randomized strength and duration.
    /// Sink phases occasionally go below -2.5 m/s so the strong-sink alarm triggers.
    private func startNewPhase(climb: Bool) {
        isClimbPhase = climb
        phaseSecondsRemaining = Int.random(in: 15...40)
        if climb {
            targetVerticalSpeed = Double.random(in: 0.8...3.0)
        } else {
            // ~1 sink phase out of 3 is strong enough to trigger the sink alarm
            targetVerticalSpeed = Int.random(in: 0...2) == 0
                ? Double.random(in: -3.5 ... -2.8)
                : Double.random(in: -2.0 ... -0.8)
        }
    }

    // MARK: - Helpers

    /// Builds a CLLocation offset east/north (meters) from the base coordinate.
    private func makeLocation(east: Double, north: Double, course: Double, speed: Double) -> CLLocation {
        let latitude = baseCoordinate.latitude + north / 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(baseCoordinate.latitude * .pi / 180.0)
        let longitude = baseCoordinate.longitude + east / metersPerDegreeLon

        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: course,
            speed: speed,
            timestamp: Date()
        )
    }
}
