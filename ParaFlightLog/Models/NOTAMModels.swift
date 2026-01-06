//
//  NOTAMModels.swift
//  ParaFlightLog
//
//  Modèles de données pour les NOTAM (Notice to Airmen) et zones d'alerte
//  Target: iOS only
//

import Foundation
import CoreLocation

// MARK: - CLLocationCoordinate2D Equatable Extension

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

// MARK: - NOTAM Types

/// Type de NOTAM
enum NOTAMType: String, Codable, CaseIterable, Identifiable {
    case tfr = "TFR"           // Temporary Flight Restriction
    case tra = "TRA"           // Temporary Reserved Airspace
    case danger = "DANGER"     // Zone dangereuse
    case prohibited = "P"      // Zone prohibée
    case restricted = "R"      // Zone restreinte
    case parachute = "PARA"    // Activité parachutage
    case drone = "DRONE"       // Zone drone
    case airshow = "AIRSHOW"   // Meeting aérien
    case military = "MIL"      // Exercice militaire
    case other = "OTHER"       // Autre

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tfr: return "Restriction temporaire"
        case .tra: return "Espace aérien réservé"
        case .danger: return "Zone dangereuse"
        case .prohibited: return "Zone prohibée"
        case .restricted: return "Zone restreinte"
        case .parachute: return "Parachutage"
        case .drone: return "Zone drone"
        case .airshow: return "Meeting aérien"
        case .military: return "Exercice militaire"
        case .other: return "Autre"
        }
    }

    var iconName: String {
        switch self {
        case .tfr: return "exclamationmark.triangle.fill"
        case .tra: return "clock.fill"
        case .danger: return "exclamationmark.octagon.fill"
        case .prohibited: return "xmark.octagon.fill"
        case .restricted: return "lock.fill"
        case .parachute: return "figure.fall"
        case .drone: return "airplane"
        case .airshow: return "sparkles"
        case .military: return "shield.fill"
        case .other: return "info.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .tfr, .danger, .prohibited: return "#FF3B30"  // Rouge
        case .tra, .restricted, .military: return "#FF9500"  // Orange
        case .parachute, .drone: return "#FFCC00"  // Jaune
        case .airshow: return "#5856D6"  // Violet
        case .other: return "#8E8E93"  // Gris
        }
    }
}

// MARK: - Altitude Range

/// Plage d'altitudes affectée par un NOTAM
struct AltitudeRange: Codable, Equatable {
    let floor: Int  // En pieds (ft)
    let ceiling: Int  // En pieds (ft)

    /// Vérifie si une altitude (en mètres) est dans la plage
    func contains(altitudeMeters: Double) -> Bool {
        let altitudeFeet = altitudeMeters * 3.28084
        return altitudeFeet >= Double(floor) && altitudeFeet <= Double(ceiling)
    }

    /// Format d'affichage (ex: "SFC - FL095" ou "1500ft - 3000ft")
    var displayString: String {
        let floorStr = floor == 0 ? "SFC" : (floor >= 10000 ? "FL\(floor / 100)" : "\(floor)ft")
        let ceilingStr = ceiling >= 10000 ? "FL\(ceiling / 100)" : "\(ceiling)ft"
        return "\(floorStr) - \(ceilingStr)"
    }

    /// Plage par défaut pour le vol libre (surface à 6500ft)
    static let freeFlight = AltitudeRange(floor: 0, ceiling: 6500)

    /// Plage illimitée
    static let unlimited = AltitudeRange(floor: 0, ceiling: 99999)
}

// MARK: - NOTAM Geometry

/// Géométrie d'un NOTAM (zone affectée)
enum NOTAMGeometry: Codable, Equatable {
    case circle(center: CLLocationCoordinate2D, radiusNM: Double)
    case polygon(coordinates: [CLLocationCoordinate2D])

    /// Vérifie si un point est dans la zone
    func contains(coordinate: CLLocationCoordinate2D) -> Bool {
        switch self {
        case .circle(let center, let radiusNM):
            let radiusMeters = radiusNM * 1852  // 1 NM = 1852 m
            let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let pointLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return pointLocation.distance(from: centerLocation) <= radiusMeters

        case .polygon(let coordinates):
            return isPointInPolygon(point: coordinate, polygon: coordinates)
        }
    }

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

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, center, radiusNM, coordinates
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
            let radiusNM = try container.decode(Double.self, forKey: .radiusNM)
            self = .circle(center: center, radiusNM: radiusNM)

        case .polygon:
            let coordsData = try container.decode([[Double]].self, forKey: .coordinates)
            let coordinates = coordsData.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            self = .polygon(coordinates: coordinates)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .circle(let center, let radiusNM):
            try container.encode(GeometryType.circle, forKey: .type)
            try container.encode([center.latitude, center.longitude], forKey: .center)
            try container.encode(radiusNM, forKey: .radiusNM)

