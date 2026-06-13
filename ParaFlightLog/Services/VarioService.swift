//
//  VarioService.swift
//  ParaFlightLog
//
//  Variomètre iPhone : baromètre (CMAltimeter) → filtre de Kalman → machine
//  à états → restitution audio temps réel (AVAudioEngine + sinusoïde).
//  Réutilise le moteur partagé VarioEngine.swift (Kalman, seuils, mapping son).
//  Target: iOS only
//

import Foundation
import CoreMotion
import AVFoundation
import os

// MARK: - Paramètres audio thread-safe

/// Paramètres lus par le render block sur le thread audio.
/// Toujours échangés d'un bloc via OSAllocatedUnfairLock (jamais champ par champ).
struct VarioAudioParams: Sendable {
    enum Mode: Sendable {
        case silent     // amplitude nulle
        case climb      // bips cadencés (montée)
        case sink       // son continu grave (descente)
        case sinkAlarm  // bi-bip rapide insistant (fort taux de chute)
    }

    var mode: Mode = .silent
    /// Fréquence de la sinusoïde (Hz)
    var frequency: Double = 600
    /// Intervalle entre débuts de bips (s) — mode .climb
    var beepInterval: Double = 0.5
    /// Durée d'un bip (s) — mode .climb
    var beepDuration: Double = 0.15
}

// MARK: - Générateur de sinusoïde (thread audio)

/// Générateur tonal utilisé par l'AVAudioSourceNode.
/// Les compteurs (phase, position dans le cycle) ne sont touchés QUE par le
/// thread audio ; les paramètres arrivent du MainActor via un lock.
final class VarioToneGenerator: @unchecked Sendable {

    private let params = OSAllocatedUnfairLock(initialState: VarioAudioParams())

    /// État interne du render block (thread audio uniquement)
    private var phase: Double = 0          // phase de la sinusoïde (rad)
    private var cycleTime: Double = 0      // position dans le cycle de bips (s)
    private var amplitude: Double = 0      // amplitude lissée (anti-clic)

    private let sampleRate: Double
    /// Lissage d'amplitude ≈ rampe d'attaque/release de ~5 ms (anti-clic)
    private let ampSmoothing: Double
    /// Gain global (marge pour éviter la saturation)
    private let masterGain: Double = 0.6

    /// Cycle et bips du mode .sinkAlarm (bi-bip rapide)
    private static let alarmCycle = 0.5
    private static let alarmBeepDuration = 0.08
    private static let alarmSecondBeepOffset = 0.14

    init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        self.ampSmoothing = 1.0 - exp(-1.0 / (0.005 * sampleRate))
    }

    /// Met à jour les paramètres depuis le MainActor (thread-safe)
    func setParams(_ newParams: VarioAudioParams) {
        params.withLock { $0 = newParams }
    }

    /// Coupe le son et réarme les compteurs (appelé hors lecture)
    func reset() {
        params.withLock { $0 = VarioAudioParams() }
        phase = 0
        cycleTime = 0
        amplitude = 0
    }

    /// Durée du cycle de modulation pour les paramètres courants (s)
    private func cycleLength(for p: VarioAudioParams) -> Double {
        switch p.mode {
        case .climb:                return max(p.beepInterval, 0.05)
        case .sinkAlarm:            return Self.alarmCycle
        case .silent, .sink:        return 1.0
        }
    }

    /// Enveloppe cible (0 ou 1) à la position `t` du cycle
    private func targetEnvelope(for p: VarioAudioParams, at t: Double) -> Double {
        switch p.mode {
        case .silent:
            return 0
        case .sink:
            return 1
        case .climb:
            return t < min(p.beepDuration, p.beepInterval) ? 1 : 0
        case .sinkAlarm:
            let inFirstBeep = t < Self.alarmBeepDuration
            let t2 = t - Self.alarmSecondBeepOffset
            let inSecondBeep = t2 >= 0 && t2 < Self.alarmBeepDuration
            return (inFirstBeep || inSecondBeep) ? 1 : 0
        }
    }

    /// Remplit le buffer audio (appelé sur le thread temps réel)
    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let p = params.withLock { $0 }
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let cycle = cycleLength(for: p)
        let phaseIncrement = 2.0 * Double.pi * p.frequency / sampleRate
        let dt = 1.0 / sampleRate

        for frame in 0..<Int(frameCount) {
            // Enveloppe lissée (rampes ~5 ms → pas de clics)
            let target = targetEnvelope(for: p, at: cycleTime)
            amplitude += (target - amplitude) * ampSmoothing

            let sample = Float(sin(phase) * amplitude * masterGain)

            phase += phaseIncrement
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            cycleTime += dt
            if cycleTime >= cycle { cycleTime -= cycle }

            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                data[frame] = sample
            }
        }
    }
}

// MARK: - VarioService

/// Service vario iPhone : pilote le baromètre et l'audio pendant le vol.
/// Démarré/arrêté par TimerView au même cycle de vie que le tracking GPS.
@Observable
@MainActor
final class VarioService {

    static let shared = VarioService()

    // MARK: État publié (UI)

    /// Vitesse verticale filtrée (m/s), pour affichage temps réel
    private(set) var currentVz: Double = 0
    /// État sonore courant (silence / montée / descente / alarme)
    private(set) var state: VarioState = .silent
    /// Le vario est-il en train de tourner ?
    private(set) var isRunning = false
    /// Baromètre disponible sur cet appareil ? (pas de fallback GPS en v1)
    private(set) var isBarometerAvailable = true

