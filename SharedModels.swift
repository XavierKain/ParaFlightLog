//
//  SharedModels.swift
//  ParaFlightLog
//
//  DTOs (Data Transfer Objects) shared between iOS and Watch
//  Target: iOS + Watch
//

import Foundation

// MARK: - FlightType
/// Category of a flight session. Shared between iOS and Watch.
nonisolated enum FlightType: String, Codable, CaseIterable, Identifiable {
    case soaring = "Soaring"
    case thermal = "Thermal"
    case airSurfing = "Air Surfing"
    case groundHandling = "Ground Handling"
    case other = "Other"

    var id: String { rawValue }

    /// SF Symbol used to represent this flight type.
    var symbolName: String {
        switch self {
        case .soaring: return "wind"
        case .thermal: return "sun.max"
        case .airSurfing: return "figure.surfing"
        case .groundHandling: return "figure.walk"
        case .other: return "questionmark.circle"
        }
    }

    /// Short description shown next to the icon in the flight-type picker.
    var subtitle: String {
        switch self {
        case .soaring: return "Ridge / dynamic lift"
        case .thermal: return "Climbing in thermals"
        case .airSurfing: return "Speed riding / acro"
        case .groundHandling: return "Kiting on the ground"
        case .other: return "Anything else"
        }
    }
}

// MARK: - WatchSyncKeys
/// Keys and message types used by the Watch <-> iPhone WatchConnectivity protocol.
/// Kept in one place so both sides always agree.
nonisolated enum WatchSyncKeys {
    /// Message/userInfo payload key holding an encoded FlightDTO.
    static let flightData = "flightData"
    /// applicationContext key holding encoded [WingDTO].
    static let wingsData = "wingsData"
    /// applicationContext key holding watch settings.
    static let settingsData = "settingsData"
    /// Reply key: Bool, true when the iPhone persisted the flight.
    static let flightSaved = "flightSaved"
    /// Payload key: unique flight id (UUID string) used for deduplication and acks.
    static let flightId = "flightId"
    /// Marker (Bool) set on a Watch->iPhone payload carrying settings changed on the Watch.
    static let watchSettingsUpdate = "watchSettingsUpdate"
}

// MARK: - GPSTrackPoint
/// GPS point of a flight track
nonisolated struct GPSTrackPoint: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let speed: Double?       // Ground speed in m/s

    init(id: UUID = UUID(), timestamp: Date = Date(), latitude: Double, longitude: Double, altitude: Double? = nil, speed: Double? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
    }
}

// MARK: - WingDTO
/// DTO used to transfer wings from the iPhone to the Watch
nonisolated struct WingDTO: Codable, Identifiable, Hashable {
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

    /// Short display name for the Apple Watch.
    /// Strips a leading brand word when the name is long, e.g. "Moustache M1 2025 18m" -> "M1 2025 18m".
    var shortName: String {
        if name.hasPrefix("Moustache ") {
            return String(name.dropFirst("Moustache ".count))
        }
        return name
    }
}

// MARK: - FlightDTO
/// DTO used to transfer flights from the Watch to the iPhone
nonisolated struct FlightDTO: Codable, Identifiable {
    let id: UUID
    let wingId: UUID
    let startDate: Date
    let endDate: Date
    let durationSeconds: Int
    let createdAt: Date

    /// Flight category chosen by the pilot (raw value of FlightType)
    let flightType: String?

    // Tracking data
    let startAltitude: Double?      // Takeoff altitude (m)
    let maxAltitude: Double?        // Maximum altitude (m)
    let endAltitude: Double?        // Landing altitude (m)
    let totalDistance: Double?      // Total distance flown (m)
    let maxSpeed: Double?           // Maximum ground speed (m/s)
    let maxGForce: Double?          // Maximum G-force (G)

    // GPS track of the flight
    let gpsTrack: [GPSTrackPoint]?

    init(id: UUID = UUID(),
         wingId: UUID,
         startDate: Date,
         endDate: Date,
         durationSeconds: Int,
         createdAt: Date = Date(),
         flightType: String? = nil,
         startAltitude: Double? = nil,
         maxAltitude: Double? = nil,
         endAltitude: Double? = nil,
         totalDistance: Double? = nil,
         maxSpeed: Double? = nil,
         maxGForce: Double? = nil,
         gpsTrack: [GPSTrackPoint]? = nil) {
        self.id = id
        self.wingId = wingId
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.flightType = flightType
        self.startAltitude = startAltitude
        self.maxAltitude = maxAltitude
        self.endAltitude = endAltitude
        self.totalDistance = totalDistance
        self.maxSpeed = maxSpeed
        self.maxGForce = maxGForce
        self.gpsTrack = gpsTrack
    }
}