        case .polygon(let coordinates):
            try container.encode(GeometryType.polygon, forKey: .type)
            let coordsData = coordinates.map { [$0.latitude, $0.longitude] }
            try container.encode(coordsData, forKey: .coordinates)
        }
    }
}

// MARK: - NOTAM

/// Représente un NOTAM (Notice to Airmen)
struct NOTAM: Codable, Identifiable, Equatable {
    let id: String
    let type: NOTAMType
    let title: String
    let description: String
    let effectiveStart: Date
    let effectiveEnd: Date
    let altitudes: AltitudeRange
    let geometry: NOTAMGeometry
    let source: String  // Ex: "SIA France", "FAA", "Eurocontrol"
    let rawText: String?  // Texte brut original du NOTAM

    /// Indique si le NOTAM est actuellement actif
    var isActive: Bool {
        let now = Date()
        return now >= effectiveStart && now <= effectiveEnd
    }

    /// Indique si le NOTAM expire bientôt (dans les 24h)
    var expiresSoon: Bool {
        let hoursUntilEnd = effectiveEnd.timeIntervalSinceNow / 3600
        return hoursUntilEnd > 0 && hoursUntilEnd <= 24
    }

    /// Durée restante formatée
    var remainingTimeFormatted: String {
        let remaining = effectiveEnd.timeIntervalSinceNow
        if remaining <= 0 { return "Expiré" }

        let hours = Int(remaining / 3600)
        let days = hours / 24

        if days > 0 {
            return "\(days)j \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            let minutes = Int(remaining / 60)
            return "\(minutes)min"
        }
    }

    /// Vérifie si le NOTAM affecte une position donnée
    func affects(coordinate: CLLocationCoordinate2D, altitude: Double? = nil) -> Bool {
        // Vérifier la géométrie
        guard geometry.contains(coordinate: coordinate) else { return false }

        // Vérifier l'altitude si fournie
        if let alt = altitude {
            return altitudes.contains(altitudeMeters: alt)
        }

        return true
    }
}

// MARK: - Alert Zone

/// Zone d'alerte personnalisée créée par l'utilisateur
struct AlertZone: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String?
    var isEnabled: Bool
    var notifyOnNewNOTAM: Bool
    var notifyBeforeFlight: Bool
    var notifyOnExpiration: Bool
    var geometry: ZoneGeometry
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        isEnabled: Bool = true,
        notifyOnNewNOTAM: Bool = true,
        notifyBeforeFlight: Bool = true,
        notifyOnExpiration: Bool = false,
        geometry: ZoneGeometry,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.notifyOnNewNOTAM = notifyOnNewNOTAM
        self.notifyBeforeFlight = notifyBeforeFlight
        self.notifyOnExpiration = notifyOnExpiration
        self.geometry = geometry
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Zone Geometry

/// Géométrie d'une zone d'alerte utilisateur
enum ZoneGeometry: Codable, Equatable {
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

    /// Centre de la zone (pour le centrage de la carte)
    var center: CLLocationCoordinate2D {
        switch self {
        case .circle(let center, _):
            return center

        case .polygon(let coordinates):
            guard !coordinates.isEmpty else {
                return CLLocationCoordinate2D(latitude: 0, longitude: 0)
            }
            let sumLat = coordinates.reduce(0.0) { $0 + $1.latitude }
            let sumLon = coordinates.reduce(0.0) { $0 + $1.longitude }
            return CLLocationCoordinate2D(
                latitude: sumLat / Double(coordinates.count),
                longitude: sumLon / Double(coordinates.count)
            )
        }
    }

    /// Rayon approximatif pour le zoom de la carte
    var approximateRadius: Double {
        switch self {
        case .circle(_, let radiusMeters):
            return radiusMeters

        case .polygon(let coordinates):
            let center = self.center
            let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
            var maxDistance: Double = 0

            for coord in coordinates {
                let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                let distance = location.distance(from: centerLocation)
                maxDistance = max(maxDistance, distance)
            }

            return maxDistance
        }
    }

    // Algorithme ray-casting pour point dans polygone
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

// MARK: - NOTAM Check Result

/// Résultat d'une vérification NOTAM avant vol
struct NOTAMCheckResult: Equatable {
    let checkDate: Date
    let location: CLLocationCoordinate2D
    let activeNOTAMs: [NOTAM]
    let warnings: [String]

    var hasActiveNOTAMs: Bool { !activeNOTAMs.isEmpty }
    var isFlightRestricted: Bool {
        activeNOTAMs.contains { $0.type == .prohibited || $0.type == .tfr }
    }

    var summaryText: String {
        if activeNOTAMs.isEmpty {
            return "Aucun NOTAM actif dans cette zone"
        } else if isFlightRestricted {
            return "⚠️ Vol interdit - \(activeNOTAMs.count) NOTAM(s) actif(s)"
        } else {
            return "⚡ \(activeNOTAMs.count) NOTAM(s) actif(s) - Vérifiez les restrictions"
        }
    }
}
