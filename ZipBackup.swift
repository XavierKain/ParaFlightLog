//
//  ZipBackup.swift
//  ParaFlightLog
//
//  Backup export/import as a `.paraflightlog` folder bundle.
//
//  Format v2 (current): backup.json (single JSON manifest, ISO 8601 dates,
//  all wing and flight fields including full GPS tracks) + images/<wingId>.jpg
//  JSON removes the CSV-escaping corruption of format v1.
//  Additive v2 fields (optional, still formatVersion 2): a `spots` array and
//  a per-flight `spotId`. Older v2 files without them import unchanged and
//  fall back to name-based linking (linkUnlinkedFlights).
//
//  Format v1 (legacy, import only): wings.csv + flights.csv + metadata.json.
//  Users have real historical backups in this format, so the v1 parser is kept
//  and hardened: it never crashes on malformed rows, it skips and counts them.
//
//  Cloud format (single file): `ParaFlightLog-backup.paraflightlogx`, a flat
//  JSON document with the same v2 manifest structure plus an optional `images`
//  dict (wingId -> base64 JPEG). Cloud backups are stored in an Appwrite
//  database column (CloudBackupService) and omit the images to stay small —
//  wing photos are excluded from cloud backups; the LOCAL folder/file backup
//  keeps them. Import auto-detects the single-file format and tolerates a
//  missing/empty `images` dict.
//
//  NOTE: the filename ZipBackup.swift is kept so the Xcode project reference
//  stays valid; the type is BackupManager.
//

import Foundation
import SwiftData

// MARK: - Backup v2 Manifest

