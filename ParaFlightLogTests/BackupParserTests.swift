//
//  BackupParserTests.swift
//  ParaFlightLogTests
//
//  Backup format v2 manifest / single-file cloud backup codability, plus a
//  file-based export test exercising the legacy CSV interop writer.
//
//  NOT covered on purpose:
//  - BackupManager.importBackup / insert / merge dedup: they require a full
//    DataController, whose only initializer opens the app's real persistent
//    store (no in-memory injection point) — mutating real data from tests is
//    off the table.
//  - parseCSVRow / parseV1 / legacyEscapeCSV directly: private. The export
//    test below covers the legacy CSV escaping through the public surface.
//

import Foundation
import SwiftData
import Testing
@testable import ParaFlightLog

/// Deterministic UTC date builder (whole seconds: ISO 8601 without
/// fractional seconds is the manifest's date encoding).
private nonisolated func utcDate(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

@Suite struct BackupManifestCodingTests {

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeManifest() -> BackupManifest {
        let wingId = UUID()
        let spotId = UUID()
        let wing = BackupWing(
            id: wingId, name: "Moustache M1", brand: "Flare", size: "18",
            type: "Soaring", color: "Red", isArchived: false,
            createdAt: utcDate(2025, 1, 1, 12, 0, 0), displayOrder: 1,
            photoFilename: nil
        )
        let point = GPSTrackPoint(
            timestamp: utcDate(2026, 7, 4, 10, 0, 0),
            latitude: 45.9, longitude: 6.1, altitude: 1000, speed: 9.5
        )
        let flight = BackupFlight(
            id: UUID(), wingId: wingId,
            startDate: utcDate(2026, 7, 4, 10, 0, 0),
            endDate: utcDate(2026, 7, 4, 11, 5, 0),
            durationSeconds: 3900, spotName: "Punta Paloma",
            latitude: 36.0143, longitude: -5.6044,
            flightType: "Soaring", notes: "Great session",
            createdAt: utcDate(2026, 7, 4, 11, 6, 0),
            startAltitude: 100, maxAltitude: 450, endAltitude: 5,
            totalDistance: 12000, maxSpeed: 14.2, maxGForce: 2.1,
            gpsTrack: [point], spotId: spotId,
            takeoffWindSpeed: 18, takeoffWindGusts: 26,
            takeoffWindDirection: 90, takeoffTemperature: 24.5
        )
        let spot = BackupSpot(
            id: spotId, name: "Punta Paloma", city: "Tarifa",
            latitude: 36.0143, longitude: -5.6044,
            createdAt: utcDate(2025, 6, 1), windDirections: ["E", "SE"]
        )
        return BackupManifest(
            formatVersion: BackupManifest.currentFormatVersion,
            exportDate: utcDate(2026, 7, 4, 12, 0, 0),
            appVersion: "20.0",
            wings: [wing], flights: [flight], spots: [spot]
        )
    }

    @Test func manifestRoundTripsThroughISO8601JSON() throws {
        let manifest = makeManifest()
        let data = try makeEncoder().encode(manifest)
        let decoded = try makeDecoder().decode(BackupManifest.self, from: data)

        #expect(decoded.formatVersion == 2)
        #expect(decoded.exportDate == manifest.exportDate)
        #expect(decoded.wings.count == 1)
        #expect(decoded.wings[0].id == manifest.wings[0].id)
        #expect(decoded.wings[0].brand == "Flare")
        #expect(decoded.wings[0].createdAt == utcDate(2025, 1, 1, 12, 0, 0))

        let flight = try #require(decoded.flights.first)
        #expect(flight.startDate == utcDate(2026, 7, 4, 10, 0, 0))
        #expect(flight.durationSeconds == 3900)
        #expect(flight.spotId == manifest.flights[0].spotId)
        #expect(flight.takeoffWindSpeed == 18)
        #expect(flight.takeoffTemperature == 24.5)

        let track = try #require(flight.gpsTrack)
        #expect(track.count == 1)
        #expect(track[0].timestamp == utcDate(2026, 7, 4, 10, 0, 0))
        #expect(track[0].altitude == 1000)

        let spot = try #require(decoded.spots?.first)
        #expect(spot.name == "Punta Paloma")
        #expect(spot.windDirections == ["E", "SE"])
    }

    @Test func dateFormatterRoundTripIsStable() throws {
        // Encoding twice yields byte-identical JSON (sorted keys + whole-second
        // ISO dates): the backup format is deterministic by design.
        let manifest = makeManifest()
        let encoder = makeEncoder()
        let first = try encoder.encode(manifest)
        let second = try encoder.encode(try makeDecoder().decode(BackupManifest.self, from: first))
        #expect(first == second)
    }

    @Test func olderV2FileWithoutAdditiveFieldsStillDecodes() throws {
        // Hand-built pre-spots v2 manifest: no "spots", no spotId/takeoff*
        // on the flight, no brand on the wing.
        let json = """
        {
          "formatVersion": 2,
          "exportDate": "2025-01-01T00:00:00Z",
          "appVersion": "12.0",
          "wings": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Old Wing",
              "isArchived": true,
              "createdAt": "2024-06-15T09:30:00Z",
              "displayOrder": 0
            }
          ],
          "flights": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "startDate": "2024-07-01T10:00:00Z",
              "endDate": "2024-07-01T10:45:00Z",
              "durationSeconds": 2700,
              "createdAt": "2024-07-01T10:46:00Z"
            }
          ]
        }
        """
        let manifest = try makeDecoder().decode(BackupManifest.self, from: Data(json.utf8))

        #expect(manifest.spots == nil)
        #expect(manifest.wings[0].brand == nil)
        #expect(manifest.wings[0].isArchived == true)
        let flight = try #require(manifest.flights.first)
        #expect(flight.spotId == nil)
        #expect(flight.takeoffWindSpeed == nil)
        #expect(flight.wingId == nil)
        #expect(flight.gpsTrack == nil)
        #expect(flight.startDate == utcDate(2024, 7, 1, 10, 0, 0))
    }

    @Test func cloudBackupFileEncodesFlatManifestPlusImages() throws {
        let photo = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02, 0x03])
        let wingId = UUID()
        let file = CloudBackupFile(
            manifest: makeManifest(),
            images: [wingId.uuidString: photo.base64EncodedString()]
        )
        let data = try makeEncoder().encode(file)

        // The on-disk shape is the manifest itself with one extra "images"
        // key — no "manifest" wrapper.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["manifest"] == nil)
        #expect(object["formatVersion"] as? Int == 2)
        #expect(object["wings"] != nil)
        #expect(object["flights"] != nil)
        #expect((object["images"] as? [String: String])?[wingId.uuidString] == photo.base64EncodedString())

        // And it round-trips
        let decoded = try makeDecoder().decode(CloudBackupFile.self, from: data)
        #expect(decoded.manifest.flights.count == 1)
        #expect(Data(base64Encoded: decoded.images[wingId.uuidString] ?? "") == photo)
    }

    @Test func cloudBackupFileWithoutImagesKeyDecodesToEmptyDict() throws {
        // A plain v2 manifest (folder-bundle backup.json content) is also a
        // valid single-file cloud backup with zero images.
        let manifestData = try makeEncoder().encode(makeManifest())
        let decoded = try makeDecoder().decode(CloudBackupFile.self, from: manifestData)
        #expect(decoded.images.isEmpty)
        #expect(decoded.manifest.wings.count == 1)
    }

    @Test func importSummaryMessageListsOnlyRelevantLines() {
        var summary = ImportSummary()
        summary.wingsImported = 2
        summary.flightsImported = 5
        #expect(summary.message.contains("Wings imported: 2"))
        #expect(summary.message.contains("Flights imported: 5"))
        #expect(!summary.message.contains("Skipped duplicates"))
        #expect(!summary.message.contains("GPS tracks"))

        summary.skippedDuplicates = 3
        summary.skippedMalformed = 1
        summary.gpsTracksImported = 4
        summary.spotsImported = 2
        summary.flightTypesFilled = 6
        #expect(summary.message.contains("Skipped duplicates: 3"))
        #expect(summary.message.contains("Skipped malformed rows: 1"))
        #expect(summary.message.contains("GPS tracks restored: 4"))
        #expect(summary.message.contains("Spots imported: 2"))
        #expect(summary.message.contains("Flight types filled on existing flights: 6"))
    }
}

