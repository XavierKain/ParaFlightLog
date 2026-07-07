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
//  The archive is the single-file `.paraflightlogx` JSON produced by
//  BackupManager.exportCloudBackup(...). For cloud backups the JSON is
//  generated WITHOUT base64 wing photos to keep it small — photos are NOT
//  part of cloud backups. Use the local backup export for a full copy.
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
            return "This backup is too large for cloud backup (photos aren't included in cloud backups — use the local backup export for a full copy)."
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

    /// The `payload` attribute is sized 5,000,000 bytes; stay safely below it
    /// so headers/escaping never push a valid backup over the column limit.
    private static let maxPayloadBytes = 4_800_000

    private init() {}

    // MARK: - Public API

    /// Uploads (or overwrites) the current user's backup archive.
    /// Reads the single-file `.paraflightlogx` JSON at `backupFile` as UTF-8
    /// and upserts it into the `user_backups` row keyed by the user ID.
    /// Throws `.backupTooLarge` (nothing is uploaded) when the archive exceeds
    /// the payload column limit.
    /// - Parameter backupFile: local URL of the backup archive to upload
    @MainActor
    func upload(backupFile: URL) async throws {
        let userId = try requireUserId()
        let rowId = Self.rowId(for: userId)

        // Read the single-file cloud backup JSON as a UTF-8 string.
        let payload: String
        do {
            payload = try String(contentsOf: backupFile, encoding: .utf8)
        } catch {
            logError("Cloud backup read failed: \(error)", category: .general)
            throw CloudBackupError.unknown("Could not read the backup file for upload.")
        }

        // Size guard: refuse oversized backups outright, never partially upload.
        let byteCount = payload.utf8.count
        guard byteCount <= Self.maxPayloadBytes else {
            logError("Cloud backup too large: \(byteCount) bytes (limit \(Self.maxPayloadBytes))", category: .general)
            throw CloudBackupError.backupTooLarge
        }

        let now = Date()
        var data: [String: Any] = [
            "payload": payload,
            "updatedAt": Self.isoString(from: now),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        ]
        if let flightCount = Self.flightCount(inPayload: payload) {
            data["flightCount"] = flightCount
        }
        let permissions = [
            Permission.read(Role.user(userId)),
            Permission.update(Role.user(userId)),
            Permission.delete(Role.user(userId))
        ]

        do {
            // Upsert by id: update the existing row, create it on first backup.
            let row: Row<[String: AnyCodable]>
            do {
                row = try await tablesDB.updateRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.userBackupsCollectionId,
                    rowId: rowId,
                    data: data,
                    permissions: permissions
                )
            } catch let error where Self.isNotFound(error) {
                row = try await tablesDB.createRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.userBackupsCollectionId,
                    rowId: rowId,
                    data: data,
                    permissions: permissions
                )
            }
            lastBackupDate = Self.backupDate(from: row) ?? now
            logInfo("Uploaded cloud backup (\(byteCount) bytes) to table", category: .general)
        } catch {
            logError("Cloud backup upload failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
    }

    /// Downloads the current user's backup archive to a temporary local URL.
    /// The caller is responsible for importing it and cleaning up the file.
    @MainActor
    func downloadLatestBackup() async throws -> URL {
        let userId = try requireUserId()

        do {
            let row = try await tablesDB.getRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.userBackupsCollectionId,
                rowId: Self.rowId(for: userId)
            )
            guard let payload = row.data["payload"]?.value as? String, !payload.isEmpty else {
                throw CloudBackupError.noBackupFound
            }
            lastBackupDate = Self.backupDate(from: row)

            // Write to a fixed-name temp file; the importer recognizes the
            // .paraflightlogx extension as a single-file cloud backup.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ParaFlightLog-cloud.paraflightlogx")
            try? FileManager.default.removeItem(at: destination)
            try Data(payload.utf8).write(to: destination, options: .atomic)

            logInfo("Downloaded cloud backup (\(payload.utf8.count) bytes) to \(destination.lastPathComponent)", category: .general)
            return destination
        } catch {
            logError("Cloud backup download failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
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
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
