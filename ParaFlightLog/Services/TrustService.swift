//
//  TrustService.swift
//  ParaFlightLog
//
//  Service de gestion des niveaux de confiance utilisateurs
//  Calcule le trust level basé sur l'activité et les contributions
//  Target: iOS only
//

import Foundation
import Appwrite

// MARK: - Trust Service Errors

enum TrustServiceError: LocalizedError {
    case notAuthenticated
    case userNotFound
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .userNotFound:
            return "Utilisateur non trouvé"
        case .networkError(let message):
            return "Erreur réseau: \(message)"
        }
    }
}

// MARK: - Trust Info

/// Informations complètes sur le trust level d'un utilisateur
struct TrustInfo: Equatable {
    let level: TrustLevel
    let score: Double
    let totalFlights: Int
    let uniqueSpots: Int
    let accountAgeDays: Int
    let zonesProposed: Int
    let zonesApproved: Int
    let isModerator: Bool
    let bannedFromProposals: Bool

    /// Progression vers le prochain niveau (0.0 - 1.0)
    var progressToNextLevel: Double {
        guard level != .moderateur else { return 1.0 }

        let nextLevel = TrustLevel(rawValue: level.rawValue + 1) ?? .moderateur
        guard let currentCriteria = TrustCriteria.all.first(where: { $0.level == level }),
              let nextCriteria = TrustCriteria.all.first(where: { $0.level == nextLevel }) else {
            return 0
        }

        // Calculer la progression basée sur les vols (critère principal)
        let flightProgress = Double(totalFlights - currentCriteria.minFlights) /
                            Double(max(1, nextCriteria.minFlights - currentCriteria.minFlights))

        return min(1.0, max(0.0, flightProgress))
    }

    /// Critères manquants pour le prochain niveau
    var missingCriteriaForNextLevel: [String] {
        guard level != .moderateur else { return [] }

        let nextLevel = TrustLevel(rawValue: level.rawValue + 1) ?? .moderateur
        guard let nextCriteria = TrustCriteria.all.first(where: { $0.level == nextLevel }) else {
            return []
        }

        var missing: [String] = []

        if totalFlights < nextCriteria.minFlights {
            missing.append("\(nextCriteria.minFlights - totalFlights) vols supplémentaires")
        }
        if uniqueSpots < nextCriteria.minSpots {
            missing.append("\(nextCriteria.minSpots - uniqueSpots) spots différents")
        }
        if accountAgeDays < nextCriteria.minAccountAgeDays {
            let daysNeeded = nextCriteria.minAccountAgeDays - accountAgeDays
            missing.append("\(daysNeeded) jours d'ancienneté")
        }

        return missing
    }
}

// MARK: - Trust Service

@Observable
final class TrustService {
    static let shared = TrustService()

    // MARK: - Properties

    private let tablesDB: TablesDB

    private(set) var currentUserTrustInfo: TrustInfo?
    private(set) var isLoading = false

    // Cache des trust info par userId
    private var trustCache: [String: (info: TrustInfo, fetchedAt: Date)] = [:]
    private let cacheValiditySeconds: TimeInterval = 300  // 5 minutes

    // MARK: - Init

    private init() {
        self.tablesDB = AppwriteService.shared.tablesDB
    }

    // MARK: - Public Methods

    /// Récupère le trust info de l'utilisateur connecté
    @discardableResult
    func getCurrentUserTrustInfo() async throws -> TrustInfo {
        guard let profile = UserService.shared.currentUserProfile else {
            throw TrustServiceError.notAuthenticated
        }

        let info = try await getTrustInfo(for: profile)
        currentUserTrustInfo = info
        return info
    }

    /// Récupère le trust info d'un utilisateur par son profil
    func getTrustInfo(for profile: CloudUserProfile) async throws -> TrustInfo {
        // Vérifier le cache
        if let cached = trustCache[profile.id],
           Date().timeIntervalSince(cached.fetchedAt) < cacheValiditySeconds {
            return cached.info
        }

        isLoading = true
        defer { isLoading = false }

        // Calculer les métriques
        let uniqueSpots = try await countUniqueSpots(for: profile.authUserId)
        let accountAgeDays = Calendar.current.dateComponents([.day], from: profile.createdAt, to: Date()).day ?? 0
        let (zonesProposed, zonesApproved) = try await countZoneContributions(for: profile.authUserId)
        let isModerator = try await checkModeratorStatus(for: profile.authUserId)
        let bannedFromProposals = try await checkBanStatus(for: profile.authUserId)

        // Calculer le trust level
        let level = TrustCriteria.levelFor(
            flights: profile.totalFlights,
            spots: uniqueSpots,
            accountAgeDays: accountAgeDays,
            approvedZones: zonesApproved,
            isModerator: isModerator
        )

        // Calculer le score
        let score = calculateTrustScore(
            accountAgeDays: accountAgeDays,
            totalFlights: profile.totalFlights,
            approvedZones: zonesApproved,
            rejectedZones: zonesProposed - zonesApproved
        )

        let info = TrustInfo(
            level: level,
            score: score,
            totalFlights: profile.totalFlights,
            uniqueSpots: uniqueSpots,
            accountAgeDays: accountAgeDays,
            zonesProposed: zonesProposed,
            zonesApproved: zonesApproved,
            isModerator: isModerator,
            bannedFromProposals: bannedFromProposals
        )

        // Mettre en cache
        trustCache[profile.id] = (info, Date())

        return info
    }

