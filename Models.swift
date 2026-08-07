//
//  Models.swift
//  ParaFlightLog
//
//  SwiftData models for iOS-side persistence.
//  CloudKit-compatible: no unique constraints, optional relationships,
//  and every stored attribute is optional or has an inline default value.
//  Target: iOS only
//

import Foundation
import SwiftData
import UIKit

// MARK: - Wing
/// SwiftData model representing a paraglider wing
@Model
final class Wing {
    var id: UUID = UUID()
    var name: String = ""     // Model name (e.g. "Moustache M1")
    var brand: String?        // Manufacturer (e.g. "Flare")
    var size: String?
    var type: String?         // e.g. "Soaring", "Cross", "Acro"
    var color: String?        // free text or hex
    var photoData: Data?      // Wing photo stored as Data
    var isArchived: Bool = false   // Archived wings are hidden by default
    var createdAt: Date = Date()
    var displayOrder: Int = 0      // Custom display order (0 = first)

    // Maintenance / trim tracking. All optional or with an inline default so
    // the additions stay CloudKit-compatible (lightweight migration), like
    // every other stored attribute of this model.
    var previousHours: Double?          // Hours flown BEFORE this app (used wing / paper logbook)
    var purchaseDate: Date?
    var purchasedUsed: Bool = false     // Bought second-hand
    var lastTrimDate: Date?             // Last known trim (mainly for used wings)
    var serviceLogData: Data?           // JSON-encoded [WingServiceEvent]
    var smallTrimIntervalHours: Double? // e.g. 10 h (Flare Bandit break-in trim)
    var fullTrimIntervalHours: Double?  // e.g. 200 h
    var fullTrimIntervalMonths: Int?    // e.g. 24 ("200 h or 2 years, whichever first")

    // Inverse relationship: all flights flown with this wing.
    // Must stay optional for CloudKit compatibility.
    @Relationship(deleteRule: .cascade, inverse: \Flight.wing)
    var flights: [Flight]?

    init(id: UUID = UUID(), name: String, brand: String? = nil, size: String? = nil, type: String? = nil, color: String? = nil, photoData: Data? = nil, isArchived: Bool = false, createdAt: Date = Date(), displayOrder: Int = 0) {
        self.id = id
        self.name = name
        self.brand = brand
        self.size = size
        self.type = type
        self.color = color
        self.photoData = photoData
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.displayOrder = displayOrder
    }

    /// Decodes the service log (empty when the wing was never serviced).
    /// Same pattern as Flight.gpsTrack.
    var serviceLog: [WingServiceEvent] {
        guard let data = serviceLogData else { return [] }
        do {
            return try JSONDecoder().decode([WingServiceEvent].self, from: data)
        } catch {
            logError("Failed to decode wing service log: \(error.localizedDescription)", category: .dataController)
            return []
        }
    }

    /// Encodes and stores the service log. Same pattern as Flight.setGPSTrack.
    func setServiceLog(_ events: [WingServiceEvent]) {
        do {
            serviceLogData = try JSONEncoder().encode(events)
        } catch {
            logError("Failed to encode wing service log: \(error.localizedDescription)", category: .dataController)
        }
    }

    /// Appends one service event to the log
    func addServiceEvent(_ event: WingServiceEvent) {
        setServiceLog(serviceLog + [event])
    }

    /// Converts to a DTO with a small PNG thumbnail (max 72x72) for the Watch.
    /// Preserves PNG transparency so the image adapts to any background.
    func toDTOWithThumbnail() -> WingDTO {
        Wing.thumbnailDTO(from: toDTOWithoutPhoto(), photoData: photoData)
    }

    /// Converts to a DTO without any photo (fallback when the payload is too large).
    func toDTOWithoutPhoto() -> WingDTO {
        WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
    }

    /// Builds a thumbnail DTO (max 72x72 PNG) from a no-photo DTO + raw photo data.
    /// Static and model-free on purpose: `nonisolated` so it can run off the
    /// main actor (Task.detached) after snapshotting the photo Data on the
    /// main queue. UIGraphicsImageRenderer is thread-safe.
    nonisolated static func thumbnailDTO(from dto: WingDTO, photoData: Data?) -> WingDTO {
        // No photo = no thumbnail
        guard let originalData = photoData else {
            return dto
        }

        guard let image = UIImage(data: originalData) else {
            logWarning("Wing \(dto.name): failed to create UIImage from \(originalData.count) bytes", category: .watchSync)
            return dto
        }

        // Compute the target size (max 72x72)
        let maxSize: CGFloat = 72
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let targetSize = CGSize(
            width: max(1, round(image.size.width * scale)),
            height: max(1, round(image.size.height * scale))
        )

        // Use UIGraphicsImageRenderer preserving transparency
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Encode as PNG to keep transparency
        guard let thumbnailData = resizedImage.pngData() else {
            logWarning("Wing \(dto.name): pngData() returned nil", category: .watchSync)
            return dto
        }

        return WingDTO(id: dto.id, name: dto.name, size: dto.size, type: dto.type, color: dto.color, photoData: thumbnailData, displayOrder: dto.displayOrder)
    }
}

