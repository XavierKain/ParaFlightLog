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
    var name: String
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

    init(id: UUID = UUID(), name: String, size: String? = nil, type: String? = nil, color: String? = nil, photoData: Data? = nil, isArchived: Bool = false, createdAt: Date = Date(), displayOrder: Int = 0) {
        self.id = id
        self.name = name
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

    /// Convertit en DTO avec photo compressée pour la Watch (max 50KB)
    func toDTOForWatch() -> WingDTO {
        var compressedPhotoData: Data? = nil

        if let originalData = photoData, let image = UIImage(data: originalData) {
            // Redimensionner l'image pour la Watch (max 100x100)
            let maxSize: CGFloat = 100
            let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

            // Format explicitement non-opaque pour conserver la transparence
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false

            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            let resizedImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }

            // Utiliser PNG pour conserver la transparence (pas JPEG)
            compressedPhotoData = resizedImage.pngData()
        }

        return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: compressedPhotoData, displayOrder: displayOrder)
    }

    /// Convertit en DTO sans photo (fallback si la sync avec images échoue)
    func toDTOWithoutPhoto() -> WingDTO {
        return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
    }

    /// Convertit en DTO avec miniature pour la Watch (48x48 max)
    /// Envoie le PNG original si petit, sinon redimensionne en préservant la transparence
    func toDTOWithThumbnail() -> WingDTO {
        // Pas de photo = pas de miniature
        guard let originalData = photoData else {
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
        }

        // Si l'image originale est petite (< 10KB), l'envoyer telle quelle
        // Cela préserve parfaitement la transparence des PNG
        if originalData.count < 10 * 1024 {
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: originalData, displayOrder: displayOrder)
        }

        // Pour les images plus grandes, redimensionner
        guard let image = UIImage(data: originalData) else {
            return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil, displayOrder: displayOrder)
        }

        // Miniature pour la Watch (48x48 pixels max)
        let maxSize: CGFloat = 48
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        // Utiliser UIGraphicsImageRenderer avec format non-opaque pour la transparence
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1.0  // Éviter le scale retina pour garder la taille exacte

        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resizedImage = renderer.image { context in
            // Effacer avec transparent (pas de couleur de fond)
            context.cgContext.clear(CGRect(origin: .zero, size: newSize))
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        // Toujours encoder en PNG pour préserver la transparence
        let thumbnailData = resizedImage.pngData()

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
         createdAt: Date = Date()) {
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
