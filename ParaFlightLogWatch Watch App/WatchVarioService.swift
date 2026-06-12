//
//  WatchVarioService.swift
//  ParaFlightLogWatch Watch App
//
//  Vario haptique + sonore : baromètre (CMAltimeter) → altitude pression → Kalman →
//  machine à états → restitution haptique (taps de montée, alarme de chute)
//  et, en option, bips audio (AVAudioEngine + sinusoïde).
//  Réutilise le moteur partagé VarioEngine.swift (iPhone + Watch).
//  Target: Watch only
//

import Foundation
import CoreMotion
import WatchKit
import AVFoundation
import os

// MARK: - Paramètres audio thread-safe (Watch)

/// Paramètres lus par le render block sur le thread audio.
/// Toujours échangés d'un bloc via OSAllocatedUnfairLock (jamais champ par champ).
/// Pas de mode descente continue sur la Watch : cohérent avec l'haptique
/// (rien en descente « normale », seulement montée + alarme de chute).
struct WatchVarioAudioParams: Sendable {
    enum Mode: Sendable {
        case silent     // amplitude nulle
        case climb      // bips cadencés (montée)
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

/// Générateur tonal Watch utilisé par l'AVAudioSourceNode.
/// Inspiré du VarioToneGenerator de l'iPhone (VarioService.swift) :
/// sinusoïde + enveloppe lissée anti-clic. Les compteurs (phase, position dans
/// le cycle) ne sont touchés QUE par le thread audio ; les paramètres arrivent
/// du MainActor via un lock.
final class WatchVarioToneGenerator: @unchecked Sendable {

    private let params = OSAllocatedUnfairLock(initialState: WatchVarioAudioParams())

    /// État interne du render block (thread audio uniquement)
    private var phase: Double = 0          // phase de la sinusoïde (rad)
    private var cycleTime: Double = 0      // position dans le cycle de bips (s)
    private var amplitude: Double = 0      // amplitude lissée (anti-clic)

    private let sampleRate: Double
    /// Lissage d'amplitude ≈ rampe d'attaque/release de ~5 ms (anti-clic)
    private let ampSmoothing: Double
    /// Gain global (marge pour éviter la saturation du petit HP de la Watch)
    private let masterGain: Double = 0.6

    /// Cycle et bips du mode .sinkAlarm (bi-bip rapide insistant)
    private static let alarmCycle = 0.5
    private static let alarmBeepDuration = 0.08
    private static let alarmSecondBeepOffset = 0.14

    init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        self.ampSmoothing = 1.0 - exp(-1.0 / (0.005 * sampleRate))
    }

    /// Met à jour les paramètres depuis le MainActor (thread-safe)
    func setParams(_ newParams: WatchVarioAudioParams) {
        params.withLock { $0 = newParams }
    }

    /// Coupe le son et réarme les compteurs (appelé hors lecture)
    func reset() {
        params.withLock { $0 = WatchVarioAudioParams() }
        phase = 0
        cycleTime = 0
        amplitude = 0
    }

    /// Durée du cycle de modulation pour les paramètres courants (s)
    private func cycleLength(for p: WatchVarioAudioParams) -> Double {
        switch p.mode {
        case .climb:        return max(p.beepInterval, 0.05)
        case .sinkAlarm:    return Self.alarmCycle
        case .silent:       return 1.0
        }
    }

