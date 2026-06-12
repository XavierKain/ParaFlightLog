//
//  BadgeService.swift
//  ParaFlightLog
//
//  Service de gestion des badges et de la gamification
//  Vérification et attribution des badges basés sur les vols locaux (SwiftData)
//  100 % local : définitions embarquées + persistance UserDefaults
//  Target: iOS only
//

import Foundation

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

/// Modèle d'un badge (définition embarquée dans l'app)
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
}

/// Badge débloqué par l'utilisateur (persisté localement dans UserDefaults)
struct UserBadge: Identifiable, Codable, Equatable {
    let badgeId: String
    let earnedAt: Date

    var id: String { badgeId }
}

/// Badge obtenu avec ses détails complets
struct EarnedBadge: Identifiable, Equatable {
    let id: String
    let badge: Badge
    let earnedAt: Date
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

/// Statistiques calculées à partir des vols locaux (SwiftData)
struct BadgeStats {
    let totalFlights: Int
    let totalHours: Int
    let uniqueSpots: Int
    let longestStreak: Int
    let longestFlightHours: Int
    let maxAltitude: Int
    let maxDistanceKm: Int

    static let empty = BadgeStats(
        totalFlights: 0,
        totalHours: 0,
        uniqueSpots: 0,
        longestStreak: 0,
        longestFlightHours: 0,
        maxAltitude: 0,
        maxDistanceKm: 0
    )
}

// MARK: - BadgeService

@Observable
@MainActor
final class BadgeService {
    static let shared = BadgeService()

    // MARK: - Properties

    /// Tous les badges disponibles (définitions embarquées, triées par tier)
    let allBadges: [Badge]

    /// Badges débloqués par l'utilisateur (persistés dans UserDefaults)
    private(set) var userBadges: [UserBadge] = []

    /// IDs des badges obtenus (pour recherche rapide)
    private var earnedBadgeIds: Set<String> = []

    /// Clé de persistance UserDefaults
    private static let unlockedBadgesKey = "badges.unlocked"

    /// Seuils d'XP pour chaque niveau (niveau 1 = 0 XP)
    static let levelThresholds: [Int] = [
        0, 100, 200, 300, 400, 500,
        600, 800, 1000, 1200, 1400,
        1600, 1800, 2000, 2200, 2500,
        2800, 3100, 3500, 3900, 4300,
        4700, 5100, 5600, 6100, 6700,
        7300, 8000, 8700, 9500, 10500
    ]

    // MARK: - Init

    private init() {
        self.allBadges = Self.predefinedBadges.sorted { $0.tier < $1.tier }
        loadUnlockedBadges()
    }

    // MARK: - Public Methods

    /// Vérifie si un badge est obtenu
    func hasBadge(_ badgeId: String) -> Bool {
        earnedBadgeIds.contains(badgeId)
    }

    /// Retourne le badge correspondant à un ID
    func getBadge(_ badgeId: String) -> Badge? {
        allBadges.first { $0.id == badgeId }
    }

    /// Date d'obtention d'un badge (nil si non obtenu)
    func earnedDate(for badgeId: String) -> Date? {
        userBadges.first { $0.badgeId == badgeId }?.earnedAt
    }

    /// Badges obtenus avec leurs détails complets, triés du plus récent au plus ancien
    var earnedBadges: [EarnedBadge] {
        userBadges.compactMap { userBadge in
            guard let badge = getBadge(userBadge.badgeId) else { return nil }
            return EarnedBadge(id: userBadge.badgeId, badge: badge, earnedAt: userBadge.earnedAt)
        }
    }

    /// XP total cumulé via les badges débloqués
    var totalXP: Int {
        userBadges.reduce(0) { total, userBadge in
            total + (getBadge(userBadge.badgeId)?.xpReward ?? 0)
        }
    }

    /// Niveau actuel calculé à partir de l'XP total
    var level: Int {
        let xp = totalXP
        var currentLevel = 1
        for (index, threshold) in Self.levelThresholds.enumerated() where xp >= threshold {
            currentLevel = index + 1
        }
        return currentLevel
    }

    /// Calcule les statistiques nécessaires aux badges à partir des vols locaux
    func computeStats(flights: [Flight]) -> BadgeStats {
        let totalFlights = flights.count
        let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
        let uniqueSpots = Set(flights.compactMap { $0.spotName?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }).count
        let longestFlightSeconds = flights.map { $0.durationSeconds }.max() ?? 0
        let maxAltitude = flights.compactMap { $0.maxAltitude }.max() ?? 0
        let maxDistance = flights.compactMap { $0.totalDistance }.max() ?? 0

        return BadgeStats(
            totalFlights: totalFlights,
            totalHours: totalSeconds / 3600,
            uniqueSpots: uniqueSpots,
            longestStreak: Self.longestStreak(flights: flights),
            longestFlightHours: longestFlightSeconds / 3600,
            maxAltitude: Int(maxAltitude),
            maxDistanceKm: Int(maxDistance / 1000) // Distance stockée en mètres
        )
    }

