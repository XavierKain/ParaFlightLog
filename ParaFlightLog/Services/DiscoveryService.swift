//
//  DiscoveryService.swift
//  ParaFlightLog
//
//  Service de découverte des vols publics et recherche
//  Gère les feeds, la recherche et le clustering pour la carte
//  Target: iOS only
//

import Foundation
import Appwrite
import CoreLocation
import NIOCore
import NIOFoundationCompat

// MARK: - Discovery Errors

enum DiscoveryError: LocalizedError {
    case notAuthenticated
    case fetchFailed(String)
    case invalidResponse
    case collectionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .fetchFailed(let message):
            return "Erreur de chargement: \(message)"
        case .invalidResponse:
            return "Réponse invalide du serveur"
        case .collectionNotFound(let name):
            return "La collection '\(name)' n'existe pas encore. Les fonctionnalités sociales seront bientôt disponibles."
        }
    }

    var isCollectionNotFound: Bool {
        if case .collectionNotFound = self { return true }
        return false
    }
}

// MARK: - Public Flight Model

/// Représente un vol public pour l'affichage dans les feeds
struct PublicFlight: Identifiable, Codable {
    let id: String
    let pilotId: String
    let pilotName: String
    let pilotUsername: String
    let pilotPhotoFileId: String?

    let startDate: Date
    let durationSeconds: Int
    let spotId: String?
    let spotName: String?
    let latitude: Double?
    let longitude: Double?

    let wingBrand: String?
    let wingModel: String?
    let wingSize: String?
    let wingPhotoFileId: String?  // ID de l'image de la voile dans Appwrite Storage

    let maxAltitude: Double?
    let totalDistance: Double?
    let maxSpeed: Double?

    let hasGpsTrack: Bool
    let likeCount: Int
    let commentCount: Int

    let createdAt: Date

    // Computed properties
    var formattedDuration: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes) min"
        }
    }

    var formattedMaxAltitude: String? {
        guard let alt = maxAltitude else { return nil }
        return "\(Int(alt)) m"
    }

    var formattedDistance: String? {
        guard let dist = totalDistance else { return nil }
        if dist >= 1000 {
            return String(format: "%.1f km", dist / 1000)
        }
        return "\(Int(dist)) m"
    }

    var wingDescription: String? {
        guard let brand = wingBrand, let model = wingModel else { return nil }
        if let size = wingSize {
            return "\(brand) \(model) \(size)"
        }
        return "\(brand) \(model)"
    }
}

// MARK: - Flight Details (with comments)

struct FlightDetails {
    let flight: PublicFlight
    let comments: [FlightComment]
    let likes: [PilotSummary]
    let gpsTrack: [GPSTrackPoint]?
}

// MARK: - Flight Comment

struct FlightComment: Identifiable, Codable {
    let id: String
    let flightId: String
    let userId: String
    let userName: String
    let userUsername: String
    let userPhotoFileId: String?
    let content: String
    let createdAt: Date
}

// MARK: - Pilot Summary (for likes list)

struct PilotSummary: Identifiable, Codable {
    let id: String
    let displayName: String
    let username: String
    let profilePhotoFileId: String?
}

// MARK: - Search Query

struct FlightSearchQuery {
    var spotName: String?
    var pilotName: String?
    var wingBrand: String?
    var dateFrom: Date?
    var dateTo: Date?
    var minDurationMinutes: Int?
    var maxDurationMinutes: Int?
    var minAltitude: Double?
    var bounds: MapBounds?

    var hasFilters: Bool {
        spotName != nil || pilotName != nil || wingBrand != nil ||
        dateFrom != nil || dateTo != nil || minDurationMinutes != nil ||
        maxDurationMinutes != nil || minAltitude != nil || bounds != nil
    }
}

// MARK: - Map Bounds

struct MapBounds {
    let northEast: CLLocationCoordinate2D
    let southWest: CLLocationCoordinate2D

    var centerLatitude: Double {
        (northEast.latitude + southWest.latitude) / 2
    }

    var centerLongitude: Double {
        (northEast.longitude + southWest.longitude) / 2
    }
}

// MARK: - Flight Cluster (for map)

struct FlightCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let flightCount: Int
    let flights: [PublicFlight]  // Limité aux premiers

    var isCluster: Bool { flightCount > 1 }
}

