//
//  AppwriteService.swift
//  ParaFlightLog
//
//  Service singleton pour la connexion à Appwrite
//  Réutilisable pour toutes les fonctionnalités backend
//  Target: iOS only
//

import Foundation
import Appwrite

// MARK: - Appwrite Configuration

enum AppwriteConfig {
    static let endpoint = "https://fra.cloud.appwrite.io/v1"
    static let projectId = "69524ce30037813a6abb"
    static let databaseId = "69524e510015a312526b"

    // Collections
    static let manufacturersCollectionId = "manufacturers"
    static let wingsCollectionId = "wings"

    // Community sharing collections (Step C). Console setup: see
    // APPWRITE_COMMUNITY_SETUP.md at the repo root. All community calls
    // fail soft while these don't exist yet.
    static let communitySpotsCollectionId = "community_spots"
    static let sharedFlightsCollectionId = "shared_flights"
    static let presenceCollectionId = "presence"

    // Storage
    static let wingImagesBucketId = "wing-images"

    /// Bucket holding one backup archive per user (see CloudBackupService).
    /// Console setup: create this bucket with file-level security ON and
    /// Create/Read/Update/Delete permissions for role "users".
    static let backupsBucketId = "user-backups"
}

// MARK: - Service

final class AppwriteService {
    static let shared = AppwriteService()

    let client: Client
    let databases: Databases
    let tablesDB: TablesDB
    let storage: Storage
    let account: Account

    private init() {
        client = Client()
            .setEndpoint(AppwriteConfig.endpoint)
            .setProject(AppwriteConfig.projectId)

        databases = Databases(client)
        tablesDB = TablesDB(client)
        storage = Storage(client)
        account = Account(client)
    }
}
