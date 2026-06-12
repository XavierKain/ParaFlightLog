//
//  VarioEngine.swift
//  SoarX
//
//  Moteur de variomètre partagé iPhone + Watch.
//  Filtre de Kalman 2 états (altitude, vitesse verticale) alimenté par
//  l'altitude pression du baromètre (CMAltimeter) — cadence ~1 Hz imposée
//  par iOS. Positionné comme « assistant thermique », pas comme vario certifié.
//  Target: iOS + Watch
//

import Foundation

// MARK: - Filtre de Kalman altitude/Vz

/// Filtre de Kalman 2 états : altitude (m) et vitesse verticale (m/s).
/// Entrée : altitude pression (ou GPS en secours), sortie : Vz lissée.
final class VarioKalmanFilter {
    private var altitude: Double = 0
    private var verticalSpeed: Double = 0
    private var p00 = 1.0, p01 = 0.0, p10 = 0.0, p11 = 1.0
    private var lastTimestamp: TimeInterval?

    /// Bruit de process (variance d'accélération, (m/s²)²) — plus haut = plus réactif, plus bruité
    private let accelVariance: Double
    /// Bruit de mesure (m²) — baromètre ≈ 0,1, GPS ≈ 10
    private let measurementVariance: Double

    init(accelVariance: Double = 0.5, measurementVariance: Double = 0.12) {
        self.accelVariance = accelVariance
        self.measurementVariance = measurementVariance
    }

    func reset() {
        altitude = 0
        verticalSpeed = 0
        p00 = 1; p01 = 0; p10 = 0; p11 = 1
        lastTimestamp = nil
    }

    /// Intègre une mesure d'altitude et retourne la Vz filtrée (m/s)
    @discardableResult
    func update(altitudeMeasurement z: Double, timestamp t: TimeInterval) -> Double {
        guard let last = lastTimestamp else {
            altitude = z
            lastTimestamp = t
            return 0
        }
        let dt = t - last
        lastTimestamp = t

        // Trou de mesure ou horloge incohérente : on repart de la mesure
        guard dt > 0, dt < 10 else {
            altitude = z
            verticalSpeed = 0
            p00 = 1; p01 = 0; p10 = 0; p11 = 1
            return 0
        }

        // Prédiction
        altitude += verticalSpeed * dt
        let q = accelVariance
        p00 += dt * (p10 + p01) + dt * dt * p11 + 0.25 * q * dt * dt * dt * dt
        p01 += dt * p11 + 0.5 * q * dt * dt * dt
        p10 += dt * p11 + 0.5 * q * dt * dt * dt
        p11 += q * dt * dt

        // Correction
        let innovation = z - altitude
        let s = p00 + measurementVariance
        let k0 = p00 / s
        let k1 = p10 / s
        altitude += k0 * innovation
        verticalSpeed += k1 * innovation
        let newP00 = (1 - k0) * p00
        let newP01 = (1 - k0) * p01
        p10 -= k1 * p00
        p11 -= k1 * p01
        p00 = newP00
        p01 = newP01

        return verticalSpeed
    }

    var currentVerticalSpeed: Double { verticalSpeed }
    var currentAltitude: Double { altitude }
}

// MARK: - Conversion pression → altitude

enum BarometricFormula {
    /// Altitude pression standard (m) depuis une pression en kPa (formule ISA, réf. 101,325 kPa).
    /// L'altitude absolue importe peu pour un vario : seules les variations comptent.
    static func pressureAltitude(fromKilopascals pressure: Double) -> Double {
        44330.0 * (1.0 - pow(pressure / 101.325, 0.1903))
    }
}

// MARK: - Réglages du vario

/// Réglages utilisateur du vario, persistés en UserDefaults (clés communes iPhone/Watch).
struct VarioSettings {
    /// Seuil de déclenchement des bips de montée (m/s)
    var climbOnThreshold: Double = 0.2
    /// Seuil d'arrêt des bips de montée (hystérésis, m/s)
    var climbOffThreshold: Double = 0.1
    /// Seuil de déclenchement du son de descente (m/s, négatif)
    var sinkOnThreshold: Double = -2.5
    /// Alarme de fort taux de chute (m/s, négatif)
    var sinkAlarmThreshold: Double = -6.0

