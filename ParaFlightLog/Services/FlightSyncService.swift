//
//  FlightSyncService.swift
//  ParaFlightLog
//
//  Service de synchronisation des vols avec le cloud Appwrite
//  Upload, download et gestion des conflits
//  Target: iOS only
//

import Foundation
import Appwrite
import SwiftData
import NIOCore
import NIOFoundationCompat

// MARK: - Sync Errors

enum FlightSyncError: LocalizedError {
    case notAuthenticated
    case noProfile
    case uploadFailed(String)
    case downloadFailed(String)
    case gpsTrackUploadFailed
    case gpsTrackDownloadFailed
    case conflictDetected
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté pour synchroniser"
        case .noProfile:
            return "Profil utilisateur non trouvé"
        case .uploadFailed(let message):
            return "Échec de l'upload: \(message)"
        case .downloadFailed(let message):
            return "Échec du téléchargement: \(message)"
        case .gpsTrackUploadFailed:
            return "Échec de l'upload de la trace GPS"
        case .gpsTrackDownloadFailed:
            return "Échec du téléchargement de la trace GPS"
        case .conflictDetected:
            return "Conflit de synchronisation détecté"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Sync Result

struct SyncResult {
    let uploaded: Int
    let downloaded: Int
    let conflicts: Int
    let errors: [String]

    var isSuccess: Bool {
        errors.isEmpty
    }

    static let empty = SyncResult(uploaded: 0, downloaded: 0, conflicts: 0, errors: [])
}

// MARK: - Conflict Resolution

enum ConflictResolution {
    case keepLocal
    case keepRemote
    case merge
}

// MARK: - Cloud Flight Model

struct CloudFlight: Codable, Identifiable {
    let id: String
    let userId: String
    let localFlightId: String
    let isPrivate: Bool
    let startDate: Date
    let endDate: Date
    let durationSeconds: Int
    let spotId: String?
    let spotName: String?
    let latitude: Double?
    let longitude: Double?
    let geohash: String?
    let wingBrand: String?
    let wingModel: String?
    let wingSize: String?
    let wingType: String?
    let startAltitude: Double?
    let maxAltitude: Double?
    let endAltitude: Double?
    let totalDistance: Double?
    let maxSpeed: Double?
    let maxGForce: Double?
    let flightType: String?
    let notes: String?
    let hasGpsTrack: Bool
    let gpsTrackFileId: String?
    let trackPointCount: Int?
    let likeCount: Int
    let commentCount: Int
    let createdAt: Date
    let syncedAt: Date
    let deviceSource: String

    enum CodingKeys: String, CodingKey {
        case id = "$id"
        case userId, localFlightId, isPrivate
        case startDate, endDate, durationSeconds
        case spotId, spotName, latitude, longitude, geohash
        case wingBrand, wingModel, wingSize, wingType
        case startAltitude, maxAltitude, endAltitude
        case totalDistance, maxSpeed, maxGForce
        case flightType, notes
        case hasGpsTrack, gpsTrackFileId, trackPointCount
        case likeCount, commentCount
        case createdAt, syncedAt, deviceSource
    }
}

// MARK: - FlightSyncService

@Observable
final class FlightSyncService {
    static let shared = FlightSyncService()

    // MARK: - Properties

    private let databases: Databases
    private let storage: Storage

    private(set) var isSyncing: Bool = false
    private(set) var lastSyncDate: Date?
    private(set) var pendingUploads: Int = 0
    private(set) var lastError: String?

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases
        self.storage = AppwriteService.shared.storage
        loadLastSyncDate()
    }

    // MARK: - Full Sync

