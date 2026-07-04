//
//  VarioService.swift
//  ParaFlightLogWatch Watch App
//
//  Barometric variometer: computes a smoothed vertical speed from
//  CMAltimeter relative altitude updates and gives haptic feedback
//  (climb beeps that speed up with the climb rate, strong-sink alarm).
//  Active only during a flight; started/stopped from ActiveFlightView.
//  Target: Watch only
//

import Foundation
import CoreMotion
import WatchKit

@Observable
final class VarioService {
    static let shared = VarioService()

    /// True when the device has a barometric altimeter. When false, the
    /// vario feature is hidden entirely in the UI.
    static var isAvailable: Bool {
        CMAltimeter.isRelativeAltitudeAvailable()
    }

    /// Smoothed vertical speed in m/s (positive = climbing)
    var verticalSpeed: Double = 0.0
    private(set) var isRunning: Bool = false

    // MARK: - Tuning

    /// Climb haptics start above this rate (m/s)
    private let climbThreshold: Double = 0.5
    /// Strong sink alarm below this rate (m/s)
    private let strongSinkThreshold: Double = -2.5
    /// Exponential smoothing time constant (~1s)
    private let smoothingTimeConstant: TimeInterval = 1.0
    /// Minimum interval between strong-sink alarms
    private let sinkAlarmInterval: TimeInterval = 1.5

    // MARK: - Private state

    private var altimeter: CMAltimeter?
    private var lastRelativeAltitude: Double?
    private var lastSampleTimestamp: TimeInterval?
    private var hapticTimer: Timer?
    private var lastHapticDate: Date = .distantPast

    private init() {}

    // MARK: - Lifecycle

    /// Starts altimeter updates and haptic feedback. No-op if unavailable or already running.
    func start() {
        guard Self.isAvailable, !isRunning else { return }
        isRunning = true
        verticalSpeed = 0.0
        lastRelativeAltitude = nil
        lastSampleTimestamp = nil
        lastHapticDate = .distantPast

        let altimeter = CMAltimeter()
        self.altimeter = altimeter
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data, error == nil else { return }
            self.process(relativeAltitude: data.relativeAltitude.doubleValue,
                         timestamp: data.timestamp)
        }

        // Small tick timer that decides when to play the next haptic
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.hapticTick()
        }
        hapticTimer = timer

        watchLogInfo("Vario started", category: .flight)
    }

    /// Stops altimeter updates and haptics (called when the flight ends).
    func stop() {
        guard isRunning else { return }
        isRunning = false
        altimeter?.stopRelativeAltitudeUpdates()
        altimeter = nil
        hapticTimer?.invalidate()
        hapticTimer = nil
        verticalSpeed = 0.0
        lastRelativeAltitude = nil
        lastSampleTimestamp = nil

        watchLogInfo("Vario stopped", category: .flight)
    }

    // MARK: - Vertical Speed

    private func process(relativeAltitude: Double, timestamp: TimeInterval) {
        defer {
            lastRelativeAltitude = relativeAltitude
            lastSampleTimestamp = timestamp
        }

        guard let lastAltitude = lastRelativeAltitude,
              let lastTimestamp = lastSampleTimestamp else {
            return
        }

        let dt = timestamp - lastTimestamp
        guard dt > 0.01 else { return }

        let rawSpeed = (relativeAltitude - lastAltitude) / dt

        // Filter absurd spikes (> 30 m/s vertical is sensor noise)
        guard abs(rawSpeed) < 30.0 else { return }

        // Exponential smoothing over ~1s
        let alpha = dt / (smoothingTimeConstant + dt)
        verticalSpeed += alpha * (rawSpeed - verticalSpeed)
    }

    // MARK: - Haptics

    private func hapticTick() {
        guard isRunning else { return }
        let speed = verticalSpeed
        let now = Date()

        if speed >= climbThreshold {
            // Climb: repeating .directionUp, faster as the climb strengthens
            if now.timeIntervalSince(lastHapticDate) >= climbBeepInterval(for: speed) {
                WKInterfaceDevice.current().play(.directionUp)
                lastHapticDate = now
            }
        } else if speed <= strongSinkThreshold {
            // Strong sink: alarm
            if now.timeIntervalSince(lastHapticDate) >= sinkAlarmInterval {
                WKInterfaceDevice.current().play(.failure)
                lastHapticDate = now
            }
        }
    }

    /// Interval between climb beeps: ~1.0s at +0.5 m/s down to ~0.3s at +4 m/s and above
    private func climbBeepInterval(for climbRate: Double) -> TimeInterval {
        let maxRate = 4.0
        let clamped = min(max(climbRate, climbThreshold), maxRate)
        let progress = (clamped - climbThreshold) / (maxRate - climbThreshold)
        return 1.0 - progress * 0.7
    }
}
