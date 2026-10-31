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

/// Why the vario is, or is not, showing a number. The readout used to print a
/// silent "0.0 m/s" in every failure case, which is indistinguishable from
/// genuinely level flight — so a denied Motion & Fitness permission looked
/// exactly like a working vario.
enum VarioStatus: Equatable {
    /// Switched off by the pilot.
    case off
    /// This Watch has no barometer.
    case unsupported
    /// Motion & Fitness is denied or restricted — no samples will ever arrive.
    case needsPermission
    /// Running, but no usable sample yet (the first callback is discarded
    /// because a vertical speed needs two of them).
    case warmingUp
    /// Delivering vertical speed.
    case running
    /// Core Motion reported an error.
    case failed
}

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
    private(set) var status: VarioStatus = .off

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
    /// True while the fake flight feed is driving the vario instead of the
    /// barometer (see `ingestSimulatedAltitude`).
    private var isSimulated = false
    private var lastRelativeAltitude: Double?
    private var lastSampleTimestamp: TimeInterval?
    private var hapticTimer: Timer?
    private var lastHapticDate: Date = .distantPast

    private init() {}

    // MARK: - Lifecycle

    /// Starts altimeter updates and haptic feedback. No-op if already running.
    /// Sets `status` on every early return so the UI can say why instead of
    /// showing a motionless zero.
    func start() {
        guard !isRunning else { return }

        // Developer mode: the fake flight feed moves altitude, speed and
        // G-force but the barometer stays where the Watch is, so the vario was
        // the one tile that could never move during a simulated flight — which
        // reads exactly like a broken vario. Let the feed drive it instead.
        if WatchSettings.shared.simulateFlightEnabled {
            startSimulated()
            return
        }

        guard Self.isAvailable else {
            status = .unsupported
            watchLogWarning("Vario not started: this Watch has no barometer", category: .flight)
            return
        }

        // Motion & Fitness is per-device, so a freshly paired Watch starts out
        // unauthorized even though the iPhone app has had the permission for
        // months. .notDetermined is fine: the first updates call prompts.
        switch CMAltimeter.authorizationStatus() {
        case .denied, .restricted:
            status = .needsPermission
            watchLogWarning("Vario not started: Motion & Fitness denied or restricted", category: .flight)
            return
        case .notDetermined, .authorized:
            break
        @unknown default:
            break
        }

        isRunning = true
        status = .warmingUp
        verticalSpeed = 0.0
        lastRelativeAltitude = nil
        lastSampleTimestamp = nil
        lastHapticDate = .distantPast

        let altimeter = CMAltimeter()
        self.altimeter = altimeter
        // The handler closure is @Sendable: extract the plain values, then hop
        // to the main actor before touching @Observable/MainActor state.
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            let errorDescription = error?.localizedDescription
            let sample = data.map { ($0.relativeAltitude.doubleValue, $0.timestamp) }
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }
                if let errorDescription {
                    // Swallowing this is what made a permission problem
                    // look like still air.
                    self.status = .failed
                    watchLogWarning("Vario altimeter error: \(errorDescription)", category: .flight)
                    return
                }
                guard let sample else { return }
                self.process(relativeAltitude: sample.0, timestamp: sample.1)
            }
        }

        // Small tick timer that decides when to play the next haptic.
        // The timer block is @Sendable: hop to main before calling hapticTick().
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hapticTick()
            }
        }
        hapticTimer = timer

        watchLogInfo("Vario started", category: .flight)
    }

    /// Runs the vario off the simulated flight feed: no altimeter, no
    /// permission needed, but the same smoothing and the same haptics, so what
    /// is exercised is the real code path.
    private func startSimulated() {
        isRunning = true
        isSimulated = true
        status = .warmingUp
        verticalSpeed = 0.0
        lastRelativeAltitude = nil
        lastSampleTimestamp = nil
        lastHapticDate = .distantPast

        hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hapticTick()
            }
        }

        watchLogInfo("Vario started on the simulated feed", category: .flight)
    }

    /// Feeds one simulated altitude sample. Called from the fake flight feed
    /// so the vario and the altitude tile can never disagree: both come from
    /// the same number.
    func ingestSimulatedAltitude(_ altitude: Double) {
        guard isRunning, isSimulated else { return }
        process(relativeAltitude: altitude, timestamp: ProcessInfo.processInfo.systemUptime)
    }

    /// Stops altimeter updates and haptics (called when the flight ends).
    func stop() {
        guard isRunning else {
            // Clear a failure state so the next flight starts from scratch
            // instead of inheriting a stale "needs permission".
            status = .off
            return
        }
        isRunning = false
        isSimulated = false
        status = .off
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

        if status != .running {
            status = .running
            watchLogInfo("Vario delivering samples", category: .flight)
        }
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