    /// Effectue une synchronisation complète (upload puis download)
    @MainActor
    func performFullSync(modelContext: ModelContext) async throws -> SyncResult {
        guard AuthService.shared.isAuthenticated else {
            throw FlightSyncError.notAuthenticated
        }

        guard UserService.shared.currentUserProfile != nil else {
            throw FlightSyncError.noProfile
        }

        isSyncing = true
        defer {
            isSyncing = false
            saveLastSyncDate()
        }

        var uploaded = 0
        var downloaded = 0
        let conflicts = 0
        var errors: [String] = []

        // 1. Upload des vols locaux en attente
        do {
            uploaded = try await uploadPendingFlights(modelContext: modelContext)
        } catch {
            errors.append("Upload: \(error.localizedDescription)")
        }

        // 2. Download des vols depuis le cloud
        do {
            downloaded = try await downloadNewFlights(modelContext: modelContext)
        } catch {
            errors.append("Download: \(error.localizedDescription)")
        }

        lastSyncDate = Date()
        lastError = errors.isEmpty ? nil : errors.joined(separator: "; ")

        // 3. Vérifier et attribuer les badges après sync réussie
        if uploaded > 0 || downloaded > 0 {
            await checkAndAwardBadgesAfterSync(modelContext: modelContext)
        }

        return SyncResult(
            uploaded: uploaded,
            downloaded: downloaded,
            conflicts: conflicts,
            errors: errors
        )
    }

    // MARK: - Upload

    /// Upload un vol vers le cloud
    func uploadFlight(_ flight: Flight) async throws -> CloudFlight {
        guard AuthService.shared.isAuthenticated else {
            throw FlightSyncError.notAuthenticated
        }

        guard let profile = UserService.shared.currentUserProfile else {
            throw FlightSyncError.noProfile
        }

        let now = Date()

        // Préparer les données du vol
        var flightData: [String: Any] = [
            "userId": profile.id,
            "localFlightId": flight.id.uuidString,
            "isPrivate": flight.isPrivate,
            "startDate": flight.startDate.ISO8601Format(),
            "endDate": flight.endDate.ISO8601Format(),
            "durationSeconds": flight.durationSeconds,
            "hasGpsTrack": flight.gpsTrackData != nil,
            "trackPointCount": flight.gpsTrack?.count ?? 0,
            "likeCount": 0,
            "commentCount": 0,
            "createdAt": flight.createdAt.ISO8601Format(),
            "syncedAt": now.ISO8601Format(),
            "deviceSource": "iphone",
            // Pilot info for discovery feed
            "pilotName": profile.displayName,
            "pilotUsername": profile.username
        ]

        // Champs optionnels
        if let spotName = flight.spotName {
            flightData["spotName"] = spotName
        }
        if let lat = flight.latitude {
            flightData["latitude"] = lat
        }
        if let lon = flight.longitude {
            flightData["longitude"] = lon
            // Calculer le geohash pour les queries de proximité
            if let lat = flight.latitude {
                flightData["geohash"] = calculateGeohash(lat: lat, lon: lon)
            }
        }
        if let wing = flight.wing {
            flightData["wingBrand"] = wing.brand
            flightData["wingModel"] = wing.name
            flightData["wingSize"] = wing.size
            flightData["wingType"] = wing.type
        }
        if let startAlt = flight.startAltitude {
            flightData["startAltitude"] = startAlt
        }
        if let maxAlt = flight.maxAltitude {
            flightData["maxAltitude"] = maxAlt
        }
        if let endAlt = flight.endAltitude {
            flightData["endAltitude"] = endAlt
        }
        if let distance = flight.totalDistance {
            flightData["totalDistance"] = distance
        }
        if let speed = flight.maxSpeed {
            flightData["maxSpeed"] = speed
        }
        if let gforce = flight.maxGForce {
            flightData["maxGForce"] = gforce
        }
        if let type = flight.flightType {
            flightData["flightType"] = type
        }
        if let notes = flight.notes {
            flightData["notes"] = notes
        }

        do {
            let document: Document<[String: AnyCodable]>

            // Créer ou mettre à jour selon si le vol existe déjà dans le cloud
            if let cloudId = flight.cloudId {
                // Mise à jour
                document = try await databases.updateDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: AppwriteConfig.flightsCollectionId,
                    documentId: cloudId,
                    data: flightData
                )
            } else {
                // Création
                document = try await databases.createDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: AppwriteConfig.flightsCollectionId,
                    documentId: ID.unique(),
                    data: flightData
                )
            }

            let cloudFlight = try parseCloudFlight(from: document.data)

