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
    case speedflying = "Speedflying"
    case groundHandling = "Ground Handling"
    case other = "Other"

    var id: String { rawValue }

    /// SF Symbol used to represent this flight type.
    var symbolName: String {
        switch self {
        case .soaring: return "wind"
        case .thermal: return "sun.max"
        case .airSurfing: return "figure.surfing"
        case .speedflying: return "hare.fill"
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
        case .speedflying: return "Small wing, fast descents"
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
    /// Version stamp (Double, seconds since 1970) of the settings in a payload,
    /// carried in BOTH directions. Whoever changed a setting last wins: a side
    /// applies an incoming payload only when this is strictly newer than its own
    /// stamp. Without it the two devices had no ordering, so the iPhone's
    /// push-on-activation silently overwrote a change made on the Watch.
    static let settingsUpdatedAt = "settingsUpdatedAt"
    /// Marker (Bool) on a best-effort Watch->iPhone sendMessage when a flight
    /// STARTS, alongside "latitude"/"longitude" (Double). Drives the live
    /// presence heartbeat (Step C2). Ephemeral by design: sent via
    /// sendMessage only, never through the persistent outbox.
    static let flightStarted = "flightStarted"
}

// MARK: - SettingsSyncPolicy

/// The one rule both devices use to merge Watch-synced settings: the most
/// recent edit wins, wherever it was made. Kept as a pure function so the
/// policy is identical on iPhone and Watch and can be unit-tested — the bug it
/// replaces was that neither side had any notion of ordering, so the iPhone's
/// push-on-activation silently reverted a setting just changed on the Watch.
nonisolated enum SettingsSyncPolicy {
    /// - Parameters:
    ///   - incomingStamp: version stamp carried by the payload, nil when it
    ///     comes from a build that predates stamping.
    ///   - localStamp: stamp of the settings this device currently holds.
    /// - Returns: true when the payload should overwrite the local values.
    static func shouldApply(incomingStamp: Double?, localStamp: Double) -> Bool {
        // No stamp: an older app version on the other side. Accept it, so a
        // mixed-version pair keeps syncing the way it always did.
        guard let incomingStamp else { return true }
        // Strictly newer only: on a tie the local value stands, which stops two
        // devices bouncing the same payload back and forth.
        return incomingStamp > localStamp
    }
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

// MARK: - FlightActivityAttributes
//
// Lives HERE (and not in ParaFlightLog/ or ParaFlightLogWidgetExtension/)
// on purpose: this root-level file is the only source file explicitly
// compiled into BOTH the iOS app target and the widget extension target
// (pbxproj Sources phases: app 25C97992, widget extension 25145C44, watch
// app 25C97990), so both sides share ONE definition — ActivityKit matches
// activities by attributes type name + coding, so app and widget must agree.
//
// The whole block is compile-guarded: ActivityKit does not exist on watchOS
// (the current widget extension and the watch app build with SDKROOT =
// watchos), so the type simply vanishes from those targets.
#if canImport(ActivityKit)
import ActivityKit

/// Attributes of the Live Activity shown while a phone-tracked flight runs.
/// Static data (wing, flight type) is fixed at start; everything that can
/// change in-flight lives in `ContentState`.
nonisolated struct FlightActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        /// Elapsed flight time at the moment of the push (the visible timer
        /// ticks by itself via Text(timerInterval:), anchored to startDate).
        var elapsedSeconds: Int
        /// Current altitude in meters (GPS or simulator), nil when unknown.
        var altitude: Double?
        /// Current vertical speed in m/s (vario), nil when the vario is off.
        var verticalSpeed: Double?
        /// Takeoff spot name; carries a "(Simulation)" suffix for simulated flights.
        var spotName: String
        /// Flight start — the anchor for the self-ticking timer.
        var startDate: Date
    }

    /// Name of the wing being flown (fixed for the whole activity).
    var wingName: String
    /// Raw value of the FlightType chosen by the pilot.
    var flightType: String
}
#endif
