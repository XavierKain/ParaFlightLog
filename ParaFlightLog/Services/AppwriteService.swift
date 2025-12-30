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

    // Collections - Wing Library
    static let manufacturersCollectionId = "manufacturers"
    static let wingsCollectionId = "wings"

    // Collections - Social (à créer dans Appwrite Console)
    static let usersCollectionId = "users"
    static let pilotsCollectionId = "pilots"
    static let spotsCollectionId = "spots"
    static let flightsCollectionId = "flights"
    static let followsCollectionId = "follows"
    static let spotSubscriptionsCollectionId = "spot_subscriptions"
    static let zoneAlertsCollectionId = "zone_alerts"
    static let notificationsCollectionId = "notifications"
    static let liveFlightsCollectionId = "live_flights"
    static let flightLikesCollectionId = "flight_likes"
    static let flightCommentsCollectionId = "flight_comments"

    // Collections - Gamification
    static let badgesCollectionId = "badges"
    static let userBadgesCollectionId = "user_badges"
    static let challengesCollectionId = "challenges"
    static let challengeParticipantsCollectionId = "challenge_participants"

    // Collections - Safety
    static let emergencyContactsCollectionId = "emergency_contacts"
    static let sosAlertsCollectionId = "sos_alerts"
    static let spotWeatherCacheCollectionId = "spot_weather_cache"

    // Storage - Wing Library
    static let wingImagesBucketId = "wing-images"

    // Storage - Social
    static let profilePhotosBucketId = "profile-photos"
    static let flightPhotosBucketId = "flight-photos"
    static let gpsTracksBucketId = "gps-tracks"
    static let spotPhotosBucketId = "spot-photos"
}

// MARK: - Service

final class AppwriteService {
    static let shared = AppwriteService()

    let client: Client
    let account: Account
    let databases: Databases
    let storage: Storage

    private init() {
        client = Client()
            .setEndpoint(AppwriteConfig.endpoint)
            .setProject(AppwriteConfig.projectId)

        account = Account(client)
        databases = Databases(client)
        storage = Storage(client)
    }
}
