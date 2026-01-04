//
//  LiveFlightService.swift
//  ParaFlightLog
//
//  Service de gestion des vols en direct
//  Permet d'afficher les pilotes actuellement en vol sur une carte
//  Target: iOS only
//

import Foundation
import Appwrite
import CoreLocation

// MARK: - Live Flight Model

/// Représente un vol en cours
struct LiveFlight: Identifiable, Equatable, Hashable {
    let id: String
    let oderId: String
    let pilotName: String
    let pilotUsername: String
    let pilotPhotoFileId: String?
    let startedAt: Date
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var spotName: String?
    var wingName: String?
    var isActive: Bool

    /// Durée du vol depuis le début
    var duration: TimeInterval {
        Date().timeIntervalSince(startedAt)
    }

    /// Durée formatée
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let hours = minutes / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes % 60))"
        } else {
            return "\(minutes)min"
        }
    }

    /// Coordonnées si disponibles
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Initialisation depuis un dictionnaire Appwrite
    init(from data: [String: Any]) throws {
        guard let id = data["$id"] as? String else {
            throw LiveFlightError.invalidData("Missing $id")
        }

        self.id = id
        self.oderId = data["userId"] as? String ?? ""
        self.pilotName = data["pilotName"] as? String ?? "Pilote"
        self.pilotUsername = data["pilotUsername"] as? String ?? "pilot"
        self.pilotPhotoFileId = data["pilotPhotoFileId"] as? String
        self.latitude = data["latitude"] as? Double
        self.longitude = data["longitude"] as? Double
        self.altitude = data["altitude"] as? Double
        self.spotName = data["spotName"] as? String
        self.wingName = data["wingName"] as? String
        self.isActive = data["isActive"] as? Bool ?? true

        if let startedAtStr = data["startedAt"] as? String,
           let startedAt = ISO8601DateFormatter().date(from: startedAtStr) {
            self.startedAt = startedAt
        } else {
            self.startedAt = Date()
        }
    }

    /// Initialisation directe
    init(
        id: String,
        userId: String,
        pilotName: String,
        pilotUsername: String,
        pilotPhotoFileId: String? = nil,
        startedAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        spotName: String? = nil,
        wingName: String? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.oderId = userId
        self.pilotName = pilotName
        self.pilotUsername = pilotUsername
        self.pilotPhotoFileId = pilotPhotoFileId
        self.startedAt = startedAt
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.spotName = spotName
        self.wingName = wingName
        self.isActive = isActive
    }
}

// MARK: - Live Flight Errors

enum LiveFlightError: LocalizedError {
    case notAuthenticated
    case noProfile
    case invalidData(String)
    case alreadyFlying
    case notFlying
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .noProfile:
            return "Profil utilisateur non trouvé"
        case .invalidData(let msg):
            return "Données invalides: \(msg)"
        case .alreadyFlying:
            return "Vous êtes déjà en vol"
        case .notFlying:
            return "Vous n'êtes pas en vol"
        case .networkError(let msg):
            return "Erreur réseau: \(msg)"
        }
    }
}

// MARK: - LiveFlightService

@Observable
final class LiveFlightService {
    static let shared = LiveFlightService()

    // MARK: - Properties

    private let databases: Databases

    /// Vol en cours de l'utilisateur actuel
    private(set) var currentLiveFlight: LiveFlight?

    /// Liste des vols en direct visibles
    private(set) var liveFlights: [LiveFlight] = []

    /// Indique si on est en train de charger
    private(set) var isLoading = false

    /// ID du document live flight actuel
    private var currentLiveFlightDocId: String?

