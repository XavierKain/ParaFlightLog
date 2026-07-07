//
//  FlyabilityTests.swift
//  ParaFlightLogTests
//
//  WeatherService compass helpers + flyability rating.
//  Pure static logic — no networking involved.
//

import Testing
@testable import ParaFlightLog

// MARK: - Compass helpers

@Suite struct CompassHelperTests {

    @Test func degreesToCompassMapsThe8Points() {
        #expect(WeatherService.degreesToCompass(0) == "N")
        #expect(WeatherService.degreesToCompass(45) == "NE")
        #expect(WeatherService.degreesToCompass(90) == "E")
        #expect(WeatherService.degreesToCompass(135) == "SE")
        #expect(WeatherService.degreesToCompass(180) == "S")
        #expect(WeatherService.degreesToCompass(225) == "SW")
        #expect(WeatherService.degreesToCompass(270) == "W")
        #expect(WeatherService.degreesToCompass(315) == "NW")
    }

    @Test func degreesToCompassSectorBoundaries() {
        // Each sector is bearing ± 22.5°, upper bound inclusive of the next
        #expect(WeatherService.degreesToCompass(22.4) == "N")
        #expect(WeatherService.degreesToCompass(22.5) == "NE")
        #expect(WeatherService.degreesToCompass(337.4) == "NW")
        #expect(WeatherService.degreesToCompass(337.5) == "N")
        // 200° is still in the S sector (157.5–202.5), 210° is in SW
        #expect(WeatherService.degreesToCompass(200) == "S")
        #expect(WeatherService.degreesToCompass(210) == "SW")
    }

    @Test func degreesToCompassNormalizesOutOfRangeBearings() {
        #expect(WeatherService.degreesToCompass(360) == "N")
        #expect(WeatherService.degreesToCompass(720) == "N")
        #expect(WeatherService.degreesToCompass(-45) == "NW")
        #expect(WeatherService.degreesToCompass(-90) == "W")
        #expect(WeatherService.degreesToCompass(405) == "NE")
    }

    @Test func compassToDegreesIsTheInverseOnAll8Points() {
        for point in WeatherService.compassPoints {
            let degrees = WeatherService.compassToDegrees(point)
            #expect(WeatherService.degreesToCompass(degrees) == point)
        }
        #expect(WeatherService.compassToDegrees("N") == 0)
        #expect(WeatherService.compassToDegrees("SW") == 225)
    }

    @Test func compassToDegreesUnknownLabelMapsToNorth() {
        #expect(WeatherService.compassToDegrees("NNE") == 0)
        #expect(WeatherService.compassToDegrees("") == 0)
    }
}

// MARK: - Flyability

@Suite struct FlyabilityTests {

    /// Shorthand: rate wind against launch directions.
    private func rate(_ direction: Double?, speed: Double?, gusts: Double?, spot: [String]) -> Flyability {
        WeatherService.flyability(windDirectionDeg: direction, windSpeed: speed,
                                  windGusts: gusts, spotDirections: spot)
    }

    // MARK: Direction

    @Test func directionWithin45DegreesIsGoodWithCalmWind() {
        // West launch, wind exactly from W
        #expect(rate(270, speed: 10, gusts: 15, spot: ["W"]) == .good)
        // ±45° edges are inclusive
        #expect(rate(225, speed: 10, gusts: 15, spot: ["W"]) == .good)
        #expect(rate(315, speed: 10, gusts: 15, spot: ["W"]) == .good)
    }

    @Test func borderlineDirectionIsMarginalWithCalmWind() {
        // 67.5° off a W launch: borderline sector
        #expect(rate(337.5, speed: 10, gusts: 15, spot: ["W"]) == .marginal)
        #expect(rate(202.5, speed: 10, gusts: 15, spot: ["W"]) == .marginal)
        // 46° off: already borderline (past the good sector)
        #expect(rate(316, speed: 10, gusts: 15, spot: ["W"]) == .marginal)
    }

    @Test func wrongDirectionIsBad() {
        // Wind from the East on a West launch
        #expect(rate(90, speed: 10, gusts: 15, spot: ["W"]) == .bad)
        // Just past the borderline sector
        #expect(rate(338, speed: 10, gusts: 15, spot: ["W"]) == .bad)
        #expect(rate(180, speed: 5, gusts: 5, spot: ["N"]) == .bad)
    }

    @Test func bestMatchingDirectionWins() {
        // Multi-direction launch: any selected point within 45° is enough
        #expect(rate(90, speed: 10, gusts: 15, spot: ["W", "E"]) == .good)
        #expect(rate(0, speed: 10, gusts: 15, spot: ["S", "SW", "N"]) == .good)
    }

    @Test func northWrapAround() {
        // 350° is only 10° away from N (0°) across the wrap
        #expect(rate(350, speed: 10, gusts: 15, spot: ["N"]) == .good)
        #expect(rate(10, speed: 10, gusts: 15, spot: ["N"]) == .good)
        // NW launch (315°), wind from 5°: 50° across the wrap -> borderline
        #expect(rate(5, speed: 10, gusts: 15, spot: ["NW"]) == .marginal)
    }

    // MARK: Missing data

    @Test func unknownWithoutSpotDirectionsOrWindData() {
        #expect(rate(270, speed: 10, gusts: 15, spot: []) == .unknown)
        #expect(rate(nil, speed: 10, gusts: 15, spot: ["W"]) == .unknown)
        #expect(rate(270, speed: nil, gusts: 15, spot: ["W"]) == .unknown)
        #expect(rate(nil, speed: nil, gusts: nil, spot: []) == .unknown)
    }

    @Test func missingGustsFallBackToSpeed() {
        // Gusts default to the sustained speed
        #expect(rate(270, speed: 20, gusts: nil, spot: ["W"]) == .good)
        // Speed 30 -> implied gusts 30: marginal band
        #expect(rate(270, speed: 30, gusts: nil, spot: ["W"]) == .marginal)
        // Speed 40 -> implied gusts 40: over both marginal caps
        #expect(rate(270, speed: 40, gusts: nil, spot: ["W"]) == .bad)
    }

    // MARK: Speed / gust thresholds (direction OK)

    @Test func goodBoundaryIs25SpeedAnd40Gusts() {
        #expect(rate(270, speed: 25, gusts: 40, spot: ["W"]) == .good)
        // One over either cap drops to marginal
        #expect(rate(270, speed: 26, gusts: 40, spot: ["W"]) == .marginal)
        #expect(rate(270, speed: 25, gusts: 41, spot: ["W"]) == .marginal)
    }

    @Test func marginalBoundaryIs35SpeedAnd55Gusts() {
        #expect(rate(270, speed: 35, gusts: 55, spot: ["W"]) == .marginal)
        // One over either cap is bad
        #expect(rate(270, speed: 36, gusts: 55, spot: ["W"]) == .bad)
        #expect(rate(270, speed: 35, gusts: 56, spot: ["W"]) == .bad)
    }

    @Test func borderlineDirectionRequiresGoodSpeeds() {
        // Borderline direction + good speeds -> marginal
        #expect(rate(337.5, speed: 25, gusts: 40, spot: ["W"]) == .marginal)
        // Borderline direction + only-marginal speeds -> bad
        #expect(rate(337.5, speed: 30, gusts: 45, spot: ["W"]) == .bad)
    }

    @Test func strongWindIsBadEvenStraightIn() {
        #expect(rate(270, speed: 50, gusts: 70, spot: ["W"]) == .bad)
        #expect(rate(270, speed: 20, gusts: 60, spot: ["W"]) == .bad)
    }
}
