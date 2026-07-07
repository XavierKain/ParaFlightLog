//
//  TrackExporterTests.swift
//  ParaFlightLogTests
//
//  GPX / IGC export of a flight's GPS track, plus export -> import
//  round-trips through TrackImporter.
//

import Foundation
import SwiftData
import Testing
@testable import ParaFlightLog

/// Deterministic UTC date builder (whole seconds only — both formats
/// serialize whole seconds).
private nonisolated func utcDate(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

@Suite struct TrackExporterTests {

    let container: ModelContainer

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Wing.self, Flight.self, Spot.self,
                                       configurations: configuration)
    }

    /// Inserts a Flight with the given track into the in-memory store.
    private func makeFlight(points: [GPSTrackPoint], spotName: String? = "Cumbuco", wing: Wing? = nil) -> Flight {
        let start = points.first?.timestamp ?? utcDate(2026, 7, 4, 10, 0, 0)
        let end = points.last?.timestamp ?? start
        let flight = Flight(
            startDate: start,
            endDate: end,
            durationSeconds: Int(end.timeIntervalSince(start)),
            spotName: spotName
        )
        if let wing {
            container.mainContext.insert(wing)
        }
        container.mainContext.insert(flight)
        if let wing {
            flight.wing = wing
        }
        flight.setGPSTrack(points)
        return flight
    }

    /// Three points at Passy (45.9, 6.1), 10 s apart, exactly on IGC minute
    /// thousandths so coordinate assertions are exact.
    private func standardTrack() -> [GPSTrackPoint] {
        let t0 = utcDate(2026, 7, 4, 10, 0, 0)
        return [
            GPSTrackPoint(timestamp: t0, latitude: 45.9, longitude: 6.1, altitude: 1000, speed: 0),
            GPSTrackPoint(timestamp: t0.addingTimeInterval(10), latitude: 45.905, longitude: 6.105, altitude: 1050, speed: 10),
            GPSTrackPoint(timestamp: t0.addingTimeInterval(20), latitude: 45.910, longitude: 6.110, altitude: 1100, speed: 12)
        ]
    }

    // MARK: - GPX

    @Test func gpxContainsAllTrackPointsAndISODates() throws {
        let flight = makeFlight(points: standardTrack())
        let url = try TrackExporter.gpxFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }
        let gpx = try String(contentsOf: url, encoding: .utf8)

        #expect(gpx.components(separatedBy: "<trkpt").count - 1 == 3)
        #expect(gpx.contains("<time>2026-07-04T10:00:00Z</time>"))
        #expect(gpx.contains("<time>2026-07-04T10:00:20Z</time>"))
        #expect(gpx.contains("lat=\"45.900000\" lon=\"6.100000\""))
        #expect(gpx.contains("<ele>1000.0</ele>"))
        #expect(gpx.contains("<gpx version=\"1.1\""))
        #expect(url.pathExtension == "gpx")
        #expect(url.lastPathComponent.hasSuffix("_Cumbuco.gpx"))
    }

    @Test func gpxEscapesXMLInTrackName() throws {
        let flight = makeFlight(points: standardTrack(), spotName: "Dune <du> \"Pyla\" & Co")
        let url = try TrackExporter.gpxFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }
        let gpx = try String(contentsOf: url, encoding: .utf8)

        #expect(gpx.contains("<name>Dune &lt;du&gt; &quot;Pyla&quot; &amp; Co</name>"))
        #expect(!gpx.contains("<name>Dune <du>"))
    }

    @Test func gpxThrowsNoTrackWhenEmpty() {
        let noTrackFlight = makeFlight(points: [])
        // setGPSTrack([]) stores an empty array — still "no track"
        #expect(throws: TrackExportError.noTrack) {
            _ = try TrackExporter.gpxFile(for: noTrackFlight)
        }

        let nilTrackFlight = Flight(startDate: utcDate(2026, 7, 4), endDate: utcDate(2026, 7, 4), durationSeconds: 0)
        container.mainContext.insert(nilTrackFlight)
        #expect(throws: TrackExportError.noTrack) {
            _ = try TrackExporter.gpxFile(for: nilTrackFlight)
        }
    }

    // MARK: - IGC

    @Test func igcHeaderMatchesStartDate() throws {
        let flight = makeFlight(points: standardTrack())
        let url = try TrackExporter.igcFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }
        let igc = try String(contentsOf: url, encoding: .ascii)

        #expect(igc.contains("HFDTE040726"))
        #expect(igc.hasPrefix("AXXX ParaFlightLog"))
        // No wing attached -> generic glider type
        #expect(igc.contains("HFGTYGLIDERTYPE:Paraglider"))
        #expect(url.pathExtension == "igc")
    }

    @Test func igcHasOneBRecordPerPoint() throws {
        let flight = makeFlight(points: standardTrack())
        let url = try TrackExporter.igcFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }
        let igc = try String(contentsOf: url, encoding: .ascii)

        let bRecords = igc.components(separatedBy: "\r\n").filter { $0.hasPrefix("B") }
        #expect(bRecords.count == 3)
        // Every B record: B + 6 time + 8 lat + 9 lon + 1 validity + 5 + 5 alt = 35 chars
        for record in bRecords {
            #expect(record.count == 35)
        }
    }

    @Test func igcEncodesDDMMmmmCoordinates() throws {
        // 45.9° = 45° 54.000', 6.1° = 6° 06.000'
        let flight = makeFlight(points: standardTrack())
        let url = try TrackExporter.igcFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }
        let igc = try String(contentsOf: url, encoding: .ascii)

        #expect(igc.contains("B1000004554000N00606000EA0100001000"))
        // Second point: 45.905 = 45° 54.300', 6.105 = 6° 06.300'
        #expect(igc.contains("B1000104554300N00606300EA0105001050"))
    }

    @Test func igcEncodesSouthernAndWesternHemispheres() throws {
        let t0 = utcDate(2026, 7, 4, 10, 0, 0)
        let flight = makeFlight(points: [
            GPSTrackPoint(timestamp: t0, latitude: -45.9, longitude: -6.1, altitude: 500)
        ])
        let url = try TrackExporter.igcFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }
        let igc = try String(contentsOf: url, encoding: .ascii)

        #expect(igc.contains("4554000S"))
        #expect(igc.contains("00606000W"))
    }

    @Test func igcHandlesMinuteRolloverAndAltitudeClamping() throws {
        let t0 = utcDate(2026, 7, 4, 10, 0, 0)
        let flight = makeFlight(points: [
            // 45.9999999° -> minutes round to 60.000 -> must roll to 46° 00.000'
            GPSTrackPoint(timestamp: t0, latitude: 45.9999999, longitude: 6.1, altitude: -15),
            GPSTrackPoint(timestamp: t0.addingTimeInterval(5), latitude: 45.9, longitude: 6.1, altitude: nil)
        ])
        let url = try TrackExporter.igcFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }
        let igc = try String(contentsOf: url, encoding: .ascii)

        #expect(igc.contains("4600000N"))
        // Negative altitude clamps to 00000, nil altitude becomes 00000
        #expect(igc.contains("B1000004600000N00606000EA0000000000"))
        #expect(igc.contains("B1000054554000N00606000EA0000000000"))
    }

    @Test func igcSanitizesGliderTypeToASCII() throws {
        let wing = Wing(name: "Épsilon 9")
        let flight = makeFlight(points: standardTrack(), wing: wing)
        let url = try TrackExporter.igcFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }
        let igc = try String(contentsOf: url, encoding: .ascii)

        // Non-ASCII "É" is stripped, the rest survives
        #expect(igc.contains("HFGTYGLIDERTYPE:psilon 9"))
    }

    @Test func igcThrowsNoTrackWhenEmpty() {
        let flight = makeFlight(points: [])
        #expect(throws: TrackExportError.noTrack) {
            _ = try TrackExporter.igcFile(for: flight)
        }
    }

    // MARK: - Round-trips (export -> re-import)

    @Test func gpxRoundTripPreservesPointsAndTimestamps() throws {
        let original = standardTrack()
        let flight = makeFlight(points: original)
        let url = try TrackExporter.gpxFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try TrackImporter.parseGPX(Data(contentsOf: url))
        #expect(parsed.points.count == original.count)
        for (reimported, source) in zip(parsed.points, original) {
            #expect(abs(reimported.timestamp.timeIntervalSince(source.timestamp)) < 1)
            #expect(abs(reimported.latitude - source.latitude) < 0.00001)
            #expect(abs(reimported.longitude - source.longitude) < 0.00001)
            #expect(reimported.altitude != nil)
        }
        #expect(parsed.durationSeconds == 20)
        #expect(parsed.startDate == original.first?.timestamp)
    }

    @Test func igcRoundTripPreservesPointsAndTimestamps() throws {
        let original = standardTrack()
        let flight = makeFlight(points: original)
        let url = try TrackExporter.igcFile(for: flight)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try TrackImporter.parseIGC(Data(contentsOf: url))
        #expect(parsed.points.count == original.count)
        for (reimported, source) in zip(parsed.points, original) {
            // IGC timestamps are whole seconds and dates come from HFDTE
            #expect(abs(reimported.timestamp.timeIntervalSince(source.timestamp)) < 1)
            // IGC coordinate resolution: 1/1000 arc-minute ~ 1.7e-5 degrees
            #expect(abs(reimported.latitude - source.latitude) < 0.0001)
            #expect(abs(reimported.longitude - source.longitude) < 0.0001)
        }
        #expect(parsed.maxAltitude == 1100)
    }
}
