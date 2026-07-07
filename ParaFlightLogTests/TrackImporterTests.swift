//
//  TrackImporterTests.swift
//  ParaFlightLogTests
//
//  Pure IGC / GPX parsers (nonisolated statics on TrackImporter).
//  The @MainActor orchestration (createFlight/importTrack) needs a full
//  DataController backed by the real store, so it is intentionally not
//  covered here.
//

import Foundation
import Testing
@testable import ParaFlightLog

/// Deterministic UTC date builder.
private nonisolated func utcDate(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

/// Builds IGC file data from record lines (CRLF-terminated like real files).
private nonisolated func igcData(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
}

@Suite struct TrackImporterIGCTests {

    // MARK: - Basic parsing

    /// 3 fixes at 45.9N 6.1E climbing 185 m north every 10 s.
    private let basicIGC = igcData([
        "AXXX ParaFlightLog",
        "HFDTE040726",
        "HFPLTPILOTINCHARGE:Test",
        "B1000004554000N00606000EA0100001100",
        "B1000104554100N00606000EA0100001150",
        "B1000204554200N00606000EA0100001200"
    ])

    @Test func parsesBRecordCountAndCoordinates() throws {
        let track = try TrackImporter.parseIGC(basicIGC)

        #expect(track.points.count == 3)
        let first = try #require(track.points.first)
        // 45° 54.000' N, 6° 06.000' E
        #expect(abs(first.latitude - 45.9) < 0.000001)
        #expect(abs(first.longitude - 6.1) < 0.000001)
        // 54.100' = 45.90166...°
        let second = track.points[1]
        #expect(abs(second.latitude - (45.0 + 54.1 / 60.0)) < 0.000001)
    }

    @Test func timestampsAreUTCOnTheHFDTEDay() throws {
        let track = try TrackImporter.parseIGC(basicIGC)

        #expect(track.startDate == utcDate(2026, 7, 4, 10, 0, 0))
        #expect(track.endDate == utcDate(2026, 7, 4, 10, 0, 20))
        #expect(track.points[1].timestamp == utcDate(2026, 7, 4, 10, 0, 10))
    }

    @Test func acceptsHFDTEDATEColonVariant() throws {
        let data = igcData([
            "AXXX ParaFlightLog",
            "HFDTEDATE:040726,01",
            "B1000004554000N00606000EA0100001100"
        ])
        let track = try TrackImporter.parseIGC(data)
        #expect(track.startDate == utcDate(2026, 7, 4, 10, 0, 0))
    }

    // MARK: - Midnight rollover

    @Test func midnightRolloverAdvancesTheDay() throws {
        let data = igcData([
            "AXXX ParaFlightLog",
            "HFDTE311225",
            "B2359504554000N00606000EA0100001000",
            "B0000104554100N00606000EA0100001000"
        ])
        let track = try TrackImporter.parseIGC(data)

        #expect(track.points.count == 2)
        #expect(track.startDate == utcDate(2025, 12, 31, 23, 59, 50))
        // Second fix crossed midnight into 2026-01-01
        #expect(track.endDate == utcDate(2026, 1, 1, 0, 0, 10))
        #expect(track.durationSeconds == 20)
    }

    // MARK: - Altitude preference

    @Test func prefersGPSAltitudeFor3DFixes() throws {
        let track = try TrackImporter.parseIGC(basicIGC)
        // Validity "A" and GPS altitude != 0 -> GPS altitude (1100), not pressure (1000)
        #expect(track.points[0].altitude == 1100)
        #expect(track.maxAltitude == 1200)
        #expect(track.startAltitude == 1100)
        #expect(track.endAltitude == 1200)
    }

    @Test func fallsBackToPressureAltitude() throws {
        let data = igcData([
            "AXXX ParaFlightLog",
            "HFDTE040726",
            // Validity "V" (2D fix) -> pressure altitude wins
            "B1000004554000N00606000EV0098701100",
            // Validity "A" but GPS altitude 0 -> pressure altitude wins
            "B1000104554100N00606000EA0098800000"
        ])
        let track = try TrackImporter.parseIGC(data)

        #expect(track.points[0].altitude == 987)
        #expect(track.points[1].altitude == 988)
    }

    // MARK: - Derived stats

    @Test func derivesDurationDistanceAndSpeed() throws {
        let track = try TrackImporter.parseIGC(basicIGC)

        #expect(track.durationSeconds == 20)
        // Two hops of 0.1 arc-minute of latitude each (~185.2 m)
        let distance = try #require(track.totalDistance)
        #expect(distance > 360 && distance < 380)
        let maxSpeed = try #require(track.maxSpeed)
        // ~185 m in 10 s
        #expect(maxSpeed > 17 && maxSpeed < 20)
        // First point has no previous fix -> no derived speed
        #expect(track.points[0].speed == nil)
        #expect(track.points[1].speed != nil)
    }

    // MARK: - Robustness

    @Test func skipsMalformedBRecords() throws {
        let data = igcData([
            "AXXX ParaFlightLog",
            "HFDTE040726",
            "B10000",                                     // far too short
            "B1000004554000X00606000EA0100001100",        // invalid hemisphere
            "B1000104554100N00606000EA0100001100"         // valid
        ])
        let track = try TrackImporter.parseIGC(data)
        #expect(track.points.count == 1)
    }

    @Test func missingHFDTEThrowsInvalidFile() {
        let data = igcData([
            "AXXX ParaFlightLog",
            "B1000004554000N00606000EA0100001100"
        ])
        do {
            _ = try TrackImporter.parseIGC(data)
            Issue.record("expected TrackImportError.invalidFile")
        } catch TrackImportError.invalidFile {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func noBRecordsThrowsNoFixes() {
        let data = igcData([
            "AXXX ParaFlightLog",
            "HFDTE040726"
        ])
        do {
            _ = try TrackImporter.parseIGC(data)
            Issue.record("expected TrackImportError.noFixes")
        } catch TrackImportError.noFixes {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Suite struct TrackImporterGPXTests {

    private func gpx(_ trkpts: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>Test</name>
            <trkseg>
        \(trkpts)
            </trkseg>
          </trk>
        </gpx>
        """.utf8)
    }

    @Test func parsesTimedPoints() throws {
        let data = gpx("""
              <trkpt lat="45.900000" lon="6.100000"><ele>1000.0</ele><time>2026-07-04T10:00:00Z</time></trkpt>
              <trkpt lat="45.905000" lon="6.100000"><ele>1050.0</ele><time>2026-07-04T10:00:30Z</time></trkpt>
              <trkpt lat="45.910000" lon="6.100000"><ele>1100.0</ele><time>2026-07-04T10:01:00Z</time></trkpt>
        """)
        let track = try TrackImporter.parseGPX(data)

        #expect(track.points.count == 3)
        #expect(track.startDate == utcDate(2026, 7, 4, 10, 0, 0))
        #expect(track.endDate == utcDate(2026, 7, 4, 10, 1, 0))
        #expect(track.durationSeconds == 60)
        #expect(track.points[0].altitude == 1000)
        #expect(track.maxAltitude == 1100)
        let distance = try #require(track.totalDistance)
        #expect(distance > 0)
    }

    @Test func interpolatesUntimedMiddlePoint() throws {
        let data = gpx("""
              <trkpt lat="45.900000" lon="6.100000"><time>2026-07-04T10:00:00Z</time></trkpt>
              <trkpt lat="45.905000" lon="6.100000"></trkpt>
              <trkpt lat="45.910000" lon="6.100000"><time>2026-07-04T10:01:00Z</time></trkpt>
        """)
        let track = try TrackImporter.parseGPX(data)

        #expect(track.points.count == 3)
        // Halfway by position -> halfway in time
        #expect(track.points[1].timestamp == utcDate(2026, 7, 4, 10, 0, 30))
    }

    @Test func dropsUntimedEdgePoints() throws {
        let data = gpx("""
              <trkpt lat="45.895000" lon="6.100000"></trkpt>
              <trkpt lat="45.900000" lon="6.100000"><time>2026-07-04T10:00:00Z</time></trkpt>
              <trkpt lat="45.905000" lon="6.100000"><time>2026-07-04T10:00:30Z</time></trkpt>
              <trkpt lat="45.910000" lon="6.100000"></trkpt>
        """)
        let track = try TrackImporter.parseGPX(data)

        #expect(track.points.count == 2)
        #expect(track.startDate == utcDate(2026, 7, 4, 10, 0, 0))
    }

    @Test func noTimestampsThrows() {
        let data = gpx("""
              <trkpt lat="45.900000" lon="6.100000"><ele>1000.0</ele></trkpt>
              <trkpt lat="45.905000" lon="6.100000"><ele>1050.0</ele></trkpt>
        """)
        do {
            _ = try TrackImporter.parseGPX(data)
            Issue.record("expected TrackImportError.noTimestamps")
        } catch TrackImportError.noTimestamps {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func toleratesMissingElevation() throws {
        let data = gpx("""
              <trkpt lat="45.900000" lon="6.100000"><time>2026-07-04T10:00:00Z</time></trkpt>
              <trkpt lat="45.905000" lon="6.100000"><ele>1050.0</ele><time>2026-07-04T10:00:30Z</time></trkpt>
        """)
        let track = try TrackImporter.parseGPX(data)

        #expect(track.points[0].altitude == nil)
        #expect(track.points[1].altitude == 1050)
        // startAltitude falls back to the first known altitude
        #expect(track.startAltitude == 1050)
        #expect(track.maxAltitude == 1050)
    }

    @Test func acceptsFractionalSecondTimes() throws {
        let data = gpx("""
              <trkpt lat="45.900000" lon="6.100000"><time>2026-07-04T10:00:00.500Z</time></trkpt>
              <trkpt lat="45.905000" lon="6.100000"><time>2026-07-04T10:00:10.500Z</time></trkpt>
        """)
        let track = try TrackImporter.parseGPX(data)
        #expect(track.points.count == 2)
        #expect(track.durationSeconds == 10)
    }

    @Test func onlyFirstTrackIsParsed() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><trkseg>
            <trkpt lat="45.900000" lon="6.100000"><time>2026-07-04T10:00:00Z</time></trkpt>
            <trkpt lat="45.905000" lon="6.100000"><time>2026-07-04T10:00:30Z</time></trkpt>
          </trkseg></trk>
          <trk><trkseg>
            <trkpt lat="10.000000" lon="10.000000"><time>2026-07-04T12:00:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """.utf8)
        let track = try TrackImporter.parseGPX(data)
        #expect(track.points.count == 2)
        #expect(track.endDate == utcDate(2026, 7, 4, 10, 0, 30))
    }

    @Test func emptyGPXThrowsNoFixes() {
        let data = gpx("")
        do {
            _ = try TrackImporter.parseGPX(data)
            Issue.record("expected TrackImportError.noFixes")
        } catch TrackImportError.noFixes {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func ignoresJitterSegmentsInDistance() throws {
        // Two identical fixes then one real move: jitter (< 2 m) must not
        // contribute to totalDistance.
        let data = gpx("""
              <trkpt lat="45.900000" lon="6.100000"><time>2026-07-04T10:00:00Z</time></trkpt>
              <trkpt lat="45.900000" lon="6.100000"><time>2026-07-04T10:00:10Z</time></trkpt>
              <trkpt lat="45.901000" lon="6.100000"><time>2026-07-04T10:00:20Z</time></trkpt>
        """)
        let track = try TrackImporter.parseGPX(data)
        let distance = try #require(track.totalDistance)
        // Only the 0.001° hop (~111 m) counts
        #expect(distance > 100 && distance < 125)
    }
}

@Suite struct TrackImporterFormatDetectionTests {

    private let minimalIGC = igcData([
        "AXXX ParaFlightLog",
        "HFDTE040726",
        "B1000004554000N00606000EA0100001100"
    ])

    private let minimalGPX = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
      <trk><trkseg>
        <trkpt lat="45.900000" lon="6.100000"><time>2026-07-04T10:00:00Z</time></trkpt>
      </trkseg></trk>
    </gpx>
    """.utf8)

    @Test func detectsByExtension() throws {
        #expect(try TrackImporter.parse(data: minimalIGC, filename: "flight.igc").points.count == 1)
        #expect(try TrackImporter.parse(data: minimalGPX, filename: "flight.gpx").points.count == 1)
        #expect(try TrackImporter.parse(data: minimalGPX, filename: "flight.xml").points.count == 1)
    }

    @Test func detectsByContentWhenExtensionUnknown() throws {
        #expect(try TrackImporter.parse(data: minimalIGC, filename: "download.dat").points.count == 1)
        #expect(try TrackImporter.parse(data: minimalGPX, filename: "download").points.count == 1)
    }

    @Test func unknownContentThrowsUnrecognizedFormat() {
        let garbage = Data("just some text\nnothing else".utf8)
        do {
            _ = try TrackImporter.parse(data: garbage, filename: "notes.txt")
            Issue.record("expected TrackImportError.unrecognizedFormat")
        } catch TrackImportError.unrecognizedFormat {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
