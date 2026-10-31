//
//  VarioTone.swift
//  ParaFlightLogWatch Watch App
//
//  The audible half of the variometer: a short sine beep whose pitch rises
//  with the climb rate, and a low tone for strong sink. Synthesised rather
//  than played from files, so one generator covers every rate.
//  Target: Watch only
//

import Foundation
import AVFoundation

/// Plays the vario beeps.
///
/// Everything here is fail-soft: a Watch whose audio session cannot be taken
/// (another app holding it, a route that disappears) silently falls back to
/// haptics only. A vario that crashes a flight would be far worse than a
/// vario that stays quiet.
final class VarioTone {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private(set) var isReady = false

    // MARK: - Tuning

    /// Pitch at the lowest beeping climb rate (Hz).
    private let lowPitch: Double = 600
    /// Pitch at and above `maxRate` (Hz).
    private let highPitch: Double = 1400
    /// Climb rate mapped to `highPitch` (m/s).
    private let maxRate: Double = 4.0
    /// Strong-sink tone (Hz) — deliberately far below the climb range so the
    /// two are never mistaken for one another.
    private let sinkPitch: Double = 220
    /// Peak amplitude. Low on purpose: this plays next to the pilot's ear for
    /// a whole flight.
    private let amplitude: Double = 0.35
    /// Fade applied to both ends of every beep, to kill the click a square
    /// start and stop would otherwise produce.
    private let fade: TimeInterval = 0.006

    // MARK: - Lifecycle

    /// Starts the audio engine. Returns false when sound is not available, so
    /// the caller can fall back to haptics without retrying every tick.
    @discardableResult
    func start() -> Bool {
        guard !isReady else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback keeps the beeps audible with the wrist down; ducking
            // leaves whatever the pilot is listening to running underneath.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)

            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
            self.format = format
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
            isReady = true
            watchLogInfo("Vario tone ready", category: .flight)
            return true
        } catch {
            isReady = false
            watchLogWarning("Vario tone unavailable: \(error.localizedDescription)", category: .flight)
            return false
        }
    }

    func stop() {
        guard isReady else { return }
        isReady = false
        player.stop()
        engine.stop()
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Beeps

    /// One climb beep. Pitch rises with the rate, so the pilot reads the climb
    /// without looking at the watch — the whole point of an audible vario.
    func playClimb(rate: Double, duration: TimeInterval) {
        let clamped = min(max(rate, 0.5), maxRate)
        let progress = (clamped - 0.5) / (maxRate - 0.5)
        play(frequency: lowPitch + progress * (highPitch - lowPitch), duration: duration)
    }

    /// The strong-sink warning: low and longer than any climb beep.
    func playSink() {
        play(frequency: sinkPitch, duration: 0.35)
    }

    private func play(frequency: Double, duration: TimeInterval) {
        guard isReady, let format, let buffer = makeBuffer(frequency: frequency, duration: duration, format: format) else { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// Builds one faded sine burst.
    private func makeBuffer(frequency: Double, duration: TimeInterval, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let twoPi = 2.0 * Double.pi
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            var envelope = amplitude
            if t < fade {
                envelope *= t / fade
            }
            let remaining = duration - t
            if remaining < fade {
                envelope *= max(0, remaining / fade)
            }
            samples[frame] = Float(sin(twoPi * frequency * t) * envelope)
        }
        return buffer
    }
}
