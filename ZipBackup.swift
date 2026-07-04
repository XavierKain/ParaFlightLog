//
//  ZipBackup.swift
//  ParaFlightLog
//
//  Backup export/import as a `.paraflightlog` folder bundle.
//
//  Format v2 (current): backup.json (single JSON manifest, ISO 8601 dates,
//  all wing and flight fields including full GPS tracks) + images/<wingId>.jpg
//  JSON removes the CSV-escaping corruption of format v1.
//
//  Format v1 (legacy, import only): wings.csv + flights.csv + metadata.json.
//  Users have real historical backups in this format, so the v1 parser is kept
//  and hardened: it never crashes on malformed rows, it skips and counts them.
//
//  NOTE: the filename ZipBackup.swift is kept so the Xcode project reference
//  stays valid; the type is BackupManager.
//

import Foundation
import SwiftData

// MARK: - Backup v2 Manifest

/// Wing snapshot in backup.json (all fields, photo stored separately in images/)
struct BackupWing: Codable {
    let id: UUID
    let name: String
    let brand: String?
    let size: String?
    let type: String?
    let color: String?
    let isArchived: Bool
    let createdAt: Date
    let displayOrder: Int
    /// Filename inside images/ (e.g. "<wingId>.jpg"), nil when the wing has no photo
    let photoFilename: String?
}

/// Flight snapshot in backup.json (all fields, including the full GPS track)
struct BackupFlight: Codable {
    let id: UUID
    let wingId: UUID?
    let startDate: Date
    let endDate: Date
    let durationSeconds: Int
    let spotName: String?
    let latitude: Double?
    let longitude: Double?
    let flightType: String?
    let notes: String?
    let createdAt: Date
    let startAltitude: Double?
    let maxAltitude: Double?
    let endAltitude: Double?
    let totalDistance: Double?
    let maxSpeed: Double?
    let maxGForce: Double?
    let gpsTrack: [GPSTrackPoint]?
}

/// Single JSON manifest written to backup.json
struct BackupManifest: Codable {
    let formatVersion: Int
    let exportDate: Date
    let appVersion: String
    let wings: [BackupWing]
    let flights: [BackupFlight]

    static let currentFormatVersion = 2
}

// MARK: - Import Types

enum ImportMode {
    /// Keep existing data, skip wings/flights whose UUID already exists
    case merge
    /// Parse and validate everything first, then delete all existing data and insert
    case replace
}

/// Result of an import operation
struct ImportSummary {
    var wingsImported: Int = 0
    var flightsImported: Int = 0
    var skippedDuplicates: Int = 0
    var skippedMalformed: Int = 0

    /// Human-readable English summary for the UI
    var message: String {
        var lines = [
            "Import complete.",
            "Wings imported: \(wingsImported)",
            "Flights imported: \(flightsImported)"
        ]
        if skippedDuplicates > 0 {
            lines.append("Skipped duplicates: \(skippedDuplicates)")
        }
        if skippedMalformed > 0 {
            lines.append("Skipped malformed rows: \(skippedMalformed)")
        }
        return lines.joined(separator: "\n")
    }
}

enum BackupError: LocalizedError {
    case unrecognizedFormat
    case invalidManifest(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "This folder is not a recognized ParaFlightLog backup (no backup.json or wings.csv/flights.csv found)."
        case .invalidManifest(let detail):
            return "The backup file is damaged: \(detail)"
        case .exportFailed(let detail):
            return "Backup export failed: \(detail)"
        }
    }
}

// MARK: - BackupManager

enum BackupManager {

    // MARK: - Export (format v2)