    /// Calcule la progression pour un badge donné
    func getProgress(for badge: Badge, stats: BadgeStats) -> BadgeProgress {
        let currentValue: Int

        switch badge.requirementType {
        case .totalFlights:
            currentValue = stats.totalFlights
        case .totalHours:
            currentValue = stats.totalHours
        case .uniqueSpots:
            currentValue = stats.uniqueSpots
        case .consecutiveDays:
            currentValue = stats.longestStreak
        case .singleFlightDuration:
            currentValue = stats.longestFlightHours
        case .singleFlightAltitude:
            currentValue = stats.maxAltitude
        case .singleFlightDistance:
            currentValue = stats.maxDistanceKm
        }

        return BadgeProgress(
            badge: badge,
            currentValue: currentValue,
            targetValue: badge.requirementValue,
            isEarned: hasBadge(badge.id)
        )
    }

    /// Calcule la progression pour un badge donné à partir des vols
    func getProgress(for badge: Badge, flights: [Flight]) -> BadgeProgress {
        getProgress(for: badge, stats: computeStats(flights: flights))
    }

    /// Vérifie et attribue les badges mérités à partir des vols locaux
    /// Retourne la liste des nouveaux badges obtenus
    @discardableResult
    func checkBadges(flights: [Flight], wings: [Wing] = []) -> [Badge] {
        let stats = computeStats(flights: flights)
        var newBadges: [Badge] = []

        for badge in allBadges {
            // Ignorer si déjà obtenu
            if hasBadge(badge.id) {
                continue
            }

            let progress = getProgress(for: badge, stats: stats)

            if progress.currentValue >= badge.requirementValue {
                awardBadge(badge)
                newBadges.append(badge)
                logInfo("Badge earned: \(badge.name)", category: .general)
            }
        }

        if !newBadges.isEmpty {
            saveUnlockedBadges()
        }

        return newBadges
    }

    /// Réinitialise les badges débloqués (suppression des données locales)
    func clearLocalData() {
        userBadges = []
        earnedBadgeIds = []
        UserDefaults.standard.removeObject(forKey: Self.unlockedBadgesKey)
    }

    // MARK: - Private Methods

    /// Attribue un badge localement (cache + persistance différée)
    private func awardBadge(_ badge: Badge) {
        let userBadge = UserBadge(badgeId: badge.id, earnedAt: Date())
        userBadges.insert(userBadge, at: 0)
        earnedBadgeIds.insert(badge.id)
    }

    /// Charge les badges débloqués depuis UserDefaults
    private func loadUnlockedBadges() {
        guard let data = UserDefaults.standard.data(forKey: Self.unlockedBadgesKey) else {
            return
        }

        do {
            let badges = try JSONDecoder().decode([UserBadge].self, from: data)
            self.userBadges = badges.sorted { $0.earnedAt > $1.earnedAt }
            self.earnedBadgeIds = Set(badges.map { $0.badgeId })
        } catch {
            logError("Failed to load unlocked badges: \(error.localizedDescription)", category: .general)
        }
    }

    /// Sauvegarde les badges débloqués dans UserDefaults
    private func saveUnlockedBadges() {
        do {
            let data = try JSONEncoder().encode(userBadges)
            UserDefaults.standard.set(data, forKey: Self.unlockedBadgesKey)
        } catch {
            logError("Failed to save unlocked badges: \(error.localizedDescription)", category: .general)
        }
    }

    /// Calcule la plus longue série de jours consécutifs avec au moins un vol
    private static func longestStreak(flights: [Flight]) -> Int {
        let calendar = Calendar.current
        let flightDays = Set(flights.map { calendar.startOfDay(for: $0.startDate) })
        guard !flightDays.isEmpty else { return 0 }

        let sortedDays = flightDays.sorted()
        var longest = 1
        var current = 1

        for index in 1..<sortedDays.count {
            let daysBetween = calendar.dateComponents([.day], from: sortedDays[index - 1], to: sortedDays[index]).day ?? 0
            if daysBetween == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }

        return longest
    }

    // MARK: - Predefined Badges

    /// Badges prédéfinis (définitions embarquées dans l'app)
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