            // Upload la trace GPS si présente
            if let gpsData = flight.gpsTrackData {
                do {
                    let fileId = try await uploadGPSTrack(flightId: cloudFlight.id, trackData: gpsData)
                    // Mettre à jour le document avec le fileId
                    _ = try await databases.updateDocument(
                        databaseId: AppwriteConfig.databaseId,
                        collectionId: AppwriteConfig.flightsCollectionId,
                        documentId: cloudFlight.id,
                        data: ["gpsTrackFileId": fileId, "hasGpsTrack": true]
                    )
                } catch {
                    logWarning("GPS track upload failed: \(error.localizedDescription)", category: .sync)
                }
            }

            logInfo("Flight uploaded: \(cloudFlight.id)", category: .sync)
            return cloudFlight

        } catch let error as AppwriteError {
            throw FlightSyncError.uploadFailed(error.message)
        } catch {
            throw FlightSyncError.uploadFailed(error.localizedDescription)
        }
    }

    /// Upload la trace GPS d'un vol
    func uploadGPSTrack(flightId: String, trackData: Data) async throws -> String {
        do {
            let file = try await storage.createFile(
                bucketId: AppwriteConfig.gpsTracksBucketId,
                fileId: ID.unique(),
                file: InputFile.fromData(trackData, filename: "\(flightId).json", mimeType: "application/json")
            )
            logInfo("GPS track uploaded: \(file.id)", category: .sync)
            return file.id
        } catch {
            throw FlightSyncError.gpsTrackUploadFailed
        }
    }

    /// Download la trace GPS d'un vol
    func downloadGPSTrack(fileId: String) async throws -> Data {
        do {
            let byteBuffer = try await storage.getFileDownload(
                bucketId: AppwriteConfig.gpsTracksBucketId,
                fileId: fileId
            )
            guard let data = byteBuffer.getData(at: 0, length: byteBuffer.readableBytes) else {
                throw FlightSyncError.gpsTrackDownloadFailed
            }
            return data
        } catch {
            throw FlightSyncError.gpsTrackDownloadFailed
        }
    }

    // MARK: - Download

    /// Télécharge les vols depuis le cloud depuis une date donnée
    func downloadFlights(since: Date?) async throws -> [CloudFlight] {
        guard AuthService.shared.isAuthenticated else {
            throw FlightSyncError.notAuthenticated
        }

        guard let profile = UserService.shared.currentUserProfile else {
            throw FlightSyncError.noProfile
        }

        var queries = [
            Query.equal("userId", value: profile.id),
            Query.orderDesc("startDate"),
            Query.limit(100)
        ]

        if let sinceDate = since {
            queries.append(Query.greaterThan("syncedAt", value: sinceDate.ISO8601Format()))
        }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                queries: queries
            )

            var flights: [CloudFlight] = []
            for doc in documents.documents {
                if let flight = try? parseCloudFlight(from: doc.data) {
                    flights.append(flight)
                }
            }

            logInfo("Downloaded \(flights.count) flights from cloud", category: .sync)
            return flights

        } catch let error as AppwriteError {
            throw FlightSyncError.downloadFailed(error.message)
        } catch {
            throw FlightSyncError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Privacy

    /// Modifie la visibilité d'un vol (public/privé)
    func setFlightPrivacy(flightId: String, isPrivate: Bool) async throws {
        do {
            _ = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                documentId: flightId,
                data: [
                    "isPrivate": isPrivate,
                    "syncedAt": Date().ISO8601Format()
                ]
            )
            logInfo("Flight privacy updated: \(flightId) -> \(isPrivate ? "private" : "public")", category: .sync)
        } catch let error as AppwriteError {
            throw FlightSyncError.uploadFailed(error.message)
        }
    }

    /// Supprime un vol du cloud
    func deleteCloudFlight(flightId: String) async throws {
        do {
            // D'abord récupérer le document pour voir s'il y a une trace GPS à supprimer
            let document = try await databases.getDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                documentId: flightId
            )

            // Supprimer la trace GPS si elle existe
            if let gpsFileId = document.data["gpsTrackFileId"]?.value as? String {
                _ = try? await storage.deleteFile(
                    bucketId: AppwriteConfig.gpsTracksBucketId,
                    fileId: gpsFileId
                )
            }

            // Supprimer le document
            _ = try await databases.deleteDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.flightsCollectionId,
                documentId: flightId
            )

            logInfo("Flight deleted from cloud: \(flightId)", category: .sync)
        } catch let error as AppwriteError {
            throw FlightSyncError.uploadFailed(error.message)
        }
    }

    // MARK: - Pending Uploads

    /// Upload tous les vols en attente de synchronisation
    @MainActor
    private func uploadPendingFlights(modelContext: ModelContext) async throws -> Int {
        let descriptor = FetchDescriptor<Flight>(
            predicate: #Predicate<Flight> { $0.needsSync == true }
        )

        let pendingFlights = try modelContext.fetch(descriptor)
        pendingUploads = pendingFlights.count

        var uploadedCount = 0
        for flight in pendingFlights {
            do {
                let cloudFlight = try await uploadFlight(flight)
                flight.cloudId = cloudFlight.id
                flight.cloudSyncedAt = Date()
                flight.needsSync = false
                flight.syncError = nil
                flight.hasGpsTrackInCloud = cloudFlight.hasGpsTrack
                uploadedCount += 1
                pendingUploads -= 1
            } catch {
                flight.syncError = error.localizedDescription
                logWarning("Failed to upload flight \(flight.id): \(error.localizedDescription)", category: .sync)
            }
        }

        try modelContext.save()
        return uploadedCount
    }

    /// Download et intègre les nouveaux vols depuis le cloud
    @MainActor
    private func downloadNewFlights(modelContext: ModelContext) async throws -> Int {
        let cloudFlights = try await downloadFlights(since: lastSyncDate)
        var downloadedCount = 0

        for cloudFlight in cloudFlights {
            // Vérifier si le vol existe déjà localement (par localFlightId)
            guard let localId = UUID(uuidString: cloudFlight.localFlightId) else {
                continue
            }

            // Fetch tous les vols et filtrer manuellement (contournement limitation #Predicate)
            let descriptor = FetchDescriptor<Flight>()
            let allFlights = try? modelContext.fetch(descriptor)
            let existingFlights = allFlights?.filter { $0.id == localId }

            if let existingFlight = existingFlights?.first {
                // Mettre à jour les données sociales
                existingFlight.likeCount = cloudFlight.likeCount
                existingFlight.commentCount = cloudFlight.commentCount
                existingFlight.cloudId = cloudFlight.id
                existingFlight.cloudSyncedAt = cloudFlight.syncedAt
                existingFlight.hasGpsTrackInCloud = cloudFlight.hasGpsTrack
            } else {
                // Créer un nouveau vol local depuis le cloud
                // (cas rare - vol créé sur un autre appareil)
                let newFlight = Flight(
                    id: UUID(uuidString: cloudFlight.localFlightId) ?? UUID(),
                    startDate: cloudFlight.startDate,
                    endDate: cloudFlight.endDate,
                    durationSeconds: cloudFlight.durationSeconds,
                    spotName: cloudFlight.spotName,
                    latitude: cloudFlight.latitude,
                    longitude: cloudFlight.longitude,
                    flightType: cloudFlight.flightType,
                    notes: cloudFlight.notes,
                    createdAt: cloudFlight.createdAt,
                    startAltitude: cloudFlight.startAltitude,
                    maxAltitude: cloudFlight.maxAltitude,
                    endAltitude: cloudFlight.endAltitude,
                    totalDistance: cloudFlight.totalDistance,
                    maxSpeed: cloudFlight.maxSpeed,
                    maxGForce: cloudFlight.maxGForce,
                    cloudId: cloudFlight.id,
                    cloudSyncedAt: cloudFlight.syncedAt,
                    isPrivate: cloudFlight.isPrivate,
                    needsSync: false,
                    likeCount: cloudFlight.likeCount,
                    commentCount: cloudFlight.commentCount,
                    hasGpsTrackInCloud: cloudFlight.hasGpsTrack
                )

                // Télécharger la trace GPS si disponible
                if let gpsFileId = cloudFlight.gpsTrackFileId {
                    do {
                        let gpsData = try await downloadGPSTrack(fileId: gpsFileId)
                        newFlight.gpsTrackData = gpsData
                    } catch {
                        logWarning("Failed to download GPS track for flight \(cloudFlight.id)", category: .sync)
                    }
                }

                modelContext.insert(newFlight)
                downloadedCount += 1
            }
        }

        try modelContext.save()
        return downloadedCount
    }

    // MARK: - Conflict Resolution

    /// Résout un conflit entre un vol local et distant
    func resolveConflict(local: Flight, remote: CloudFlight) -> ConflictResolution {
        // Stratégie simple : le plus récent gagne
        guard let localSyncDate = local.cloudSyncedAt else {
            return .keepRemote
        }

        if remote.syncedAt > localSyncDate {
            return .keepRemote
        } else {
            return .keepLocal
        }
    }

    // MARK: - Background Sync

    /// Programme une synchronisation en arrière-plan
    func scheduleBackgroundSync() {
        // TODO: Implémenter avec BGTaskScheduler
        logInfo("Background sync scheduled", category: .sync)
    }

    // MARK: - Badge Verification

    /// Vérifie et attribue les badges après une synchronisation
    @MainActor
    private func checkAndAwardBadgesAfterSync(modelContext: ModelContext) async {
        guard let profile = UserService.shared.currentUserProfile else { return }

        // Récupérer les stats nécessaires pour les badges
        let descriptor = FetchDescriptor<Flight>()
        guard let allFlights = try? modelContext.fetch(descriptor) else { return }

        // Calculer les stats
        let uniqueSpots = Set(allFlights.compactMap { $0.spotName }).count
        let maxAltitude = allFlights.compactMap { $0.maxAltitude }.max() ?? 0
        let maxDistance = allFlights.compactMap { $0.totalDistance }.max() ?? 0
        let longestFlight = allFlights.map { $0.durationSeconds }.max() ?? 0

        do {
            // Vérifier et attribuer les nouveaux badges
            let newBadges = try await BadgeService.shared.checkAndAwardBadges(
                profile: profile,
                uniqueSpots: uniqueSpots,
                maxAltitude: maxAltitude,
                maxDistance: maxDistance,
                longestFlightSeconds: longestFlight
            )

            // Notifier l'utilisateur pour chaque nouveau badge
            for badge in newBadges {
                try? await NotificationService.shared.scheduleLocalNotification(
                    title: "Badge obtenu !".localized,
                    body: badge.localizedName,
                    identifier: "badge_\(badge.id)",
                    timeInterval: 1,
                    userInfo: ["badgeId": badge.id]
                )
                logInfo("Badge earned: \(badge.id)", category: .sync)
            }

            // Mettre à jour le profil avec les nouveaux XP si des badges ont été gagnés
            if !newBadges.isEmpty {
                let xpGained = newBadges.reduce(0) { $0 + $1.xpReward }
                await UserService.shared.addXP(xpGained)
            }
        } catch {
            logWarning("Badge check failed: \(error.localizedDescription)", category: .sync)
        }
    }

    // MARK: - Private Helpers

    private func parseCloudFlight(from data: [String: AnyCodable]) throws -> CloudFlight {
        let jsonData = try JSONSerialization.data(withJSONObject: data.mapValues { $0.value })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudFlight.self, from: jsonData)
    }

    /// Calcule un geohash simple pour les queries de proximité
    private func calculateGeohash(lat: Double, lon: Double, precision: Int = 6) -> String {
        // Implémentation simplifiée du geohash
        let base32 = "0123456789bcdefghjkmnpqrstuvwxyz"
        var hash = ""

        var minLat = -90.0, maxLat = 90.0
        var minLon = -180.0, maxLon = 180.0

        var isEven = true
        var bit = 0
        var ch = 0

        while hash.count < precision {
            if isEven {
                let mid = (minLon + maxLon) / 2
                if lon > mid {
                    ch |= (1 << (4 - bit))
                    minLon = mid
                } else {
                    maxLon = mid
                }
            } else {
                let mid = (minLat + maxLat) / 2
                if lat > mid {
                    ch |= (1 << (4 - bit))
                    minLat = mid
                } else {
                    maxLat = mid
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

    private func loadLastSyncDate() {
        lastSyncDate = UserDefaults.standard.object(forKey: "lastFlightSyncDate") as? Date
    }

    private func saveLastSyncDate() {
        UserDefaults.standard.set(lastSyncDate, forKey: "lastFlightSyncDate")
    }
}