// MARK: - WingServiceEvent

/// The kind of wing service recorded in a wing's maintenance log.
/// `smallTrim` resets the small-trim hour counter; `fullTrim` resets both
/// counters (a full trim includes the small one); `check` resets nothing.
nonisolated enum WingServiceType: String, Codable, Sendable, CaseIterable {
    case check
    case smallTrim
    case fullTrim

    /// English display label for the UI
    var label: String {
        switch self {
        case .check: return "Check"
        case .smallTrim: return "Small trim"
        case .fullTrim: return "Full trim"
        }
    }
}

/// One entry of a wing's maintenance log, stored JSON-encoded in
/// `Wing.serviceLogData` (same pattern as Flight.gpsTrackData).
/// Pure value type: `nonisolated` so it can be encoded/decoded off the main actor.
nonisolated struct WingServiceEvent: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var date: Date
    var type: WingServiceType
    var note: String?
    /// The wing's total hours (previousHours + logged flights) when the
    /// service happened — lets the trim counters reset by hours, not only date.
    var hoursAtService: Double?
}

// MARK: - Spot
/// A flying site. `name` is the precise launch ("Punta Paloma") and `city`
/// the locality it belongs to ("Tarifa"). When only reverse geocoding is
/// available, both start equal to the geocoded city — editable afterwards.
///
/// `Flight.spotName` stays as a denormalized copy of `spot.name` so lists,
/// stats and backups keep working unchanged; DataController rewrites it on
/// rename/reassign.
@Model
final class Spot {
    var id: UUID = UUID()
    var name: String = ""
    var city: String?
    var latitude: Double?
    var longitude: Double?
    var createdAt: Date = Date()

    /// Compass points this launch works with ("N", "NE", "E", "SE", "S",
    /// "SW", "W", "NW") — drives the flyability hints in the weather views.
    /// Inline default keeps the field CloudKit-compatible.
    var windDirections: [String] = []

    /// Global community identity of this spot (Appwrite `community_spots`
    /// document ID, see CommunitySpotKey). Set on first share, nil until
    /// then. Optional keeps the field CloudKit-compatible.
    var communitySpotKey: String?

    /// The kind of flying this launch is known for, PINNED by the pilot.
    /// Raw value of a `FlightType` (e.g. "Soaring"). Optional/nil by default
    /// keeps the field CloudKit-compatible; when nil the UI falls back to the
    /// derived `dominantFlightType` (shown with an "(auto)" hint).
    var spotType: String?

    // Inverse of Flight.spot. Optional for CloudKit compatibility.
    @Relationship(deleteRule: .nullify, inverse: \Flight.spot)
    var flights: [Flight]?

    init(id: UUID = UUID(),
         name: String,
         city: String? = nil,
         latitude: Double? = nil,
         longitude: Double? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
    }

    /// Typed accessor bridging the raw `spotType` string storage — the type
    /// the pilot PINNED for this launch (nil when none is pinned).
    var spotTypeEnum: FlightType? {
        get { spotType.flatMap { FlightType(rawValue: $0) } }
        set { spotType = newValue?.rawValue }
    }