    /// Exports all data into a `.paraflightlog` folder bundle containing
    /// backup.json + images/<wingId>.jpg. Deterministic: entries are sorted
    /// and the JSON uses sorted keys.
    /// - Parameters:
    ///   - wings: wings to export
    ///   - flights: flights to export
    ///   - completion: callback on the main queue with the bundle URL (or error)
    static func exportBackup(wings: [Wing], flights: [Flight], completion: @escaping (Result<URL, Error>) -> Void) {
        // Capture everything we need from the models on the calling (main) thread:
        // SwiftData models must not be touched from a background queue.
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        let backupWings: [(wing: BackupWing, photoData: Data?)] = wings
            .sorted { $0.createdAt < $1.createdAt }
            .map { wing in
                let photoFilename = wing.photoData != nil ? "\(wing.id.uuidString).jpg" : nil
                let snapshot = BackupWing(
                    id: wing.id,
                    name: wing.name,
                    brand: wing.brand,
                    size: wing.size,
                    type: wing.type,
                    color: wing.color,
                    isArchived: wing.isArchived,
                    createdAt: wing.createdAt,
                    displayOrder: wing.displayOrder,
                    photoFilename: photoFilename
                )
                return (snapshot, wing.photoData)
            }

        let backupFlights: [BackupFlight] = flights
            .sorted { $0.startDate < $1.startDate }
            .map { flight in
                BackupFlight(
                    id: flight.id,
                    wingId: flight.wing?.id,
                    startDate: flight.startDate,
                    endDate: flight.endDate,
                    durationSeconds: flight.durationSeconds,
                    spotName: flight.spotName,
                    latitude: flight.latitude,
                    longitude: flight.longitude,
                    flightType: flight.flightType,
                    notes: flight.notes,
                    createdAt: flight.createdAt,
                    startAltitude: flight.startAltitude,
                    maxAltitude: flight.maxAltitude,
                    endAltitude: flight.endAltitude,
                    totalDistance: flight.totalDistance,
                    maxSpeed: flight.maxSpeed,
                    maxGForce: flight.maxGForce,
                    gpsTrack: flight.gpsTrack
                )
            }

        let manifest = BackupManifest(
            formatVersion: BackupManifest.currentFormatVersion,
            exportDate: Date(),
            appVersion: appVersion,
            wings: backupWings.map(\.wing),
            flights: backupFlights
        )

        let photosByFilename: [String: Data] = backupWings.reduce(into: [:]) { dict, entry in
            if let filename = entry.wing.photoFilename, let data = entry.photoData {
                dict[filename] = data
            }
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let bundleName = "ParaFlightLog_Backup_\(formatDateForFilename(Date())).paraflightlog"
                let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(bundleName)

                // Remove any previous bundle with the same name
                try? FileManager.default.removeItem(at: bundleURL)
                try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

                // 1. backup.json (ISO 8601 dates, sorted keys for determinism)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let manifestData = try encoder.encode(manifest)
                try manifestData.write(to: bundleURL.appendingPathComponent("backup.json"))

                // 2. images/<wingId>.jpg
                let imagesDir = bundleURL.appendingPathComponent("images")
                try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                for (filename, data) in photosByFilename.sorted(by: { $0.key < $1.key }) {
                    try data.write(to: imagesDir.appendingPathComponent(filename))
                }

                DispatchQueue.main.async {
                    completion(.success(bundleURL))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(BackupError.exportFailed(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - Import (auto-detects v2 / v1)

    /// Imports a `.paraflightlog` folder bundle.
    /// Auto-detects the format: v2 = backup.json present, v1 legacy = wings.csv/flights.csv.
    /// - Parameters:
    ///   - url: backup bundle URL
    ///   - dataController: destination store
    ///   - mode: .merge (dedup by UUID) or .replace (validate everything, then wipe and insert)
    ///   - completion: callback on the main queue with an ImportSummary (or error)
    static func importBackup(
        from url: URL,
        dataController: DataController,
        mode: ImportMode = .merge,
        completion: @escaping (Result<ImportSummary, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                // Parse + validate EVERYTHING before touching the database
                let parsed: ParsedBackup
                let manifestURL = url.appendingPathComponent("backup.json")
                let wingsCSVURL = url.appendingPathComponent("wings.csv")

                if FileManager.default.fileExists(atPath: manifestURL.path) {
                    parsed = try parseV2(bundleURL: url)
                } else if FileManager.default.fileExists(atPath: wingsCSVURL.path) {
                    parsed = try parseV1(bundleURL: url)
                } else {
                    throw BackupError.unrecognizedFormat
                }

                // Insert on the main queue (SwiftData requirement)
                DispatchQueue.main.async {
                    do {
                        let summary = try insert(parsed, into: dataController, mode: mode)
                        completion(.success(summary))
                    } catch {
                        completion(.failure(error))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Parsed intermediate representation

    /// Fully parsed backup, validated before any database mutation
    private struct ParsedBackup {
        var wings: [BackupWing]
        var flights: [BackupFlight]
        var photosByWingId: [UUID: Data]
        var skippedMalformed: Int
    }

    // MARK: - v2 Parsing

    private static func parseV2(bundleURL: URL) throws -> ParsedBackup {
        let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("backup.json"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest: BackupManifest
        do {
            manifest = try decoder.decode(BackupManifest.self, from: manifestData)
        } catch {
            throw BackupError.invalidManifest(error.localizedDescription)
        }

        logInfo("Importing v\(manifest.formatVersion) backup from \(manifest.exportDate): \(manifest.wings.count) wings, \(manifest.flights.count) flights", category: .dataImport)

        // Load photos referenced by the manifest
        var photos: [UUID: Data] = [:]
        let imagesDir = bundleURL.appendingPathComponent("images")
        for wing in manifest.wings {
            guard let filename = wing.photoFilename else { continue }
            let imageURL = imagesDir.appendingPathComponent(filename)
            if let data = try? Data(contentsOf: imageURL) {
                photos[wing.id] = data
            }
        }

        return ParsedBackup(
            wings: manifest.wings,
            flights: manifest.flights,
            photosByWingId: photos,
            skippedMalformed: 0
        )
    }

    // MARK: - v1 (legacy CSV) Parsing

    /// Parses a legacy v1 backup (wings.csv + flights.csv).
    /// Robust by design: malformed rows are skipped and counted, never a crash.
    /// Note: v1 export replaced "," with ";" inside values, so values may
    /// contain ";" where the original text had a comma - they are kept as-is.
    private static func parseV1(bundleURL: URL) throws -> ParsedBackup {
        // v1 dates were written as "dd/MM/yyyy HH:mm" in the device's timezone
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "dd/MM/yyyy HH:mm"

        var skippedMalformed = 0

        // --- wings.csv ---
        // Columns: 0=id, 1=name, 2=size, 3=type, 4=color, 5=archived,
        //          6=createdAt, 7=displayOrder, 8=photoFilename
        let wingsCSV = try String(contentsOf: bundleURL.appendingPathComponent("wings.csv"), encoding: .utf8)
        let wingsRows = wingsCSV.components(separatedBy: "\n").dropFirst() // skip header

        var wings: [BackupWing] = []
        var photos: [UUID: Data] = [:]
        let imagesDir = bundleURL.appendingPathComponent("images")

        for row in wingsRows {
            let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let cols = parseCSVRow(trimmed)
            // Need at least id..displayOrder; the photo column may be missing entirely
            guard cols.count >= 8, let wingId = UUID(uuidString: cols[0]) else {
                skippedMalformed += 1
                logWarning("Skipping malformed wing row", category: .dataImport)
                continue
            }

            let createdAt = dateFormatter.date(from: cols[6]) ?? Date()
            // v1 wrote "Oui"/"Non"; accept English variants too
            let isArchived = ["oui", "yes", "true"].contains(cols[5].lowercased())
            let displayOrder = Int(cols[7]) ?? 0

            // Guarded photo column access (v1 importer crashed here on short rows)
            var photoFilename: String? = nil
            if cols.count >= 9, !cols[8].isEmpty {
                let imageURL = imagesDir.appendingPathComponent(cols[8])
                if let data = try? Data(contentsOf: imageURL) {
                    photos[wingId] = data
                    photoFilename = cols[8]
                }
            }

            wings.append(BackupWing(
                id: wingId,
                name: cols[1],
                brand: nil,
                size: cols[2].isEmpty ? nil : cols[2],
                type: cols[3].isEmpty ? nil : cols[3],
                color: cols[4].isEmpty ? nil : cols[4],
                isArchived: isArchived,
                createdAt: createdAt,
                displayOrder: displayOrder,
                photoFilename: photoFilename
            ))
        }

        // --- flights.csv ---
        // Columns: 0=id, 1=startDate, 2=endDate, 3=durationSeconds, 4=wingId,
        //          5=wingName, 6=spotName, 7=latitude, 8=longitude, 9=flightType, 10=notes
        let flightsCSV = try String(contentsOf: bundleURL.appendingPathComponent("flights.csv"), encoding: .utf8)
        let flightsRows = flightsCSV.components(separatedBy: "\n").dropFirst() // skip header

        var flights: [BackupFlight] = []

        for row in flightsRows {
            let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let cols = parseCSVRow(trimmed)
            guard cols.count >= 10,
                  let flightId = UUID(uuidString: cols[0]),
                  let startDate = dateFormatter.date(from: cols[1]),
                  let endDate = dateFormatter.date(from: cols[2]),
                  let durationSeconds = Int(cols[3]) else {
                skippedMalformed += 1
                logWarning("Skipping malformed flight row", category: .dataImport)
                continue
            }

            let notes: String?
            if cols.count >= 11, !cols[10].isEmpty {
                notes = cols[10].replacingOccurrences(of: "\"", with: "")
            } else {
                notes = nil
            }

            flights.append(BackupFlight(
                id: flightId,
                wingId: UUID(uuidString: cols[4]),
                startDate: startDate,
                endDate: endDate,
                durationSeconds: durationSeconds,
                spotName: cols[6].isEmpty ? nil : cols[6],
                latitude: Double(cols[7]),
                longitude: Double(cols[8]),
                flightType: cols[9].isEmpty ? nil : cols[9],
                notes: notes,
                createdAt: startDate,
                startAltitude: nil,
                maxAltitude: nil,
                endAltitude: nil,
                totalDistance: nil,
                maxSpeed: nil,
                maxGForce: nil,
                gpsTrack: nil
            ))
        }

        logInfo("Parsed legacy v1 backup: \(wings.count) wings, \(flights.count) flights, \(skippedMalformed) malformed rows skipped", category: .dataImport)

        return ParsedBackup(
            wings: wings,
            flights: flights,
            photosByWingId: photos,
            skippedMalformed: skippedMalformed
        )
    }

    // MARK: - Insertion (main queue)

    /// Inserts a fully-parsed backup into the store. Must run on the main queue.
    private static func insert(_ parsed: ParsedBackup, into dataController: DataController, mode: ImportMode) throws -> ImportSummary {
        let modelContext = dataController.modelContext

        var summary = ImportSummary()
        summary.skippedMalformed = parsed.skippedMalformed

        // Replace mode: everything is already parsed and validated - safe to wipe now
        if mode == .replace {
            try modelContext.delete(model: Flight.self)
            try modelContext.delete(model: Wing.self)
            try modelContext.save()
        }

        // Existing ids for merge deduplication
        var existingWingIds = Set<UUID>()
        var existingFlightIds = Set<UUID>()
        if mode == .merge {
            existingWingIds = Set(dataController.fetchWings(includeArchived: true).map(\.id))
            existingFlightIds = Set(dataController.fetchFlights().map(\.id))
        }

        // Wings
        var wingsById: [UUID: Wing] = [:]
        for backupWing in parsed.wings {
            if existingWingIds.contains(backupWing.id) {
                summary.skippedDuplicates += 1
                // Still resolve it so imported flights can attach to it
                if let existing = dataController.findWing(byId: backupWing.id) {
                    wingsById[backupWing.id] = existing
                }
                continue
            }

            let wing = Wing(
                id: backupWing.id,
                name: backupWing.name,
                brand: backupWing.brand,
                size: backupWing.size,
                type: backupWing.type,
                color: backupWing.color,
                photoData: parsed.photosByWingId[backupWing.id],
                isArchived: backupWing.isArchived,
                createdAt: backupWing.createdAt,
                displayOrder: backupWing.displayOrder
            )
            modelContext.insert(wing)
            wingsById[backupWing.id] = wing
            summary.wingsImported += 1
        }

        // Flights
        for backupFlight in parsed.flights {
            if existingFlightIds.contains(backupFlight.id) {
                summary.skippedDuplicates += 1
                continue
            }

            var gpsTrackData: Data? = nil
            if let track = backupFlight.gpsTrack, !track.isEmpty {
                gpsTrackData = try? JSONEncoder().encode(track)
            }

            let flight = Flight(
                id: backupFlight.id,
                wing: backupFlight.wingId.flatMap { wingsById[$0] },
                startDate: backupFlight.startDate,
                endDate: backupFlight.endDate,
                durationSeconds: backupFlight.durationSeconds,
                spotName: backupFlight.spotName,
                latitude: backupFlight.latitude,
                longitude: backupFlight.longitude,
                flightType: backupFlight.flightType,
                notes: backupFlight.notes,
                createdAt: backupFlight.createdAt,
                startAltitude: backupFlight.startAltitude,
                maxAltitude: backupFlight.maxAltitude,
                endAltitude: backupFlight.endAltitude,
                totalDistance: backupFlight.totalDistance,
                maxSpeed: backupFlight.maxSpeed,
                maxGForce: backupFlight.maxGForce,
                gpsTrackData: gpsTrackData
            )
            modelContext.insert(flight)
            summary.flightsImported += 1
        }

        try modelContext.save()
        logInfo("Backup import done: \(summary.wingsImported) wings, \(summary.flightsImported) flights, \(summary.skippedDuplicates) duplicates skipped, \(summary.skippedMalformed) malformed rows skipped", category: .dataImport)

        return summary
    }

    // MARK: - Helpers

    /// Minimal CSV row parser handling basic double-quoted fields (v1 legacy)
    private static func parseCSVRow(_ row: String) -> [String] {
        var result: [String] = []
        var currentField = ""
        var inQuotes = false

        for char in row {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(currentField)
                currentField = ""
            } else {
                currentField.append(char)
            }
        }
        result.append(currentField)

        return result
    }

    private static func formatDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }
}
