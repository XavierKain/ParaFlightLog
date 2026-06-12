//
//  WatchVarioService.swift
//  ParaFlightLogWatch Watch App
//
//  Vario haptique : baromètre (CMAltimeter) → altitude pression → Kalman →
//  machine à états → restitution haptique (taps de montée, alarme de chute).
//  Réutilise le moteur partagé VarioEngine.swift (iPhone + Watch).
//  Target: Watch only
//

import Foundation
import CoreMotion
import WatchKit

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

    /// Activation utilisateur — même clé que l'iPhone, mais chaque appareil a ses UserDefaults
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
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

        startWatchdog()
        watchLogInfo("Vario started", category: .flight)
    }

    /// Arrête le vario et coupe toute haptique en cours
    func stop() {
        guard isRunning else { return }
        isRunning = false
        altimeter.stopRelativeAltitudeUpdates()
        stopClimbHaptics()
        stopSinkAlarmHaptics()
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

    // MARK: - Restitution haptique

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
        // Sécurité : couper les haptiques basées sur des données périmées
        stopClimbHaptics()
        stopSinkAlarmHaptics()
    }
}
