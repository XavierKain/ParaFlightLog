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

    // Storage
    static let wingImagesBucketId = "wing-images"
}

// MARK: - Service

final class AppwriteService {
    static let shared = AppwriteService()

    let client: Client
    let databases: Databases
    let storage: Storage

    private init() {
        client = Client()
            .setEndpoint(AppwriteConfig.endpoint)
            .setProject(AppwriteConfig.projectId)

        databases = Databases(client)
        storage = Storage(client)
    }
}