    // MARK: Activation persistée

    private static let enabledKey = "vario.enabled"

    @ObservationIgnored
    private var _isEnabled: Bool = UserDefaults.standard.bool(forKey: VarioService.enabledKey)

    /// Vario activé par l'utilisateur (persisté). Si false, start() ne fait rien.
    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return _isEnabled
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                _isEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            }
        }
    }

    // MARK: Internes

    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var kalmanFilter = VarioKalmanFilter(accelVariance: 0.5, measurementVariance: 0.12)
    @ObservationIgnored private var stateMachine = VarioStateMachine()
    @ObservationIgnored private let toneGenerator = VarioToneGenerator()
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?

    private init() {
        observeAudioInterruptions()
    }

    // MARK: - Cycle de vie

    /// Démarre le vario (baromètre + audio). Sans effet si désactivé ou déjà lancé.
    func start() {
        guard isEnabled, !isRunning else { return }

        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            // Pas de baromètre (vieil appareil / simulateur) : pas d'audio GPS en v1
            isBarometerAvailable = false
            return
        }
        isBarometerAvailable = true

        // Réarmer les filtres et recharger les seuils utilisateur
        kalmanFilter.reset()
        stateMachine.reset()
        stateMachine.settings = VarioSettings.load()
        currentVz = 0
        state = .silent
        toneGenerator.reset()

        startAudioEngine()

        // CMAltimeter délivre ~1 Hz sur la main queue : pression brute → altitude ISA
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard error == nil, let data else { return }
            let pressureKPa = data.pressure.doubleValue
            let timestamp = data.timestamp
            MainActor.assumeIsolated {
                self?.processAltitudeSample(pressureKPa: pressureKPa, timestamp: timestamp)
            }
        }

        isRunning = true
    }

    /// Coupe le vario : altimètre, audio, et remise à zéro des filtres.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        altimeter.stopRelativeAltitudeUpdates()
        stopAudioEngine()

        kalmanFilter.reset()
        stateMachine.reset()
        toneGenerator.reset()
        currentVz = 0
        state = .silent
    }

    // MARK: - Traitement des mesures

    /// Pression brute (kPa) → altitude pression → Kalman → état sonore → audio
    private func processAltitudeSample(pressureKPa: Double, timestamp: TimeInterval) {
        guard isRunning else { return }

        let altitude = BarometricFormula.pressureAltitude(fromKilopascals: pressureKPa)
        let vz = kalmanFilter.update(altitudeMeasurement: altitude, timestamp: timestamp)
        currentVz = vz
        state = stateMachine.update(vz: vz)

        // Traduire l'état en paramètres audio pour le thread temps réel
        var params = VarioAudioParams()
        switch state {
        case .silent:
            params.mode = .silent
        case .climbing(let v):
            params.mode = .climb
            params.frequency = VarioTone.frequency(forClimb: v)
            params.beepInterval = VarioTone.beepInterval(forClimb: v)
            params.beepDuration = VarioTone.beepDuration(forClimb: v)
        case .sinking(let v):
            params.mode = .sink
            params.frequency = VarioTone.frequency(forSink: v)
        case .sinkAlarm:
            params.mode = .sinkAlarm
            params.frequency = 950   // bi-bip aigu insistant
        }
        toneGenerator.setParams(params)
    }

    // MARK: - Moteur audio

    /// Active la session audio et démarre l'AVAudioEngine + source sinusoïdale
    private func startAudioEngine() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback + mixWithOthers : continue en arrière-plan, ne coupe pas la musique
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Session audio indisponible : on n'installe pas de moteur muet trompeur.
            logError("Vario: échec d'activation de la session audio, vario audio désactivé: \(error.localizedDescription)", category: .general)
            return
        }

        let engine = AVAudioEngine()
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else { return }

        let generator = toneGenerator
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            generator.render(frameCount: frameCount, audioBufferList: audioBufferList)
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
            audioEngine = engine
            sourceNode = source
        } catch {
            logError("Vario: échec de démarrage du moteur audio: \(error.localizedDescription)", category: .general)
            engine.detach(source)
        }
    }

    /// Arrête le moteur audio et libère la session (en notifiant les autres apps)
    private func stopAudioEngine() {
        if let engine = audioEngine {
            engine.stop()
            if let source = sourceNode {
                engine.detach(source)
            }
        }
        audioEngine = nil
        sourceNode = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logError("Vario: échec de désactivation de la session audio: \(error.localizedDescription)", category: .general)
        }
    }

    // MARK: - Interruptions audio (appel, Siri, …)

    /// Relance le moteur après une interruption système si le vario tourne encore
    private func observeAudioInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            MainActor.assumeIsolated {
                self?.handleAudioInterruption(type: type, options: options)
            }
        }
    }

    private func handleAudioInterruption(type: AVAudioSession.InterruptionType,
                                         options: AVAudioSession.InterruptionOptions) {
        guard isRunning else { return }

        switch type {
        case .began:
            // Le moteur est mis en pause par le système — rien à faire ici
            break
        case .ended:
            // Relancer le moteur (même sans .shouldResume : le vario est un outil de vol)
            _ = options
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                if let engine = audioEngine, !engine.isRunning {
                    try engine.start()
                }
            } catch {
                logError("Vario: échec de reprise audio après interruption: \(error.localizedDescription)", category: .general)
            }
        @unknown default:
            break
        }
    }
}
