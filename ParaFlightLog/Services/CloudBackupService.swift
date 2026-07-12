//
//  CloudBackupService.swift
//  ParaFlightLog
//
//  Stores the user's backup archive in an Appwrite DATABASE table (one row
//  per user, row ID = user ID) instead of Appwrite Storage.
//
//  Why a table and not a bucket: the free Appwrite plan allows only ONE
//  storage bucket, and it is already used by the wing catalog (`wing-images`).
//  The `user-backups` bucket could never be created, so every Storage
//  upload/download failed silently. The backup archive is small once wing
//  photos are excluded (see below), so it fits comfortably in a String column.
//
//  The archive is the single-file `.paraflightlogz` produced by
//  BackupManager.exportCloudBackup(...): the v2 manifest JSON, zlib-compressed
//  and base64-encoded (`PFLZ1:` magic). For cloud backups the JSON is generated
//  WITHOUT base64 wing photos to keep it small — photos are NOT part of cloud
//  backups. Use the local backup export for a full copy.
//
//  Compression cuts track-heavy JSON ~8–12x, so a normal backup fits one row.
//  If the compressed payload still exceeds one column it is CHUNKED across
//  rows: row 1 (`<userId>`) stores `PFLCHUNK:<N>:` + its share, rows 2…N
//  (`<userId>-2`, `-3`, …) store raw shares, and download concatenates 1…N.
//
//  Appwrite console setup (one-time):
//  - Table `user_backups` (AppwriteConfig.userBackupsCollectionId)
//    Attributes: payload (String, size 5,000,000, required),
//    appVersion (String, optional), flightCount (Integer, optional),
//    updatedAt (Datetime, optional).
//  - Collection permissions: create("users"); Document Security ON.
//  Each row is additionally restricted to its owner via per-row
//  read/update/delete permissions written on every upload, so users can only
//  ever see their own backup.
//
//  Target: iOS only
//

import Foundation
import Appwrite // re-exports JSONCodable (AnyCodable)

// MARK: - Errors

enum CloudBackupError: LocalizedError {
    case notSignedIn
    case noBackupFound
    case backupTooLarge
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You must be signed in to use cloud backup."
        case .noBackupFound:
            return "No cloud backup found for this account."
        case .backupTooLarge:
            return "This backup is too large for cloud backup even after compression. Use the local backup export (Settings › Data) for a full copy."
        case .network:
            return "Network error. Check your connection and try again."
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Service

@Observable
final class CloudBackupService {
    static let shared = CloudBackupService()

    /// Date of the last cloud backup (the stored row's updatedAt),
    /// nil if none exists or it hasn't been fetched yet
    private(set) var lastBackupDate: Date?

    private var tablesDB: TablesDB { AppwriteService.shared.tablesDB }

    /// The `payload` attribute holds up to 5,000,000 chars; stay safely below it
    /// so headers/escaping never push a row over the column limit.
    private static let maxPayloadBytes = 4_800_000

    /// Bytes stored per chunk share. Below `maxPayloadBytes` so the first row
    /// can also carry the small `PFLCHUNK:<N>:` envelope prefix and stay legal.
    private static let chunkShareBytes = maxPayloadBytes - 100_000

    /// Envelope prefix on the FIRST row's payload when a backup is chunked:
    /// `PFLCHUNK:<N>:` followed by that row's share. Download reassembles rows
    /// 1…N in order. The table has no `parts` column, so N travels inline.
    private static let chunkMagic = "PFLCHUNK:"

    /// Hard ceiling on the (compressed) payload. Beyond this the backup is
    /// genuinely pathological — refuse it rather than sprawl across rows.
    private static let maxTotalPayloadBytes = 20_000_000

    /// Safety cap on chunk count for the stale-part cleanup loop. Derived from
    /// the ceiling above (⌈20M / 4.7M⌉ = 5) with headroom.
    private static let maxChunks = 8

