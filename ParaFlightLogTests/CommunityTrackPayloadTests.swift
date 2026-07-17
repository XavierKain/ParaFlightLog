//
//  CommunityTrackPayloadTests.swift
//  ParaFlightLogTests
//
//  Round-trip tests for the shared-flight GPS track payload
//  (CommunityService.encodeTrackPayload / decodeTrackPayload): the encoded
//  string must stay under the Appwrite column budget, survive a decode with
//  coordinates/altitude/speed intact within the rounding tolerances, keep
//  the landing point, and fail soft (nil) on degenerate input.
//

import Foundation
import Testing
@testable import ParaFlightLog

@MainActor
struct CommunityTrackPayloadTests {

    /// A synthetic soaring track: `count` points, 1 s apart, drifting NE,
    /// climbing then sinking, speed varying 5…15 m/s.
    private func makeTrack(count: Int, withAltitude: Bool = true, withSpeed: Bool = true) -> [GPSTrackPoint] {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        return (0..<count).map { index in
            let progress = Double(index) / Double(max(count - 1, 1))
            return GPSTrackPoint(
                timestamp: start.addingTimeInterval(Double(index)),
                latitude: 47.5 + progress * 0.01,
                longitude: -3.1 + progress * 0.01,
                altitude: withAltitude ? 100 + 50 * sin(progress * .pi) : nil,
                speed: withSpeed ? 5 + 10 * progress : nil
            )
        }
    }

    @Test func roundTripPreservesTrackWithinTolerance() throws {
        let track = makeTrack(count: 600)
        let payload = try #require(CommunityService.encodeTrackPayload(track))
        #expect(payload.hasPrefix("PFLZ1:"))
        #expect(payload.count <= 190_000)

        let decoded = try #require(CommunityService.decodeTrackPayload(payload))
        // No downsampling below 1200 points: same count.
        #expect(decoded.count == track.count)

        // First/last points survive with full fidelity budgets:
        // 5 decimals ≈ 1.1 m for coordinates, 0.1 for alt/speed, 1 s for time.
        let pairs = [(track.first!, decoded.first!), (track.last!, decoded.last!)]
        for (original, roundTripped) in pairs {
            #expect(abs(original.latitude - roundTripped.latitude) < 0.00002)
            #expect(abs(original.longitude - roundTripped.longitude) < 0.00002)
            #expect(abs(original.altitude! - roundTripped.altitude!) < 0.11)
            #expect(abs(original.speed! - roundTripped.speed!) < 0.11)
            #expect(abs(original.timestamp.timeIntervalSince(roundTripped.timestamp)) < 1.0)
        }
    }

    @Test func longTrackIsDownsampledAndKeepsLanding() throws {
        // 4 hours at 1 Hz — way over the 1200-point budget.
        let track = makeTrack(count: 14_400)
        let payload = try #require(CommunityService.encodeTrackPayload(track))
        #expect(payload.count <= 190_000)

        let decoded = try #require(CommunityService.decodeTrackPayload(payload))
        #expect(decoded.count <= 1201) // ≤1200 + explicitly-appended landing
        #expect(decoded.count >= 600)  // but not decimated into oblivion

        // The landing point must survive downsampling exactly.
        let landing = track.last!
        let decodedLanding = decoded.last!
        #expect(abs(landing.latitude - decodedLanding.latitude) < 0.00002)
        #expect(abs(landing.timestamp.timeIntervalSince(decodedLanding.timestamp)) < 1.0)
    }

    @Test func missingAltitudeAndSpeedRoundTripAsNil() throws {
        let track = makeTrack(count: 50, withAltitude: false, withSpeed: false)
        let payload = try #require(CommunityService.encodeTrackPayload(track))
        let decoded = try #require(CommunityService.decodeTrackPayload(payload))
        #expect(decoded.allSatisfy { $0.altitude == nil })
        #expect(decoded.allSatisfy { $0.speed == nil })
    }

    @Test func degenerateInputsFailSoft() {
        // Too short to be a track.
        #expect(CommunityService.encodeTrackPayload([]) == nil)
        #expect(CommunityService.encodeTrackPayload(Array(makeTrack(count: 1))) == nil)
        // Garbage payloads decode to nil, never crash.
        #expect(CommunityService.decodeTrackPayload("") == nil)
        #expect(CommunityService.decodeTrackPayload("not-a-payload") == nil)
        #expect(CommunityService.decodeTrackPayload("PFLZ1:%%%invalid-base64%%%") == nil)
    }
}

// MARK: - MonthClimatology (pure aggregation queries)

struct MonthClimatologyTests {

    /// July: 30 observed days — 10 too-light NW days, 15 flyable N days,
    /// 5 flyable E days (already filtered to the 10–35 km/h band upstream).
    private var july: MonthClimatology {
        MonthClimatology(
            month: 7,
            dayCount: 30,
            bandDayCounts: [10, 15, 5, 0, 0],
            // N NE E SE S SW W NW
            flyableCandidatesBySector: [15, 0, 5, 0, 0, 0, 0, 0],
            tempMaxAvg: 24, tempMinAvg: 15
        )
    }

    @Test func bandSharesSumToObservedDays() {
        #expect(abs(july.bandShares.reduce(0, +) - 1.0) < 0.0001)
        #expect(july.bandShares.count == 5)
    }

    @Test func flyableShareCountsSelectedAndNeighbourSectors() {
        // N selected → N days count, and E is NOT a neighbour of N.
        let northOnly = july.flyableShare(directions: ["N"])
        #expect(northOnly != nil)
        #expect(abs(northOnly! - 0.5) < 0.0001) // 15/30

        // NE selected → N and E both count as neighbours.
        let northEast = july.flyableShare(directions: ["NE"])
        #expect(abs(northEast! - (20.0 / 30.0)) < 0.0001)

        // South-facing spot: none of the observed days help.
        #expect(abs(july.flyableShare(directions: ["S"])! - 0.0) < 0.0001)
    }

    @Test func flyableShareFailsSoftOnMissingInput() {
        #expect(july.flyableShare(directions: []) == nil)
        let empty = MonthClimatology(month: 1, dayCount: 0, bandDayCounts: [0,0,0,0,0],
                                     flyableCandidatesBySector: [0,0,0,0,0,0,0,0],
                                     tempMaxAvg: nil, tempMinAvg: nil)
        #expect(empty.flyableShare(directions: ["N"]) == nil)
    }
}

// MARK: - WindForce bands (report scale incl. the 2026-07 recalibration)

struct WindForceScaleTests {

    @Test func knotsBandsAreContiguous() {
        let ordered: [WindForce] = [.calm, .light, .moderate, .strong, .veryStrong, .tooMuch]
        #expect(WindForce.allCases == ordered)
        // Each band's upper bound is the next band's lower bound.
        for (current, next) in zip(ordered, ordered.dropFirst()) {
            #expect(current.knotsRange.upper == next.knotsRange.lower)
        }
        #expect(WindForce.strong.knotsRange == (18, 25))
        #expect(WindForce.veryStrong.knotsRange == (25, 30))
    }

    @Test func rangeHintsRespectTheUnit() {
        #expect(WindForce.strong.rangeHint(in: .knots) == "18–25 kt")
        // 18 kt ≈ 33 km/h, 25 kt ≈ 46 km/h.
        #expect(WindForce.strong.rangeHint(in: .kmh) == "33–46 km/h")
        #expect(WindForce.calm.rangeHint(in: .knots) == "< 5 kt")
        #expect(WindForce.tooMuch.rangeHint(in: .knots) == "> 30 kt")
    }
}
