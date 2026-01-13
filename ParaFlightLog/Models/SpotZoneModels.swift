//
//  SpotZoneModels.swift
//  ParaFlightLog
//
//  Modèles pour le système de zones de spots communautaires
//  Permet de définir des zones polygonales, proposer des noms et voter
//  Target: iOS only
//

import Foundation
import CoreLocation

// MARK: - Trust Level

/// Niveau de confiance d'un utilisateur pour les actions sur les spots
enum TrustLevel: Int, Codable, Comparable {
    case nouveau = 0      // Par défaut - peut voter (poids 0.5)
    case actif = 1        // 5+ vols, 30+ jours - peut voter (poids 1.0)
    case confirme = 2     // 20+ vols, 3+ spots, 90+ jours - peut proposer des noms
    case expert = 3       // 50+ vols, 10+ spots, 180+ jours - peut dessiner des zones
    case moderateur = 4   // Manuel - tous les droits

    static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .nouveau: return "Nouveau"
        case .actif: return "Actif"
        case .confirme: return "Confirmé"
        case .expert: return "Expert"
        case .moderateur: return "Modérateur"
        }
    }

    var voteWeight: Double {
        switch self {
        case .nouveau: return 0.5
        case .actif: return 1.0
        case .confirme: return 1.5
        case .expert: return 2.0
        case .moderateur: return 3.0
        }
    }

    var canProposeName: Bool {
        self >= .confirme
    }

    var canDrawZone: Bool {
        self >= .expert
    }

    var maxZoneAreaKm2: Double {
        switch self {
        case .nouveau, .actif, .confirme: return 0  // Ne peut pas dessiner
        case .expert: return 10
        case .moderateur: return 25
        }
    }

    var badgeColor: String {
        switch self {
        case .nouveau: return "#8E8E93"    // Gris
        case .actif: return "#34C759"      // Vert
        case .confirme: return "#007AFF"   // Bleu
        case .expert: return "#AF52DE"     // Violet
        case .moderateur: return "#FF9500" // Orange
        }
    }
}

// MARK: - Zone Status

/// Statut d'une zone proposée
enum ZoneStatus: String, Codable {
    case draft = "draft"              // Brouillon (non soumis)
    case pending = "pending"          // En attente de votes
    case approved = "approved"        // Approuvée par la communauté
    case rejected = "rejected"        // Rejetée
    case expired = "expired"          // Expirée (pas assez de votes)
    case merged = "merged"            // Fusionnée avec une autre zone

    var displayName: String {
        switch self {
        case .draft: return "Brouillon"
        case .pending: return "En vote"
        case .approved: return "Approuvée"
        case .rejected: return "Rejetée"
        case .expired: return "Expirée"
        case .merged: return "Fusionnée"
        }
    }

    var color: String {
        switch self {
        case .draft: return "#8E8E93"
        case .pending: return "#FF9500"
        case .approved: return "#34C759"
        case .rejected: return "#FF3B30"
        case .expired: return "#8E8E93"
        case .merged: return "#007AFF"
        }
    }
}

// MARK: - Vote Type

enum ZoneVoteType: String, Codable {
    case approve = "approve"
    case reject = "reject"
}

// MARK: - Bounding Box

/// Boîte englobante pour pré-filtrage rapide
struct BoundingBox: Codable, Equatable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    /// Vérifie si un point est dans la bounding box
    func contains(coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLat &&
        coordinate.latitude <= maxLat &&
        coordinate.longitude >= minLon &&
        coordinate.longitude <= maxLon
    }

    /// Calcule la bounding box à partir d'un polygone
    static func from(coordinates: [CLLocationCoordinate2D]) -> BoundingBox? {
        guard !coordinates.isEmpty else { return nil }

        let lats = coordinates.map { $0.latitude }
        let lons = coordinates.map { $0.longitude }

        return BoundingBox(
            minLat: lats.min()!,
            maxLat: lats.max()!,
            minLon: lons.min()!,
            maxLon: lons.max()!
        )
    }

    /// Marge autour de la bounding box (en degrés, ~1km)
    func expanded(byDegrees margin: Double = 0.01) -> BoundingBox {
        BoundingBox(
            minLat: minLat - margin,
            maxLat: maxLat + margin,
            minLon: minLon - margin,
            maxLon: maxLon + margin
        )
    }
}

// MARK: - Zone Geometry

/// Géométrie d'une zone de spot (polygone ou cercle)
enum SpotZoneGeometry: Codable, Equatable {
    case circle(center: CLLocationCoordinate2D, radiusMeters: Double)
    case polygon(coordinates: [CLLocationCoordinate2D])