    private init() {}

    // MARK: - Public API

    /// Uploads (or overwrites) the current user's backup archive.
    /// Reads the single-file `.paraflightlogz` payload at `backupFile` as UTF-8
    /// and upserts it into the `user_backups` row(s) keyed by the user ID,
    /// chunking across rows when the compressed payload exceeds one column.
    /// Throws `.backupTooLarge` (nothing is uploaded) only when the payload
    /// exceeds the pathological ceiling even after compression.
    /// - Parameter backupFile: local URL of the backup archive to upload
    @MainActor
    func upload(backupFile: URL) async throws {
        let userId = try requireUserId()
        let baseRowId = Self.rowId(for: userId)

        // Read the single-file cloud backup as a UTF-8 string. Since
        // exportCloudBackup now emits a compressed base64 payload (`PFLZ1:`
        // magic), this is ASCII; a legacy uncompressed JSON file also reads
        // fine and takes the single-row path.
        let payload: String
        do {
            payload = try String(contentsOf: backupFile, encoding: .utf8)
        } catch {
            logError("Cloud backup read failed: \(error)", category: .general)
            throw CloudBackupError.unknown("Could not read the backup file for upload.")
        }

        // Size guard: refuse only the genuinely pathological case. Compression
        // (~8–12x on track JSON) plus chunking handle everything below this.
        let byteCount = payload.utf8.count
        guard byteCount <= Self.maxTotalPayloadBytes else {
            logError("Cloud backup too large: \(byteCount) bytes (ceiling \(Self.maxTotalPayloadBytes))", category: .general)
            throw CloudBackupError.backupTooLarge
        }

        let now = Date()
        let nowString = Self.isoString(from: now)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let permissions = [
            Permission.read(Role.user(userId)),
            Permission.update(Role.user(userId)),
            Permission.delete(Role.user(userId))
        ]

        // Split into per-row shares (one share when it fits a single row).
        let shares = Self.splitPayload(payload)
        let partCount = shares.count

        do {
            // Write the extra parts (rows 2…N) FIRST, then row 1 last, so the
            // base row's updatedAt marks a complete upload ("last one wins").
            for index in 1..<partCount {
                let partData: [String: Any] = [
                    "payload": shares[index],
                    "updatedAt": nowString
                ]
                _ = try await upsertRow(
                    rowId: Self.partRowId(base: baseRowId, part: index + 1),
                    data: partData,
                    permissions: permissions
                )
            }

            // Row 1: single share as-is, or the `PFLCHUNK:<N>:` envelope + share.
            let firstPayload = partCount == 1
                ? shares[0]
                : "\(Self.chunkMagic)\(partCount):" + shares[0]
            var firstData: [String: Any] = [
                "payload": firstPayload,
                "updatedAt": nowString,
                "appVersion": appVersion
            ]
            if let flightCount = Self.flightCount(inPayload: payload) {
                firstData["flightCount"] = flightCount
            }
            let row = try await upsertRow(
                rowId: baseRowId,
                data: firstData,
                permissions: permissions
            )
            lastBackupDate = Self.backupDate(from: row) ?? now

            // Delete stale extra parts left over from a previous, larger backup.
            await deleteStaleParts(base: baseRowId, keeping: partCount)

            logInfo("Uploaded cloud backup (\(byteCount) bytes, \(partCount) part\(partCount == 1 ? "" : "s")) to table", category: .general)
        } catch {
            logError("Cloud backup upload failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
    }

    /// Upserts one row by id: update in place, create it if missing.
    @MainActor
    private func upsertRow(
        rowId: String,
        data: [String: Any],
        permissions: [String]
    ) async throws -> Row<[String: AnyCodable]> {
        do {
            return try await tablesDB.updateRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.userBackupsCollectionId,
                rowId: rowId,
                data: data,
                permissions: permissions
            )
        } catch let error where Self.isNotFound(error) {
            return try await tablesDB.createRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.userBackupsCollectionId,
                rowId: rowId,
                data: data,
                permissions: permissions
            )
        }
    }

