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