    /// Vérifie si un point est dans la zone
    func contains(coordinate: CLLocationCoordinate2D) -> Bool {
        switch self {
        case .circle(let center, let radiusMeters):
            let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let pointLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return pointLocation.distance(from: centerLocation) <= radiusMeters

        case .polygon(let coordinates):
            return isPointInPolygon(point: coordinate, polygon: coordinates)
        }
    }

    /// Calcule l'aire en km²
    var areaKm2: Double {
        switch self {
        case .circle(_, let radiusMeters):
            let radiusKm = radiusMeters / 1000
            return Double.pi * radiusKm * radiusKm

        case .polygon(let coordinates):
            return calculatePolygonAreaKm2(coordinates: coordinates)
        }
    }

    /// Centre de la zone
    var centroid: CLLocationCoordinate2D {
        switch self {
        case .circle(let center, _):
            return center

        case .polygon(let coordinates):
            guard !coordinates.isEmpty else {
                return CLLocationCoordinate2D(latitude: 0, longitude: 0)
            }
            let avgLat = coordinates.map { $0.latitude }.reduce(0, +) / Double(coordinates.count)
            let avgLon = coordinates.map { $0.longitude }.reduce(0, +) / Double(coordinates.count)
            return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
        }
    }

    /// Bounding box de la zone
    var boundingBox: BoundingBox {
        switch self {
        case .circle(let center, let radiusMeters):
            // Approximation: 1 degré ≈ 111km
            let marginDegrees = radiusMeters / 111000
            return BoundingBox(
                minLat: center.latitude - marginDegrees,
                maxLat: center.latitude + marginDegrees,
                minLon: center.longitude - marginDegrees,
                maxLon: center.longitude + marginDegrees
            )

        case .polygon(let coordinates):
            return BoundingBox.from(coordinates: coordinates) ?? BoundingBox(minLat: 0, maxLat: 0, minLon: 0, maxLon: 0)
        }
    }

    // MARK: - Private Helpers

    /// Algorithme ray-casting pour point dans polygone
    private func isPointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let xi = polygon[i].longitude
            let yi = polygon[i].latitude
            let xj = polygon[j].longitude
            let yj = polygon[j].latitude

            let intersect = ((yi > point.latitude) != (yj > point.latitude)) &&
                           (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi)

            if intersect {
                inside = !inside
            }
            j = i
        }

        return inside
    }

    /// Calcul de l'aire d'un polygone en km² (formule de Shoelace avec projection)
    private func calculatePolygonAreaKm2(coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 3 else { return 0 }

        // Conversion en mètres par rapport au centroïde
        let centroid = self.centroid
        let metersPerDegreeLat = 111320.0
        let metersPerDegreeLon = 111320.0 * cos(centroid.latitude * .pi / 180)

        var area: Double = 0
        let n = coordinates.count

        for i in 0..<n {
            let j = (i + 1) % n
            let xi = (coordinates[i].longitude - centroid.longitude) * metersPerDegreeLon
            let yi = (coordinates[i].latitude - centroid.latitude) * metersPerDegreeLat
            let xj = (coordinates[j].longitude - centroid.longitude) * metersPerDegreeLon
            let yj = (coordinates[j].latitude - centroid.latitude) * metersPerDegreeLat

            area += xi * yj - xj * yi
        }

        return abs(area) / 2 / 1_000_000  // Convertir m² en km²
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, center, radiusMeters, coordinates
    }

    private enum GeometryType: String, Codable {
        case circle, polygon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(GeometryType.self, forKey: .type)

        switch type {
        case .circle:
            let centerData = try container.decode([Double].self, forKey: .center)
            let center = CLLocationCoordinate2D(latitude: centerData[0], longitude: centerData[1])
            let radiusMeters = try container.decode(Double.self, forKey: .radiusMeters)
            self = .circle(center: center, radiusMeters: radiusMeters)

        case .polygon:
            let coordsData = try container.decode([[Double]].self, forKey: .coordinates)
            let coordinates = coordsData.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            self = .polygon(coordinates: coordinates)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .circle(let center, let radiusMeters):
            try container.encode(GeometryType.circle, forKey: .type)
            try container.encode([center.latitude, center.longitude], forKey: .center)
            try container.encode(radiusMeters, forKey: .radiusMeters)

        case .polygon(let coordinates):
            try container.encode(GeometryType.polygon, forKey: .type)
            let coordsData = coordinates.map { [$0.latitude, $0.longitude] }
            try container.encode(coordsData, forKey: .coordinates)
        }
    }
}

// MARK: - Spot Zone

/// Zone de spot définie par un utilisateur
struct SpotZone: Identifiable, Codable {
    let id: String
    let name: String
    let normalizedName: String
    let geometry: SpotZoneGeometry
    let boundingBox: BoundingBox
    let areaKm2: Double
    let createdByUserId: String
    let createdByUsername: String?
    let status: ZoneStatus
    let parentSpotId: String?