    private static let climbOnKey = "vario.climbOnThreshold"
    private static let climbOffKey = "vario.climbOffThreshold"
    private static let sinkOnKey = "vario.sinkOnThreshold"
    private static let sinkAlarmKey = "vario.sinkAlarmThreshold"

    static func load(from defaults: UserDefaults = .standard) -> VarioSettings {
        var s = VarioSettings()
        if defaults.object(forKey: climbOnKey) != nil { s.climbOnThreshold = defaults.double(forKey: climbOnKey) }
        if defaults.object(forKey: climbOffKey) != nil { s.climbOffThreshold = defaults.double(forKey: climbOffKey) }
        if defaults.object(forKey: sinkOnKey) != nil { s.sinkOnThreshold = defaults.double(forKey: sinkOnKey) }
        if defaults.object(forKey: sinkAlarmKey) != nil { s.sinkAlarmThreshold = defaults.double(forKey: sinkAlarmKey) }
        return s
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(climbOnThreshold, forKey: Self.climbOnKey)
        defaults.set(climbOffThreshold, forKey: Self.climbOffKey)
        defaults.set(sinkOnThreshold, forKey: Self.sinkOnKey)
        defaults.set(sinkAlarmThreshold, forKey: Self.sinkAlarmKey)
    }
}

// MARK: - État sonore du vario

/// État de restitution dérivé de la Vz + seuils (avec hystérésis sur la montée)
enum VarioState: Equatable {
    case silent
    case climbing(vz: Double)
    case sinking(vz: Double)
    case sinkAlarm(vz: Double)
}

/// Machine à états : transforme la Vz filtrée en état sonore stable (hystérésis)
final class VarioStateMachine {
    private(set) var state: VarioState = .silent
    var settings: VarioSettings

    init(settings: VarioSettings = VarioSettings()) {
        self.settings = settings
    }

    @discardableResult
    func update(vz: Double) -> VarioState {
        switch state {
        case .climbing:
            if vz <= settings.sinkAlarmThreshold { state = .sinkAlarm(vz: vz) }
            else if vz <= settings.sinkOnThreshold { state = .sinking(vz: vz) }
            else if vz < settings.climbOffThreshold { state = .silent }
            else { state = .climbing(vz: vz) }
        case .silent, .sinking, .sinkAlarm:
            if vz <= settings.sinkAlarmThreshold { state = .sinkAlarm(vz: vz) }
            else if vz <= settings.sinkOnThreshold { state = .sinking(vz: vz) }
            else if vz >= settings.climbOnThreshold { state = .climbing(vz: vz) }
            else { state = .silent }
        }
        return state
    }

    func reset() { state = .silent }
}

// MARK: - Mapping Vz → son

/// Mapping classique vario : plus ça monte, plus le bip est aigu et rapproché
enum VarioTone {
    /// Fréquence du bip (Hz) pour une Vz de montée (clampée 0…+5 m/s)
    static func frequency(forClimb vz: Double) -> Double {
        let clamped = min(max(vz, 0), 5)
        return 600 + clamped * 160   // 600 Hz → 1400 Hz
    }

    /// Intervalle entre débuts de bips (s) pour une Vz de montée
    static func beepInterval(forClimb vz: Double) -> Double {
        let clamped = min(max(vz, 0), 5)
        return max(0.12, 0.55 - clamped * 0.08)   // 0,55 s → 0,15 s
    }

    /// Durée d'un bip (s)
    static func beepDuration(forClimb vz: Double) -> Double {
        min(0.18, beepInterval(forClimb: vz) * 0.45)
    }

    /// Fréquence du son continu de descente (Hz) — grave, descend avec la Vz
    static func frequency(forSink vz: Double) -> Double {
        let clamped = min(max(-vz, 2.5), 8)
        return max(180, 420 - clamped * 30)
    }

    /// Cadence haptique Watch (intervalle s entre taps) pour une Vz de montée
    static func hapticInterval(forClimb vz: Double) -> Double {
        let clamped = min(max(vz, 0), 5)
        return max(0.25, 0.9 - clamped * 0.13)   // 0,9 s → 0,25 s
    }
}
