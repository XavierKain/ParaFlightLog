//
//  SpotService.swift
//  ParaFlightLog
//
//  Service de gestion des spots de vol
//  Création, recherche, abonnements et statistiques
//  Target: iOS only
//

import Foundation
import Appwrite
import CoreLocation

// MARK: - Spot Errors

enum SpotError: LocalizedError {
    case notAuthenticated
    case spotNotFound
    case createFailed(String)
    case fetchFailed(String)
    case alreadySubscribed
    case notSubscribed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .spotNotFound:
            return "Spot non trouvé"
        case .createFailed(let message):
            return "Erreur de création: \(message)"
        case .fetchFailed(let message):
            return "Erreur de chargement: \(message)"
        case .alreadySubscribed:
            return "Vous êtes déjà abonné à ce spot"
        case .notSubscribed:
            return "Vous n'êtes pas abonné à ce spot"
        }
    }
}

// MARK: - Spot Model

struct Spot: Identifiable, Codable {
    let id: String
    let name: String
    let normalizedName: String
    let latitude: Double
    let longitude: Double
    let altitude: Int?
    let country: String?
    let region: String?
    let description: String?
    let photoFileIds: [String]
    let createdByUserId: String?
    let createdAt: Date

    // Stats
    let totalFlights: Int
    let totalFlightSeconds: Int
    let avgFlightSeconds: Int
    let longestFlightSeconds: Int
    let longestFlightUserId: String?
    let maxAltitudeGain: Double?
    let maxAltitudeUserId: String?
    let lastFlightAt: Date?
    let subscriberCount: Int

    // Meta
    let isVerified: Bool
    let windDirections: [String]
    let spotType: String?  // soaring, thermal, coastal

    // Computed
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var formattedTotalFlightTime: String {
        let hours = totalFlightSeconds / 3600
        let minutes = (totalFlightSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        }
        return "\(minutes) min"
    }

    var formattedAvgFlightTime: String {
        let minutes = avgFlightSeconds / 60
        return "\(minutes) min"
    }

    var formattedLongestFlight: String {
        let hours = longestFlightSeconds / 3600
        let minutes = (longestFlightSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        }
        return "\(minutes) min"
    }
}

// MARK: - Spot Stats

struct SpotStats {
    let totalFlights: Int
    let totalPilots: Int
    let totalFlightHours: Double
    let avgFlightMinutes: Int
    let longestFlightMinutes: Int
    let maxAltitudeGain: Double?
    let mostActiveMonth: String?
    let flightsByMonth: [String: Int]
}

// MARK: - Spot Leaderboard Entry

struct SpotLeaderEntry: Identifiable {
    let id: String
    let rank: Int
    let pilotId: String
    let pilotName: String
    let pilotUsername: String
    let pilotPhotoFileId: String?
    let value: Int  // Selon le type de classement (durée, nb vols, etc.)
    let formattedValue: String
}

// MARK: - Spot Leaderboards

struct SpotLeaderboards {
    let longestFlight: [SpotLeaderEntry]
    let mostFlights: [SpotLeaderEntry]
    let totalTime: [SpotLeaderEntry]
    let highestAltitude: [SpotLeaderEntry]
}

// MARK: - Spot Subscription

struct SpotSubscription: Identifiable, Codable {
    let id: String
    let userId: String
    let spotId: String
    let createdAt: Date
    let notifyOnFlight: Bool
}

// MARK: - SpotService

@Observable
final class SpotService {
    static let shared = SpotService()

    private let databases: Databases
    private let storage: Storage

    // Cache
    private var spotCache: [String: Spot] = [:]
    private var subscriptionsCache: [SpotSubscription]?
    private var subscriptionsCacheDate: Date?
    private let cacheValiditySeconds: TimeInterval = 300  // 5 minutes

    private init() {
        self.databases = AppwriteService.shared.databases
        self.storage = AppwriteService.shared.storage
    }

