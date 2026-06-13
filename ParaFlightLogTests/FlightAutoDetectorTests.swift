//
//  FlightAutoDetectorTests.swift
//  ParaFlightLogTests
//
//  Tests de la machine à états de détection auto décollage/atterrissage,
//  y compris le mode pause/reprise du soaring.
//  (FlightAutoDetector est compilé directement dans la cible de test.)
//

import XCTest

final class FlightAutoDetectorTests: XCTestCase {

    // MARK: - Décollage

    func testTakeoffAfterSustainedSpeed() {
        let detector = FlightAutoDetector()
        var takeoff = false
        detector.onTakeoffDetected = { takeoff = true }
        detector.arm()

        // Vitesse soutenue > 4 m/s pendant 6 s
        for t in 0...6 {
            detector.update(speed: 6.0, timestamp: Double(t))
        }
        XCTAssertTrue(takeoff, "Le décollage doit être détecté après 5 s à > 4 m/s")
        XCTAssertEqual(detector.state, .flying)
    }

    func testNoTakeoffIfSpeedNotSustained() {
        let detector = FlightAutoDetector()
        var takeoff = false
        detector.onTakeoffDetected = { takeoff = true }
        detector.arm()

        // Pics de vitesse non soutenus
        detector.update(speed: 6.0, timestamp: 0)
        detector.update(speed: 1.0, timestamp: 1)
        detector.update(speed: 6.0, timestamp: 2)
        detector.update(speed: 1.0, timestamp: 3)
        XCTAssertFalse(takeoff)
        XCTAssertEqual(detector.state, .armed)
    }

    func testIdleDetectorIgnoresUpdates() {
        let detector = FlightAutoDetector()
        var takeoff = false
        detector.onTakeoffDetected = { takeoff = true }
        // pas de arm() → reste idle
        for t in 0...10 { detector.update(speed: 10.0, timestamp: Double(t)) }
        XCTAssertFalse(takeoff)
        XCTAssertEqual(detector.state, .idle)
    }

    // MARK: - Atterrissage (mode .stop, thermique)

    func testLandingStopBehavior() {
        let detector = FlightAutoDetector()
        detector.landingBehavior = .stop
        var landed = false
        detector.onLandingDetected = { landed = true }
        detector.flightStarted()

        // Vitesse faible + altitude stable pendant > 90 s
        for t in 0...95 {
            detector.update(speed: 0.5, vz: 0.1, gpsAltitude: 100, timestamp: Double(t))
        }
        XCTAssertTrue(landed, "L'atterrissage (mode stop) doit être détecté après 90 s au sol")
    }

    func testNoLandingWhileStillMoving() {
        let detector = FlightAutoDetector()
        detector.landingBehavior = .stop
        var landed = false
        detector.onLandingDetected = { landed = true }
        detector.flightStarted()

        for t in 0...120 {
            detector.update(speed: 8.0, vz: 0.0, gpsAltitude: 500, timestamp: Double(t))
        }
        XCTAssertFalse(landed, "Pas d'atterrissage tant qu'on vole")
    }

    // MARK: - Pause/reprise (mode soaring)

    func testSoaringPauseThenResume() {
        let detector = FlightAutoDetector()
        detector.landingBehavior = .pauseAndResume(maxPause: 30 * 60)
        var paused = false
        var resumed = false
        var timedOut = false
        detector.onPauseStarted = { paused = true }
        detector.onResumed = { resumed = true }
        detector.onPauseTimeout = { timedOut = true }
        detector.flightStarted()

        // Au sol > 90 s → pause (pas d'arrêt)
        var t = 0.0
        while t <= 95 {
            detector.update(speed: 0.5, vz: 0.1, gpsAltitude: 100, timestamp: t)
            t += 1
        }
        XCTAssertTrue(paused, "Le soaring doit passer en pause, pas s'arrêter")
        XCTAssertEqual(detector.state, .pausedOnGround)

        // Redécollage soutenu → reprise du même vol
        for _ in 0...6 {
            detector.update(speed: 6.0, timestamp: t)
            t += 1
        }
        XCTAssertTrue(resumed, "Un redécollage doit reprendre le même vol")
        XCTAssertFalse(timedOut)
        XCTAssertEqual(detector.state, .flying)
    }

    func testSoaringPauseTimeout() {
        let detector = FlightAutoDetector()
        detector.landingBehavior = .pauseAndResume(maxPause: 60) // 60 s pour le test
        var timedOut = false
        detector.onPauseTimeout = { timedOut = true }
        detector.flightStarted()

        var t = 0.0
        // descendre au sol → pause
        while t <= 95 {
            detector.update(speed: 0.3, vz: 0.0, gpsAltitude: 100, timestamp: t)
            t += 1
        }
        XCTAssertEqual(detector.state, .pausedOnGround)
        // rester au sol au-delà de maxPause
        while t <= 95 + 65 {
            detector.update(speed: 0.3, vz: 0.0, gpsAltitude: 100, timestamp: t)
            t += 1
        }
        XCTAssertTrue(timedOut, "Une pause trop longue doit déclencher l'arrêt")
    }
}