    /// The flight type flown most often at this spot, or nil when no flight
    /// here carries a type. This is the AUTO/derived spot type used when the
    /// pilot hasn't pinned one via `spotType`. Ties are broken deterministically
    /// by `FlightType.allCases` order.
    var dominantFlightType: FlightType? {
        guard let flights, !flights.isEmpty else { return nil }
        var counts: [FlightType: Int] = [:]
        for flight in flights {
            if let type = flight.flightTypeEnum {
                counts[type, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return nil }
        return FlightType.allCases
            .filter { counts[$0] != nil }
            .max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
    }

    /// The type shown for this spot: the pinned `spotTypeEnum` if set,
    /// otherwise the derived `dominantFlightType`. nil when neither exists.
    var effectiveFlightType: FlightType? {
        spotTypeEnum ?? dominantFlightType
    }
}

// MARK: - Flight
/// SwiftData model representing a paragliding flight
@Model
final class Flight {
    var id: UUID = UUID()
    var startDate: Date = Date()
    var endDate: Date = Date()
    var durationSeconds: Int = 0
    var spotName: String?    // e.g. "Cumbuco", "Saint-Gervais-les-Bains"
    var latitude: Double?
    var longitude: Double?
    var flightType: String?  // raw value of FlightType (e.g. "Soaring")
    var notes: String?
    var createdAt: Date = Date()

    // Tracking data (from Watch)
    var startAltitude: Double?      // Takeoff altitude (m)
    var maxAltitude: Double?        // Maximum altitude (m)
    var endAltitude: Double?        // Landing altitude (m)
    var totalDistance: Double?      // Total distance flown (m)
    var maxSpeed: Double?           // Maximum ground speed (m/s)
    var maxGForce: Double?          // Maximum G-force (G)

    // Weather snapshot at takeoff (best-effort, filled asynchronously by
    // WeatherService.captureSnapshot after the flight is saved).
    var takeoffWindSpeed: Double?       // km/h
    var takeoffWindGusts: Double?       // km/h
    var takeoffWindDirection: Double?   // degrees (direction the wind comes FROM)
    var takeoffTemperature: Double?     // °C

    // GPS track of the flight (stored as JSON)
    var gpsTrackData: Data?

    // Relationship: the wing used for this flight.
    // Must stay optional for CloudKit compatibility.
    var wing: Wing?

    // Relationship: the flying site (source of truth for name/city/coords).
    // `spotName` above remains a denormalized copy of `spot.name`.
    var spot: Spot?

    init(id: UUID = UUID(),
         wing: Wing? = nil,
         startDate: Date,
         endDate: Date,
         durationSeconds: Int,
         spotName: String? = nil,
         latitude: Double? = nil,
         longitude: Double? = nil,
         flightType: String? = nil,
         notes: String? = nil,
         createdAt: Date = Date(),
         startAltitude: Double? = nil,
         maxAltitude: Double? = nil,
         endAltitude: Double? = nil,
         totalDistance: Double? = nil,
         maxSpeed: Double? = nil,
         maxGForce: Double? = nil,
         gpsTrackData: Data? = nil) {
        self.id = id
        self.wing = wing
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.spotName = spotName
        self.latitude = latitude
        self.longitude = longitude
        self.flightType = flightType
        self.notes = notes
        self.createdAt = createdAt
        self.startAltitude = startAltitude
        self.maxAltitude = maxAltitude
        self.endAltitude = endAltitude
        self.totalDistance = totalDistance
        self.maxSpeed = maxSpeed
        self.maxGForce = maxGForce
        self.gpsTrackData = gpsTrackData
    }

    /// Typed accessor bridging the raw `flightType` string storage.
    var flightTypeEnum: FlightType? {
        get { flightType.flatMap { FlightType(rawValue: $0) } }
        set { flightType = newValue?.rawValue }
    }

    /// Decodes the GPS track
    var gpsTrack: [GPSTrackPoint]? {
        guard let data = gpsTrackData else { return nil }
        do {
            return try JSONDecoder().decode([GPSTrackPoint].self, from: data)
        } catch {
            logError("Failed to decode GPS track: \(error.localizedDescription)", category: .flight)
            return nil
        }
    }

    /// Encodes and stores the GPS track
    func setGPSTrack(_ points: [GPSTrackPoint]) {
        do {
            gpsTrackData = try JSONEncoder().encode(points)
        } catch {
            logError("Failed to encode GPS track: \(error.localizedDescription)", category: .flight)
        }
    }

    /// Formatted duration (e.g. "1h23" or "45min")
    var durationFormatted: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }

    /// Formatted start date for display (uses the current locale)
    var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .autoupdatingCurrent
        return formatter.string(from: startDate)
    }
}

// MARK: - ArchivedSpotReport