// MARK: - File-based export (bundle + legacy CSV interop)

@Suite struct BackupExportFileTests {

    let container: ModelContainer

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Wing.self, Flight.self, Spot.self,
                                       configurations: configuration)
    }

    /// One wing + one flight with values chosen to exercise the legacy CSV
    /// escaping (commas, quotes, newlines).
    private func makeSampleData() -> (wing: Wing, flight: Flight) {
        let context = container.mainContext
        let wing = Wing(name: "Moustache, M1 \"Pro\"", brand: "Flare", createdAt: utcDate(2025, 1, 1, 12, 0, 0))
        context.insert(wing)

        let flight = Flight(
            startDate: utcDate(2026, 7, 4, 10, 0, 0),
            endDate: utcDate(2026, 7, 4, 10, 45, 0),
            durationSeconds: 2700,
            spotName: "Punta, Paloma",
            latitude: 36.0143,
            longitude: -5.6044,
            flightType: "Soaring",
            notes: "Nice, flight\nsecond line"
        )
        context.insert(flight)
        flight.wing = wing
        flight.setGPSTrack([
            GPSTrackPoint(timestamp: utcDate(2026, 7, 4, 10, 0, 0), latitude: 36.0143, longitude: -5.6044, altitude: 30),
            GPSTrackPoint(timestamp: utcDate(2026, 7, 4, 10, 0, 5), latitude: 36.0145, longitude: -5.6044, altitude: 35)
        ])
        return (wing, flight)
    }

    private func exportBundle(wings: [Wing], flights: [Flight]) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            BackupManager.exportBackup(wings: wings, flights: flights) { @Sendable result in
                continuation.resume(with: result)
            }
        }
    }

    @Test func exportedBundleContainsValidManifestAndLegacyInterop() async throws {
        let (wing, flight) = makeSampleData()
        let bundleURL = try await exportBundle(wings: [wing], flights: [flight])
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        #expect(bundleURL.lastPathComponent.hasSuffix(".paraflightlog"))

        // --- backup.json (v2 manifest) ---
        let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("backup.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)

        #expect(manifest.formatVersion == 2)
        #expect(manifest.wings.count == 1)
        #expect(manifest.wings[0].name == "Moustache, M1 \"Pro\"")  // JSON keeps the raw name
        #expect(manifest.flights.count == 1)
        #expect(manifest.flights[0].id == flight.id)
        #expect(manifest.flights[0].startDate == utcDate(2026, 7, 4, 10, 0, 0))
        #expect(manifest.flights[0].wingId == wing.id)
        #expect(manifest.flights[0].gpsTrack?.count == 2)
        #expect(manifest.spots?.isEmpty == true)  // no Spot entities linked

        // --- wings.csv (legacy interop: comma -> ";", quote -> "'") ---
        let wingsCSV = try String(contentsOf: bundleURL.appendingPathComponent("wings.csv"), encoding: .utf8)
        #expect(wingsCSV.contains("Moustache; M1 'Pro'"))
        #expect(!wingsCSV.contains("Moustache, M1"))
        #expect(wingsCSV.contains(wing.id.uuidString))

        // --- flights.csv (spot comma escaped, notes quoted + newline flattened) ---
        let flightsCSV = try String(contentsOf: bundleURL.appendingPathComponent("flights.csv"), encoding: .utf8)
        #expect(flightsCSV.contains("Punta; Paloma"))
        #expect(flightsCSV.contains("\"Nice; flight second line\""))
        #expect(flightsCSV.contains(flight.id.uuidString))

        // --- gps/<flightId>.json decodable with a PLAIN JSONDecoder (dev-3 contract) ---
        let trackURL = bundleURL.appendingPathComponent("gps/\(flight.id.uuidString).json")
        let trackData = try Data(contentsOf: trackURL)
        let track = try JSONDecoder().decode([GPSTrackPoint].self, from: trackData)
        #expect(track.count == 2)
        #expect(track[0].altitude == 30)

        // --- metadata.json ---
        let metadataData = try Data(contentsOf: bundleURL.appendingPathComponent("metadata.json"))
        let metadata = try #require(try JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        #expect(metadata["wingsCount"] as? Int == 1)
        #expect(metadata["flightsCount"] as? Int == 1)
    }

    @Test func cloudExportWritesSingleDecodableFile() async throws {
        let (wing, flight) = makeSampleData()
        let fileURL: URL = try await withCheckedThrowingContinuation { continuation in
            BackupManager.exportCloudBackup(wings: [wing], flights: [flight]) { @Sendable result in
                continuation.resume(with: result)
            }
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(fileURL.lastPathComponent == "ParaFlightLog-backup.paraflightlogx")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue == false)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(CloudBackupFile.self, from: Data(contentsOf: fileURL))
        #expect(file.manifest.wings.count == 1)
        #expect(file.manifest.flights.count == 1)
        #expect(file.manifest.flights[0].gpsTrack?.count == 2)
        #expect(file.images.isEmpty)  // wing has no photo
    }
}
