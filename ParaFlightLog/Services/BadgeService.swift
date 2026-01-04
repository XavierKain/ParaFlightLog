//
//  BadgeService.swift
//  ParaFlightLog
//
//  Service de gestion des badges et de la gamification
//  Vérification et attribution des badges basés sur les statistiques utilisateur
//  Target: iOS only
//

import Foundation
import Appwrite

// MARK: - Badge Models

/// Catégories de badges
enum BadgeCategory: String, Codable, CaseIterable {
    case flights = "flights"
    case duration = "duration"
    case spots = "spots"
    case performance = "performance"
    case streak = "streak"

    var displayName: String {
        switch self {
        case .flights: return "Vols".localized
        case .duration: return "Durée".localized
        case .spots: return "Spots".localized
        case .performance: return "Performance".localized
        case .streak: return "Séries".localized
        }
    }

    var icon: String {
        switch self {
        case .flights: return "airplane"
        case .duration: return "clock.fill"
        case .spots: return "mappin.and.ellipse"
        case .performance: return "flame.fill"
        case .streak: return "calendar.badge.checkmark"
        }
    }
}

/// Niveaux de badges
enum BadgeTier: String, Codable, CaseIterable, Comparable {
    case bronze = "bronze"
    case silver = "silver"
    case gold = "gold"
    case platinum = "platinum"

    var displayName: String {
        switch self {
        case .bronze: return "Bronze"
        case .silver: return "Argent".localized
        case .gold: return "Or".localized
        case .platinum: return "Platine".localized
        }
    }

    var color: String {
        switch self {
        case .bronze: return "#CD7F32"
        case .silver: return "#C0C0C0"
        case .gold: return "#FFD700"
        case .platinum: return "#E5E4E2"
        }
    }

    static func < (lhs: BadgeTier, rhs: BadgeTier) -> Bool {
        let order: [BadgeTier] = [.bronze, .silver, .gold, .platinum]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}

/// Types de conditions pour les badges
enum BadgeRequirementType: String, Codable {
    case totalFlights = "total_flights"
    case totalHours = "total_hours"
    case uniqueSpots = "unique_spots"
    case singleFlightDuration = "single_flight_duration"
    case singleFlightAltitude = "single_flight_altitude"
    case singleFlightDistance = "single_flight_distance"
    case consecutiveDays = "consecutive_days"
}

/// Modèle d'un badge
struct Badge: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let nameEn: String
    let description: String
    let descriptionEn: String
    let icon: String
    let category: BadgeCategory
    let tier: BadgeTier
    let requirementType: BadgeRequirementType
    let requirementValue: Int
    let xpReward: Int

    /// Nom localisé
    var localizedName: String {
        Locale.current.language.languageCode?.identifier == "fr" ? name : nameEn
    }

    /// Description localisée
    var localizedDescription: String {
        Locale.current.language.languageCode?.identifier == "fr" ? description : descriptionEn
    }

    /// Initialisation depuis un dictionnaire Appwrite
    init(from data: [String: Any]) throws {
        guard let id = data["$id"] as? String else {
            throw BadgeError.invalidData("Missing $id")
        }

        self.id = id
        self.name = data["name"] as? String ?? ""
        self.nameEn = data["nameEn"] as? String ?? self.name
        self.description = data["description"] as? String ?? ""
        self.descriptionEn = data["descriptionEn"] as? String ?? self.description
        self.icon = data["icon"] as? String ?? "star.fill"

        if let categoryStr = data["category"] as? String,
           let category = BadgeCategory(rawValue: categoryStr) {
            self.category = category
        } else {
            self.category = .flights
        }

        if let tierStr = data["tier"] as? String,
           let tier = BadgeTier(rawValue: tierStr) {
            self.tier = tier
        } else {
            self.tier = .bronze
        }

        if let reqTypeStr = data["requirementType"] as? String,
           let reqType = BadgeRequirementType(rawValue: reqTypeStr) {
            self.requirementType = reqType
        } else {
            self.requirementType = .totalFlights
        }

        self.requirementValue = data["requirementValue"] as? Int ?? 1
        self.xpReward = data["xpReward"] as? Int ?? 50
    }