// MARK: - DiscoveryService

@Observable
final class DiscoveryService {
    static let shared = DiscoveryService()

    private let databases: Databases
    private let storage: Storage

    // Cache
    private var feedCache: [String: [PublicFlight]] = [:]
    private var lastFeedFetch: [String: Date] = [:]
    private let cacheValiditySeconds: TimeInterval = 60  // 1 minute

    private init() {
        self.databases = AppwriteService.shared.databases
        self.storage = AppwriteService.shared.storage
    }

    // MARK: - Global Feed

    /// Récupère le feed global (tous les vols publics, du plus récent au plus ancien)
    func getGlobalFeed(page: Int = 0, limit: Int = 20) async throws -> [PublicFlight] {
        let offset = page * limit

        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                queries: [
                    Query.equal("isPrivate", value: false),
                    Query.orderDesc("startDate"),
                    Query.limit(limit),
                    Query.offset(offset)
                ]
            )

            logInfo("Global feed: fetched \(response.documents.count) documents", category: .sync)

            var flights: [PublicFlight] = []
            for doc in response.documents {
                do {
                    let flight = try parsePublicFlight(from: doc.data)
                    flights.append(flight)
                } catch {
                    logWarning("Failed to parse flight document: \(error.localizedDescription)", category: .sync)
                    // Continue with next document instead of failing completely
                }
            }

