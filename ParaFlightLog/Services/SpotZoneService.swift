//
//  SpotZoneService.swift
//  ParaFlightLog
//
//  Service de gestion des zones de spots communautaires
//  Matching GPS → Zone, cache local, CRUD des zones
//  Target: iOS only
//

import Foundation
import Appwrite
import CoreLocation

// MARK: - Spot Zone Errors

enum SpotZoneError: LocalizedError {
    case notAuthenticated
    case zoneNotFound
    case insufficientTrustLevel(required: TrustLevel)
    case zoneTooLarge(maxKm2: Double)
    case zoneOverlap(existingZoneName: String)
    case invalidPolygon
    case alreadyVoted
    case votingClosed
    case cooldownActive(daysRemaining: Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .zoneNotFound:
            return "Zone non trouvée"
        case .insufficientTrustLevel(let required):
            return "Niveau \(required.displayName) requis pour cette action"
        case .zoneTooLarge(let maxKm2):
            return "La zone ne peut pas dépasser \(Int(maxKm2)) km²"
        case .zoneOverlap(let name):
            return "Cette zone chevauche \"\(name)\" (>10%)"
        case .invalidPolygon:
            return "Le polygone doit avoir au moins 3 points"
        case .alreadyVoted:
            return "Vous avez déjà voté sur cette proposition"
        case .votingClosed:
            return "Le vote est terminé"
        case .cooldownActive(let days):
            return "Vous devez attendre \(days) jours avant de reproposer"
        case .networkError(let message):
            return "Erreur réseau: \(message)"
        }
    }
}

// MARK: - Spot Zone Service

@Observable
final class SpotZoneService {
    static let shared = SpotZoneService()

    // MARK: - Properties

    private let tablesDB: TablesDB
    private let storage: Storage

    private(set) var isLoading = false

    // Cache local des zones approuvées (pour matching rapide)
    private var zoneCache: [SpotZone] = []
    private var zoneCacheFetchedAt: Date?
    private var zoneCacheCenter: CLLocationCoordinate2D?
    private let zoneCacheRadiusKm: Double = 100
    private let zoneCacheValiditySeconds: TimeInterval = 86400  // 24h

    // MARK: - Init

    private init() {
        self.tablesDB = AppwriteService.shared.tablesDB
        self.storage = AppwriteService.shared.storage
    }

    // MARK: - Zone Matching

    /// Trouve la zone correspondant à une coordonnée GPS
    /// Retourne nil si aucune zone custom ne correspond (fallback vers reverse geocoding)
    func findMatchingZone(coordinate: CLLocationCoordinate2D) async -> SpotZone? {
        // Rafraîchir le cache si nécessaire
        await refreshCacheIfNeeded(near: coordinate)

        // Pré-filtrer par bounding box
        let candidates = zoneCache.filter { zone in
            zone.boundingBox.contains(coordinate: coordinate)
        }

        // Tester le polygone pour chaque candidat
        var matches: [SpotZone] = []
        for zone in candidates where zone.status == .approved {
            if zone.geometry.contains(coordinate: coordinate) {
                matches.append(zone)
            }
        }

        // Si plusieurs matchs, préférer la zone la plus petite (plus spécifique)
        if matches.count > 1 {
            matches.sort { $0.areaKm2 < $1.areaKm2 }
        }

        return matches.first
    }

    /// Trouve toutes les zones proches d'une coordonnée (pour affichage sur carte)
    func findNearbyZones(coordinate: CLLocationCoordinate2D, radiusKm: Double = 50) async -> [SpotZone] {
        await refreshCacheIfNeeded(near: coordinate)

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return zoneCache.filter { zone in
            let zoneLocation = CLLocation(latitude: zone.coordinate.latitude, longitude: zone.coordinate.longitude)
            let distanceKm = location.distance(from: zoneLocation) / 1000
            return distanceKm <= radiusKm && zone.status == .approved
        }.sorted { zone1, zone2 in
            let loc1 = CLLocation(latitude: zone1.coordinate.latitude, longitude: zone1.coordinate.longitude)
            let loc2 = CLLocation(latitude: zone2.coordinate.latitude, longitude: zone2.coordinate.longitude)
            return location.distance(from: loc1) < location.distance(from: loc2)
        }
    }