    /// Initialisation directe
    init(
        id: String,
        name: String,
        nameEn: String,
        description: String,
        descriptionEn: String,
        icon: String,
        category: BadgeCategory,
        tier: BadgeTier,
        requirementType: BadgeRequirementType,
        requirementValue: Int,
        xpReward: Int
    ) {
        self.id = id
        self.name = name
        self.nameEn = nameEn
        self.description = description
        self.descriptionEn = descriptionEn
        self.icon = icon
        self.category = category
        self.tier = tier
        self.requirementType = requirementType
        self.requirementValue = requirementValue
        self.xpReward = xpReward
    }
}

/// Badge obtenu par un utilisateur
struct UserBadge: Identifiable, Codable, Equatable {
    let id: String
    let oderId: String
    let badgeId: String
    let earnedAt: Date

    /// Initialisation depuis un dictionnaire Appwrite
    init(from data: [String: Any]) throws {
        guard let id = data["$id"] as? String else {
            throw BadgeError.invalidData("Missing $id")
        }

        self.id = id
        self.oderId = data["userId"] as? String ?? ""
        self.badgeId = data["badgeId"] as? String ?? ""

        if let earnedAtStr = data["earnedAt"] as? String,
           let date = ISO8601DateFormatter().date(from: earnedAtStr) {
            self.earnedAt = date
        } else {
            self.earnedAt = Date()
        }
    }

    init(id: String, userId: String, badgeId: String, earnedAt: Date) {
        self.id = id
        self.oderId = userId
        self.badgeId = badgeId
        self.earnedAt = earnedAt
    }
}

/// Progression vers un badge
struct BadgeProgress {
    let badge: Badge
    let currentValue: Int
    let targetValue: Int
    let isEarned: Bool

    var progress: Double {
        guard targetValue > 0 else { return isEarned ? 1.0 : 0.0 }
        return min(Double(currentValue) / Double(targetValue), 1.0)
    }

    var progressText: String {
        "\(currentValue)/\(targetValue)"
    }
}

// MARK: - Badge Errors

enum BadgeError: LocalizedError {
    case notAuthenticated
    case invalidData(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .invalidData(let msg):
            return "Données invalides: \(msg)"
        case .networkError(let msg):
            return "Erreur réseau: \(msg)"
        }
    }
}

// MARK: - BadgeService

@Observable
final class BadgeService {
    static let shared = BadgeService()

    // MARK: - Properties

    private let databases: Databases

    /// Cache des badges disponibles
    private(set) var allBadges: [Badge] = []

    /// Badges obtenus par l'utilisateur courant
    private(set) var userBadges: [UserBadge] = []

    /// IDs des badges obtenus (pour recherche rapide)
    private var earnedBadgeIds: Set<String> = []

    private(set) var isLoading = false

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases

        // Charger les badges prédéfinis si pas encore en base
        Task {
            await loadAllBadges()
        }
    }

    // MARK: - Public Methods

    /// Charge tous les badges disponibles depuis Appwrite
    func loadAllBadges() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.badgesCollectionId,
                queries: [Query.limit(100)]
            )

            var badges: [Badge] = []
            for doc in documents.documents {
                // Convertir AnyCodable en types natifs
                var nativeData: [String: Any] = [:]
                for (key, value) in doc.data {
                    if let anyCodable = value as? AnyCodable {
                        nativeData[key] = anyCodable.value
                    } else {
                        nativeData[key] = value
                    }
                }

                if let badge = try? Badge(from: nativeData) {
                    badges.append(badge)
                }
            }

            // Si aucun badge en base, utiliser les badges prédéfinis
            if badges.isEmpty {
                badges = Self.predefinedBadges
                logInfo("Using predefined badges (no badges in database)", category: .general)
            }

            await MainActor.run {
                self.allBadges = badges.sorted { $0.tier < $1.tier }
            }

            logInfo("Loaded \(badges.count) badges", category: .general)
        } catch {
            logError("Failed to load badges: \(error.localizedDescription)", category: .general)
            // Utiliser les badges prédéfinis en cas d'erreur
            await MainActor.run {
                self.allBadges = Self.predefinedBadges
            }
        }
    }

    /// Charge les badges obtenus par l'utilisateur
    func loadUserBadges(userId: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.userBadgesCollectionId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.limit(100)
                ]
            )

            var badges: [UserBadge] = []
            for doc in documents.documents {
                var nativeData: [String: Any] = [:]
                for (key, value) in doc.data {
                    if let anyCodable = value as? AnyCodable {
                        nativeData[key] = anyCodable.value
                    } else {
                        nativeData[key] = value
                    }
                }

                if let badge = try? UserBadge(from: nativeData) {
                    badges.append(badge)
                }
            }

            await MainActor.run {
                self.userBadges = badges.sorted { $0.earnedAt > $1.earnedAt }
                self.earnedBadgeIds = Set(badges.map { $0.badgeId })
            }

            logInfo("Loaded \(badges.count) user badges", category: .general)
        } catch {
            logError("Failed to load user badges: \(error.localizedDescription)", category: .general)
        }
    }

    /// Vérifie si un badge est obtenu
    func hasBadge(_ badgeId: String) -> Bool {
        earnedBadgeIds.contains(badgeId)
    }

    /// Retourne le badge correspondant à un ID
    func getBadge(_ badgeId: String) -> Badge? {
        allBadges.first { $0.id == badgeId }
    }

    /// Calcule la progression pour un badge donné
    func getProgress(for badge: Badge, profile: CloudUserProfile, uniqueSpots: Int = 0) -> BadgeProgress {
        let currentValue: Int

        switch badge.requirementType {
        case .totalFlights:
            currentValue = profile.totalFlights
        case .totalHours:
            currentValue = profile.totalFlightSeconds / 3600
        case .uniqueSpots:
            currentValue = uniqueSpots
        case .consecutiveDays:
            currentValue = profile.longestStreak
        case .singleFlightDuration, .singleFlightAltitude, .singleFlightDistance:
            // Ces badges nécessitent une vérification par vol
            currentValue = 0
        }

        return BadgeProgress(
            badge: badge,
            currentValue: currentValue,
            targetValue: badge.requirementValue,
            isEarned: hasBadge(badge.id)
        )
    }

    /// Erreurs rencontrées lors de la dernière attribution (pour debug)
    private(set) var lastAwardErrors: [String] = []

    /// Vérifie et attribue les badges mérités
    /// Retourne la liste des nouveaux badges obtenus
    @discardableResult
    func checkAndAwardBadges(
        profile: CloudUserProfile,
        uniqueSpots: Int = 0,
        maxAltitude: Double? = nil,
        maxDistance: Double? = nil,
        longestFlightSeconds: Int? = nil
    ) async throws -> [Badge] {
        guard let userId = UserService.shared.currentUserProfile?.id else {
            throw BadgeError.notAuthenticated
        }

        var newBadges: [Badge] = []
        var errors: [String] = []

        for badge in allBadges {
            // Ignorer si déjà obtenu
            if hasBadge(badge.id) {
                continue
            }

            let earned: Bool

            switch badge.requirementType {
            case .totalFlights:
                earned = profile.totalFlights >= badge.requirementValue

            case .totalHours:
                let totalHours = profile.totalFlightSeconds / 3600
                earned = totalHours >= badge.requirementValue

            case .uniqueSpots:
                earned = uniqueSpots >= badge.requirementValue

            case .consecutiveDays:
                earned = profile.longestStreak >= badge.requirementValue

            case .singleFlightDuration:
                if let seconds = longestFlightSeconds {
                    let hours = seconds / 3600
                    earned = hours >= badge.requirementValue
                } else {
                    earned = false
                }

            case .singleFlightAltitude:
                if let altitude = maxAltitude {
                    earned = Int(altitude) >= badge.requirementValue
                } else {
                    earned = false
                }

            case .singleFlightDistance:
                if let distance = maxDistance {
                    // Distance en km
                    earned = Int(distance / 1000) >= badge.requirementValue
                } else {
                    earned = false
                }
            }

            if earned {
                // Attribuer le badge
                do {
                    try await awardBadge(badge, toUserId: userId)
                    newBadges.append(badge)
                    logInfo("Badge earned: \(badge.name)", category: .general)
                } catch {
                    // Log détaillé de l'erreur pour debug
                    var errorDetail = "\(badge.name): "
                    if let appwriteError = error as? AppwriteError {
                        errorDetail += "\(appwriteError.message) (code: \(appwriteError.code ?? 0))"
                        logError("Appwrite error details - message: \(appwriteError.message), code: \(appwriteError.code ?? 0), type: \(appwriteError.type ?? "unknown")", category: .general)
                    } else {
                        errorDetail += error.localizedDescription
                    }
                    errors.append(errorDetail)
                    logError("Failed to award badge \(badge.name): \(error)", category: .general)
                }
            }
        }

        // Sauvegarder les erreurs pour debug
        await MainActor.run {
            self.lastAwardErrors = errors
        }

        // Ajouter l'XP pour les nouveaux badges
        if !newBadges.isEmpty {
            let totalXP = newBadges.reduce(0) { $0 + $1.xpReward }
            try? await UserService.shared.updateStats(addXP: totalXP)
        }

        return newBadges
    }

    /// Nettoie les données locales (déconnexion)
    func clearLocalData() {
        userBadges = []
        earnedBadgeIds = []
    }

    // MARK: - Private Methods

    /// Attribue un badge à un utilisateur
    private func awardBadge(_ badge: Badge, toUserId userId: String) async throws {
        let data: [String: Any] = [
            "userId": userId,
            "badgeId": badge.id,
            "earnedAt": Date().ISO8601Format()
        ]

        let document = try await databases.createDocument(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.userBadgesCollectionId,
            documentId: ID.unique(),
            data: data
        )

        // Mettre à jour le cache local
        var nativeData: [String: Any] = [:]
        for (key, value) in document.data {
            if let anyCodable = value as? AnyCodable {
                nativeData[key] = anyCodable.value
            } else {
                nativeData[key] = value
            }
        }

        if let userBadge = try? UserBadge(from: nativeData) {
            await MainActor.run {
                self.userBadges.insert(userBadge, at: 0)
                self.earnedBadgeIds.insert(badge.id)
            }
        }
    }

    // MARK: - Predefined Badges

    /// Badges prédéfinis (utilisés si la collection est vide)
    static let predefinedBadges: [Badge] = [
        // Catégorie Vols
        Badge(id: "first_flight", name: "Premier Vol", nameEn: "First Flight",
              description: "Complétez votre premier vol", descriptionEn: "Complete your first flight",
              icon: "airplane.departure", category: .flights, tier: .bronze,
              requirementType: .totalFlights, requirementValue: 1, xpReward: 50),

        Badge(id: "regular_pilot", name: "Pilote Régulier", nameEn: "Regular Pilot",
              description: "Complétez 10 vols", descriptionEn: "Complete 10 flights",
              icon: "airplane", category: .flights, tier: .bronze,
              requirementType: .totalFlights, requirementValue: 10, xpReward: 100),

        Badge(id: "dedicated_pilot", name: "Pilote Assidu", nameEn: "Dedicated Pilot",
              description: "Complétez 50 vols", descriptionEn: "Complete 50 flights",
              icon: "airplane.circle", category: .flights, tier: .silver,
              requirementType: .totalFlights, requirementValue: 50, xpReward: 250),

        Badge(id: "centurion", name: "Centurion", nameEn: "Centurion",
              description: "Complétez 100 vols", descriptionEn: "Complete 100 flights",
              icon: "airplane.circle.fill", category: .flights, tier: .gold,
              requirementType: .totalFlights, requirementValue: 100, xpReward: 500),

        Badge(id: "master_of_skies", name: "Maître des Airs", nameEn: "Master of Skies",
              description: "Complétez 500 vols", descriptionEn: "Complete 500 flights",
              icon: "crown.fill", category: .flights, tier: .platinum,
              requirementType: .totalFlights, requirementValue: 500, xpReward: 1000),

        // Catégorie Durée
        Badge(id: "first_hour", name: "Première Heure", nameEn: "First Hour",
              description: "Cumulez 1 heure de vol", descriptionEn: "Accumulate 1 hour of flight",
              icon: "clock", category: .duration, tier: .bronze,
              requirementType: .totalHours, requirementValue: 1, xpReward: 50),

        Badge(id: "ten_hours", name: "10 Heures", nameEn: "10 Hours",
              description: "Cumulez 10 heures de vol", descriptionEn: "Accumulate 10 hours of flight",
              icon: "clock.fill", category: .duration, tier: .bronze,
              requirementType: .totalHours, requirementValue: 10, xpReward: 100),

        Badge(id: "fifty_hours", name: "50 Heures", nameEn: "50 Hours",
              description: "Cumulez 50 heures de vol", descriptionEn: "Accumulate 50 hours of flight",
              icon: "clock.badge.checkmark", category: .duration, tier: .silver,
              requirementType: .totalHours, requirementValue: 50, xpReward: 250),

        Badge(id: "hundred_hours", name: "100 Heures", nameEn: "100 Hours",
              description: "Cumulez 100 heures de vol", descriptionEn: "Accumulate 100 hours of flight",
              icon: "clock.badge.checkmark.fill", category: .duration, tier: .gold,
              requirementType: .totalHours, requirementValue: 100, xpReward: 500),

        // Catégorie Spots
        Badge(id: "explorer", name: "Explorateur", nameEn: "Explorer",
              description: "Volez sur 5 spots différents", descriptionEn: "Fly at 5 different spots",
              icon: "map", category: .spots, tier: .bronze,
              requirementType: .uniqueSpots, requirementValue: 5, xpReward: 100),

        Badge(id: "globe_trotter", name: "Globe-Trotter", nameEn: "Globe Trotter",
              description: "Volez sur 20 spots différents", descriptionEn: "Fly at 20 different spots",
              icon: "map.fill", category: .spots, tier: .silver,
              requirementType: .uniqueSpots, requirementValue: 20, xpReward: 250),

        Badge(id: "traveler", name: "Voyageur", nameEn: "Traveler",
              description: "Volez sur 50 spots différents", descriptionEn: "Fly at 50 different spots",
              icon: "globe.europe.africa.fill", category: .spots, tier: .gold,
              requirementType: .uniqueSpots, requirementValue: 50, xpReward: 500),

        // Catégorie Performance
        Badge(id: "long_flight", name: "Vol Long", nameEn: "Long Flight",
              description: "Faites un vol de plus de 2 heures", descriptionEn: "Complete a flight over 2 hours",
              icon: "timer", category: .performance, tier: .silver,
              requirementType: .singleFlightDuration, requirementValue: 2, xpReward: 200),

        Badge(id: "marathon", name: "Marathonien", nameEn: "Marathon",
              description: "Faites un vol de plus de 4 heures", descriptionEn: "Complete a flight over 4 hours",
              icon: "timer.circle.fill", category: .performance, tier: .gold,
              requirementType: .singleFlightDuration, requirementValue: 4, xpReward: 400),

        Badge(id: "altitude_2000", name: "Altitude 2000", nameEn: "Altitude 2000",
              description: "Atteignez 2000m d'altitude", descriptionEn: "Reach 2000m altitude",
              icon: "arrow.up.to.line", category: .performance, tier: .silver,
              requirementType: .singleFlightAltitude, requirementValue: 2000, xpReward: 200),

        Badge(id: "altitude_3000", name: "Altitude 3000", nameEn: "Altitude 3000",
              description: "Atteignez 3000m d'altitude", descriptionEn: "Reach 3000m altitude",
              icon: "arrow.up.to.line.circle.fill", category: .performance, tier: .gold,
              requirementType: .singleFlightAltitude, requirementValue: 3000, xpReward: 400),

        Badge(id: "distance_50km", name: "Distance 50km", nameEn: "Distance 50km",
              description: "Parcourez 50km en un vol", descriptionEn: "Travel 50km in one flight",
              icon: "arrow.left.and.right", category: .performance, tier: .gold,
              requirementType: .singleFlightDistance, requirementValue: 50, xpReward: 400),

        Badge(id: "distance_100km", name: "Distance 100km", nameEn: "Distance 100km",
              description: "Parcourez 100km en un vol", descriptionEn: "Travel 100km in one flight",
              icon: "arrow.left.and.right.circle.fill", category: .performance, tier: .platinum,
              requirementType: .singleFlightDistance, requirementValue: 100, xpReward: 800),

        // Catégorie Streak
        Badge(id: "streak_7", name: "Série de 7", nameEn: "7-Day Streak",
              description: "Volez 7 jours consécutifs", descriptionEn: "Fly 7 consecutive days",
              icon: "calendar", category: .streak, tier: .bronze,
              requirementType: .consecutiveDays, requirementValue: 7, xpReward: 100),

        Badge(id: "streak_30", name: "Série de 30", nameEn: "30-Day Streak",
              description: "Volez 30 jours consécutifs", descriptionEn: "Fly 30 consecutive days",
              icon: "calendar.badge.checkmark", category: .streak, tier: .silver,
              requirementType: .consecutiveDays, requirementValue: 30, xpReward: 300),
    ]
}