    // Votes
    let approvalWeight: Double
    let rejectionWeight: Double
    let voterCount: Int
    let votingEndsAt: Date?

    // Stats
    let flightCount: Int
    let uniquePilotCount: Int

    // Métadonnées
    let reason: String?
    let photoFileIds: [String]
    let createdAt: Date
    let updatedAt: Date?
    let mergedIntoZoneId: String?

    // Historique des noms
    let nameHistory: [NameHistoryEntry]

    var coordinate: CLLocationCoordinate2D {
        geometry.centroid
    }

    var approvalPercentage: Double {
        let total = approvalWeight + rejectionWeight
        guard total > 0 else { return 0 }
        return (approvalWeight / total) * 100
    }

    var isApproved: Bool {
        status == .approved
    }

    var votingTimeRemaining: TimeInterval? {
        guard let votingEndsAt = votingEndsAt else { return nil }
        return votingEndsAt.timeIntervalSinceNow
    }

    var formattedVotingTimeRemaining: String? {
        guard let remaining = votingTimeRemaining, remaining > 0 else { return nil }

        let days = Int(remaining / 86400)
        let hours = Int((remaining.truncatingRemainder(dividingBy: 86400)) / 3600)

        if days > 0 {
            return "\(days)j \(hours)h"
        } else if hours > 0 {
            let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)min"
        } else {
            let minutes = Int(remaining / 60)
            return "\(minutes) min"
        }
    }
}

// MARK: - Name History Entry

/// Entrée dans l'historique des noms d'un spot
struct NameHistoryEntry: Codable, Equatable {
    let name: String
    let changedAt: Date
    let changedByUserId: String
    let changedByUsername: String?
    let reason: String?
}

// MARK: - Zone Vote

/// Vote d'un utilisateur sur une zone
struct ZoneVote: Identifiable, Codable {
    let id: String
    let zoneId: String
    let odflightlogins: String
    let username: String?
    let vote: ZoneVoteType
    let weight: Double
    let reason: String?
    let createdAt: Date
    let updatedAt: Date?

    var isApproval: Bool {
        vote == .approve
    }
}

// MARK: - Create Zone Request

/// Requête de création d'une nouvelle zone
struct CreateZoneRequest: Codable {
    let name: String
    let geometry: SpotZoneGeometry
    let reason: String
    let parentSpotId: String?
    let photoFileIds: [String]

    var normalizedName: String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }
}

// MARK: - Vote Request

/// Requête de vote sur une zone
struct ZoneVoteRequest: Codable {
    let zoneId: String
    let vote: ZoneVoteType
    let reason: String?
}

// MARK: - Trust Criteria

/// Critères pour atteindre un niveau de confiance
struct TrustCriteria {
    let level: TrustLevel
    let minFlights: Int
    let minSpots: Int
    let minAccountAgeDays: Int
    let minApprovedZones: Int

    static let all: [TrustCriteria] = [
        TrustCriteria(level: .nouveau, minFlights: 0, minSpots: 0, minAccountAgeDays: 0, minApprovedZones: 0),
        TrustCriteria(level: .actif, minFlights: 5, minSpots: 0, minAccountAgeDays: 30, minApprovedZones: 0),
        TrustCriteria(level: .confirme, minFlights: 20, minSpots: 3, minAccountAgeDays: 90, minApprovedZones: 0),
        TrustCriteria(level: .expert, minFlights: 50, minSpots: 10, minAccountAgeDays: 180, minApprovedZones: 0),
        // moderateur est manuel
    ]

    static func levelFor(flights: Int, spots: Int, accountAgeDays: Int, approvedZones: Int, isModerator: Bool) -> TrustLevel {
        if isModerator { return .moderateur }

        var achievedLevel: TrustLevel = .nouveau

        for criteria in all {
            if flights >= criteria.minFlights &&
               spots >= criteria.minSpots &&
               accountAgeDays >= criteria.minAccountAgeDays &&
               approvedZones >= criteria.minApprovedZones {
                achievedLevel = criteria.level
            }
        }

        return achievedLevel
    }
}

// MARK: - Voting Constants

enum VotingConstants {
    static let approvalThreshold: Double = 0.6  // 60%
    static let minimumVoters: Int = 5
    static let minimumVoteWeight: Double = 8.0
    static let votingDurationDays: Int = 7
    static let maxExtensions: Int = 1
    static let extensionDays: Int = 7
    static let cooldownAfterRejectionDays: Int = 30
    static let localPilotBonusRadius: Double = 500  // mètres
    static let localPilotBonusWeight: Double = 0.5
    static let eligibilityRadiusKm: Double = 50
    static let maxVotesPerDay: Int = 10
}