/// A community condition report kept on the device so it can still be read
/// long after the server copy is gone.
///
/// `spot_reports` rows carry a 3-hour TTL: they answer "is it flyable RIGHT
/// NOW?", and the query that reads them filters on `expiresAt`. That makes
/// them useless as flight history — by the time you open a flight the evening
/// after, every report from that session has expired. So each report that
/// matters is copied here at the moment it is known: the pilot's own reports
/// when they are posted, and the other pilots' reports at the spot when a
/// flight is saved.
///
/// Reports are NOT linked to a flight by a relationship. A report exists
/// before the flight it describes (and may describe a flight that never
/// happened), the spot may only be resolved after landing, and the same
/// report legitimately belongs to several pilots' flights. Matching is done
/// at read time on spot key + time window — see
/// `DataController.conditionReports(for:)`.
@Model
final class ArchivedSpotReport {
    /// Appwrite row ID, the report's natural identity. Not a unique
    /// constraint (CloudKit forbids them) — writers de-duplicate on it.
    var id: String = ""
    var spotKey: String = ""
    var spotName: String?
    var userId: String = ""
    var pilotName: String = ""
    /// `ReportStatus` raw value; kept as a string so an unknown future status
    /// round-trips instead of failing to decode.
    var status: String = ""
    /// `WindForce` raw value.
    var windForce: String?
    var windDirectionDeg: Double?
    var wingSize: String?
    var note: String?
    var createdAt: Date = Date()
    /// True when this is the signed-in pilot's own report — it reads as "you"
    /// rather than as a stranger's opinion of the same air.
    var isMine: Bool = false

    init(id: String, spotKey: String, spotName: String?, userId: String,
         pilotName: String, status: String, windForce: String?,
         windDirectionDeg: Double?, wingSize: String?, note: String?,
         createdAt: Date, isMine: Bool) {
        self.id = id
        self.spotKey = spotKey
        self.spotName = spotName
        self.userId = userId
        self.pilotName = pilotName
        self.status = status
        self.windForce = windForce
        self.windDirectionDeg = windDirectionDeg
        self.wingSize = wingSize
        self.note = note
        self.createdAt = createdAt
        self.isMine = isMine
    }

    var statusEnum: ReportStatus? { ReportStatus(rawValue: status) }
    var windForceEnum: WindForce? { windForce.flatMap(WindForce.init(rawValue:)) }

    /// How far either side of a flight a report still describes that flight's
    /// air. Mirrors the report's own 3-hour relevance window: a report filed
    /// at launch and one filed after landing both have to land inside it.
    nonisolated static let flightMatchWindow: TimeInterval = 3 * 3600
}

// MARK: - TrashedFlight

/// A deleted flight, kept for a week so an accidental delete is recoverable.
///
/// Deliberately a SEPARATE table rather than a `deletedAt` flag on `Flight`.
/// Flights are read by a dozen `@Query` sites plus the stats, the community
/// share and the backup export; a flag would have to be excluded from every
/// one of them, and the day one is missed a deleted flight silently comes back
/// into someone's totals. Nothing here can leak: the row is not a `Flight`.
///
/// The flight itself is stored as an encoded `BackupFlight` — the same shape
/// the backup format uses — so restoring reuses a mapping that is already
/// exercised by import/export instead of a second, parallel one.
@Model
final class TrashedFlight {
    /// The original flight's id, so a restore lands back on the same identity
    /// (and a second restore cannot duplicate it).
    var id: UUID = UUID()
    var deletedAt: Date = Date()

    /// Denormalised so the trash list renders without decoding every payload.
    var flightDate: Date = Date()
    var durationSeconds: Int = 0
    var spotName: String?
    var flightType: String?

    /// Wing name at the time of deletion. Denormalised rather than resolved
    /// from the payload's `wingId`, because the wing itself may be retired or
    /// deleted before the pilot comes looking for the flight — and "which wing
    /// was it?" is half of how you tell two flights apart in the trash.
    /// nil on rows trashed before this was recorded.
    var wingName: String?

    /// JSON-encoded `BackupFlight`, GPS track included.
    var payload: Data = Data()

    init(id: UUID, deletedAt: Date, flightDate: Date, durationSeconds: Int,
         spotName: String?, flightType: String?, wingName: String? = nil, payload: Data) {
        self.id = id
        self.deletedAt = deletedAt
        self.flightDate = flightDate
        self.durationSeconds = durationSeconds
        self.spotName = spotName
        self.flightType = flightType
        self.wingName = wingName
        self.payload = payload
    }

    /// How long a deleted flight is kept before it is purged for good.
    nonisolated static let retention: TimeInterval = 7 * 24 * 3600

    /// Whole days left before this row is purged (0 = today).
    var daysLeft: Int {
        let remaining = deletedAt.addingTimeInterval(Self.retention).timeIntervalSinceNow
        return max(0, Int(remaining / 86400))
    }
}
