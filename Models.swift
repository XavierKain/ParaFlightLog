//
//  Models.swift
//  ParaFlightLog
//
//  SwiftData models pour la persistence côté iOS
//  Target: iOS only
//

import Foundation
import SwiftData
import UIKit

// MARK: - DateFormatter Cache

/// Cache statique des DateFormatters pour éviter les créations répétées (coûteuses)
private enum DateFormattersCache {
    static let mediumDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}

// MARK: - Wing
/// Modèle SwiftData représentant une voile de parapente
@Model
final class Wing {
    var id: UUID
    var name: String         // Nom du modèle (ex: "Moustache M1")
    var brand: String?       // Marque/fabricant (ex: "Flare")
    var size: String?
    var type: String?        // ex: "Soaring", "Cross", "Acro"
    var color: String?       // texte libre ou hex
    var photoData: Data?     // Photo de la voile stockée en Data
    var isArchived: Bool     // Voile archivée (masquée par défaut)
    var createdAt: Date
    var displayOrder: Int    // Ordre d'affichage personnalisé (0 = premier)

    // Relation inverse : tous les vols effectués avec cette voile
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

    /// Convertit le modèle SwiftData en DTO pour l'envoi vers la Watch
    func toDTO() -> WingDTO {
        WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: photoData, displayOrder: displayOrder)
    }

    /// Convertit en DTO avec photo redimensionnée pour la Watch (max 120x120)
    /// Préserve la transparence PNG pour s'adapter à tous les fonds
    func toDTOForWatch() -> WingDTO {
        var compressedPhotoData: Data? = nil

        if let originalData = photoData, let image = UIImage(data: originalData) {
            compressedPhotoData = image.resizedForWatch()
        }

        return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: compressedPhotoData, displayOrder: displayOrder)
    }

    /// Convertit en DTO sans photo (fallback si la sync avec images échoue)
    func toDTOWithoutPhoto() -> WingDTO {
        return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
    }

    /// Convertit en DTO avec miniature pour la Watch (72x72 max)
    /// Préserve la transparence PNG pour s'adapter à tous les fonds
    func toDTOWithThumbnail() -> WingDTO {
        // Pas de photo = pas de miniature
        guard let originalData = photoData else {
            Log.info("Wing \(name): no photo data", category: .watchSync)
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
        }

        guard let image = UIImage(data: originalData) else {
            Log.warning("Wing \(name): failed to create UIImage from \(originalData.count) bytes", category: .watchSync)
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
        }

        guard let thumbnailData = image.thumbnailForWatch() else {
            Log.warning("Wing \(name): thumbnailForWatch() returned nil", category: .watchSync)
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
        }

        Log.info("Wing \(name): thumbnail created, \(thumbnailData.count) bytes", category: .watchSync)
        return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: thumbnailData, displayOrder: displayOrder)
    }
}

// MARK: - Flight
/// Modèle SwiftData représentant un vol de parapente
@Model
final class Flight {
    var id: UUID
    var startDate: Date
    var endDate: Date
    var durationSeconds: Int
    var spotName: String?    // ex: "Cumbuco", "Saint-Gervais-les-Bains"
    var latitude: Double?
    var longitude: Double?
    var flightType: String?  // ex: "Soaring", "Thermique", "Gonflage"
    var notes: String?
    var createdAt: Date

    // Données de tracking (depuis Watch)
    var startAltitude: Double?      // Altitude de départ (m)
    var maxAltitude: Double?         // Altitude maximale (m)
    var endAltitude: Double?         // Altitude d'atterrissage (m)
    var totalDistance: Double?       // Distance totale parcourue (m)
    var maxSpeed: Double?            // Vitesse maximale au sol (m/s)
    var maxGForce: Double?           // G-force maximale (G)

    // Trace GPS du vol (stockée en JSON)
    var gpsTrackData: Data?

    // MARK: - Cloud Sync
    /// ID du document Appwrite dans la collection flights
    var cloudId: String?
    /// Date de dernière synchronisation avec le cloud
    var cloudSyncedAt: Date?
    /// Vol privé (visible uniquement par le propriétaire) - fonctionnalité premium
    var isPrivate: Bool = false
    /// Indique si le vol doit être synchronisé (créé/modifié localement)
    var needsSync: Bool = true
    /// Dernière erreur de synchronisation (pour affichage/debug)
    var syncError: String?

    // MARK: - Social (cache cloud)
    /// Nombre de likes sur ce vol (cache local du cloud)
    var likeCount: Int = 0
    /// Nombre de commentaires sur ce vol (cache local du cloud)
    var commentCount: Int = 0
    /// Indique si la trace GPS est uploadée dans le cloud
    var hasGpsTrackInCloud: Bool = false

    // Relation : la voile utilisée pour ce vol
    var wing: Wing?

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
         gpsTrackData: Data? = nil,
         cloudId: String? = nil,
         cloudSyncedAt: Date? = nil,
         isPrivate: Bool = false,
         needsSync: Bool = true,
         syncError: String? = nil,
         likeCount: Int = 0,
         commentCount: Int = 0,
         hasGpsTrackInCloud: Bool = false) {
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
        self.cloudId = cloudId
        self.cloudSyncedAt = cloudSyncedAt
        self.isPrivate = isPrivate
        self.needsSync = needsSync
        self.syncError = syncError
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.hasGpsTrackInCloud = hasGpsTrackInCloud
    }

    /// Décoder la trace GPS
    var gpsTrack: [GPSTrackPoint]? {
        guard let data = gpsTrackData else { return nil }
        do {
            return try JSONDecoder().decode([GPSTrackPoint].self, from: data)
        } catch {
            Log.error("Failed to decode GPS track: \(error.localizedDescription)", category: .flight)
            return nil
        }
    }

    /// Encoder et sauvegarder la trace GPS
    func setGPSTrack(_ points: [GPSTrackPoint]) {
        do {
            gpsTrackData = try JSONEncoder().encode(points)
        } catch {
            Log.error("Failed to encode GPS track: \(error.localizedDescription)", category: .flight)
        }
    }

    /// Durée formatée (ex: "1h23" ou "45min")
    var durationFormatted: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }

    /// Date formatée pour l'affichage (utilise le cache pour les performances)
    var dateFormatted: String {
        DateFormattersCache.mediumDateTime.string(from: startDate)
    }
}
