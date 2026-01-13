//
//  ZoneVotingService.swift
//  ParaFlightLog
//
//  Service de gestion des votes sur les zones de spots
//  Vote, résolution, approbation/rejet des zones
//  Target: iOS only
//

import Foundation
import Appwrite
import CoreLocation

// MARK: - Zone Voting Service

@Observable
final class ZoneVotingService {
    static let shared = ZoneVotingService()

    // MARK: - Properties

    private let tablesDB: TablesDB

    private(set) var isLoading = false

    // Cache des votes de l'utilisateur actuel
    private var userVotesCache: [String: ZoneVote] = [:]  // zoneId -> vote
    private var userVotesCacheFetchedAt: Date?
    private let cacheValiditySeconds: TimeInterval = 300  // 5 minutes

    // MARK: - Init

    private init() {
        self.tablesDB = AppwriteService.shared.tablesDB
    }

    // MARK: - Voting

    /// Vote sur une zone (approuver ou rejeter)
    func vote(on zoneId: String, voteType: ZoneVoteType, reason: String? = nil) async throws -> ZoneVote {
        guard let authUserId = AuthService.shared.currentUserId else {
            throw SpotZoneError.notAuthenticated
        }

        // Vérifier que la zone existe et est en vote
        let zone = try await SpotZoneService.shared.getZone(id: zoneId)

        guard zone.status == .pending else {
            throw SpotZoneError.votingClosed
        }

        guard let votingEndsAt = zone.votingEndsAt, votingEndsAt > Date() else {
            throw SpotZoneError.votingClosed
        }

        // Vérifier que l'utilisateur n'a pas déjà voté
        if let existingVote = try await getUserVote(for: zoneId) {
            // Permettre le changement de vote
            return try await updateVote(existingVote, newVoteType: voteType, reason: reason)
        }

        // Vérifier l'éligibilité (a volé près du spot)
        let isEligible = try await checkVotingEligibility(for: authUserId, zone: zone)
        if !isEligible {
            throw SpotZoneError.insufficientTrustLevel(required: .actif)
        }

        // Récupérer le poids du vote
        let trustInfo = try await TrustService.shared.getCurrentUserTrustInfo()
        var weight = trustInfo.level.voteWeight

        // Bonus si l'utilisateur a volé localement (dans un rayon de 500m)
        let hasLocalFlight = try await hasFlightNearZone(userId: authUserId, zone: zone, radiusMeters: VotingConstants.localPilotBonusRadius)
        if hasLocalFlight {
            weight += VotingConstants.localPilotBonusWeight
        }

        let username = UserService.shared.currentUserProfile?.username
        let now = Date()

        let voteData: [String: Any] = [
            "zoneId": zoneId,
            "userId": authUserId,
            "username": username ?? "",
            "vote": voteType.rawValue,
            "weight": weight,
            "reason": reason ?? "",
            "createdAt": now.ISO8601Format()
        ]

        isLoading = true
        defer { isLoading = false }

        do {
            // Créer le vote
            let document = try await tablesDB.createRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.zoneVotesCollectionId,
                rowId: ID.unique(),
                data: voteData
            )

            let vote = try parseVote(from: document.data)

            // Mettre à jour les compteurs de la zone
            try await updateZoneVoteCounts(zoneId: zoneId, addedVoteType: voteType, addedWeight: weight)

            // Mettre en cache
            userVotesCache[zoneId] = vote

            // Vérifier si le vote est décisif
            try await checkAndResolveVoting(zoneId: zoneId)

            logInfo("Vote recorded: \(voteType.rawValue) on zone \(zoneId) with weight \(weight)", category: .auth)
            return vote
        } catch let error as SpotZoneError {
            throw error
        } catch {
            throw SpotZoneError.networkError(error.localizedDescription)
        }
    }

    /// Modifie un vote existant
    private func updateVote(_ existingVote: ZoneVote, newVoteType: ZoneVoteType, reason: String?) async throws -> ZoneVote {
        guard existingVote.vote != newVoteType else {
            // Même vote, rien à faire
            return existingVote
        }

        isLoading = true
        defer { isLoading = false }

        do {
            // Mettre à jour le document
            let document = try await tablesDB.updateRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.zoneVotesCollectionId,
                rowId: existingVote.id,
                data: [
                    "vote": newVoteType.rawValue,
                    "reason": reason ?? "",
                    "updatedAt": Date().ISO8601Format()
                ]
            )

            let updatedVote = try parseVote(from: document.data)

            // Mettre à jour les compteurs de la zone (soustraire l'ancien, ajouter le nouveau)
            try await updateZoneVoteCountsForChange(
                zoneId: existingVote.zoneId,
                oldVoteType: existingVote.vote,
                newVoteType: newVoteType,
                weight: existingVote.weight
            )

            // Mettre en cache
            userVotesCache[existingVote.zoneId] = updatedVote

            logInfo("Vote updated: \(existingVote.vote.rawValue) -> \(newVoteType.rawValue) on zone \(existingVote.zoneId)", category: .auth)
            return updatedVote
        } catch {
            throw SpotZoneError.networkError(error.localizedDescription)
        }
    }

    /// Récupère le vote de l'utilisateur actuel sur une zone
    func getUserVote(for zoneId: String) async throws -> ZoneVote? {
        guard let authUserId = AuthService.shared.currentUserId else {
            return nil
        }

        // Vérifier le cache
        if let cached = userVotesCache[zoneId],
           let fetchedAt = userVotesCacheFetchedAt,
           Date().timeIntervalSince(fetchedAt) < cacheValiditySeconds {
            return cached
        }

        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.zoneVotesCollectionId,
                queries: [
                    Query.equal("zoneId", value: zoneId),
                    Query.equal("userId", value: authUserId),
                    Query.limit(1)
                ]
            )

            if let doc = response.rows.first {
                let vote = try parseVote(from: doc.data)
                userVotesCache[zoneId] = vote
                userVotesCacheFetchedAt = Date()
                return vote
            }

            return nil
        } catch {
            return nil
        }
    }

    /// Récupère tous les votes sur une zone
    func getVotes(for zoneId: String) async throws -> [ZoneVote] {
        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.zoneVotesCollectionId,
                queries: [
                    Query.equal("zoneId", value: zoneId),
                    Query.orderDesc("createdAt"),
                    Query.limit(100)
                ]
            )

            return try response.rows.map { try parseVote(from: $0.data) }
        } catch {
            throw SpotZoneError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Vote Resolution

    /// Vérifie si le vote doit être résolu et le résout si nécessaire
    private func checkAndResolveVoting(zoneId: String) async throws {
        let zone = try await SpotZoneService.shared.getZone(id: zoneId)

        guard zone.status == .pending else { return }

        // Vérifier si le vote est terminé (date dépassée)
        if let votingEndsAt = zone.votingEndsAt, votingEndsAt <= Date() {
            try await resolveVoting(zone: zone)
            return
        }

        // Vérifier si le seuil est atteint de manière décisive
        let totalWeight = zone.approvalWeight + zone.rejectionWeight

        guard totalWeight >= VotingConstants.minimumVoteWeight &&
              zone.voterCount >= VotingConstants.minimumVoters else {
            return
        }

        let approvalRatio = zone.approvalWeight / totalWeight

        // Si on a une majorité claire (>70% ou <30%), résoudre immédiatement
        if approvalRatio >= 0.7 || approvalRatio <= 0.3 {
            try await resolveVoting(zone: zone)
        }
    }

    /// Résout le vote sur une zone (approbation ou rejet)
    func resolveVoting(zone: SpotZone) async throws {
        let totalWeight = zone.approvalWeight + zone.rejectionWeight

        guard totalWeight > 0 else {
            // Pas assez de votes, marquer comme expiré
            try await updateZoneStatus(zoneId: zone.id, status: .expired)
            return
        }

        let approvalRatio = zone.approvalWeight / totalWeight
        let isApproved = approvalRatio >= VotingConstants.approvalThreshold &&
                        zone.voterCount >= VotingConstants.minimumVoters

        if isApproved {
            // Approuver la zone
            try await updateZoneStatus(zoneId: zone.id, status: .approved)

            // Mettre à jour les vols existants dans cette zone
            try await SpotZoneService.shared.updateFlightsInZone(zone)

            logInfo("Zone approved: \(zone.name) with \(Int(approvalRatio * 100))% approval", category: .auth)
        } else {
            // Rejeter la zone
            try await updateZoneStatus(zoneId: zone.id, status: .rejected)

            logInfo("Zone rejected: \(zone.name) with \(Int(approvalRatio * 100))% approval", category: .auth)
        }

        // Invalider le cache des zones
        SpotZoneService.shared.invalidateCache()
    }

    // MARK: - Private Helpers

    /// Vérifie si l'utilisateur est éligible pour voter (a volé près du spot)
    private func checkVotingEligibility(for userId: String, zone: SpotZone) async throws -> Bool {
        // Les modérateurs peuvent toujours voter
        let trustInfo = try await TrustService.shared.getCurrentUserTrustInfo()
        if trustInfo.level == .moderateur {
            return true
        }

        // Vérifier si l'utilisateur a un vol dans un rayon de 50km
        return try await hasFlightNearZone(
            userId: userId,
            zone: zone,
            radiusMeters: VotingConstants.eligibilityRadiusKm * 1000
        )
    }

    /// Vérifie si l'utilisateur a un vol près de la zone
    private func hasFlightNearZone(userId: String, zone: SpotZone, radiusMeters: Double) async throws -> Bool {
        let radiusKm = radiusMeters / 1000
        let latDelta = radiusKm / 111.0
        let lonDelta = radiusKm / (111.0 * cos(zone.coordinate.latitude * .pi / 180))

        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.flightsCollectionId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.greaterThan("latitude", value: zone.coordinate.latitude - latDelta),
                    Query.lessThan("latitude", value: zone.coordinate.latitude + latDelta),
                    Query.greaterThan("longitude", value: zone.coordinate.longitude - lonDelta),
                    Query.lessThan("longitude", value: zone.coordinate.longitude + lonDelta),
                    Query.limit(1)
                ]
            )

            return !response.rows.isEmpty
        } catch {
            return false
        }
    }

    /// Met à jour les compteurs de votes d'une zone
    private func updateZoneVoteCounts(zoneId: String, addedVoteType: ZoneVoteType, addedWeight: Double) async throws {
        let zone = try await SpotZoneService.shared.getZone(id: zoneId)

        var updateData: [String: Any] = [
            "voterCount": zone.voterCount + 1
        ]

        if addedVoteType == .approve {
            updateData["approvalWeight"] = zone.approvalWeight + addedWeight
        } else {
            updateData["rejectionWeight"] = zone.rejectionWeight + addedWeight
        }

        _ = try await tablesDB.updateRow(
            databaseId: AppwriteConfig.databaseId,
            tableId: AppwriteConfig.spotZonesCollectionId,
            rowId: zoneId,
            data: updateData
        )
    }

    /// Met à jour les compteurs de votes lors d'un changement de vote
    private func updateZoneVoteCountsForChange(zoneId: String, oldVoteType: ZoneVoteType, newVoteType: ZoneVoteType, weight: Double) async throws {
        let zone = try await SpotZoneService.shared.getZone(id: zoneId)

        var approvalWeight = zone.approvalWeight
        var rejectionWeight = zone.rejectionWeight

        // Soustraire l'ancien vote
        if oldVoteType == .approve {
            approvalWeight -= weight
        } else {
            rejectionWeight -= weight
        }

        // Ajouter le nouveau vote
        if newVoteType == .approve {
            approvalWeight += weight
        } else {
            rejectionWeight += weight
        }

        _ = try await tablesDB.updateRow(
            databaseId: AppwriteConfig.databaseId,
            tableId: AppwriteConfig.spotZonesCollectionId,
            rowId: zoneId,
            data: [
                "approvalWeight": max(0, approvalWeight),
                "rejectionWeight": max(0, rejectionWeight)
            ]
        )
    }

    /// Met à jour le statut d'une zone
    private func updateZoneStatus(zoneId: String, status: ZoneStatus) async throws {
        _ = try await tablesDB.updateRow(
            databaseId: AppwriteConfig.databaseId,
            tableId: AppwriteConfig.spotZonesCollectionId,
            rowId: zoneId,
            data: [
                "status": status.rawValue
            ]
        )
    }

    /// Parse un vote depuis les données Appwrite
    private func parseVote(from data: [String: Any]) throws -> ZoneVote {
        guard let id = data["$id"] as? String else {
            throw SpotZoneError.zoneNotFound
        }

        let getValue: (String) -> Any? = { key in
            if let anyCodable = data[key] as? AnyCodable {
                return anyCodable.value
            }
            return data[key]
        }

        let createdAt: Date
        if let createdAtStr = getValue("createdAt") as? String {
            createdAt = ISO8601DateFormatter().date(from: createdAtStr) ?? Date()
        } else {
            createdAt = Date()
        }

        let updatedAt: Date?
        if let updatedAtStr = getValue("updatedAt") as? String {
            updatedAt = ISO8601DateFormatter().date(from: updatedAtStr)
        } else {
            updatedAt = nil
        }

        let voteType = ZoneVoteType(rawValue: getValue("vote") as? String ?? "") ?? .approve

        return ZoneVote(
            id: id,
            zoneId: getValue("zoneId") as? String ?? "",
            odflightlogins: getValue("userId") as? String ?? "",
            username: getValue("username") as? String,
            vote: voteType,
            weight: getValue("weight") as? Double ?? 1.0,
            reason: getValue("reason") as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Invalide le cache des votes
    func invalidateCache() {
        userVotesCache.removeAll()
        userVotesCacheFetchedAt = nil
    }
}

// MARK: - Batch Resolution

extension ZoneVotingService {
    /// Résout tous les votes expirés (à appeler périodiquement ou via cron)
    func resolveExpiredVotings() async {
        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                queries: [
                    Query.equal("status", value: ZoneStatus.pending.rawValue),
                    Query.lessThan("votingEndsAt", value: Date().ISO8601Format()),
                    Query.limit(50)
                ]
            )

            for row in response.rows {
                if let zone = try? await SpotZoneService.shared.getZone(id: row.id) {
                    try? await resolveVoting(zone: zone)
                }
            }

            logInfo("Resolved \(response.rows.count) expired votings", category: .auth)
        } catch {
            logWarning("Failed to resolve expired votings: \(error.localizedDescription)", category: .auth)
        }
    }
}