/// Wing snapshot in backup.json (all fields, photo stored separately in images/)
/// Pure value type: `nonisolated` so it can be encoded/decoded off the main actor.
nonisolated struct BackupWing: Codable {
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
/// Pure value type: `nonisolated` so it can be encoded/decoded off the main actor.
nonisolated struct BackupFlight: Codable {
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
    /// Additive v2 field: id of the Spot entity this flight is linked to.
    /// nil in older backups — the import then falls back to name linking.
    let spotId: UUID?
    /// Additive v2 fields (Step B): weather snapshot at takeoff.
    /// nil in older backups.
    let takeoffWindSpeed: Double?
    let takeoffWindGusts: Double?
    let takeoffWindDirection: Double?
    let takeoffTemperature: Double?
}

/// Spot snapshot in backup.json (additive v2 field; older v2 files lack it)
/// Pure value type: `nonisolated` so it can be encoded/decoded off the main actor.
nonisolated struct BackupSpot: Codable {
    let id: UUID
    let name: String
    let city: String?
    let latitude: Double?
    let longitude: Double?
    let createdAt: Date
    /// Additive v2 field (Step B): launch wind directions ("N", "NE", ...).
    /// nil in older backups.
    let windDirections: [String]?
}

/// Single JSON manifest written to backup.json
/// Pure value type: `nonisolated` so it can be encoded/decoded off the main actor.
nonisolated struct BackupManifest: Codable {
    let formatVersion: Int
    let exportDate: Date
    let appVersion: String
    let wings: [BackupWing]
    let flights: [BackupFlight]
    /// Additive v2 field: optional so older v2 files (without spots) decode.
    let spots: [BackupSpot]?

    static let currentFormatVersion = 2
}

/// Single-file cloud backup: the v2 manifest JSON at the top level PLUS an
/// `images` dict (wingId uuidString -> base64 JPEG). Custom Codable so the
/// on-disk JSON is literally the manifest structure with one extra key;
/// the folder bundle format is untouched.
nonisolated struct CloudBackupFile: Codable {
    let manifest: BackupManifest
    let images: [String: String]

    init(manifest: BackupManifest, images: [String: String]) {
        self.manifest = manifest
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case images
    }

    init(from decoder: Decoder) throws {
        manifest = try BackupManifest(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        images = try container.decodeIfPresent([String: String].self, forKey: .images) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        try manifest.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(images, forKey: .images)
    }
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
    var spotsImported: Int = 0
    var skippedDuplicates: Int = 0
    var skippedMalformed: Int = 0
    var gpsTracksImported: Int = 0
    var flightTypesFilled: Int = 0

    /// Human-readable English summary for the UI
    var message: String {
        var lines = [
            "Import complete.",
            "Wings imported: \(wingsImported)",
            "Flights imported: \(flightsImported)"
        ]
        if spotsImported > 0 {
            lines.append("Spots imported: \(spotsImported)")
        }
        if gpsTracksImported > 0 {
            lines.append("GPS tracks restored: \(gpsTracksImported)")
        }
        if flightTypesFilled > 0 {
            lines.append("Flight types filled on existing flights: \(flightTypesFilled)")
        }
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
            return "This is not a recognized ParaFlightLog backup: expected a .paraflightlog folder bundle (backup.json or wings.csv/flights.csv) or a single-file cloud backup (.paraflightlogz / .paraflightlogx)."
        case .invalidManifest(let detail):
            return "The backup file is damaged: \(detail)"
        case .exportFailed(let detail):
            return "Backup export failed: \(detail)"
        }
    }
}

// MARK: - BackupManager

enum BackupManager {

    // MARK: - Compressed cloud format

    /// Magic prefix marking a compressed single-file cloud backup: the JSON is
    /// zlib-compressed then base64-encoded, and this ASCII header is prepended
    /// so import can detect the format from content alone (extension-agnostic).
    /// `nonisolated` so the off-main encode/decode paths can reference it.
    nonisolated static let compressedCloudMagic = "PFLZ1:"

    /// File extension for the compressed cloud backup.
    static let compressedCloudExtension = "paraflightlogz"

    /// Compresses `json` to the `PFLZ1:` base64 payload string.
    /// zlib (raw DEFLATE) via `NSData.compressed(using:)`, which round-trips
    /// cleanly with `NSData.decompressed(using:)` on device.
    nonisolated static func compressCloudPayload(_ json: Data) throws -> String {
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        return compressedCloudMagic + compressed.base64EncodedString()
    }

    /// Inverse of `compressCloudPayload`: strips the magic, base64-decodes and
    /// inflates back to the original JSON bytes. Throws `invalidManifest` when
    /// the payload is not a well-formed compressed backup.
    nonisolated static func decompressCloudPayload(_ payload: String) throws -> Data {
        guard payload.hasPrefix(compressedCloudMagic) else {
            throw BackupError.invalidManifest("Not a compressed cloud backup.")
        }
        let base64 = String(payload.dropFirst(compressedCloudMagic.count))
        guard let compressed = Data(base64Encoded: base64) else {
            throw BackupError.invalidManifest("Corrupt compressed backup (base64).")
        }
        do {
            return try (compressed as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw BackupError.invalidManifest("Corrupt compressed backup (inflate).")
        }
    }

    // MARK: - Export (format v2)

    /// Exports all data into a `.paraflightlog` folder bundle containing
    /// backup.json + images/<wingId>.jpg. Deterministic: entries are sorted
    /// and the JSON uses sorted keys.
    /// - Parameters:
    ///   - wings: wings to export
    ///   - flights: flights to export
    ///   - spots: spots to export; when nil, the spots linked from `flights`
    ///     are exported (existing call sites keep working, but spots without
    ///     any flight are only included when the caller passes them)
    ///   - completion: callback on the main queue with the bundle URL (or error)
    static func exportBackup(wings: [Wing], flights: [Flight], spots: [Spot]? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        // Capture everything we need from the models on the calling (main) thread:
        // SwiftData models must not be touched from a background queue.
        let (manifest, photosByWingId) = makeManifestSnapshot(wings: wings, flights: flights, spots: spots)

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

                // 2. images/<wingId>.jpg (manifest.wings is sorted -> deterministic)
                let imagesDir = bundleURL.appendingPathComponent("images")
                try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                for wing in manifest.wings {
                    guard let filename = wing.photoFilename, let data = photosByWingId[wing.id] else { continue }
                    try data.write(to: imagesDir.appendingPathComponent(filename))
                }

                // 3. Legacy interop files (wings.csv / flights.csv / gps/ /
                //    metadata.json) so the dev-3 (old) app can import this
                //    bundle too. v20 itself always prefers backup.json.
                try writeLegacyInterop(into: bundleURL, manifest: manifest)

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

    /// Exports all data as a SINGLE regular file suitable for cloud upload
    /// (`ParaFlightLog-backup.paraflightlogx`): a flat JSON document with the
    /// same v2 manifest structure plus an `images` dict (wingId -> base64 JPEG).
    /// The single-file layout is also what the cloud backup table stores.
    /// - Parameters:
    ///   - wings: wings to export
    ///   - flights: flights to export
    ///   - spots: spots to export; when nil, the spots linked from `flights`
    ///     are exported (see `exportBackup`)
    ///   - includeImages: base64 wing photos bloat the file and cloud backups
    ///     store it in a size-limited database column, so cloud backups omit
    ///     them (default). Photos are only in the LOCAL folder/file backup.
    ///     Import tolerates a missing `images` dict — flights/wings/spots/tracks
    ///     are what matter.
    ///   - completion: callback on the main queue with the file URL (or error)
    static func exportCloudBackup(wings: [Wing], flights: [Flight], spots: [Spot]? = nil, includeImages: Bool = false, completion: @escaping (Result<URL, Error>) -> Void) {
        // Snapshot the models on the calling (main) thread, encode/write off-main.
        let (manifest, photosByWingId) = makeManifestSnapshot(wings: wings, flights: flights, spots: spots)

        DispatchQueue.global(qos: .utility).async {
            do {
                let images: [String: String] = includeImages
                    ? photosByWingId.reduce(into: [:]) { dict, entry in
                        dict[entry.key.uuidString] = entry.value.base64EncodedString()
                    }
                    : [:]
                let file = CloudBackupFile(manifest: manifest, images: images)

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(file)

                // Compress (zlib) + base64 + magic header. Track-heavy JSON
                // compresses ~8–12x, keeping the cloud payload well under the
                // database column limit. The uncompressed path still imports
                // (old cloud backups / other tools) — see parseSingleFile.
                let payload = try compressCloudPayload(data)

                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ParaFlightLog-backup.\(compressedCloudExtension)")
                try? FileManager.default.removeItem(at: fileURL)
                try Data(payload.utf8).write(to: fileURL, options: .atomic)

                DispatchQueue.main.async {
                    completion(.success(fileURL))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(BackupError.exportFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// Snapshots the SwiftData models into a v2 manifest + wingId -> photo data map.
    /// Must run on the main actor: models must not be touched from a background queue.
    private static func makeManifestSnapshot(wings: [Wing], flights: [Flight], spots: [Spot]?) -> (manifest: BackupManifest, photosByWingId: [UUID: Data]) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        // Spots: the caller's array when provided, always completed with any
        // spot still reachable from the flights so every flight.spotId in the
        // manifest resolves to a spots entry.
        var spotsToExport: [Spot] = spots ?? []
        var seenSpotIds = Set(spotsToExport.map(\.id))
        for flight in flights {
            if let spot = flight.spot, seenSpotIds.insert(spot.id).inserted {
                spotsToExport.append(spot)
            }
        }
        let backupSpots: [BackupSpot] = spotsToExport
            .sorted { $0.createdAt < $1.createdAt }
            .map { spot in
                BackupSpot(
                    id: spot.id,
                    name: spot.name,
                    city: spot.city,
                    latitude: spot.latitude,
                    longitude: spot.longitude,
                    createdAt: spot.createdAt,
                    windDirections: spot.windDirections.isEmpty ? nil : spot.windDirections
                )
            }

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
                    gpsTrack: flight.gpsTrack,
                    spotId: flight.spot?.id,
                    takeoffWindSpeed: flight.takeoffWindSpeed,
                    takeoffWindGusts: flight.takeoffWindGusts,
                    takeoffWindDirection: flight.takeoffWindDirection,
                    takeoffTemperature: flight.takeoffTemperature
                )
            }

        let manifest = BackupManifest(
            formatVersion: BackupManifest.currentFormatVersion,
            exportDate: Date(),
            appVersion: appVersion,
            wings: backupWings.map(\.wing),
            flights: backupFlights,
            spots: backupSpots
        )

        let photosByWingId: [UUID: Data] = backupWings.reduce(into: [:]) { dict, entry in
            if entry.wing.photoFilename != nil, let data = entry.photoData {
                dict[entry.wing.id] = data
            }
        }

        return (manifest, photosByWingId)
    }

    // MARK: - Import (auto-detects single-file cloud / v2 / v1)

    /// Imports a backup: a `.paraflightlog` folder bundle or a single-file cloud backup.
    /// Auto-detects the format: regular file = single-file cloud JSON,
    /// v2 = backup.json present, v1 legacy = wings.csv/flights.csv.
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

                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

                if exists && !isDirectory.boolValue {
                    // Regular file: single-file cloud backup (manifest + base64 images)
                    parsed = try parseSingleFile(fileURL: url)
                } else if FileManager.default.fileExists(atPath: manifestURL.path) {
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

    /// Fully parsed backup, validated before any database mutation.
    /// Pure value type: `nonisolated` so parsing can run off the main actor.
    private nonisolated struct ParsedBackup {
        var wings: [BackupWing]
        var flights: [BackupFlight]
        /// Empty for v1 backups and older v2 files without the spots field.
        var spots: [BackupSpot]
        var photosByWingId: [UUID: Data]
        var skippedMalformed: Int
    }

    // MARK: - Single-file (cloud) Parsing

    /// Parses a single-file cloud backup: v2 manifest JSON + inline base64 images.
    /// Pure file/parse helper: `nonisolated`, runs on the import utility queue.
    private nonisolated static func parseSingleFile(fileURL: URL) throws -> ParsedBackup {
        let rawData = try Data(contentsOf: fileURL)

        // Detect the compressed cloud format (`PFLZ1:` magic) from content, so
        // the extension (.paraflightlogz / .paraflightlogx) doesn't matter.
        // Fall back to plain JSON for legacy/uncompressed single-file backups.
        let jsonData: Data
        if rawData.starts(with: Array(compressedCloudMagic.utf8)),
           let payload = String(data: rawData, encoding: .utf8) {
            jsonData = try decompressCloudPayload(payload)
        } else {
            jsonData = rawData
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let file: CloudBackupFile
        do {
            file = try decoder.decode(CloudBackupFile.self, from: jsonData)
        } catch {
            throw BackupError.invalidManifest(error.localizedDescription)
        }

        logInfo("Importing single-file v\(file.manifest.formatVersion) cloud backup from \(file.manifest.exportDate): \(file.manifest.wings.count) wings, \(file.manifest.flights.count) flights", category: .dataImport)

        // Decode the inline base64 photos
        var photos: [UUID: Data] = [:]
        for (key, base64) in file.images {
            guard let wingId = UUID(uuidString: key),
                  let photoData = Data(base64Encoded: base64) else { continue }
            photos[wingId] = photoData
        }

        return ParsedBackup(
            wings: file.manifest.wings,
            flights: file.manifest.flights,
            spots: file.manifest.spots ?? [],
            photosByWingId: photos,
            skippedMalformed: 0
        )
    }

    // MARK: - v2 Parsing

    /// Pure file/parse helper: `nonisolated`, runs on the import utility queue.
    private nonisolated static func parseV2(bundleURL: URL) throws -> ParsedBackup {
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
            spots: manifest.spots ?? [],
            photosByWingId: photos,
            skippedMalformed: 0
        )
    }

    // MARK: - v1 (legacy CSV) Parsing

    /// Parses a legacy v1 backup (wings.csv + flights.csv).
    /// Robust by design: malformed rows are skipped and counted, never a crash.
    /// Note: v1 export replaced "," with ";" inside values, so values may
    /// contain ";" where the original text had a comma - they are kept as-is.
    /// Pure file/parse helper: `nonisolated`, runs on the import utility queue.
    private nonisolated static func parseV1(bundleURL: URL) throws -> ParsedBackup {
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
                // Column 9 (Marque/brand) exists in extended dev-3 exports
                brand: (cols.count >= 10 && !cols[9].isEmpty) ? cols[9] : nil,
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
        // Base columns: 0=id, 1=startDate, 2=endDate, 3=durationSeconds, 4=wingId,
        //               5=wingName, 6=spotName, 7=latitude, 8=longitude, 9=flightType, 10=notes
        // Extended (dev-3 exports): 11=startAlt, 12=maxAlt, 13=endAlt,
        //               14=distance(m), 15=maxSpeed(m/s), 16=maxGForce, 17=createdAt
        let flightsCSV = try String(contentsOf: bundleURL.appendingPathComponent("flights.csv"), encoding: .utf8)
        let flightsRows = flightsCSV.components(separatedBy: "\n").dropFirst() // skip header

        // SoarX v10+ backups store one GPS track per flight as gps/<flightId>.json
        // (a JSON-encoded [GPSTrackPoint]). Read it so replays/exports survive the
        // migration; older backups without this folder just import without a track.
        let gpsDir = bundleURL.appendingPathComponent("gps")
        var gpsTracksImported = 0

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

            // Keep the flight even if its wing link can't be parsed, but surface
            // it: a non-empty-yet-invalid wingId would silently orphan the flight.
            let wingId = UUID(uuidString: cols[4])
            if wingId == nil && !cols[4].isEmpty {
                logWarning("Imported flight \(flightId) has an unrecognized wing id '\(cols[4])' — it will not be linked to a wing", category: .dataImport)
            }

            // GPS track from gps/<flightId>.json, if the backup includes it
            var gpsTrack: [GPSTrackPoint]? = nil
            let trackURL = gpsDir.appendingPathComponent("\(flightId.uuidString).json")
            if let trackData = try? Data(contentsOf: trackURL) {
                if let decoded = try? JSONDecoder().decode([GPSTrackPoint].self, from: trackData), !decoded.isEmpty {
                    gpsTrack = decoded
                    gpsTracksImported += 1
                } else {
                    logWarning("Could not decode GPS track for flight \(flightId)", category: .dataImport)
                }
            }

            // Extended tracking columns (dev-3 exports); absent in older backups
            func extendedDouble(_ index: Int) -> Double? {
                cols.count > index ? Double(cols[index]) : nil
            }
            let createdAt: Date
            if cols.count > 17, let parsed = dateFormatter.date(from: cols[17]) {
                createdAt = parsed
            } else {
                createdAt = startDate
            }

            flights.append(BackupFlight(
                id: flightId,
                wingId: wingId,
                startDate: startDate,
                endDate: endDate,
                durationSeconds: durationSeconds,
                spotName: cols[6].isEmpty ? nil : cols[6],
                latitude: Double(cols[7]),
                longitude: Double(cols[8]),
                flightType: cols[9].isEmpty ? nil : cols[9],
                notes: notes,
                createdAt: createdAt,
                startAltitude: extendedDouble(11),
                maxAltitude: extendedDouble(12),
                endAltitude: extendedDouble(13),
                totalDistance: extendedDouble(14),
                maxSpeed: extendedDouble(15),
                maxGForce: extendedDouble(16),
                gpsTrack: gpsTrack,
                spotId: nil,  // v1 predates Spot entities; name linking applies
                takeoffWindSpeed: nil,
                takeoffWindGusts: nil,
                takeoffWindDirection: nil,
                takeoffTemperature: nil
            ))
        }

        logInfo("Parsed legacy v1 backup: \(wings.count) wings, \(flights.count) flights, \(gpsTracksImported) GPS tracks, \(skippedMalformed) malformed rows skipped", category: .dataImport)

        return ParsedBackup(
            wings: wings,
            flights: flights,
            spots: [],
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
            try modelContext.delete(model: Spot.self)
            try modelContext.save()
        }

        // Existing entities for merge deduplication (flights kept as a dict so
        // duplicates can still be ENRICHED — e.g. a type edited in the CSV on
        // a computer fills the local flight's missing type on reimport)
        var existingWingIds = Set<UUID>()
        var existingFlightsById: [UUID: Flight] = [:]
        if mode == .merge {
            existingWingIds = Set(dataController.fetchWings(includeArchived: true).map(\.id))
            existingFlightsById = Dictionary(
                dataController.fetchFlights().map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
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

        // Spots: upsert by id — existing ids are kept (only missing city/coords
        // are backfilled, never overwritten). A same-name spot with a different
        // id (e.g. auto-created independently on another device) is reused
        // instead of duplicated. Old backups without spots skip this entirely.
        var spotsById: [UUID: Spot] = [:]
        if !parsed.spots.isEmpty {
            let existingSpots = dataController.fetchSpots()
            var existingById = Dictionary(existingSpots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var existingByName = Dictionary(existingSpots.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

            for backupSpot in parsed.spots {
                if let existing = existingById[backupSpot.id] ?? existingByName[backupSpot.name.lowercased()] {
                    if existing.city == nil, let city = backupSpot.city {
                        existing.city = city
                    }
                    if existing.latitude == nil, let lat = backupSpot.latitude, let lon = backupSpot.longitude {
                        existing.latitude = lat
                        existing.longitude = lon
                    }
                    if existing.windDirections.isEmpty, let directions = backupSpot.windDirections, !directions.isEmpty {
                        existing.windDirections = directions
                    }
                    spotsById[backupSpot.id] = existing
                    continue
                }

                let spot = Spot(
                    id: backupSpot.id,
                    name: backupSpot.name,
                    city: backupSpot.city,
                    latitude: backupSpot.latitude,
                    longitude: backupSpot.longitude,
                    createdAt: backupSpot.createdAt
                )
                spot.windDirections = backupSpot.windDirections ?? []
                modelContext.insert(spot)
                existingById[backupSpot.id] = spot
                existingByName[backupSpot.name.lowercased()] = spot
                spotsById[backupSpot.id] = spot
                summary.spotsImported += 1
            }
        }

        // Flights
        for backupFlight in parsed.flights {
            if let existing = existingFlightsById[backupFlight.id] {
                // Duplicate — but fill a missing flight type from the backup
                // (lets you categorize in a spreadsheet and reimport).
                if (existing.flightType?.isEmpty ?? true),
                   let type = backupFlight.flightType, !type.isEmpty {
                    existing.flightType = type
                    summary.flightTypesFilled += 1
                }
                // Backfill missing takeoff weather from the backup (never
                // overwrites values the local flight already has).
                if existing.takeoffWindSpeed == nil, let v = backupFlight.takeoffWindSpeed {
                    existing.takeoffWindSpeed = v
                }
                if existing.takeoffWindGusts == nil, let v = backupFlight.takeoffWindGusts {
                    existing.takeoffWindGusts = v
                }
                if existing.takeoffWindDirection == nil, let v = backupFlight.takeoffWindDirection {
                    existing.takeoffWindDirection = v
                }
                if existing.takeoffTemperature == nil, let v = backupFlight.takeoffTemperature {
                    existing.takeoffTemperature = v
                }
                summary.skippedDuplicates += 1
                continue
            }

            var gpsTrackData: Data? = nil
            if let track = backupFlight.gpsTrack, !track.isEmpty {
                gpsTrackData = try? JSONEncoder().encode(track)
                if gpsTrackData != nil {
                    summary.gpsTracksImported += 1
                }
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
            flight.takeoffWindSpeed = backupFlight.takeoffWindSpeed
            flight.takeoffWindGusts = backupFlight.takeoffWindGusts
            flight.takeoffWindDirection = backupFlight.takeoffWindDirection
            flight.takeoffTemperature = backupFlight.takeoffTemperature
            modelContext.insert(flight)
            // Direct spot link when the backup carries it; flights without a
            // spotId (older backups) are left to linkUnlinkedFlights below.
            if let spotId = backupFlight.spotId, let spot = spotsById[spotId] {
                flight.spot = spot
                flight.spotName = spot.name
            }
            summary.flightsImported += 1
        }

        try modelContext.save()

        // Attach remaining unlinked flights to Spot entities by name
        // (intentional explicit call — the launch migration runs only once)
        dataController.linkUnlinkedFlights()

        logInfo("Backup import done: \(summary.wingsImported) wings, \(summary.flightsImported) flights, \(summary.skippedDuplicates) duplicates skipped, \(summary.skippedMalformed) malformed rows skipped", category: .dataImport)

        return summary
    }

    // MARK: - Helpers

    /// Minimal CSV row parser handling basic double-quoted fields (v1 legacy).
    /// Pure parse helper: `nonisolated`, safe off the main actor.
    private nonisolated static func parseCSVRow(_ row: String) -> [String] {
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

    /// Pure format helper: `nonisolated`, called from the export utility queue.
    private nonisolated static func formatDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }

    // MARK: - Legacy Interop Export (dev-3 / SoarX v10 compatible)

    /// CSV escaping matching the dev-3 exporter/importer: commas become
    /// semicolons, double quotes apostrophes (a stray `"` desynchronizes
    /// parseCSVRow's quote toggling on re-import) and newlines spaces.
    /// Lossy on purpose — these files exist only so the OLD app can read the
    /// bundle; backup.json holds the truth.
    private nonisolated static func legacyEscapeCSV(_ string: String) -> String {
        string.replacingOccurrences(of: ",", with: ";")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Writes the dev-3-compatible files into the export bundle:
    /// wings.csv (17 columns), flights.csv (18 columns incl. tracking metrics),
    /// gps/<flightId>.json (default-strategy JSON, what the old app decodes)
    /// and metadata.json. The old app's importer keys off wings.csv.
    private nonisolated static func writeLegacyInterop(into bundleURL: URL, manifest: BackupManifest) throws {
        // dev-3 dates: "dd/MM/yyyy HH:mm" in the device's timezone
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "dd/MM/yyyy HH:mm"

        // --- wings.csv (17 columns; ownership/maintenance columns left empty) ---
        var wingsCSV = "ID,Nom,Taille,Type,Couleur,Archivé,Date de création,Ordre d'affichage,Photo,Marque,Possédée,Heures initiales,Date achat,Date revente,Intervalle maintenance (h),Heures dern. maintenance,Date dern. maintenance\n"
        for wing in manifest.wings {
            let fields = [
                wing.id.uuidString,
                legacyEscapeCSV(wing.name),
                legacyEscapeCSV(wing.size ?? ""),
                legacyEscapeCSV(wing.type ?? ""),
                legacyEscapeCSV(wing.color ?? ""),
                wing.isArchived ? "Oui" : "Non",
                dateFormatter.string(from: wing.createdAt),
                "\(wing.displayOrder)",
                wing.photoFilename ?? "",
                legacyEscapeCSV(wing.brand ?? "")
            ]
            wingsCSV += fields.joined(separator: ",") + ",,,,,,,\n"
        }
        try wingsCSV.write(to: bundleURL.appendingPathComponent("wings.csv"), atomically: true, encoding: .utf8)

        // --- flights.csv (18 columns) + gps/<id>.json ---
        var flightsCSV = "ID,Date début,Date fin,Durée (sec),Voile ID,Voile Nom,Spot,Latitude,Longitude,Type,Notes,Alt départ,Alt max,Alt fin,Distance (m),Vitesse max (m/s),GForce max,Date de création\n"

        let gpsDir = bundleURL.appendingPathComponent("gps")
        try FileManager.default.createDirectory(at: gpsDir, withIntermediateDirectories: true)
        // Default date strategy: the old app decodes these blobs with a plain
        // JSONDecoder(), so the encoder must match.
        let trackEncoder = JSONEncoder()

        // Small helper keeps the row-building expressions simple enough for
        // the type-checker (a single mixed array literal timed it out).
        func optionalNumber(_ value: Double?) -> String {
            value.map { String($0) } ?? ""
        }

        for flight in manifest.flights {
            var fields: [String] = []
            fields.append(flight.id.uuidString)
            fields.append(dateFormatter.string(from: flight.startDate))
            fields.append(dateFormatter.string(from: flight.endDate))
            fields.append(String(flight.durationSeconds))
            fields.append(flight.wingId?.uuidString ?? "")
            fields.append("")   // wing name: informational only, resolved by id on import
            fields.append(legacyEscapeCSV(flight.spotName ?? ""))
            fields.append(optionalNumber(flight.latitude))
            fields.append(optionalNumber(flight.longitude))
            fields.append(legacyEscapeCSV(flight.flightType ?? ""))
            fields.append("\"" + legacyEscapeCSV(flight.notes ?? "") + "\"")
            fields.append(optionalNumber(flight.startAltitude))
            fields.append(optionalNumber(flight.maxAltitude))
            fields.append(optionalNumber(flight.endAltitude))
            fields.append(optionalNumber(flight.totalDistance))
            fields.append(optionalNumber(flight.maxSpeed))
            fields.append(optionalNumber(flight.maxGForce))
            fields.append(dateFormatter.string(from: flight.createdAt))
            flightsCSV += fields.joined(separator: ",") + "\n"

            if let track = flight.gpsTrack, !track.isEmpty,
               let trackData = try? trackEncoder.encode(track) {
                try trackData.write(to: gpsDir.appendingPathComponent("\(flight.id.uuidString).json"))
            }
        }
        try flightsCSV.write(to: bundleURL.appendingPathComponent("flights.csv"), atomically: true, encoding: .utf8)

        // --- metadata.json (informational, dev-3 shape) ---
        let metadata: [String: Any] = [
            "version": "1.0",
            "appVersion": manifest.appVersion,
            "exportDate": manifest.exportDate.timeIntervalSinceReferenceDate,
            "wingsCount": manifest.wings.count,
            "flightsCount": manifest.flights.count,
            "imagesCount": manifest.wings.filter { $0.photoFilename != nil }.count
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try metadataData.write(to: bundleURL.appendingPathComponent("metadata.json"))
    }
}
