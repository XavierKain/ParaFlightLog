//
//  CloudBackupService.swift
//  ParaFlightLog
//
//  Uploads/downloads the user's backup archive to/from Appwrite Storage.
//  This service only moves files: creating the local backup archive and
//  importing a downloaded one are handled elsewhere (backup manager).
//
//  Appwrite console setup (one-time):
//  - Create a Storage bucket with ID "user-backups" (AppwriteConfig.backupsBucketId)
//  - Enable file-level security ("File security" toggle ON)
//  - Bucket permissions: Create, Read, Update, Delete for role "users"
//  Each uploaded file is additionally restricted to its owner via per-file
//  permissions, so users can only ever see their own backup.
//
//  Target: iOS only
//

import Foundation
import Appwrite
import NIOCore // transitive dependency of the Appwrite SDK, needed for ByteBuffer

// MARK: - Errors

enum CloudBackupError: LocalizedError {
    case notSignedIn
    case noBackupFound
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You must be signed in to use cloud backup."
        case .noBackupFound:
            return "No cloud backup found for this account."
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

    /// Date of the last cloud backup (the stored file's $updatedAt),
    /// nil if none exists or it hasn't been fetched yet
    private(set) var lastBackupDate: Date?

    private var storage: Storage { AppwriteService.shared.storage }

    private init() {}

    // MARK: - Public API

    /// Uploads (or overwrites) the current user's backup archive.
    /// Appwrite Storage has no overwrite, so any existing backup is deleted first.
    /// - Parameter backupFile: local URL of the backup archive to upload
    @MainActor
    func upload(backupFile: URL) async throws {
        let userId = try requireUserId()
        let fileId = Self.backupFileId(for: userId)

        // Delete any previous backup; ignore failures ("file not found" is
        // expected on first upload, anything else will surface in createFile)
        _ = try? await storage.deleteFile(
            bucketId: AppwriteConfig.backupsBucketId,
            fileId: fileId
        )

        do {
            let file = try await storage.createFile(
                bucketId: AppwriteConfig.backupsBucketId,
                fileId: fileId,
                file: InputFile.fromPath(backupFile.path),
                permissions: [
                    Permission.read(Role.user(userId)),
                    Permission.update(Role.user(userId)),
                    Permission.delete(Role.user(userId))
                ]
            )
            lastBackupDate = Self.parseAppwriteDate(file.updatedAt) ?? Date()
            logInfo("Uploaded cloud backup (\(file.sizeOriginal) bytes)", category: .general)
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
        let fileId = Self.backupFileId(for: userId)

        do {
            // Fetch metadata first (original filename + last backup date)
            let file = try await storage.getFile(
                bucketId: AppwriteConfig.backupsBucketId,
                fileId: fileId
            )
            lastBackupDate = Self.parseAppwriteDate(file.updatedAt)

            let buffer = try await storage.getFileDownload(
                bucketId: AppwriteConfig.backupsBucketId,
                fileId: fileId
            )
            let data = Data(buffer.readableBytesView)

            // Preserve the original file extension so the importer recognizes it
            let ext = (file.name as NSString).pathExtension
            var fileName = "ParaFlightLog-CloudBackup-\(UUID().uuidString)"
            if !ext.isEmpty {
                fileName += ".\(ext)"
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            try data.write(to: destination, options: .atomic)

            logInfo("Downloaded cloud backup (\(data.count) bytes) to \(destination.lastPathComponent)", category: .general)
            return destination
        } catch {
            logError("Cloud backup download failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
    }

    /// Refreshes `lastBackupDate` from the stored file's metadata.
    /// Sets it to nil when signed out or when no backup exists yet.
    @MainActor
    func refreshLastBackupDate() async {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            lastBackupDate = nil
            return
        }

        do {
            let file = try await storage.getFile(
                bucketId: AppwriteConfig.backupsBucketId,
                fileId: Self.backupFileId(for: userId)
            )
            lastBackupDate = Self.parseAppwriteDate(file.updatedAt)
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

    /// Deterministic per-user file ID. Appwrite file IDs allow a-z, 0-9 and
    /// hyphen (max 36 chars); user IDs generated by ID.unique() already
    /// satisfy these rules, lowercasing/truncating is only defensive.
    private static func backupFileId(for userId: String) -> String {
        String(userId.lowercased().prefix(36))
    }

    /// Parses Appwrite ISO 8601 timestamps (e.g. "2026-07-04T10:15:30.123+00:00")
    private static func parseAppwriteDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
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
        case "storage_file_not_found", "storage_bucket_not_found":
            return CloudBackupError.noBackupFound
        case "user_unauthorized", "general_unauthorized_scope":
            return CloudBackupError.notSignedIn
        default:
            return CloudBackupError.unknown(appwriteError.message)
        }
    }
}