    /// Trouve les zones en attente de vote (pour l'onglet Discover)
    func findPendingZones(near coordinate: CLLocationCoordinate2D?, limit: Int = 20) async throws -> [SpotZone] {
        var queries: [String] = [
            Query.equal("status", value: ZoneStatus.pending.rawValue),
            Query.orderDesc("createdAt"),
            Query.limit(limit)
        ]

        // Si on a une coordonnée, filtrer par proximité (approximatif via bounding box large)
        if let coord = coordinate {
            let margin = 1.0  // ~100km
            queries.append(Query.greaterThan("centroidLat", value: coord.latitude - margin))
            queries.append(Query.lessThan("centroidLat", value: coord.latitude + margin))
            queries.append(Query.greaterThan("centroidLon", value: coord.longitude - margin))
            queries.append(Query.lessThan("centroidLon", value: coord.longitude + margin))
        }

        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                queries: queries
            )

            return try response.rows.map { try parseZone(from: $0.data) }
        } catch {
            throw SpotZoneError.networkError(error.localizedDescription)
        }
    }

    /// Récupère toutes les zones approuvées
    func getApprovedZones(limit: Int = 100) async throws -> [SpotZone] {
        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                queries: [
                    Query.equal("status", value: ZoneStatus.approved.rawValue),
                    Query.orderDesc("flightCount"),
                    Query.limit(limit)
                ]
            )

            return try response.rows.map { try parseZone(from: $0.data) }
        } catch {
            throw SpotZoneError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Zone CRUD

    /// Crée une nouvelle zone (soumise au vote)
    func createZone(request: CreateZoneRequest) async throws -> SpotZone {
        guard let authUserId = AuthService.shared.currentUserId else {
            throw SpotZoneError.notAuthenticated
        }

        // Vérifier le trust level
        let trustInfo = try await TrustService.shared.getCurrentUserTrustInfo()

        if case .polygon = request.geometry {
            guard trustInfo.level.canDrawZone else {
                throw SpotZoneError.insufficientTrustLevel(required: .expert)
            }
        } else {
            guard trustInfo.level.canProposeName else {
                throw SpotZoneError.insufficientTrustLevel(required: .confirme)
            }
        }

        // Vérifier la taille
        let areaKm2 = request.geometry.areaKm2
        let maxArea = trustInfo.level.maxZoneAreaKm2
        if maxArea > 0 && areaKm2 > maxArea {
            throw SpotZoneError.zoneTooLarge(maxKm2: maxArea)
        }

        // Vérifier les chevauchements
        if let overlap = await findOverlappingZone(for: request.geometry) {
            throw SpotZoneError.zoneOverlap(existingZoneName: overlap.name)
        }

        // Vérifier le cooldown
        if let daysRemaining = try await checkCooldown(for: authUserId) {
            throw SpotZoneError.cooldownActive(daysRemaining: daysRemaining)
        }

        let now = Date()
        let votingEndsAt = Calendar.current.date(byAdding: .day, value: VotingConstants.votingDurationDays, to: now)!
        let boundingBox = request.geometry.boundingBox
        let centroid = request.geometry.centroid

        let username = UserService.shared.currentUserProfile?.username

        let zoneData: [String: Any] = [
            "name": request.name,
            "normalizedName": request.normalizedName,
            "geometry": encodeGeometry(request.geometry),
            "boundingBox": encodeBoundingBox(boundingBox),
            "centroidLat": centroid.latitude,
            "centroidLon": centroid.longitude,
            "areaKm2": areaKm2,
            "createdByUserId": authUserId,
            "createdByUsername": username ?? "",
            "status": ZoneStatus.pending.rawValue,
            "parentSpotId": request.parentSpotId ?? "",
            "approvalWeight": 0.0,
            "rejectionWeight": 0.0,
            "voterCount": 0,
            "votingEndsAt": votingEndsAt.ISO8601Format(),
            "flightCount": 0,
            "uniquePilotCount": 0,
            "reason": request.reason,
            "photoFileIds": request.photoFileIds.joined(separator: ","),
            "nameHistory": "[]",
            "createdAt": now.ISO8601Format()
        ]

        isLoading = true
        defer { isLoading = false }

        do {
            let document = try await tablesDB.createRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                rowId: ID.unique(),
                data: zoneData
            )

            // Construire la zone directement (document.data ne contient pas $id après création)
            var dataWithId = document.data
            dataWithId["$id"] = AnyCodable(document.id)
            let zone = try parseZone(from: dataWithId)

            // Invalider le cache
            invalidateCache()

            logInfo("Zone created: \(zone.name) by \(authUserId)", category: .auth)
            return zone
        } catch {
            throw SpotZoneError.networkError(error.localizedDescription)
        }
    }

    /// Récupère une zone par son ID
    func getZone(id: String) async throws -> SpotZone {
        do {
            let document = try await tablesDB.getRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                rowId: id
            )

            return try parseZone(from: document.data)
        } catch {
            throw SpotZoneError.zoneNotFound
        }
    }

    /// Récupère les zones créées par l'utilisateur actuel
    func getMyZones() async throws -> [SpotZone] {
        guard let authUserId = AuthService.shared.currentUserId else {
            throw SpotZoneError.notAuthenticated
        }

        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                queries: [
                    Query.equal("createdByUserId", value: authUserId),
                    Query.orderDesc("createdAt"),
                    Query.limit(100)
                ]
            )

            return try response.rows.map { try parseZone(from: $0.data) }
        } catch {
            throw SpotZoneError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Cache Management

    /// Rafraîchit le cache si nécessaire
    private func refreshCacheIfNeeded(near coordinate: CLLocationCoordinate2D) async {
        // Vérifier si le cache est valide
        if let fetchedAt = zoneCacheFetchedAt,
           let cacheCenter = zoneCacheCenter,
           Date().timeIntervalSince(fetchedAt) < zoneCacheValiditySeconds {
            // Vérifier si on est encore dans la zone du cache
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let cacheLocation = CLLocation(latitude: cacheCenter.latitude, longitude: cacheCenter.longitude)
            let distanceKm = location.distance(from: cacheLocation) / 1000

            if distanceKm < zoneCacheRadiusKm * 0.5 {
                // Encore dans la zone, pas besoin de rafraîchir
                return
            }
        }

        await refreshCache(near: coordinate)
    }

    /// Force le rafraîchissement du cache
    func refreshCache(near coordinate: CLLocationCoordinate2D) async {
        let margin = zoneCacheRadiusKm / 111.0  // Conversion km vers degrés (approximatif)

        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                queries: [
                    Query.equal("status", value: ZoneStatus.approved.rawValue),
                    Query.greaterThan("centroidLat", value: coordinate.latitude - margin),
                    Query.lessThan("centroidLat", value: coordinate.latitude + margin),
                    Query.greaterThan("centroidLon", value: coordinate.longitude - margin),
                    Query.lessThan("centroidLon", value: coordinate.longitude + margin),
                    Query.limit(500)
                ]
            )

            let zones = try response.rows.compactMap { try? parseZone(from: $0.data) }

            await MainActor.run {
                self.zoneCache = zones
                self.zoneCacheFetchedAt = Date()
                self.zoneCacheCenter = coordinate
            }

            logInfo("Zone cache refreshed: \(zones.count) zones loaded", category: .auth)
        } catch {
            logWarning("Failed to refresh zone cache: \(error.localizedDescription)", category: .auth)
        }
    }

    /// Invalide le cache
    func invalidateCache() {
        zoneCache = []
        zoneCacheFetchedAt = nil
        zoneCacheCenter = nil
    }

    // MARK: - Overlap Detection

    /// Vérifie si une géométrie chevauche une zone existante (>10%)
    private func findOverlappingZone(for geometry: SpotZoneGeometry) async -> SpotZone? {
        let centroid = geometry.centroid
        await refreshCacheIfNeeded(near: centroid)

        // Vérification simplifiée: on vérifie si le centroïde de la nouvelle zone
        // est dans une zone existante ou vice-versa
        for existingZone in zoneCache where existingZone.status == .approved {
            // Vérifier si le centroïde de la nouvelle zone est dans la zone existante
            if existingZone.geometry.contains(coordinate: centroid) {
                return existingZone
            }

            // Vérifier si le centroïde de la zone existante est dans la nouvelle zone
            if geometry.contains(coordinate: existingZone.coordinate) {
                return existingZone
            }

            // Pour une détection plus précise, on pourrait calculer l'intersection réelle
            // mais c'est complexe et cette approximation suffit pour le MVP
        }

        return nil
    }

    // MARK: - Cooldown Check

    /// Vérifie si l'utilisateur est en cooldown après un rejet
    private func checkCooldown(for userId: String) async throws -> Int? {
        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                queries: [
                    Query.equal("createdByUserId", value: userId),
                    Query.equal("status", value: ZoneStatus.rejected.rawValue),
                    Query.orderDesc("createdAt"),
                    Query.limit(1)
                ]
            )

            guard let lastRejected = response.rows.first else { return nil }

            // Parser la date de création
            if let createdAtStr = lastRejected.data["createdAt"] as? String,
               let createdAt = ISO8601DateFormatter().date(from: createdAtStr) {
                let daysSinceRejection = Calendar.current.dateComponents([.day], from: createdAt, to: Date()).day ?? 0

                if daysSinceRejection < VotingConstants.cooldownAfterRejectionDays {
                    return VotingConstants.cooldownAfterRejectionDays - daysSinceRejection
                }
            }

            return nil
        } catch {
            return nil  // En cas d'erreur, on laisse passer
        }
    }

    // MARK: - Parsing Helpers

    private func parseZone(from data: [String: Any]) throws -> SpotZone {
        let getValue: (String) -> Any? = { key in
            if let anyCodable = data[key] as? AnyCodable {
                return anyCodable.value
            }
            return data[key]
        }

        guard let id = getValue("$id") as? String else {
            throw SpotZoneError.zoneNotFound
        }

        let name = getValue("name") as? String ?? ""
        let normalizedName = getValue("normalizedName") as? String ?? ""
        let status = ZoneStatus(rawValue: getValue("status") as? String ?? "") ?? .draft

        // Parser la géométrie
        let geometryStr = getValue("geometry") as? String ?? ""
        let geometry = try decodeGeometry(from: geometryStr)

        // Parser la bounding box
        let boundingBoxStr = getValue("boundingBox") as? String ?? ""
        let boundingBox = decodeBoundingBox(from: boundingBoxStr) ?? geometry.boundingBox

        // Parser l'historique des noms
        let nameHistoryStr = getValue("nameHistory") as? String ?? "[]"
        let nameHistory = decodeNameHistory(from: nameHistoryStr)

        // Parser les dates
        let createdAt: Date
        if let createdAtStr = getValue("createdAt") as? String {
            createdAt = ISO8601DateFormatter().date(from: createdAtStr) ?? Date()
        } else {
            createdAt = Date()
        }

        let votingEndsAt: Date?
        if let votingEndsAtStr = getValue("votingEndsAt") as? String {
            votingEndsAt = ISO8601DateFormatter().date(from: votingEndsAtStr)
        } else {
            votingEndsAt = nil
        }

        let updatedAt: Date?
        if let updatedAtStr = getValue("$updatedAt") as? String {
            updatedAt = ISO8601DateFormatter().date(from: updatedAtStr)
        } else {
            updatedAt = nil
        }

        // Parser les photo IDs
        let photoFileIdsStr = getValue("photoFileIds") as? String ?? ""
        let photoFileIds = photoFileIdsStr.isEmpty ? [] : photoFileIdsStr.components(separatedBy: ",")

        return SpotZone(
            id: id,
            name: name,
            normalizedName: normalizedName,
            geometry: geometry,
            boundingBox: boundingBox,
            areaKm2: getValue("areaKm2") as? Double ?? geometry.areaKm2,
            createdByUserId: getValue("createdByUserId") as? String ?? "",
            createdByUsername: getValue("createdByUsername") as? String,
            status: status,
            parentSpotId: (getValue("parentSpotId") as? String)?.isEmpty == true ? nil : getValue("parentSpotId") as? String,
            approvalWeight: getValue("approvalWeight") as? Double ?? 0,
            rejectionWeight: getValue("rejectionWeight") as? Double ?? 0,
            voterCount: getValue("voterCount") as? Int ?? 0,
            votingEndsAt: votingEndsAt,
            flightCount: getValue("flightCount") as? Int ?? 0,
            uniquePilotCount: getValue("uniquePilotCount") as? Int ?? 0,
            reason: getValue("reason") as? String,
            photoFileIds: photoFileIds,
            createdAt: createdAt,
            updatedAt: updatedAt,
            mergedIntoZoneId: getValue("mergedIntoZoneId") as? String,
            nameHistory: nameHistory
        )
    }

    // MARK: - JSON Encoding/Decoding

    private func encodeGeometry(_ geometry: SpotZoneGeometry) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(geometry),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func decodeGeometry(from json: String) throws -> SpotZoneGeometry {
        guard let data = json.data(using: .utf8) else {
            throw SpotZoneError.invalidPolygon
        }

        let decoder = JSONDecoder()
        return try decoder.decode(SpotZoneGeometry.self, from: data)
    }

    private func encodeBoundingBox(_ box: BoundingBox) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(box),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func decodeBoundingBox(from json: String) -> BoundingBox? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(BoundingBox.self, from: data)
    }

    private func decodeNameHistory(from json: String) -> [NameHistoryEntry] {
        guard let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([NameHistoryEntry].self, from: data)) ?? []
    }
}