    // MARK: - Get or Create Spot

    /// Récupère un spot existant ou en crée un nouveau basé sur le nom et la position
    func getOrCreateSpot(name: String, coordinate: CLLocationCoordinate2D) async throws -> Spot {
        let normalizedName = normalizeName(name)

        // 1. Chercher un spot existant avec ce nom dans un rayon de 5km
        let existingSpots = try await searchNearbySpotsByName(
            name: normalizedName,
            coordinate: coordinate,
            radiusKm: 5.0
        )

        if let existing = existingSpots.first {
            return existing
        }

        // 2. Créer un nouveau spot
        return try await createSpot(
            name: name,
            normalizedName: normalizedName,
            coordinate: coordinate
        )
    }

    // MARK: - Get Spot

    /// Récupère un spot par son ID
    func getSpot(spotId: String) async throws -> Spot {
        // Vérifier le cache
        if let cached = spotCache[spotId] {
            return cached
        }

        do {
            let doc = try await databases.getDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.spotsCollectionId,
                documentId: spotId
            )

            let spot = try parseSpot(from: doc.data, id: spotId)
            spotCache[spotId] = spot
            return spot
        } catch {
            throw SpotError.spotNotFound
        }
    }

    // MARK: - Search Spots

    /// Recherche de spots par nom
    func searchSpots(query: String, limit: Int = 20) async throws -> [Spot] {
        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.spotsCollectionId,
                queries: [
                    Query.search("name", value: query),
                    Query.orderDesc("totalFlights"),
                    Query.limit(limit)
                ]
            )

            return response.documents.compactMap { doc in
                try? parseSpot(from: doc.data, id: doc.id)
            }
        } catch let error as AppwriteError {
            throw SpotError.fetchFailed(error.message)
        } catch {
            throw SpotError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Nearby Spots

    /// Récupère les spots à proximité d'une coordonnée
    func getNearbySpots(coordinate: CLLocationCoordinate2D, radiusKm: Double = 50, limit: Int = 20) async throws -> [Spot] {
        // Calculer les bounds approximatives
        let latDelta = radiusKm / 111.0
        let lonDelta = radiusKm / (111.0 * cos(coordinate.latitude * .pi / 180))

        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.spotsCollectionId,
                queries: [
                    Query.greaterThanEqual("latitude", value: coordinate.latitude - latDelta),
                    Query.lessThanEqual(attribute: "latitude", value: coordinate.latitude + latDelta),
                    Query.greaterThanEqual("longitude", value: coordinate.longitude - lonDelta),
                    Query.lessThanEqual(attribute: "longitude", value: coordinate.longitude + lonDelta),
                    Query.orderDesc("totalFlights"),
                    Query.limit(limit)
                ]
            )

            return response.documents.compactMap { doc in
                try? parseSpot(from: doc.data, id: doc.id)
            }
        } catch let error as AppwriteError {
            throw SpotError.fetchFailed(error.message)
        } catch {
            throw SpotError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Popular Spots

    /// Récupère les spots les plus populaires
    func getPopularSpots(limit: Int = 20) async throws -> [Spot] {
        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.spotsCollectionId,
                queries: [
                    Query.orderDesc("totalFlights"),
                    Query.limit(limit)
                ]
            )

            return response.documents.compactMap { doc in
                try? parseSpot(from: doc.data, id: doc.id)
            }
        } catch let error as AppwriteError {
            throw SpotError.fetchFailed(error.message)
        } catch {
            throw SpotError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Spots by Country/Region

    /// Récupère les spots d'un pays ou d'une région
    func getSpots(country: String? = nil, region: String? = nil, page: Int = 0, limit: Int = 20) async throws -> [Spot] {
        var queries: [String] = [
            Query.orderDesc("totalFlights"),
            Query.limit(limit),
            Query.offset(page * limit)
        ]

        if let country = country {
            queries.append(Query.equal("country", value: country))
        }

        if let region = region {
            queries.append(Query.search("region", value: region))
        }

        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.spotsCollectionId,
                queries: queries
            )

            return response.documents.compactMap { doc in
                try? parseSpot(from: doc.data, id: doc.id)
            }
        } catch let error as AppwriteError {
            throw SpotError.fetchFailed(error.message)
        } catch {
            throw SpotError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Spot Flights

    /// Récupère les vols sur un spot
    func getFlightsAtSpot(spotId: String, page: Int = 0, limit: Int = 20) async throws -> [PublicFlight] {
        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                queries: [
                    Query.equal("spotId", value: spotId),
                    Query.equal("isPrivate", value: false),
                    Query.orderDesc("startDate"),
                    Query.limit(limit),
                    Query.offset(page * limit)
                ]
            )

            return response.documents.compactMap { doc in
                try? parsePublicFlight(from: doc.data)
            }
        } catch let error as AppwriteError {
            throw SpotError.fetchFailed(error.message)
        } catch {
            throw SpotError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Spot Stats

    /// Récupère les statistiques détaillées d'un spot
    func getSpotStats(spotId: String) async throws -> SpotStats {
        // Pour l'instant, on utilise les données cachées du spot
        // Une vraie implémentation ferait des agrégations côté serveur
        let spot = try await getSpot(spotId: spotId)

        return SpotStats(
            totalFlights: spot.totalFlights,
            totalPilots: spot.subscriberCount,  // Approximation
            totalFlightHours: Double(spot.totalFlightSeconds) / 3600.0,
            avgFlightMinutes: spot.avgFlightSeconds / 60,
            longestFlightMinutes: spot.longestFlightSeconds / 60,
            maxAltitudeGain: spot.maxAltitudeGain,
            mostActiveMonth: nil,  // Calcul à implémenter
            flightsByMonth: [:]  // Calcul à implémenter
        )
    }

    // MARK: - Spot Leaderboards

    /// Récupère les classements d'un spot
    func getSpotLeaderboards(spotId: String, limit: Int = 10) async throws -> SpotLeaderboards {
        // Note: Ceci nécessiterait des agrégations côté serveur pour être efficace
        // Pour l'instant, on récupère les vols et on calcule côté client

        let flights = try await getFlightsAtSpot(spotId: spotId, page: 0, limit: 100)

        // Grouper par pilote
        var pilotStats: [String: (name: String, username: String, photo: String?, totalSeconds: Int, flightCount: Int, longestSeconds: Int, maxAlt: Double?)] = [:]

        for flight in flights {
            if var stats = pilotStats[flight.pilotId] {
                stats.totalSeconds += flight.durationSeconds
                stats.flightCount += 1
                stats.longestSeconds = max(stats.longestSeconds, flight.durationSeconds)
                if let alt = flight.maxAltitude {
                    stats.maxAlt = max(stats.maxAlt ?? 0, alt)
                }
                pilotStats[flight.pilotId] = stats
            } else {
                pilotStats[flight.pilotId] = (
                    name: flight.pilotName,
                    username: flight.pilotUsername,
                    photo: flight.pilotPhotoFileId,
                    totalSeconds: flight.durationSeconds,
                    flightCount: 1,
                    longestSeconds: flight.durationSeconds,
                    maxAlt: flight.maxAltitude
                )
            }
        }

        // Créer les classements
        let sortedByLongest = pilotStats.sorted { $0.value.longestSeconds > $1.value.longestSeconds }.prefix(limit)
        let sortedByMost = pilotStats.sorted { $0.value.flightCount > $1.value.flightCount }.prefix(limit)
        let sortedByTotal = pilotStats.sorted { $0.value.totalSeconds > $1.value.totalSeconds }.prefix(limit)
        let sortedByAlt = pilotStats.filter { $0.value.maxAlt != nil }.sorted { ($0.value.maxAlt ?? 0) > ($1.value.maxAlt ?? 0) }.prefix(limit)

        func makeEntry(_ item: (key: String, value: (name: String, username: String, photo: String?, totalSeconds: Int, flightCount: Int, longestSeconds: Int, maxAlt: Double?)), rank: Int, value: Int, formatted: String) -> SpotLeaderEntry {
            SpotLeaderEntry(
                id: "\(item.key)_\(rank)",
                rank: rank,
                pilotId: item.key,
                pilotName: item.value.name,
                pilotUsername: item.value.username,
                pilotPhotoFileId: item.value.photo,
                value: value,
                formattedValue: formatted
            )
        }

        return SpotLeaderboards(
            longestFlight: sortedByLongest.enumerated().map { i, item in
                let hours = item.value.longestSeconds / 3600
                let minutes = (item.value.longestSeconds % 3600) / 60
                let formatted = hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(minutes) min"
                return makeEntry(item, rank: i + 1, value: item.value.longestSeconds, formatted: formatted)
            },
            mostFlights: sortedByMost.enumerated().map { i, item in
                makeEntry(item, rank: i + 1, value: item.value.flightCount, formatted: "\(item.value.flightCount) vols")
            },
            totalTime: sortedByTotal.enumerated().map { i, item in
                let hours = item.value.totalSeconds / 3600
                let minutes = (item.value.totalSeconds % 3600) / 60
                let formatted = hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(minutes) min"
                return makeEntry(item, rank: i + 1, value: item.value.totalSeconds, formatted: formatted)
            },
            highestAltitude: sortedByAlt.enumerated().map { i, item in
                let alt = Int(item.value.maxAlt ?? 0)
                return makeEntry(item, rank: i + 1, value: alt, formatted: "\(alt) m")
            }
        )
    }

    // MARK: - Subscriptions

    /// S'abonner à un spot pour recevoir des notifications
    func subscribeToSpot(spotId: String, notifyOnFlight: Bool = true) async throws {
        guard let userId = AuthService.shared.currentUserId else {
            throw SpotError.notAuthenticated
        }

        // Vérifier si déjà abonné
        if try await isSubscribed(spotId: spotId) {
            throw SpotError.alreadySubscribed
        }

        do {
            _ = try await databases.createDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.spotSubscriptionsCollectionId,
                documentId: ID.unique(),
                data: [
                    "userId": userId,
                    "spotId": spotId,
                    "createdAt": Date().ISO8601Format(),
                    "notifyOnFlight": notifyOnFlight
                ]
            )

            // Invalider le cache
            subscriptionsCache = nil
        } catch let error as AppwriteError {
            throw SpotError.createFailed(error.message)
        }
    }

    /// Se désabonner d'un spot
    func unsubscribeFromSpot(spotId: String) async throws {
        guard let userId = AuthService.shared.currentUserId else {
            throw SpotError.notAuthenticated
        }

        // Trouver l'abonnement
        let response = try await databases.listDocuments(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.spotSubscriptionsCollectionId,
            queries: [
                Query.equal("userId", value: userId),
                Query.equal("spotId", value: spotId),
                Query.limit(1)
            ]
        )

        guard let subscription = response.documents.first else {
            throw SpotError.notSubscribed
        }

        try await databases.deleteDocument(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.spotSubscriptionsCollectionId,
            documentId: subscription.id
        )

        // Invalider le cache
        subscriptionsCache = nil
    }

    /// Vérifie si l'utilisateur est abonné à un spot
    func isSubscribed(spotId: String) async throws -> Bool {
        guard let userId = AuthService.shared.currentUserId else {
            return false
        }

        let response = try await databases.listDocuments(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.spotSubscriptionsCollectionId,
            queries: [
                Query.equal("userId", value: userId),
                Query.equal("spotId", value: spotId),
                Query.limit(1)
            ]
        )

        return !response.documents.isEmpty
    }

    /// Récupère les spots auxquels l'utilisateur est abonné
    func getSubscribedSpots() async throws -> [Spot] {
        guard let userId = AuthService.shared.currentUserId else {
            throw SpotError.notAuthenticated
        }

        // Récupérer les abonnements
        let response = try await databases.listDocuments(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.spotSubscriptionsCollectionId,
            queries: [
                Query.equal("userId", value: userId),
                Query.limit(100)
            ]
        )

        let spotIds = response.documents.compactMap { doc in
            doc.data["spotId"]?.value as? String
        }

        // Récupérer les spots
        var spots: [Spot] = []
        for spotId in spotIds {
            if let spot = try? await getSpot(spotId: spotId) {
                spots.append(spot)
            }
        }

        return spots
    }

    // MARK: - Private Helpers

    private func createSpot(name: String, normalizedName: String, coordinate: CLLocationCoordinate2D) async throws -> Spot {
        let userId = AuthService.shared.currentUserId

        do {
            let doc = try await databases.createDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.spotsCollectionId,
                documentId: ID.unique(),
                data: [
                    "name": name,
                    "normalizedName": normalizedName,
                    "latitude": coordinate.latitude,
                    "longitude": coordinate.longitude,
                    "geohash": calculateGeohash(coordinate: coordinate),
                    "createdByUserId": userId as Any,
                    "createdAt": Date().ISO8601Format(),
                    "totalFlights": 0,
                    "totalFlightSeconds": 0,
                    "avgFlightSeconds": 0,
                    "longestFlightSeconds": 0,
                    "subscriberCount": 0,
                    "isVerified": false,
                    "windDirections": [] as [String],
                    "photoFileIds": [] as [String]
                ]
            )

            return try parseSpot(from: doc.data, id: doc.id)
        } catch let error as AppwriteError {
            throw SpotError.createFailed(error.message)
        }
    }

    private func searchNearbySpotsByName(name: String, coordinate: CLLocationCoordinate2D, radiusKm: Double) async throws -> [Spot] {
        let latDelta = radiusKm / 111.0
        let lonDelta = radiusKm / (111.0 * cos(coordinate.latitude * .pi / 180))

        let response = try await databases.listDocuments(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.spotsCollectionId,
            queries: [
                Query.equal("normalizedName", value: name),
                Query.greaterThanEqual("latitude", value: coordinate.latitude - latDelta),
                Query.lessThanEqual(attribute: "latitude", value: coordinate.latitude + latDelta),
                Query.greaterThanEqual("longitude", value: coordinate.longitude - lonDelta),
                Query.lessThanEqual(attribute: "longitude", value: coordinate.longitude + lonDelta),
                Query.limit(1)
            ]
        )

        return response.documents.compactMap { doc in
            try? parseSpot(from: doc.data, id: doc.id)
        }
    }

    private func normalizeName(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
    }

    private func calculateGeohash(coordinate: CLLocationCoordinate2D) -> String {
        // Implémentation simplifiée du geohash
        // Précision ~1km (6 caractères)
        let base32 = "0123456789bcdefghjkmnpqrstuvwxyz"
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var isEven = true
        var bit = 0
        var ch = 0
        var hash = ""

        while hash.count < 6 {
            if isEven {
                let mid = (lonRange.0 + lonRange.1) / 2
                if coordinate.longitude > mid {
                    ch |= (1 << (4 - bit))
                    lonRange.0 = mid
                } else {
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if coordinate.latitude > mid {
                    ch |= (1 << (4 - bit))
                    latRange.0 = mid
                } else {
                    latRange.1 = mid
                }
            }
            isEven.toggle()

            if bit < 4 {
                bit += 1
            } else {
                let index = base32.index(base32.startIndex, offsetBy: ch)
                hash.append(base32[index])
                bit = 0
                ch = 0
            }
        }

        return hash
    }

    private func parseSpot(from data: [String: AnyCodable], id: String) throws -> Spot {
        guard let name = data["name"]?.value as? String,
              let normalizedName = data["normalizedName"]?.value as? String,
              let latitude = data["latitude"]?.value as? Double,
              let longitude = data["longitude"]?.value as? Double else {
            throw SpotError.fetchFailed("Invalid spot data")
        }

        let createdAtStr = data["createdAt"]?.value as? String
        let createdAt = createdAtStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()

        let lastFlightAtStr = data["lastFlightAt"]?.value as? String
        let lastFlightAt = lastFlightAtStr.flatMap { ISO8601DateFormatter().date(from: $0) }

        return Spot(
            id: id,
            name: name,
            normalizedName: normalizedName,
            latitude: latitude,
            longitude: longitude,
            altitude: data["altitude"]?.value as? Int,
            country: data["country"]?.value as? String,
            region: data["region"]?.value as? String,
            description: data["description"]?.value as? String,
            photoFileIds: data["photoFileIds"]?.value as? [String] ?? [],
            createdByUserId: data["createdByUserId"]?.value as? String,
            createdAt: createdAt,
            totalFlights: data["totalFlights"]?.value as? Int ?? 0,
            totalFlightSeconds: data["totalFlightSeconds"]?.value as? Int ?? 0,
            avgFlightSeconds: data["avgFlightSeconds"]?.value as? Int ?? 0,
            longestFlightSeconds: data["longestFlightSeconds"]?.value as? Int ?? 0,
            longestFlightUserId: data["longestFlightUserId"]?.value as? String,
            maxAltitudeGain: data["maxAltitude"]?.value as? Double,
            maxAltitudeUserId: data["maxAltitudeUserId"]?.value as? String,
            lastFlightAt: lastFlightAt,
            subscriberCount: data["subscriberCount"]?.value as? Int ?? 0,
            isVerified: data["isVerified"]?.value as? Bool ?? false,
            windDirections: data["windDirections"]?.value as? [String] ?? [],
            spotType: data["spotType"]?.value as? String
        )
    }

    private func parsePublicFlight(from data: [String: AnyCodable]) throws -> PublicFlight {
        guard let id = data["$id"]?.value as? String,
              let pilotId = data["userId"]?.value as? String,
              let startDateStr = data["startDate"]?.value as? String,
              let startDate = ISO8601DateFormatter().date(from: startDateStr),
              let durationSeconds = data["durationSeconds"]?.value as? Int else {
            throw SpotError.fetchFailed("Invalid flight data")
        }

        let createdAtStr = data["createdAt"]?.value as? String
        let createdAt = createdAtStr.flatMap { ISO8601DateFormatter().date(from: $0) } ?? startDate

        return PublicFlight(
            id: id,
            pilotId: pilotId,
            pilotName: data["pilotName"]?.value as? String ?? "Pilote",
            pilotUsername: data["pilotUsername"]?.value as? String ?? "pilot",
            pilotPhotoFileId: data["pilotPhotoFileId"]?.value as? String,
            startDate: startDate,
            durationSeconds: durationSeconds,
            spotId: data["spotId"]?.value as? String,
            spotName: data["spotName"]?.value as? String,
            latitude: data["latitude"]?.value as? Double,
            longitude: data["longitude"]?.value as? Double,
            wingBrand: data["wingBrand"]?.value as? String,
            wingModel: data["wingModel"]?.value as? String,
            wingSize: data["wingSize"]?.value as? String,
            maxAltitude: data["maxAltitude"]?.value as? Double,
            totalDistance: data["totalDistance"]?.value as? Double,
            maxSpeed: data["maxSpeed"]?.value as? Double,
            hasGpsTrack: data["hasGpsTrack"]?.value as? Bool ?? false,
            likeCount: data["likeCount"]?.value as? Int ?? 0,
            commentCount: data["commentCount"]?.value as? Int ?? 0,
            createdAt: createdAt
        )
    }
}