    /// Timer pour mise à jour de position
    private var updateTimer: Timer?

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases
    }

    // MARK: - Public Methods

    /// Démarre un vol en direct
    func startLiveFlight(
        location: CLLocationCoordinate2D?,
        altitude: Double? = nil,
        spotName: String? = nil,
        wingName: String? = nil
    ) async throws {
        guard AuthService.shared.isAuthenticated else {
            throw LiveFlightError.notAuthenticated
        }

        guard let profile = UserService.shared.currentUserProfile else {
            throw LiveFlightError.noProfile
        }

        // Vérifier si déjà en vol
        if currentLiveFlight != nil {
            throw LiveFlightError.alreadyFlying
        }

        isLoading = true
        defer { isLoading = false }

        var flightData: [String: Any] = [
            "userId": profile.id,
            "pilotName": profile.displayName,
            "pilotUsername": profile.username,
            "startedAt": Date().ISO8601Format(),
            "isActive": true
        ]

        if let photoId = profile.profilePhotoFileId {
            flightData["pilotPhotoFileId"] = photoId
        }

        if let location = location {
            flightData["latitude"] = location.latitude
            flightData["longitude"] = location.longitude
        }

        if let altitude = altitude {
            flightData["altitude"] = altitude
        }

        if let spotName = spotName {
            flightData["spotName"] = spotName
        }

        if let wingName = wingName {
            flightData["wingName"] = wingName
        }

        do {
            let document = try await databases.createDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.liveFlightsCollectionId,
                documentId: ID.unique(),
                data: flightData
            )

            let liveFlight = try parseLiveFlight(from: document.data)
            await MainActor.run {
                self.currentLiveFlight = liveFlight
                self.currentLiveFlightDocId = document.id
            }

            logInfo("Live flight started: \(document.id)", category: .sync)

        } catch let error as AppwriteError {
            logError("Failed to start live flight: \(error.message)", category: .sync)
            throw LiveFlightError.networkError(error.message)
        }
    }

    /// Met à jour la position du vol en cours
    func updateLocation(
        location: CLLocationCoordinate2D,
        altitude: Double? = nil
    ) async throws {
        guard let docId = currentLiveFlightDocId else {
            throw LiveFlightError.notFlying
        }

        var updateData: [String: Any] = [
            "latitude": location.latitude,
            "longitude": location.longitude
        ]

        if let altitude = altitude {
            updateData["altitude"] = altitude
        }

        do {
            let document = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.liveFlightsCollectionId,
                documentId: docId,
                data: updateData
            )

            let updatedFlight = try parseLiveFlight(from: document.data)
            await MainActor.run {
                self.currentLiveFlight = updatedFlight
            }

        } catch let error as AppwriteError {
            logWarning("Failed to update live flight location: \(error.message)", category: .sync)
            // Ne pas throw - on continue le vol même si la mise à jour échoue
        }
    }

    /// Termine le vol en direct
    func endLiveFlight() async throws {
        guard let docId = currentLiveFlightDocId else {
            throw LiveFlightError.notFlying
        }

        isLoading = true
        defer { isLoading = false }

        do {
            // Supprimer le document (le vol n'est plus "live")
            _ = try await databases.deleteDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.liveFlightsCollectionId,
                documentId: docId
            )

            await MainActor.run {
                self.currentLiveFlight = nil
                self.currentLiveFlightDocId = nil
            }

            logInfo("Live flight ended: \(docId)", category: .sync)

        } catch let error as AppwriteError {
            logError("Failed to end live flight: \(error.message)", category: .sync)
            throw LiveFlightError.networkError(error.message)
        }
    }

    /// Récupère tous les vols en direct actifs
    func fetchLiveFlights() async throws -> [LiveFlight] {
        isLoading = true
        defer { isLoading = false }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.liveFlightsCollectionId,
                queries: [
                    Query.equal("isActive", value: true),
                    Query.orderDesc("startedAt"),
                    Query.limit(100)
                ]
            )

            var flights: [LiveFlight] = []
            for doc in documents.documents {
                var nativeData: [String: Any] = [:]
                for (key, value) in doc.data {
                    if let anyCodable = value as? AnyCodable {
                        nativeData[key] = anyCodable.value
                    } else {
                        nativeData[key] = value
                    }
                }

                if let flight = try? LiveFlight(from: nativeData) {
                    flights.append(flight)
                }
            }

            await MainActor.run {
                self.liveFlights = flights
            }

            logInfo("Fetched \(flights.count) live flights", category: .sync)
            return flights

        } catch let error as AppwriteError {
            logError("Failed to fetch live flights: \(error.message)", category: .sync)
            throw LiveFlightError.networkError(error.message)
        }
    }

    /// Vérifie si l'utilisateur a un vol en cours (restauration au démarrage)
    func checkExistingLiveFlight() async {
        guard AuthService.shared.isAuthenticated,
              let profile = UserService.shared.currentUserProfile else {
            return
        }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.liveFlightsCollectionId,
                queries: [
                    Query.equal("userId", value: profile.id),
                    Query.equal("isActive", value: true),
                    Query.limit(1)
                ]
            )

            if let doc = documents.documents.first {
                var nativeData: [String: Any] = [:]
                for (key, value) in doc.data {
                    if let anyCodable = value as? AnyCodable {
                        nativeData[key] = anyCodable.value
                    } else {
                        nativeData[key] = value
                    }
                }

                if let flight = try? LiveFlight(from: nativeData) {
                    await MainActor.run {
                        self.currentLiveFlight = flight
                        self.currentLiveFlightDocId = doc.id
                    }
                    logInfo("Restored existing live flight: \(doc.id)", category: .sync)
                }
            }
        } catch {
            logWarning("Failed to check existing live flight: \(error.localizedDescription)", category: .sync)
        }
    }

    /// Nettoie les données locales (déconnexion)
    func clearLocalData() {
        currentLiveFlight = nil
        currentLiveFlightDocId = nil
        liveFlights = []
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Private Helpers

    private func parseLiveFlight(from data: [String: AnyCodable]) throws -> LiveFlight {
        var nativeData: [String: Any] = [:]
        for (key, value) in data {
            nativeData[key] = value.value
        }
        return try LiveFlight(from: nativeData)
    }
}
