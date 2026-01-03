//
//  LeaderboardService.swift
//  ParaFlightLog
//
//  Service de gestion des classements globaux et nationaux
//  Utilise les données de la collection users pour les classements
//  Target: iOS only
//

import Foundation
import Appwrite

// MARK: - Leaderboard Models

/// Types de classements disponibles
enum LeaderboardType: String, CaseIterable, Identifiable {
    case flightHours = "flight_hours"
    case totalFlights = "total_flights"
    case level = "level"
    case longestStreak = "longest_streak"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flightHours: return "Heures de vol".localized
        case .totalFlights: return "Nombre de vols".localized
        case .level: return "Niveau".localized
        case .longestStreak: return "Plus longue série".localized
        }
    }

    var icon: String {
        switch self {
        case .flightHours: return "clock.fill"
        case .totalFlights: return "airplane"
        case .level: return "star.fill"
        case .longestStreak: return "flame.fill"
        }
    }

    /// Champ Appwrite correspondant pour le tri
    var sortField: String {
        switch self {
        case .flightHours: return "totalFlightSeconds"
        case .totalFlights: return "totalFlights"
        case .level: return "xpTotal"  // Trier par XP pour le niveau
        case .longestStreak: return "longestStreak"
        }
    }
}

/// Portée du classement
enum LeaderboardScope: String, CaseIterable, Identifiable {
    case global = "global"
    case national = "national"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global: return "Monde".localized
        case .national: return "National".localized
        }
    }

    var icon: String {
        switch self {
        case .global: return "globe"
        case .national: return "flag.fill"
        }
    }
}

/// Entrée dans un classement
struct LeaderboardEntry: Identifiable, Equatable {
    let id: String
    let rank: Int
    let oderId: String
    let displayName: String
    let username: String
    let profilePhotoFileId: String?
    let value: Int
    let level: Int

    /// Valeur formatée selon le type de classement
    func formattedValue(for type: LeaderboardType) -> String {
        switch type {
        case .flightHours:
            let hours = value / 3600
            let minutes = (value % 3600) / 60
            return "\(hours)h\(String(format: "%02d", minutes))"
        case .totalFlights:
            return "\(value) vols"
        case .level:
            return "Niv. \(level)"
        case .longestStreak:
            return "\(value) jours"
        }
    }
}

/// Rang de l'utilisateur dans un classement
struct UserRank {
    let rank: Int
    let total: Int
    let value: Int
    let percentile: Double

    var percentileText: String {
        if percentile <= 1 {
            return "Top 1%"
        } else if percentile <= 5 {
            return "Top 5%"
        } else if percentile <= 10 {
            return "Top 10%"
        } else if percentile <= 25 {
            return "Top 25%"
        } else if percentile <= 50 {
            return "Top 50%"
        } else {
            return "\(Int(percentile))%"
        }
    }
}

// MARK: - Leaderboard Errors

enum LeaderboardError: LocalizedError {
    case notAuthenticated
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .networkError(let msg):
            return "Erreur réseau: \(msg)"
        }
    }
}

// MARK: - LeaderboardService

@Observable
final class LeaderboardService {
    static let shared = LeaderboardService()

    // MARK: - Properties

    private let databases: Databases

    /// Cache des classements (type -> scope -> entries)
    private var leaderboardCache: [LeaderboardType: [LeaderboardScope: [LeaderboardEntry]]] = [:]

    /// Cache des rangs utilisateur
    private var userRankCache: [LeaderboardType: UserRank] = [:]

    /// Date de dernière mise à jour du cache
    private var lastCacheUpdate: Date?

    /// Durée de validité du cache (5 minutes)
    private let cacheDuration: TimeInterval = 300