    /// Enveloppe cible (0 ou 1) à la position `t` du cycle
    private func targetEnvelope(for p: WatchVarioAudioParams, at t: Double) -> Double {
        switch p.mode {
        case .silent:
            return 0
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

/// Service vario de la Watch : lit le baromètre pendant le vol, calcule la Vz
/// filtrée et la restitue en haptique. Démarré/arrêté avec le vol.
@Observable
@MainActor
final class WatchVarioService {
    static let shared = WatchVarioService()

    // MARK: - État publié (UI)

    /// Vitesse verticale filtrée (m/s)
    private(set) var currentVz: Double = 0
    /// Baromètre présent sur ce matériel
    private(set) var isBarometerAvailable: Bool = CMAltimeter.isRelativeAltitudeAvailable()
    /// Faux si le baro ne répond plus alors que le GPS bouge (cf. piège background ci-dessous)
    private(set) var isBarometerReliable: Bool = true
    /// Vario en cours d'exécution
    private(set) var isRunning: Bool = false

    // MARK: - Persistance on/off

    private static let enabledKey = "vario.enabled"
    private static let soundEnabledKey = "vario.sound.enabled"

    /// Activation utilisateur — même clé que l'iPhone, mais chaque appareil a ses UserDefaults
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Sons du vario (bips audio en plus de l'haptique). Défaut false :
    /// l'haptique reste le mode par défaut au poignet.
    static var isSoundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: soundEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: soundEnabledKey) }
    }

    // MARK: - Privé

    private let altimeter = CMAltimeter()
    private let kalmanFilter = VarioKalmanFilter()
    private let stateMachine = VarioStateMachine()

    /// Fournit la vitesse sol GPS courante (m/s) pour le diagnostic de fiabilité baro
    private var speedProvider: (() -> Double?)?

    // Haptique de montée (timer one-shot re-planifié à chaque tick selon la Vz)
    private var climbTimer: Timer?
    private var latestClimbVz: Double = 0
    // Haptique d'alarme de fort taux de chute (1 Hz)
    private var sinkAlarmTimer: Timer?

    // Audio (opt-in) : moteur démarré uniquement si le son est activé ET qu'un
    // vol est en cours — pas de moteur audio qui tourne pour rien (batterie/CPU)
    private let toneGenerator = WatchVarioToneGenerator()
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // PIÈGE CONNU À INSTRUMENTER : en background workout, la Watch peut renvoyer
    // les données baro de l'iPhone apparié (valeurs/cadence anormales). On log la
    // première pression et la cadence réelle des updates pour diagnostic en vol réel.
    private var startDate: Date?
    private var lastBaroUpdateDate: Date?
    private var firstSampleLogged = false
    private var cadenceWindowStart: Date?
    private var cadenceWindowCount = 0
    private var watchdogTimer: Timer?

    private init() {}

    // MARK: - Cycle de vie

    /// Démarre le vario. `speedProvider` retourne la vitesse sol GPS courante (m/s),
    /// utilisée pour détecter un baro silencieux alors qu'on est en mouvement.
    func start(speedProvider: (() -> Double?)? = nil) {
        guard !isRunning else { return }
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            isBarometerAvailable = false
            watchLogWarning("Vario: barometer not available on this device", category: .flight)
            return
        }

        isRunning = true
        isBarometerAvailable = true
        isBarometerReliable = true
        currentVz = 0
        self.speedProvider = speedProvider

        // Recharger les seuils utilisateur (clés communes iPhone/Watch)
        stateMachine.settings = VarioSettings.load()
        stateMachine.reset()
        kalmanFilter.reset()

        startDate = Date()
        lastBaroUpdateDate = nil
        firstSampleLogged = false
        cadenceWindowStart = nil
        cadenceWindowCount = 0

        // Updates baro sur la main queue → traitement isolé MainActor
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    watchLogWarning("Vario: altimeter error: \(error.localizedDescription)", category: .flight)
                    return
                }
                guard let data else { return }
                self.process(data)
            }
        }

        // Sons du vario (opt-in séparé) : le moteur audio ne tourne que si le
        // son est activé ET qu'un vol est en cours (économie batterie)
        if Self.isSoundEnabled {
            startAudioEngine()
        }

        startWatchdog()
        watchLogInfo("Vario started (sound: \(Self.isSoundEnabled ? "on" : "off"))", category: .flight)
    }

    /// Arrête le vario et coupe toute haptique/audio en cours
    func stop() {
        guard isRunning else { return }
        isRunning = false
        altimeter.stopRelativeAltitudeUpdates()
        stopClimbHaptics()
        stopSinkAlarmHaptics()
        stopAudioEngine()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        speedProvider = nil
        kalmanFilter.reset()
        stateMachine.reset()
        currentVz = 0
        isBarometerReliable = true
        watchLogInfo("Vario stopped", category: .flight)
    }

    // MARK: - Traitement baro

    private func process(_ data: CMAltitudeData) {
        let pressureKPa = data.pressure.doubleValue
        let altitude = BarometricFormula.pressureAltitude(fromKilopascals: pressureKPa)

        // Diagnostic : première valeur de pression brute (détection baro iPhone relayé)
        if !firstSampleLogged {
            firstSampleLogged = true
            watchLogInfo(String(format: "Vario: first baro sample %.3f kPa (pressure altitude %.1f m)", pressureKPa, altitude), category: .flight)
        }

        // Diagnostic : cadence réelle des updates (fenêtre glissante de 30 s)
        let now = Date()
        if let windowStart = cadenceWindowStart {
            cadenceWindowCount += 1
            let elapsed = now.timeIntervalSince(windowStart)
            if elapsed >= 30 {
                let rate = Double(cadenceWindowCount) / elapsed
                watchLogInfo(String(format: "Vario: baro update rate %.2f Hz (%d updates in %.0f s)", rate, cadenceWindowCount, elapsed), category: .flight)
                cadenceWindowStart = now
                cadenceWindowCount = 0
            }
        } else {
            cadenceWindowStart = now
            cadenceWindowCount = 0
        }

        lastBaroUpdateDate = now
        if !isBarometerReliable {
            isBarometerReliable = true
            watchLogInfo("Vario: baro updates resumed, marked reliable again", category: .flight)
        }

        // kPa → altitude pression → Kalman → Vz filtrée → état sonore
        let vz = kalmanFilter.update(altitudeMeasurement: altitude, timestamp: data.timestamp)
        currentVz = vz
        handle(state: stateMachine.update(vz: vz))
    }

    // MARK: - Restitution haptique + audio

    private func handle(state: VarioState) {
        switch state {
        case .climbing(let vz):
            stopSinkAlarmHaptics()
            latestClimbVz = vz
            if climbTimer == nil {
                playClimbTick()   // Premier tap immédiat, puis boucle re-planifiée
            }
        case .sinkAlarm:
            stopClimbHaptics()
            if sinkAlarmTimer == nil {
                startSinkAlarm()
            }
        case .sinking, .silent:
            // v1 : pas de restitution en descente "normale" ni en silence
            stopClimbHaptics()
            stopSinkAlarmHaptics()
        }

        // Restitution audio (no-op si le moteur audio n'est pas démarré)
        updateAudio(for: state)
    }

    // MARK: - Restitution audio (opt-in)

    /// Traduit l'état vario en paramètres audio pour le thread temps réel.
    /// Cohérent avec l'iPhone (montée → bips VarioTone, alarme → bi-bip insistant)
    /// et avec l'haptique Watch (descente « normale » : silence).
    private func updateAudio(for state: VarioState) {
        guard audioEngine != nil else { return }
        var params = WatchVarioAudioParams()
        switch state {
        case .climbing(let vz):
            params.mode = .climb
            params.frequency = VarioTone.frequency(forClimb: vz)
            params.beepInterval = VarioTone.beepInterval(forClimb: vz)
            params.beepDuration = VarioTone.beepDuration(forClimb: vz)
        case .sinkAlarm:
            params.mode = .sinkAlarm
            params.frequency = 950   // bi-bip aigu insistant (comme l'iPhone)
        case .sinking, .silent:
            params.mode = .silent
        }
        toneGenerator.setParams(params)
    }

    // MARK: - Moteur audio

    /// Active la session audio et démarre l'AVAudioEngine + source sinusoïdale.
    /// Sur watchOS, .playback peut router vers le haut-parleur de la montre.
    private func startAudioEngine() {
        guard audioEngine == nil else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playback + mixWithOthers : ne coupe pas la musique en cours
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            watchLogWarning("Vario: audio session activation failed: \(error.localizedDescription)", category: .flight)
        }

        let engine = AVAudioEngine()
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else { return }

        toneGenerator.reset()
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
            watchLogInfo("Vario: audio engine started", category: .flight)
        } catch {
            watchLogWarning("Vario: audio engine start failed: \(error.localizedDescription)", category: .flight)
            engine.detach(source)
        }
    }

    /// Arrête proprement le moteur audio et libère la session
    private func stopAudioEngine() {
        guard let engine = audioEngine else { return }
        engine.stop()
        if let source = sourceNode {
            engine.detach(source)
        }
        audioEngine = nil
        sourceNode = nil
        toneGenerator.reset()

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            watchLogWarning("Vario: audio session deactivation failed: \(error.localizedDescription)", category: .flight)
        }
        watchLogInfo("Vario: audio engine stopped", category: .flight)
    }

    /// Tap de montée, re-planifié à chaque tick avec la cadence de la Vz courante
    private func playClimbTick() {
        WKInterfaceDevice.current().play(.click)
        let interval = VarioTone.hapticInterval(forClimb: latestClimbVz)
        climbTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.climbTimer != nil else { return }
                self.playClimbTick()
            }
        }
    }

    private func stopClimbHaptics() {
        climbTimer?.invalidate()
        climbTimer = nil
    }

    /// Alarme de fort taux de chute : haptique forte toutes les 1 s
    private func startSinkAlarm() {
        WKInterfaceDevice.current().play(.notification)
        sinkAlarmTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.sinkAlarmTimer != nil else { return }
                WKInterfaceDevice.current().play(.notification)
            }
        }
    }

    private func stopSinkAlarmHaptics() {
        sinkAlarmTimer?.invalidate()
        sinkAlarmTimer = nil
    }

    // MARK: - Watchdog fiabilité baro

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkBarometerHealth()
            }
        }
    }

    /// Si aucun update baro pendant 10 s alors que le GPS bouge → baro non fiable
    private func checkBarometerHealth() {
        guard isRunning else { return }
        guard let reference = lastBaroUpdateDate ?? startDate else { return }
        let silence = Date().timeIntervalSince(reference)
        guard silence > 10 else { return }

        let gpsSpeed = speedProvider?() ?? 0
        guard gpsSpeed > 2.0 else { return }   // Immobile : silence baro non significatif

        if isBarometerReliable {
            isBarometerReliable = false
            watchLogWarning(String(format: "Vario: no baro update for %.0f s while GPS moving (%.1f m/s) — barometer marked unreliable", silence, gpsSpeed), category: .flight)
        }
        // Sécurité : couper haptiques et audio basés sur des données périmées
        stopClimbHaptics()
        stopSinkAlarmHaptics()
        toneGenerator.setParams(WatchVarioAudioParams())
    }
}