    /// Deletes chunk rows numbered `keeping+1` upward (best-effort), stopping at
    /// the first missing row. Clears parts a previous, larger backup wrote so a
    /// smaller backup never leaves orphaned tail rows behind.
    @MainActor
    private func deleteStaleParts(base: String, keeping partCount: Int) async {
        var part = partCount + 1
        while part <= Self.maxChunks {
            do {
                _ = try await tablesDB.deleteRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.userBackupsCollectionId,
                    rowId: Self.partRowId(base: base, part: part)
                )
                part += 1
            } catch {
                // First missing row (404) means no more stale parts remain.
                break
            }
        }
    }

    /// Splits a payload string into per-row shares of at most `chunkShareBytes`.
    /// Byte-based on the UTF-8 view; the compressed payload is ASCII so slices
    /// never fall mid-character. Concatenating the shares in order reproduces
    /// the original string exactly. Always returns at least one share.
    private static func splitPayload(_ payload: String) -> [String] {
        let bytes = Array(payload.utf8)
        guard bytes.count > chunkShareBytes else { return [payload] }
        var shares: [String] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + chunkShareBytes, bytes.count)
            shares.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end
        }
        return shares
    }

    /// Downloads the current user's backup archive to a temporary local URL.
    /// The caller is responsible for importing it and cleaning up the file.
    @MainActor
    func downloadLatestBackup() async throws -> URL {
        let userId = try requireUserId()

        do {
            let baseRowId = Self.rowId(for: userId)
            let row = try await tablesDB.getRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.userBackupsCollectionId,
                rowId: baseRowId
            )
            guard let firstPayload = row.data["payload"]?.value as? String, !firstPayload.isEmpty else {
                throw CloudBackupError.noBackupFound
            }
            lastBackupDate = Self.backupDate(from: row)

            // Reassemble chunked backups: row 1 carries `PFLCHUNK:<N>:` + its
            // share, rows 2…N carry raw shares. A single-row backup (no magic)
            // passes through unchanged.
            let payload = try await reassemblePayload(firstPayload: firstPayload, base: baseRowId)

            // Write to a fixed-name temp file. The importer detects the format
            // from content (compressed magic vs plain JSON), not the extension.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ParaFlightLog-cloud.paraflightlogz")
            try? FileManager.default.removeItem(at: destination)
            try Data(payload.utf8).write(to: destination, options: .atomic)

            logInfo("Downloaded cloud backup (\(payload.utf8.count) bytes) to \(destination.lastPathComponent)", category: .general)
            return destination
        } catch {
            logError("Cloud backup download failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
    }

    /// Reassembles a (possibly chunked) payload. When `firstPayload` starts with
    /// the `PFLCHUNK:<N>:` envelope, fetches rows 2…N and concatenates the
    /// shares; otherwise returns `firstPayload` unchanged.
    @MainActor
    private func reassemblePayload(firstPayload: String, base: String) async throws -> String {
        guard firstPayload.hasPrefix(Self.chunkMagic) else { return firstPayload }

        let afterMagic = firstPayload.dropFirst(Self.chunkMagic.count)
        guard let colon = afterMagic.firstIndex(of: ":"),
              let partCount = Int(afterMagic[..<colon]),
              partCount >= 1, partCount <= Self.maxChunks else {
            throw CloudBackupError.unknown("The cloud backup header is damaged.")
        }
        var assembled = String(afterMagic[afterMagic.index(after: colon)...])

        if partCount >= 2 {
            for part in 2...partCount {
                let row = try await tablesDB.getRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.userBackupsCollectionId,
                    rowId: Self.partRowId(base: base, part: part)
                )
                guard let share = row.data["payload"]?.value as? String, !share.isEmpty else {
                    // A missing/empty part means an incomplete backup on the server.
                    throw CloudBackupError.noBackupFound
                }
                assembled += share
            }
        }
        return assembled
    }

    /// Refreshes `lastBackupDate` from the stored row's metadata.
    /// Sets it to nil when signed out or when no backup exists yet.
    @MainActor
    func refreshLastBackupDate() async {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            lastBackupDate = nil
            return
        }

        do {
            let row = try await tablesDB.getRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.userBackupsCollectionId,
                rowId: Self.rowId(for: userId)
            )
            lastBackupDate = Self.backupDate(from: row)
        } catch {
            // No backup yet (404) or server unreachable
            lastBackupDate = nil
        }
    }

    // MARK: - Private

    private func requireUserId() throws -> String {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw CloudBackupError.notSignedIn
        }
        return userId
    }

    /// Deterministic per-user row ID. Appwrite row IDs allow a-z, 0-9 and
    /// hyphen (max 36 chars); user IDs generated by ID.unique() already
    /// satisfy these rules, lowercasing/truncating is only defensive.
    /// (Same convention as CommunityService.)
    private static func rowId(for userId: String) -> String {
        String(userId.lowercased().prefix(36))
    }

    /// Row ID for chunk part `part` (1 = base row). Parts 2… append `-<part>`,
    /// truncating the base if needed so the ID stays within Appwrite's 36-char
    /// limit (real user IDs are ~20 chars, so this is only defensive).
    private static func partRowId(base: String, part: Int) -> String {
        guard part >= 2 else { return base }
        let suffix = "-\(part)"
        let maxBase = max(0, 36 - suffix.count)
        return String(base.prefix(maxBase)) + suffix
    }

    /// Prefers the `updatedAt` attribute the app writes; falls back to the
    /// row's system `$updatedAt`.
    private static func backupDate(from row: Row<[String: AnyCodable]>) -> Date? {
        if let stored = row.data["updatedAt"]?.value as? String,
           let date = parseAppwriteDate(stored) {
            return date
        }
        return parseAppwriteDate(row.updatedAt)
    }

    /// Best-effort flight count from the cloud backup JSON, so the row carries
    /// a lightweight metric without decoding the whole manifest. Returns nil
    /// when it can't be derived (the attribute is optional).
    private static func flightCount(inPayload payload: String) -> Int? {
        // The payload is normally compressed (`PFLZ1:` magic); inflate it back
        // to JSON first. A legacy uncompressed payload is parsed directly.
        let jsonData: Data
        if payload.hasPrefix(BackupManager.compressedCloudMagic) {
            guard let inflated = try? BackupManager.decompressCloudPayload(payload) else {
                return nil
            }
            jsonData = inflated
        } else if let raw = payload.data(using: .utf8) {
            jsonData = raw
        } else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let flights = object["flights"] as? [Any] else {
            return nil
        }
        return flights.count
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// Parses Appwrite ISO 8601 timestamps (e.g. "2026-07-04T10:15:30.123+00:00")
    private static func parseAppwriteDate(_ string: String) -> Date? {
        if let date = isoFormatter.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// True for "row/table not found" (HTTP 404) — the first-upload case where
    /// updateRow must fall back to createRow.
    private static func isNotFound(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 404
    }

    private static func mapError(_ error: Error) -> Error {
        if let cloudError = error as? CloudBackupError {
            return cloudError
        }
        guard let appwriteError = error as? AppwriteError else {
            // Transport-level failure (no server response)
            return CloudBackupError.network
        }
        switch appwriteError.type {
        case "document_not_found", "row_not_found",
             "collection_not_found", "table_not_found", "database_not_found":
            return CloudBackupError.noBackupFound
        case "user_unauthorized", "general_unauthorized_scope", "general_unauthorized":
            return CloudBackupError.notSignedIn
        default:
            return CloudBackupError.unknown(appwriteError.message)
        }
    }
}
