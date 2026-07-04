//
//  PhoneVarioService.swift
//  ParaFlightLog
//
//  Barometric variometer for the iPhone: computes a smoothed vertical
//  speed from CMAltimeter relative altitude updates (same filtering as
//  the Watch VarioService) and plays audio beeps + haptics:
//  - climb beeps whose pitch and rate rise with the climb rate (>= +0.5 m/s)
//  - a low tone under strong sink (<= -2.5 m/s)
//  Audio uses an AVAudioEngine sine generator on a .playback session with
//  .mixWithOthers, so music/navigation keep playing.
//
//  A manual mode lets the flight simulator inject its own vertical speed
//  so the vario can be exercised in the Xcode simulator (no barometer).
//  Started/stopped from TimerView while a flight is running.
//  Target: iOS only
//

import Foundation
import CoreMotion
import AVFoundation
import UIKit

@Observable
final class PhoneVarioService {

    /// Data source for the vertical speed
    enum Mode {
        /// Real barometric altimeter (CMAltimeter)
        case altimeter
        /// Vertical speed injected via `ingest(verticalSpeed:)` (simulation)
        case manual
    }

    /// True when the device has a barometric altimeter.
    static var isAltimeterAvailable: Bool {
        CMAltimeter.isRelativeAltitudeAvailable()
    }

    /// Smoothed vertical speed in m/s (positive = climbing)
    private(set) var verticalSpeed: Double = 0.0
    private(set) var isRunning: Bool = false

    // MARK: - Tuning

    /// Climb beeps start above this rate (m/s)
    private let climbThreshold: Double = 0.5
    /// Strong sink tone below this rate (m/s)
    private let strongSinkThreshold: Double = -2.5
    /// Exponential smoothing time constant (~1s), same as the Watch vario
    private let smoothingTimeConstant: TimeInterval = 1.0
    /// Minimum interval between strong-sink tones
    private let sinkToneInterval: TimeInterval = 1.5
    /// Duration of the strong-sink tone
    private let sinkToneDuration: TimeInterval = 0.6
    /// Frequency of the strong-sink tone (Hz)
    private let sinkToneFrequency: Double = 260.0

    // MARK: - Private state

    private var mode: Mode = .altimeter
    private var altimeter: CMAltimeter?
    private var lastRelativeAltitude: Double?
    private var lastSampleTimestamp: TimeInterval?

    private var beepTimer: Timer?
    private var lastBeepDate: Date = .distantPast
    private var toneOffDate: Date = .distantPast

    private var audioEngine: AVAudioEngine?
    private var toneGenerator: ToneGenerator?

    private let climbHaptic = UIImpactFeedbackGenerator(style: .light)
    private let sinkHaptic = UIImpactFeedbackGenerator(style: .heavy)

    // MARK: - Lifecycle

    /// Starts the vario. In `.altimeter` mode this is a no-op when the
    /// device has no barometer; `.manual` mode always works.
    func start(mode: Mode = .altimeter) {
        guard !isRunning else { return }
        if mode == .altimeter && !Self.isAltimeterAvailable {
            logWarning("Vario not started: no barometric altimeter on this device", category: .flight)
            return
        }

        self.mode = mode
        isRunning = true
        verticalSpeed = 0.0
        lastRelativeAltitude = nil
        lastSampleTimestamp = nil
        lastBeepDate = .distantPast
        toneOffDate = .distantPast

        configureAudioSession()
        startAudioEngine()
        climbHaptic.prepare()

        if mode == .altimeter {
            let altimeter = CMAltimeter()
            self.altimeter = altimeter
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                guard let self = self, let data = data, error == nil else { return }
                self.process(relativeAltitude: data.relativeAltitude.doubleValue,
                             timestamp: data.timestamp)
            }
        }

