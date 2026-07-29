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

// MARK: - Explained verdict (classic thresholds)

/// The verdict must never disagree with the rating, and must name exactly ONE
/// reason — the point of the feature is that a pilot walks away with a single
/// thing to check.
@Suite struct FlyabilityVerdictTests {

    private func verdict(_ direction: Double?, speed: Double?, gusts: Double?, spot: [String]) -> FlyabilityVerdict {
        WeatherService.verdict(windDirectionDeg: direction, windSpeed: speed,
                               windGusts: gusts, spotDirections: spot)
    }

    // MARK: The rating cannot drift from the old one

    /// `flyability` is now derived from `verdict`, so this sweep is the guard
    /// that splitting speed and gusts apart didn't move any boundary.
    @Test func verdictRatingMatchesTheClassicFlyabilityEverywhere() {
        let directions: [Double] = [0, 45, 90, 180, 225, 270, 315, 337.5, 350]
        let speeds: [Double] = [0, 10, 25, 26, 35, 36, 50]
        let gustValues: [Double] = [0, 15, 40, 41, 55, 56, 80]
        let spots: [[String]] = [["W"], ["W", "NW"], ["N"], ["S", "SW", "N"], []]

        for spot in spots {
            for direction in directions {
                for speed in speeds {
                    for gusts in gustValues {
                        let classic = WeatherService.flyability(
                            windDirectionDeg: direction, windSpeed: speed,
                            windGusts: gusts, spotDirections: spot
                        )
                        let explained = verdict(direction, speed: speed, gusts: gusts, spot: spot)
                        #expect(classic == explained.rating)
                    }
                }
            }
        }
    }

    // MARK: One factor, the right one

    @Test func wrongDirectionIsBlamedOnDirection() {
        let result = verdict(90, speed: 10, gusts: 15, spot: ["W"])
        #expect(result.rating == .bad)
        #expect(result.limitingFactor == .direction(from: "E", worksWith: ["W"]))
        #expect(result.headline.contains("East"))
    }

    @Test func onlyGustsOverTheLimitIsBlamedOnGusts() {
        // Direction straight in, sustained wind fine, gusts in the marginal band
        let result = verdict(270, speed: 20, gusts: 45, spot: ["W"])
        #expect(result.rating == .marginal)
        #expect(result.limitingFactor == .gusts(kmh: 45, limit: 40, isLearned: false))
        #expect(result.headline.contains("Gusting"))
    }

    @Test func onlySustainedWindOverTheLimitIsBlamedOnSpeed() {
        let result = verdict(270, speed: 30, gusts: 30, spot: ["W"])
        #expect(result.rating == .marginal)
        #expect(result.limitingFactor == .windTooStrong(kmh: 30, band: nil, defaultLimit: 25))
    }

    /// A verdict quotes the limit it ACTUALLY broke. Saying "over the 25 km/h
    /// limit" about a red that was triggered at 35 is true and useless.
    @Test func theQuotedLimitIsTheOneThatWasCrossed() {
        let marginal = verdict(270, speed: 30, gusts: 30, spot: ["W"])
        #expect(marginal.limitingFactor == .windTooStrong(kmh: 30, band: nil, defaultLimit: 25))

        let bad = verdict(270, speed: 40, gusts: 40, spot: ["W"])
        #expect(bad.rating == .bad)
        #expect(bad.limitingFactor == .windTooStrong(kmh: 40, band: nil, defaultLimit: 35))
    }

    /// Direction and speed both marginal: direction wins, because that is the
    /// order in which a pilot calls the flight off.
    @Test func directionOutranksSpeedOnATie() {
        let result = verdict(337.5, speed: 30, gusts: 30, spot: ["W"])
        #expect(result.rating == .bad)
        if case .direction = result.limitingFactor {} else {
            Issue.record("expected direction to be blamed, got \(String(describing: result.limitingFactor))")
        }
    }

    @Test func aGoodVerdictBlamesNothing() {
        let result = verdict(270, speed: 18, gusts: 22, spot: ["W"])
        #expect(result.rating == .good)
        #expect(result.limitingFactor == nil)
        #expect(result.headline.contains("West"))
        #expect(result.headline.contains("18"))
    }

    // MARK: Provenance

    @Test func classicVerdictsSayTheLimitsAreTheOnesYouConfigured() {
        let result = verdict(90, speed: 10, gusts: 15, spot: ["W"])
        #expect(result.basis == .configured)
        #expect(result.basisNote?.contains("you set") == true)
    }

    @Test func noDirectionsIsUnknownAndSaysSo() {
        let result = verdict(270, speed: 10, gusts: 15, spot: [])
        #expect(result.rating == .unknown)
        #expect(result.basis == .unknown)
        #expect(result.basisNote == nil)
        #expect(result.headline.contains("No launch directions"))
    }

    /// Missing wind data is NOT the same as knowing nothing about the spot: the
    /// verdict keeps the basis so the UI can still say where limits would come
    /// from.
    @Test func missingWindDataKeepsTheBasis() {
        let result = verdict(nil, speed: nil, gusts: nil, spot: ["W"])
        #expect(result.rating == .unknown)
        #expect(result.basis == .configured)
        #expect(result.headline.contains("No wind data"))
    }

    // MARK: Wording helpers

    @Test func sectorListsReadAsSentences() {
        #expect(FlyabilityVerdict.list(["W"]) == "W")
        #expect(FlyabilityVerdict.list(["W", "NW"]) == "W and NW")
        #expect(FlyabilityVerdict.list(["W", "NW", "N"]) == "W, NW and N")
    }

