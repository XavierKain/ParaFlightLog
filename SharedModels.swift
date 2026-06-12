//
//  SharedModels.swift
//  ParaFlightLog
//
//  DTO (Data Transfer Objects) partagés entre iOS et Watch
//  Target: iOS + Watch
//

import Foundation

// MARK: - GPSTrackPoint
/// Point GPS pour la trace du vol
struct GPSTrackPoint: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let speed: Double?       // Vitesse en m/s
    let accuracy: Double?    // Précision horizontale en mètres

    init(id: UUID = UUID(), timestamp: Date = Date(), latitude: Double, longitude: Double, altitude: Double? = nil, speed: Double? = nil, accuracy: Double? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.accuracy = accuracy
    }
}

// MARK: - WingDTO
/// DTO pour transférer les voiles de l'iPhone vers la Watch
struct WingDTO: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let size: String?
    let type: String?
    let color: String?
    let photoData: Data?
    let displayOrder: Int

    init(id: UUID, name: String, size: String? = nil, type: String? = nil, color: String? = nil, photoData: Data? = nil, displayOrder: Int = 0) {
        self.id = id
        self.name = name
        self.size = size
        self.type = type
        self.color = color
        self.photoData = photoData
        self.displayOrder = displayOrder
    }

    /// Nom raccourci pour l'affichage sur Apple Watch
    /// Exemple: "Moustache M1 2025 18m" → "M1 2025 18m"
    /// Pour les autres voiles, garde le nom complet
    var shortName: String {
        // Seulement enlever "Moustache" au début
        if name.hasPrefix("Moustache ") {
            return String(name.dropFirst("Moustache ".count))
        }
        return name
    }
}

// MARK: - FlightDTO
/// DTO pour transférer les vols de la Watch vers l'iPhone
struct FlightDTO: Codable, Identifiable {
    let id: UUID
    let wingId: UUID
    let startDate: Date
    let endDate: Date
    let durationSeconds: Int
    let createdAt: Date

    // Nouvelles données de tracking
    let startAltitude: Double?      // Altitude de départ (m)
    let maxAltitude: Double?         // Altitude maximale (m)
    let endAltitude: Double?         // Altitude d'atterrissage (m)
    let totalDistance: Double?       // Distance totale parcourue (m)
    let maxSpeed: Double?            // Vitesse maximale au sol (m/s)
    let maxGForce: Double?           // G-force maximale (G)

    // Trace GPS du vol
    let gpsTrack: [GPSTrackPoint]?

    // Type de vol choisi au démarrage (optionnel — rétro-compatible avec les anciennes Watch)
    var flightType: String?

    init(id: UUID = UUID(),
         wingId: UUID,
         startDate: Date,
         endDate: Date,
         durationSeconds: Int,
         createdAt: Date = Date(),
         startAltitude: Double? = nil,
         maxAltitude: Double? = nil,
         endAltitude: Double? = nil,
         totalDistance: Double? = nil,
         maxSpeed: Double? = nil,
         maxGForce: Double? = nil,
         gpsTrack: [GPSTrackPoint]? = nil,
         flightType: String? = nil) {
        self.id = id
        self.wingId = wingId
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.startAltitude = startAltitude
        self.maxAltitude = maxAltitude
        self.endAltitude = endAltitude
        self.totalDistance = totalDistance
        self.maxSpeed = maxSpeed
        self.maxGForce = maxGForce
        self.gpsTrack = gpsTrack
        self.flightType = flightType
    }
}

// MARK: - Types de vol

/// Liste canonique des types de vol (partagée iPhone + Watch + Widget).
/// Stockés en clair dans Flight.flightType — les valeurs libres restent acceptées.
enum FlightTypes {
    static let soaring = "Soaring"
    static let thermal = "Thermique"
    static let glide = "Planée"
    static let airsurfing = "Airsurfing"
    static let groundHandling = "Gonflage"
    static let hikeAndFly = "Hike & Fly"
    static let cross = "Cross"

    /// Ordre d'affichage dans les sélecteurs
    static let all: [String] = [soaring, thermal, glide, airsurfing, groundHandling, hikeAndFly, cross]

    /// Icône SF Symbol associée à un type (fallback générique pour les valeurs libres)
    static func icon(for type: String?) -> String {
        switch type {
        case soaring: return "wind"
        case thermal: return "tornado"
        case glide: return "arrow.down.forward"
        case airsurfing: return "water.waves"
        case groundHandling: return "figure.walk"
        case hikeAndFly: return "figure.hiking"
        case cross: return "point.topleft.down.curvedto.point.bottomright.up"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - Widget Shared State (App Group)

/// État du vol en cours partagé entre l'app Watch et le widget via App Group
/// Écrit par l'app Watch au démarrage/arrêt d'un vol, lu par le widget pour
/// afficher le chrono en temps réel sur le cadran.
enum WidgetFlightState {
    static let appGroupId = "group.com.xavierkain.SoarX"
    private static let isFlyingKey = "widget.isFlying"
    private static let startDateKey = "widget.flightStartDate"
    private static let wingNameKey = "widget.wingName"

    /// Signale le début d'un vol au widget
    static func setFlying(startDate: Date, wingName: String?) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.set(true, forKey: isFlyingKey)
        defaults.set(startDate.timeIntervalSince1970, forKey: startDateKey)
        defaults.set(wingName, forKey: wingNameKey)
    }

    /// Signale la fin (ou l'abandon) d'un vol au widget
    static func clearFlying() {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.set(false, forKey: isFlyingKey)
        defaults.removeObject(forKey: startDateKey)
        defaults.removeObject(forKey: wingNameKey)
    }

    /// Lit l'état courant (utilisé par le widget)
    static func read() -> (isFlying: Bool, startDate: Date?, wingName: String?) {
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return (false, nil, nil) }
        let isFlying = defaults.bool(forKey: isFlyingKey)
        let interval = defaults.double(forKey: startDateKey)
        let startDate = interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        return (isFlying, startDate, defaults.string(forKey: wingNameKey))
    }
}