    private(set) var isLoading = false

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases
    }

    // MARK: - Public Methods

    /// Récupère le classement global
    func getGlobalLeaderboard(type: LeaderboardType, limit: Int = 50) async throws -> [LeaderboardEntry] {
        // Vérifier le cache
        if let cached = getCachedLeaderboard(type: type, scope: .global), !isCacheExpired() {
            return Array(cached.prefix(limit))
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.orderDesc(type.sortField),
                    Query.limit(limit)
                ]
            )

            let entries = parseLeaderboardEntries(from: documents.documents, type: type)

            // Mettre en cache
            cacheLeaderboard(entries, type: type, scope: .global)

            return entries
        } catch {
            logError("Failed to fetch global leaderboard: \(error.localizedDescription)", category: .general)
            throw LeaderboardError.networkError(error.localizedDescription)
        }
    }

    /// Récupère le classement national (basé sur homeLocationName)
    func getNationalLeaderboard(type: LeaderboardType, country: String, limit: Int = 50) async throws -> [LeaderboardEntry] {
        isLoading = true
        defer { isLoading = false }

        do {
            // Note: Appwrite ne supporte pas les requêtes LIKE/CONTAINS facilement
            // On récupère plus de résultats et on filtre côté client
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.orderDesc(type.sortField),
                    Query.limit(500)  // Récupérer plus pour filtrer
                ]
            )

            // Filtrer par pays
            let filteredDocs = documents.documents.filter { doc in
                if let location = (doc.data["homeLocationName"] as? AnyCodable)?.value as? String {
                    return location.localizedCaseInsensitiveContains(country)
                }
                return false
            }

            let entries = parseLeaderboardEntries(from: Array(filteredDocs.prefix(limit)), type: type)

            return entries
        } catch {
            logError("Failed to fetch national leaderboard: \(error.localizedDescription)", category: .general)
            throw LeaderboardError.networkError(error.localizedDescription)
        }
    }

    /// Récupère le rang de l'utilisateur courant dans un classement
    func getUserRank(type: LeaderboardType) async throws -> UserRank {
        guard let profile = UserService.shared.currentUserProfile else {
            throw LeaderboardError.notAuthenticated
        }

        // Vérifier le cache
        if let cached = userRankCache[type], !isCacheExpired() {
            return cached
        }

        isLoading = true
        defer { isLoading = false }

        let userValue: Int
        switch type {
        case .flightHours:
            userValue = profile.totalFlightSeconds
        case .totalFlights:
            userValue = profile.totalFlights
        case .level:
            userValue = profile.xpTotal
        case .longestStreak:
            userValue = profile.longestStreak
        }

        do {
            // Compter combien d'utilisateurs ont une valeur supérieure
            let aboveCount = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.greaterThan(type.sortField, value: userValue),
                    Query.limit(1)  // On veut juste le count
                ]
            )

            // Compter le total d'utilisateurs
            let totalCount = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                queries: [Query.limit(1)]
            )

            let rank = aboveCount.total + 1
            let total = totalCount.total
            let percentile = total > 0 ? Double(rank) / Double(total) * 100 : 100

            let userRank = UserRank(
                rank: rank,
                total: total,
                value: userValue,
                percentile: percentile
            )

            // Mettre en cache
            userRankCache[type] = userRank

            return userRank
        } catch {
            logError("Failed to get user rank: \(error.localizedDescription)", category: .general)
            throw LeaderboardError.networkError(error.localizedDescription)
        }
    }

    /// Invalide le cache pour forcer un rafraîchissement
    func invalidateCache() {
        leaderboardCache.removeAll()
        userRankCache.removeAll()
        lastCacheUpdate = nil
    }

    /// Nettoie les données locales (déconnexion)
    func clearLocalData() {
        invalidateCache()
    }

    // MARK: - Private Methods

    private func parseLeaderboardEntries(from documents: [Document<[String: AnyCodable]>], type: LeaderboardType) -> [LeaderboardEntry] {
        var entries: [LeaderboardEntry] = []

        for (index, doc) in documents.enumerated() {
            let data = doc.data

            // Extraire les valeurs
            let getValue: (String) -> Any? = { key in
                if let anyCodable = data[key] as? AnyCodable {
                    return anyCodable.value
                }
                return data[key]
            }

            let value: Int
            switch type {
            case .flightHours:
                value = getValue("totalFlightSeconds") as? Int ?? 0
            case .totalFlights:
                value = getValue("totalFlights") as? Int ?? 0
            case .level:
                value = getValue("xpTotal") as? Int ?? 0
            case .longestStreak:
                value = getValue("longestStreak") as? Int ?? 0
            }

            let entry = LeaderboardEntry(
                id: doc.id,
                rank: index + 1,
                oderId: doc.id,
                displayName: getValue("displayName") as? String ?? "Pilote",
                username: getValue("username") as? String ?? "pilot",
                profilePhotoFileId: getValue("profilePhotoFileId") as? String,
                value: value,
                level: getValue("level") as? Int ?? 1
            )

            entries.append(entry)
        }

        return entries
    }

    private func getCachedLeaderboard(type: LeaderboardType, scope: LeaderboardScope) -> [LeaderboardEntry]? {
        return leaderboardCache[type]?[scope]
    }

    private func cacheLeaderboard(_ entries: [LeaderboardEntry], type: LeaderboardType, scope: LeaderboardScope) {
        if leaderboardCache[type] == nil {
            leaderboardCache[type] = [:]
        }
        leaderboardCache[type]?[scope] = entries
        lastCacheUpdate = Date()
    }

    private func isCacheExpired() -> Bool {
        guard let lastUpdate = lastCacheUpdate else { return true }
        return Date().timeIntervalSince(lastUpdate) > cacheDuration
    }
}