    @Test func sectorsComeOutInCompassOrder() {
        #expect(FlyabilityVerdict.orderedPoints(["NW", "E", "W", "N"]) == ["N", "E", "W", "NW"])
        #expect(FlyabilityVerdict.orderedPoints(["NNE"]).isEmpty)
    }
}

// MARK: - Explained verdict (learned window)

/// The learned engine is the only one that can say things a generic threshold
/// cannot — a band with a FLOOR, and a provenance the pilot can weigh.
@MainActor
@Suite struct LearnedFlyabilityVerdictTests {

    /// 14 recorded takeoffs, W/NW, flown between 12 and 24 km/h.
    private var learnedWindow: SpotIntelligenceService.LearnedWindow {
        .init(sectors: ["W": 10, "NW": 4], speedRange: 12...24, totalFlights: 14, source: .learned)
    }

    /// A ParaglidingEarth seed: directions only, no speeds behind it.
    private var seededWindow: SpotIntelligenceService.LearnedWindow {
        .init(sectors: ["W": 2], speedRange: nil, totalFlights: 0, source: .seeded)
    }

    private func verdict(_ direction: Double?, speed: Double?, gusts: Double?,
                         window: SpotIntelligenceService.LearnedWindow) -> FlyabilityVerdict {
        SpotIntelligenceService.shared.verdictV2(
            windDirectionDeg: direction, windSpeed: speed, windGusts: gusts, window: window
        )
    }

    @Test func learnedRatingMatchesTheOldLearnedFlyability() {
        for window in [learnedWindow, seededWindow] {
            for direction in [0.0, 90, 180, 270, 315] {
                for speed in [0.0, 4, 18, 30, 45] {
                    for gusts in [0.0, 20, 44, 60] {
                        let plain = SpotIntelligenceService.shared.flyabilityV2(
                            windDirectionDeg: direction, windSpeed: speed, windGusts: gusts, window: window
                        )
                        let explained = verdict(direction, speed: speed, gusts: gusts, window: window)
                        #expect(plain == explained.rating)
                    }
                }
            }
        }
    }

    @Test func aLearnedVerdictNamesTheFlightsBehindIt() {
        let result = verdict(270, speed: 18, gusts: 20, window: learnedWindow)
        #expect(result.rating == .good)
        #expect(result.basis == .learned(flights: 14))
        #expect(result.basisNote?.contains("14") == true)
    }

    @Test func wrongDirectionListsTheLearnedSectorsInCompassOrder() {
        let result = verdict(180, speed: 18, gusts: 20, window: learnedWindow)
        #expect(result.rating == .bad)
        #expect(result.limitingFactor == .direction(from: "S", worksWith: ["W", "NW"]))
        #expect(result.headline.contains("South"))
        #expect(result.headline.contains("W and NW"))
    }

    @Test func tooStrongQuotesTheUnpaddedBandNotThePaddedOne() {
        // The padded ceiling is 24 × 1.2; the pilot never flew that, they flew
        // up to 24. Matched structurally rather than by value — 24 × 1.2 is not
        // exactly 28.8 in binary floating point, and the assertion here is
        // about WHICH number gets quoted, not about the padding arithmetic.
        let result = verdict(270, speed: 45, gusts: 45, window: learnedWindow)
        #expect(result.rating == .bad)
        if case .windTooStrong(let kmh, let band, _) = result.limitingFactor {
            #expect(kmh == 45)
            #expect(band == 12...24)
        } else {
            Issue.record("expected sustained wind to be blamed, got \(String(describing: result.limitingFactor))")
        }
        #expect(result.headline.contains("12–24"))
    }

    /// The case no threshold can produce: a spot that simply does not work in
    /// nothing. Only a learned band has a floor.
    @Test func tooLightOnlyExistsWithALearnedBand() {
        let learned = verdict(270, speed: 4, gusts: 4, window: learnedWindow)
        #expect(learned.rating == .bad)
        #expect(learned.limitingFactor == .windTooLight(kmh: 4, band: 12...24))
        #expect(learned.headline.contains("lighter"))

        // Same wind, seeded window (no speeds behind it): nothing to complain
        // about, because nothing is known about how light is too light.
        let seeded = verdict(270, speed: 4, gusts: 4, window: seededWindow)
        #expect(seeded.rating == .good)
        #expect(seeded.limitingFactor == nil)
    }

    @Test func learnedGustsAreAttributedToTheFlightsNotToADefault() {
        // padHigh 28.8 -> gusts good up to 43.2, marginal to 57.6
        let result = verdict(270, speed: 18, gusts: 50, window: learnedWindow)
        #expect(result.rating == .marginal)
        if case .gusts(_, _, let isLearned) = result.limitingFactor {
            #expect(isLearned)
        } else {
            Issue.record("expected gusts to be blamed, got \(String(describing: result.limitingFactor))")
        }
    }

    @Test func aSeededVerdictCreditsParaglidingEarthAndNotThePilot() {
        let result = verdict(90, speed: 15, gusts: 20, window: seededWindow)
        #expect(result.rating == .bad)
        #expect(result.basis == .seeded)
        #expect(result.headline.contains("this site faces"))
        #expect(result.basisNote?.contains("ParaglidingEarth") == true)
    }

    @Test func anEmptyWindowIsUnknownRatherThanConfidentlyWrong() {
        let empty = SpotIntelligenceService.LearnedWindow(
            sectors: [:], speedRange: nil, totalFlights: 0, source: .learned
        )
        let result = verdict(270, speed: 18, gusts: 20, window: empty)
        #expect(result.rating == .unknown)
        #expect(result.basis == .unknown)
    }
}