// MARK: - Flight Update Extension

extension SpotZoneService {
    /// Met à jour le spotName des vols existants dans une zone approuvée
    /// Appelé quand une zone est approuvée
    func updateFlightsInZone(_ zone: SpotZone) async throws {
        guard zone.status == .approved else { return }

        let boundingBox = zone.boundingBox

        // Récupérer les vols dans la bounding box
        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.flightsCollectionId,
                queries: [
                    Query.greaterThan("latitude", value: boundingBox.minLat),
                    Query.lessThan("latitude", value: boundingBox.maxLat),
                    Query.greaterThan("longitude", value: boundingBox.minLon),
                    Query.lessThan("longitude", value: boundingBox.maxLon),
                    Query.limit(100)  // Batch de 100
                ]
            )

            var updatedCount = 0

            for row in response.rows {
                guard let lat = row.data["latitude"] as? Double ?? (row.data["latitude"] as? AnyCodable)?.value as? Double,
                      let lon = row.data["longitude"] as? Double ?? (row.data["longitude"] as? AnyCodable)?.value as? Double else {
                    continue
                }

                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                // Vérifier si le vol est vraiment dans le polygone
                if zone.geometry.contains(coordinate: coordinate) {
                    // Mettre à jour le spotName
                    _ = try? await tablesDB.updateRow(
                        databaseId: AppwriteConfig.databaseId,
                        tableId: AppwriteConfig.flightsCollectionId,
                        rowId: row.id,
                        data: [
                            "spotName": zone.name,
                            "spotZoneId": zone.id
                        ]
                    )
                    updatedCount += 1
                }
            }

            logInfo("Updated \(updatedCount) flights with zone name: \(zone.name)", category: .auth)
        } catch {
            logWarning("Failed to update flights in zone: \(error.localizedDescription)", category: .auth)
        }
    }
}