        // Small tick timer that schedules beeps and the tone envelope
        beepTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.beepTick()
        }

        logInfo("Phone vario started (mode: \(mode == .altimeter ? "altimeter" : "manual"))", category: .flight)
    }

    /// Stops altimeter updates, audio and haptics. Safe to call repeatedly.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        altimeter?.stopRelativeAltitudeUpdates()
        altimeter = nil
        beepTimer?.invalidate()
        beepTimer = nil

        toneGenerator?.targetAmplitude = 0
        audioEngine?.stop()
        audioEngine = nil
        toneGenerator = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        verticalSpeed = 0.0
        lastRelativeAltitude = nil
        lastSampleTimestamp = nil

        logInfo("Phone vario stopped", category: .flight)
    }

    /// Feeds a vertical speed sample in `.manual` mode (flight simulator).
    func ingest(verticalSpeed: Double) {
        guard isRunning, mode == .manual else { return }
        self.verticalSpeed = verticalSpeed
    }

    // MARK: - Vertical speed (altimeter mode)

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

    // MARK: - Beep scheduling

    private func beepTick() {
        guard isRunning else { return }
        let speed = verticalSpeed
        let now = Date()

        // End the current beep when its duration has elapsed
        if now >= toneOffDate {
            toneGenerator?.targetAmplitude = 0
        }

        if speed >= climbThreshold {
            // Climb: short beeps, faster and higher pitched as the climb strengthens
            if now.timeIntervalSince(lastBeepDate) >= climbBeepInterval(for: speed) {
                let interval = climbBeepInterval(for: speed)
                toneGenerator?.frequency = climbFrequency(for: speed)
                toneGenerator?.targetAmplitude = 0.4
                toneOffDate = now.addingTimeInterval(interval * 0.45)
                lastBeepDate = now
                climbHaptic.impactOccurred()
            }
        } else if speed <= strongSinkThreshold {
            // Strong sink: long low tone
            if now.timeIntervalSince(lastBeepDate) >= sinkToneInterval {
                toneGenerator?.frequency = sinkToneFrequency
                toneGenerator?.targetAmplitude = 0.4
                toneOffDate = now.addingTimeInterval(sinkToneDuration)
                lastBeepDate = now
                sinkHaptic.impactOccurred()
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

    /// Beep pitch: ~670 Hz at +0.5 m/s rising to ~1440 Hz at +6 m/s
    private func climbFrequency(for climbRate: Double) -> Double {
        600.0 + 140.0 * min(max(climbRate, 0.0), 6.0)
    }

    // MARK: - Audio engine

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            logError("Vario audio session error: \(error.localizedDescription)", category: .flight)
        }
    }

    private func startAudioEngine() {
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let generator = ToneGenerator(sampleRate: sampleRate > 0 ? sampleRate : 44_100)

        let sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            generator.render(bufferList: audioBufferList, frameCount: frameCount)
            return noErr
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: generator.sampleRate, channels: 1) else {
            logError("Vario audio format creation failed", category: .flight)
            return
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
            audioEngine = engine
            toneGenerator = generator
        } catch {
            logError("Vario audio engine failed to start: \(error.localizedDescription)", category: .flight)
            audioEngine = nil
            toneGenerator = nil
        }
    }
}

// MARK: - ToneGenerator

/// Simple sine wave generator shared with the audio render thread.
/// `frequency` and `targetAmplitude` are written from the main thread and
/// read on the render thread; the amplitude is ramped per-sample to avoid
/// clicks at beep boundaries.
private final class ToneGenerator {
    let sampleRate: Double
    var frequency: Double = 700.0
    var targetAmplitude: Float = 0.0

    private var currentAmplitude: Float = 0.0
    private var phase: Double = 0.0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func render(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let phaseIncrement = 2.0 * Double.pi * frequency / sampleRate
        // ~5 ms attack/release ramp
        let ramp = Float(1.0 / (0.005 * sampleRate))
        let target = targetAmplitude

        for frame in 0..<Int(frameCount) {
            if currentAmplitude < target {
                currentAmplitude = min(currentAmplitude + ramp, target)
            } else if currentAmplitude > target {
                currentAmplitude = max(currentAmplitude - ramp, target)
            }

            let sample = Float(sin(phase)) * currentAmplitude
            phase += phaseIncrement
            if phase > 2.0 * Double.pi {
                phase -= 2.0 * Double.pi
            }

            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                data[frame] = sample
            }
        }
    }
}
