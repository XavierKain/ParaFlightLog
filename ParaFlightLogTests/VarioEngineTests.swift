//
//  VarioEngineTests.swift
//  ParaFlightLogTests
//
//  Tests du moteur de variomètre (filtre de Kalman, machine à états, tonalités).
//

import XCTest
@testable import ParaFlightLog

final class VarioEngineTests: XCTestCase {

    // MARK: - Filtre de Kalman

    /// Une montée régulière à +2 m/s doit faire converger la Vz estimée vers ~2 m/s.
    func testKalmanConvergesToConstantClimb() {
        let filter = VarioKalmanFilter()
        let climbRate = 2.0
        var altitude = 1000.0
        var vz = 0.0
        // 1 échantillon/s pendant 30 s
        for i in 0..<30 {
            altitude += climbRate * 1.0
            vz = filter.update(altitudeMeasurement: altitude, timestamp: Double(i))
        }
        XCTAssertEqual(vz, climbRate, accuracy: 0.25, "La Vz doit converger vers +2 m/s")
    }

    /// Une descente régulière doit donner une Vz négative cohérente.
    func testKalmanConvergesToConstantSink() {
        let filter = VarioKalmanFilter()
        var altitude = 2000.0
        var vz = 0.0
        for i in 0..<30 {
            altitude -= 1.5
            vz = filter.update(altitudeMeasurement: altitude, timestamp: Double(i))
        }
        XCTAssertEqual(vz, -1.5, accuracy: 0.25)
    }

    /// Altitude stable → Vz proche de zéro.
    func testKalmanStableAltitude() {
        let filter = VarioKalmanFilter()
        var vz = 0.0
        for i in 0..<20 {
            vz = filter.update(altitudeMeasurement: 1500.0, timestamp: Double(i))
        }
        XCTAssertEqual(vz, 0.0, accuracy: 0.15)
    }

    /// Un grand trou temporel réinitialise proprement (pas d'explosion de la Vz).
    func testKalmanResetsOnLargeGap() {
        let filter = VarioKalmanFilter()
        _ = filter.update(altitudeMeasurement: 1000, timestamp: 0)
        _ = filter.update(altitudeMeasurement: 1002, timestamp: 1)
        let vz = filter.update(altitudeMeasurement: 1500, timestamp: 100) // trou de 99 s
        XCTAssertEqual(vz, 0.0, accuracy: 0.001, "Un trou > 10 s doit remettre la Vz à 0")
    }

    // MARK: - Altitude barométrique

    func testPressureAltitudeAtSeaLevel() {
        // Pression standard ISA au niveau de la mer
        let alt = BarometricFormula.pressureAltitude(fromKilopascals: 101.325)
        XCTAssertEqual(alt, 0, accuracy: 1.0)
    }

    func testPressureAltitudeDecreasesWithPressure() {
        let low = BarometricFormula.pressureAltitude(fromKilopascals: 90.0)
        let high = BarometricFormula.pressureAltitude(fromKilopascals: 101.325)
        XCTAssertGreaterThan(low, high, "Une pression plus faible = altitude plus élevée")
    }

    // MARK: - Machine à états (hystérésis)

    func testStateMachineClimbHysteresis() {
        var settings = VarioSettings()
        settings.climbOnThreshold = 0.2
        settings.climbOffThreshold = 0.1
        let sm = VarioStateMachine(settings: settings)

        XCTAssertEqual(sm.update(vz: 0.05), .silent)
        // franchit le seuil ON
        guard case .climbing = sm.update(vz: 0.25) else { return XCTFail("doit passer en montée") }
        // entre les deux seuils → reste en montée (hystérésis)
        guard case .climbing = sm.update(vz: 0.15) else { return XCTFail("doit rester en montée (hystérésis)") }
        // sous le seuil OFF → silence
        XCTAssertEqual(sm.update(vz: 0.05), .silent)
    }

    func testStateMachineSinkAlarm() {
        var settings = VarioSettings()
        settings.sinkOnThreshold = -2.5
        settings.sinkAlarmThreshold = -6.0
        let sm = VarioStateMachine(settings: settings)

        guard case .sinking = sm.update(vz: -3.0) else { return XCTFail("doit passer en descente") }
        guard case .sinkAlarm = sm.update(vz: -7.0) else { return XCTFail("doit déclencher l'alarme de chute") }
    }

    // MARK: - Tonalités

    func testToneFrequencyIncreasesWithClimb() {
        XCTAssertLessThan(VarioTone.frequency(forClimb: 0.5), VarioTone.frequency(forClimb: 4.0),
                          "Plus ça monte, plus le bip est aigu")
    }

    func testBeepIntervalDecreasesWithClimb() {
        XCTAssertGreaterThan(VarioTone.beepInterval(forClimb: 0.5), VarioTone.beepInterval(forClimb: 4.0),
                             "Plus ça monte, plus les bips sont rapprochés")
    }

    func testHapticIntervalDecreasesWithClimb() {
        XCTAssertGreaterThan(VarioTone.hapticInterval(forClimb: 0.5), VarioTone.hapticInterval(forClimb: 4.0))
    }

    // MARK: - Réglages

    func testSettingsRoundTripThroughUserDefaults() {
        let suite = UserDefaults(suiteName: "VarioEngineTests.\(UUID().uuidString)")!
        var s = VarioSettings()
        s.climbOnThreshold = 0.33
        s.sinkAlarmThreshold = -5.5
        s.save(to: suite)
        let loaded = VarioSettings.load(from: suite)
        XCTAssertEqual(loaded.climbOnThreshold, 0.33, accuracy: 0.0001)
        XCTAssertEqual(loaded.sinkAlarmThreshold, -5.5, accuracy: 0.0001)
    }
}