    /// Récupère le trust level d'un utilisateur (version légère)
    func getTrustLevel(for userId: String) async throws -> TrustLevel {
        // Vérifier le cache
        if let cached = trustCache[userId],
           Date().timeIntervalSince(cached.fetchedAt) < cacheValiditySeconds {
            return cached.info.level
        }

        // Récupérer le profil
        let profile = try await UserService.shared.getProfile(userId: userId)
        let info = try await getTrustInfo(for: profile)
        return info.level
    }

    /// Vérifie si l'utilisateur peut proposer un nom de spot
    func canProposeName() async -> Bool {
        do {
            let info = try await getCurrentUserTrustInfo()
            return info.level.canProposeName && !info.bannedFromProposals
        } catch {
            return false
        }
    }

    /// Vérifie si l'utilisateur peut dessiner une zone
    func canDrawZone() async -> Bool {
        do {
            let info = try await getCurrentUserTrustInfo()
            return info.level.canDrawZone && !info.bannedFromProposals
        } catch {
            return false
        }
    }

    /// Retourne le poids de vote de l'utilisateur actuel
    func getCurrentVoteWeight() -> Double {
        currentUserTrustInfo?.level.voteWeight ?? TrustLevel.nouveau.voteWeight
    }

    /// Invalide le cache pour un utilisateur
    func invalidateCache(for userId: String) {
        trustCache.removeValue(forKey: userId)
    }

    /// Invalide tout le cache
    func invalidateAllCache() {
        trustCache.removeAll()
        currentUserTrustInfo = nil
    }

    // MARK: - Private Methods

    /// Compte le nombre de spots uniques visités par l'utilisateur
    private func countUniqueSpots(for authUserId: String) async throws -> Int {
        do {
            // Récupérer tous les vols de l'utilisateur avec spotName
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.flightsCollectionId,
                queries: [
                    Query.equal("userId", value: authUserId),
                    Query.isNotNull("spotName"),
                    Query.limit(1000)  // Limiter pour performance
                ]
            )

            // Extraire les spotNames uniques
            var uniqueSpots = Set<String>()
            for row in response.rows {
                if let spotName = row.data["spotName"] as? String,
                   !spotName.isEmpty {
                    uniqueSpots.insert(spotName.lowercased())
                } else if let anyCodable = row.data["spotName"] as? AnyCodable,
                          let spotName = anyCodable.value as? String,
                          !spotName.isEmpty {
                    uniqueSpots.insert(spotName.lowercased())
                }
            }

            return uniqueSpots.count
        } catch {
            logWarning("Failed to count unique spots: \(error.localizedDescription)", category: .auth)
            return 0
        }
    }

    /// Compte les contributions de zones (proposées et approuvées)
    private func countZoneContributions(for authUserId: String) async throws -> (proposed: Int, approved: Int) {
        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.spotZonesCollectionId,
                queries: [
                    Query.equal("createdByUserId", value: authUserId),
                    Query.limit(500)
                ]
            )

            var proposed = 0
            var approved = 0

            for row in response.rows {
                proposed += 1
                if let status = row.data["status"] as? String, status == "approved" {
                    approved += 1
                } else if let anyCodable = row.data["status"] as? AnyCodable,
                          let status = anyCodable.value as? String, status == "approved" {
                    approved += 1
                }
            }

            return (proposed, approved)
        } catch {
            // Collection peut ne pas exister encore
            logInfo("Zone contributions check failed (collection may not exist): \(error.localizedDescription)", category: .auth)
            return (0, 0)
        }
    }

    /// Vérifie si l'utilisateur est modérateur
    private func checkModeratorStatus(for authUserId: String) async throws -> Bool {
        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.equal("authUserId", value: authUserId),
                    Query.limit(1)
                ]
            )

            guard let doc = response.rows.first else { return false }

            if let isModerator = doc.data["isModerator"] as? Bool {
                return isModerator
            } else if let anyCodable = doc.data["isModerator"] as? AnyCodable,
                      let isModerator = anyCodable.value as? Bool {
                return isModerator
            }

            return false
        } catch {
            return false
        }
    }

    /// Vérifie si l'utilisateur est banni des propositions
    private func checkBanStatus(for authUserId: String) async throws -> Bool {
        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.equal("authUserId", value: authUserId),
                    Query.limit(1)
                ]
            )

            guard let doc = response.rows.first else { return false }

            if let banned = doc.data["bannedFromProposals"] as? Bool {
                return banned
            } else if let anyCodable = doc.data["bannedFromProposals"] as? AnyCodable,
                      let banned = anyCodable.value as? Bool {
                return banned
            }

            return false
        } catch {
            return false
        }
    }

    /// Calcule le score de confiance
    private func calculateTrustScore(
        accountAgeDays: Int,
        totalFlights: Int,
        approvedZones: Int,
        rejectedZones: Int
    ) -> Double {
        // baseScore = accountAgeDays / 30 (max 12 points)
        let baseScore = min(12.0, Double(accountAgeDays) / 30.0)

        // flightBonus = log2(totalFlights + 1) * 2 (max 14 points pour 8000+ vols)
        let flightBonus = min(14.0, log2(Double(totalFlights + 1)) * 2.0)

        // proposalBonus = approvedZones * 5 - rejectedZones * 2
        let proposalBonus = Double(approvedZones * 5 - rejectedZones * 2)

        let score = baseScore + flightBonus + max(0, proposalBonus)

        return max(0, score)
    }
}