            logInfo("Global feed: parsed \(flights.count) flights successfully", category: .sync)
            return flights
        } catch let error as AppwriteError {
            // Vérifier si c'est une erreur de collection manquante
            let message = error.message
            logError("Appwrite error: \(message)", category: .sync)
            if message.contains("could not be found") || message.contains("Collection") {
                throw DiscoveryError.collectionNotFound("flights")
            }
            throw DiscoveryError.fetchFailed(message)
        } catch let error as DiscoveryError {
            throw error
        } catch {
            logError("Global feed error: \(error.localizedDescription)", category: .sync)
            throw DiscoveryError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Friends Feed

    /// Récupère le feed des vols des pilotes suivis
    func getFriendsFeed(page: Int = 0, limit: Int = 20) async throws -> [PublicFlight] {
        guard let userId = AuthService.shared.currentUserId else {
            throw DiscoveryError.notAuthenticated
        }

        // 1. Récupérer la liste des pilotes suivis
        let followedIds = try await getFollowedUserIds(userId: userId)

        if followedIds.isEmpty {
            return []
        }

        // 2. Récupérer les vols de ces pilotes
        let offset = page * limit

        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                queries: [
                    Query.equal("isPrivate", value: false),
                    Query.equal("userId", value: followedIds),
                    Query.orderDesc("startDate"),
                    Query.limit(limit),
                    Query.offset(offset)
                ]
            )

            return try response.documents.compactMap { doc -> PublicFlight? in
                try parsePublicFlight(from: doc.data)
            }
        } catch let error as AppwriteError {
            throw DiscoveryError.fetchFailed(error.message)
        } catch {
            throw DiscoveryError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Flights by Area

    /// Récupère les vols dans une zone géographique
    func getFlightsInArea(bounds: MapBounds, page: Int = 0, limit: Int = 50) async throws -> [PublicFlight] {
        let offset = page * limit

        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                queries: [
                    Query.equal("isPrivate", value: false),
                    Query.greaterThanEqual("latitude", value: bounds.southWest.latitude),
                    Query.lessThanEqual(attribute: "latitude", value: bounds.northEast.latitude),
                    Query.greaterThanEqual("longitude", value: bounds.southWest.longitude),
                    Query.lessThanEqual(attribute: "longitude", value: bounds.northEast.longitude),
                    Query.orderDesc("startDate"),
                    Query.limit(limit),
                    Query.offset(offset)
                ]
            )

            return try response.documents.compactMap { doc -> PublicFlight? in
                try parsePublicFlight(from: doc.data)
            }
        } catch let error as AppwriteError {
            throw DiscoveryError.fetchFailed(error.message)
        } catch {
            throw DiscoveryError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Nearby Flights

    /// Récupère les vols à proximité d'une coordonnée
    func getFlightsNearby(coordinate: CLLocationCoordinate2D, radiusKm: Double = 50, page: Int = 0, limit: Int = 20) async throws -> [PublicFlight] {
        // Calculer les bounds approximatives
        let latDelta = radiusKm / 111.0  // ~111 km par degré de latitude
        let lonDelta = radiusKm / (111.0 * cos(coordinate.latitude * .pi / 180))

        let bounds = MapBounds(
            northEast: CLLocationCoordinate2D(
                latitude: coordinate.latitude + latDelta,
                longitude: coordinate.longitude + lonDelta
            ),
            southWest: CLLocationCoordinate2D(
                latitude: coordinate.latitude - latDelta,
                longitude: coordinate.longitude - lonDelta
            )
        )

        return try await getFlightsInArea(bounds: bounds, page: page, limit: limit)
    }

    // MARK: - Search

    /// Recherche de vols avec filtres
    func searchFlights(query: FlightSearchQuery, page: Int = 0, limit: Int = 20) async throws -> [PublicFlight] {
        var queries: [String] = [
            Query.equal("isPrivate", value: false),
            Query.orderDesc("startDate"),
            Query.limit(limit),
            Query.offset(page * limit)
        ]

        if let spotName = query.spotName, !spotName.isEmpty {
            queries.append(Query.search("spotName", value: spotName))
        }

        if let wingBrand = query.wingBrand, !wingBrand.isEmpty {
            queries.append(Query.search("wingBrand", value: wingBrand))
        }

        if let dateFrom = query.dateFrom {
            queries.append(Query.greaterThanEqual("startDate", value: dateFrom.ISO8601Format()))
        }

        if let dateTo = query.dateTo {
            queries.append(Query.lessThanEqual(attribute: "startDate", value: dateTo.ISO8601Format()))
        }

        if let minDuration = query.minDurationMinutes {
            queries.append(Query.greaterThanEqual("durationSeconds", value: minDuration * 60))
        }

        if let maxDuration = query.maxDurationMinutes {
            queries.append(Query.lessThanEqual(attribute: "durationSeconds", value: maxDuration * 60))
        }

        if let minAlt = query.minAltitude {
            queries.append(Query.greaterThanEqual("maxAltitude", value: minAlt))
        }

        if let bounds = query.bounds {
            queries.append(Query.greaterThanEqual("latitude", value: bounds.southWest.latitude))
            queries.append(Query.lessThanEqual(attribute: "latitude", value: bounds.northEast.latitude))
            queries.append(Query.greaterThanEqual("longitude", value: bounds.southWest.longitude))
            queries.append(Query.lessThanEqual(attribute: "longitude", value: bounds.northEast.longitude))
        }

        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                queries: queries
            )

            return try response.documents.compactMap { doc -> PublicFlight? in
                try parsePublicFlight(from: doc.data)
            }
        } catch let error as AppwriteError {
            throw DiscoveryError.fetchFailed(error.message)
        } catch {
            throw DiscoveryError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Flight Details

    /// Récupère les détails complets d'un vol (avec commentaires et likes)
    func getFlightDetails(flightId: String) async throws -> FlightDetails {
        // 1. Récupérer le vol
        let flightDoc = try await databases.getDocument(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.flightsCollectionId,
            documentId: flightId
        )

        guard let flight = try? parsePublicFlight(from: flightDoc.data) else {
            throw DiscoveryError.invalidResponse
        }

        // 2. Récupérer les commentaires
        let commentsResponse = try await databases.listDocuments(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.flightCommentsCollectionId,
            queries: [
                Query.equal("flightId", value: flightId),
                Query.orderDesc("createdAt"),
                Query.limit(50)
            ]
        )

        let comments = commentsResponse.documents.compactMap { doc -> FlightComment? in
            try? parseFlightComment(from: doc.data)
        }

        // 3. Récupérer les likes (juste les premiers)
        let likesResponse = try await databases.listDocuments(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.flightLikesCollectionId,
            queries: [
                Query.equal("flightId", value: flightId),
                Query.limit(20)
            ]
        )

        let likes = likesResponse.documents.compactMap { doc -> PilotSummary? in
            // Récupérer les infos du pilote depuis le like
            guard let userId = doc.data["userId"]?.value as? String else { return nil }
            // Pour l'instant, on retourne juste l'ID - les vraies infos seront fetchées à la demande
            return PilotSummary(
                id: userId,
                displayName: doc.data["userName"]?.value as? String ?? "Pilote",
                username: doc.data["userUsername"]?.value as? String ?? "pilot",
                profilePhotoFileId: doc.data["userPhotoFileId"]?.value as? String
            )
        }

        // 4. Récupérer la trace GPS si disponible
        var gpsTrack: [GPSTrackPoint]? = nil
        if flight.hasGpsTrack, let gpsFileId = flightDoc.data["gpsTrackFileId"]?.value as? String {
            gpsTrack = try? await downloadGPSTrack(fileId: gpsFileId)
        }

        return FlightDetails(
            flight: flight,
            comments: comments,
            likes: likes,
            gpsTrack: gpsTrack
        )
    }

    // MARK: - Pilot Search

    /// Recherche de pilotes par nom ou username
    func searchPilots(query: String, page: Int = 0, limit: Int = 20) async throws -> [PilotSummary] {
        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.pilotsCollectionId,
                queries: [
                    Query.or([
                        Query.search("displayName", value: query),
                        Query.search("username", value: query)
                    ]),
                    Query.limit(limit),
                    Query.offset(page * limit)
                ]
            )

            return response.documents.compactMap { doc -> PilotSummary? in
                guard let id = doc.data["userId"]?.value as? String,
                      let displayName = doc.data["displayName"]?.value as? String,
                      let username = doc.data["username"]?.value as? String else {
                    return nil
                }

                return PilotSummary(
                    id: id,
                    displayName: displayName,
                    username: username,
                    profilePhotoFileId: doc.data["profilePhotoUrl"]?.value as? String
                )
            }
        } catch let error as AppwriteError {
            throw DiscoveryError.fetchFailed(error.message)
        } catch {
            throw DiscoveryError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Pilot Flights

    /// Récupère les vols publics d'un pilote
    func getPilotFlights(userId: String, page: Int = 0, limit: Int = 20) async throws -> [PublicFlight] {
        let offset = page * limit

        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.equal("isPrivate", value: false),
                    Query.orderDesc("startDate"),
                    Query.limit(limit),
                    Query.offset(offset)
                ]
            )

            return try response.documents.compactMap { doc -> PublicFlight? in
                try parsePublicFlight(from: doc.data)
            }
        } catch let error as AppwriteError {
            throw DiscoveryError.fetchFailed(error.message)
        } catch {
            throw DiscoveryError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Clustering for Map

    /// Crée des clusters de vols pour la carte selon le niveau de zoom
    func clusterFlights(_ flights: [PublicFlight], zoomLevel: Int) -> [FlightCluster] {
        guard !flights.isEmpty else { return [] }

        // Déterminer la taille de la grille en fonction du zoom
        let gridSize: Double
        switch zoomLevel {
        case 0...5:
            gridSize = 5.0  // Très dézoomé - grands clusters
        case 6...10:
            gridSize = 1.0  // Moyen
        case 11...14:
            gridSize = 0.1  // Plus zoomé
        default:
            gridSize = 0.01  // Très zoomé - presque pas de clustering
        }

        // Grouper les vols par cellule de grille
        var grid: [String: [PublicFlight]] = [:]

        for flight in flights {
            guard let lat = flight.latitude, let lon = flight.longitude else { continue }

            let cellX = Int(floor(lon / gridSize))
            let cellY = Int(floor(lat / gridSize))
            let key = "\(cellX)_\(cellY)"

            if grid[key] == nil {
                grid[key] = []
            }
            grid[key]?.append(flight)
        }

        // Créer les clusters
        return grid.map { (key, flightsInCell) in
            // Calculer le centre du cluster
            let avgLat = flightsInCell.compactMap { $0.latitude }.reduce(0, +) / Double(flightsInCell.count)
            let avgLon = flightsInCell.compactMap { $0.longitude }.reduce(0, +) / Double(flightsInCell.count)

            return FlightCluster(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                flightCount: flightsInCell.count,
                flights: Array(flightsInCell.prefix(5))  // Garder max 5 pour l'aperçu
            )
        }
    }

    // MARK: - Private Helpers

    private func getFollowedUserIds(userId: String) async throws -> [String] {
        do {
            let response = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.followsCollectionId,
                queries: [
                    Query.equal("followerId", value: userId),
                    Query.limit(500)  // Max 500 follows pour cette requête
                ]
            )

            return response.documents.compactMap { doc in
                doc.data["followedId"]?.value as? String
            }
        } catch let error as AppwriteError {
            let message = error.message
            if message.contains("could not be found") || message.contains("Collection") {
                throw DiscoveryError.collectionNotFound("follows")
            }
            throw error
        }
    }

    private func parsePublicFlight(from data: [String: AnyCodable]) throws -> PublicFlight {
        guard let id = data["$id"]?.value as? String,
              let pilotId = data["userId"]?.value as? String else {
            logError("Missing required fields: $id or userId", category: .sync)
            throw DiscoveryError.invalidResponse
        }

        // Parse startDate with multiple formats
        let startDate: Date
        if let startDateStr = data["startDate"]?.value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: startDateStr) {
                startDate = date
            } else {
                // Try without fractional seconds
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: startDateStr) {
                    startDate = date
                } else {
                    logError("Failed to parse startDate: \(startDateStr)", category: .sync)
                    throw DiscoveryError.invalidResponse
                }
            }
        } else {
            logError("Missing startDate field", category: .sync)
            throw DiscoveryError.invalidResponse
        }

        // Parse durationSeconds flexibly (Int or Double)
        let durationSeconds: Int
        if let intValue = data["durationSeconds"]?.value as? Int {
            durationSeconds = intValue
        } else if let doubleValue = data["durationSeconds"]?.value as? Double {
            durationSeconds = Int(doubleValue)
        } else {
            logError("Missing or invalid durationSeconds", category: .sync)
            throw DiscoveryError.invalidResponse
        }

        // Parse createdAt
        let createdAt: Date
        if let createdAtStr = data["createdAt"]?.value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdAt = formatter.date(from: createdAtStr) ?? startDate
        } else {
            createdAt = startDate
        }

        // Parse optional numeric fields flexibly
        func parseDouble(_ key: String) -> Double? {
            if let doubleValue = data[key]?.value as? Double {
                return doubleValue
            } else if let intValue = data[key]?.value as? Int {
                return Double(intValue)
            }
            return nil
        }

        func parseInt(_ key: String, defaultValue: Int = 0) -> Int {
            if let intValue = data[key]?.value as? Int {
                return intValue
            } else if let doubleValue = data[key]?.value as? Double {
                return Int(doubleValue)
            }
            return defaultValue
        }

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
            latitude: parseDouble("latitude"),
            longitude: parseDouble("longitude"),
            wingBrand: data["wingBrand"]?.value as? String,
            wingModel: data["wingModel"]?.value as? String,
            wingSize: data["wingSize"]?.value as? String,
            wingPhotoFileId: data["wingPhotoFileId"]?.value as? String,
            maxAltitude: parseDouble("maxAltitude"),
            totalDistance: parseDouble("totalDistance"),
            maxSpeed: parseDouble("maxSpeed"),
            hasGpsTrack: data["hasGpsTrack"]?.value as? Bool ?? false,
            likeCount: parseInt("likeCount"),
            commentCount: parseInt("commentCount"),
            createdAt: createdAt
        )
    }

    private func parseFlightComment(from data: [String: AnyCodable]) throws -> FlightComment {
        guard let id = data["$id"]?.value as? String,
              let flightId = data["flightId"]?.value as? String,
              let userId = data["userId"]?.value as? String,
              let content = data["content"]?.value as? String,
              let createdAtStr = data["createdAt"]?.value as? String,
              let createdAt = ISO8601DateFormatter().date(from: createdAtStr) else {
            throw DiscoveryError.invalidResponse
        }

        return FlightComment(
            id: id,
            flightId: flightId,
            userId: userId,
            userName: data["userName"]?.value as? String ?? "Pilote",
            userUsername: data["userUsername"]?.value as? String ?? "pilot",
            userPhotoFileId: data["userPhotoFileId"]?.value as? String,
            content: content,
            createdAt: createdAt
        )
    }

    private func downloadGPSTrack(fileId: String) async throws -> [GPSTrackPoint] {
        let data = try await storage.getFileDownload(
            bucketId: AppwriteConfig.gpsTracksBucketId,
            fileId: fileId
        )

        // Convertir ByteBuffer en Data
        var buffer = data
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            throw DiscoveryError.invalidResponse
        }

        let jsonData = Data(bytes)
        return try JSONDecoder().decode([GPSTrackPoint].self, from: jsonData)
    }
}
