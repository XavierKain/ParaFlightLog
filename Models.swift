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
            // Calculer la taille cible (max 120x120)
            let maxSize: CGFloat = 120
            let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
            let targetSize = CGSize(
                width: max(1, round(image.size.width * scale)),
                height: max(1, round(image.size.height * scale))
            )

            // Utiliser UIGraphicsImageRenderer avec transparence
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = false  // Préserver la transparence

            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            let resizedImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }

            // Encoder en PNG pour préserver la transparence
            compressedPhotoData = resizedImage.pngData()
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
            logInfo("Wing \(name): no photo data", category: .watchSync)
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
        }

        guard let image = UIImage(data: originalData) else {
            logWarning("Wing \(name): failed to create UIImage from \(originalData.count) bytes", category: .watchSync)
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
        }

        // Calculer la taille cible (max 72x72)
        let maxSize: CGFloat = 72
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let targetSize = CGSize(
            width: max(1, round(image.size.width * scale)),
            height: max(1, round(image.size.height * scale))
        )

        // Utiliser UIGraphicsImageRenderer avec transparence
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false  // Préserver la transparence

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Encoder en PNG pour préserver la transparence
        guard let thumbnailData = resizedImage.pngData() else {
            logWarning("Wing \(name): pngData() returned nil", category: .watchSync)
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
        }

        logInfo("Wing \(name): thumbnail created \(targetSize.width)x\(targetSize.height), \(thumbnailData.count) bytes", category: .watchSync)
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

    /// Décoder la trace GPS
    var gpsTrack: [GPSTrackPoint]? {
        guard let data = gpsTrackData else { return nil }
        do {
            return try JSONDecoder().decode([GPSTrackPoint].self, from: data)
        } catch {
            logError("Failed to decode GPS track: \(error.localizedDescription)", category: .flight)
            return nil
        }
    }

    /// Encoder et sauvegarder la trace GPS
    func setGPSTrack(_ points: [GPSTrackPoint]) {
        do {
            gpsTrackData = try JSONEncoder().encode(points)
        } catch {
            logError("Failed to encode GPS track: \(error.localizedDescription)", category: .flight)
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

    /// Date formatée pour l'affichage
    var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.string(from: startDate)
    }
}
