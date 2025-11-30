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
    var createdAt: Date

    // Relation inverse : tous les vols effectués avec cette voile
    @Relationship(deleteRule: .cascade, inverse: \Flight.wing)
    var flights: [Flight]?

    init(id: UUID = UUID(), name: String, size: String? = nil, type: String? = nil, color: String? = nil, photoData: Data? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.size = size
        self.type = type
        self.color = color
        self.photoData = photoData
        self.createdAt = createdAt
    }

    /// Convertit le modèle SwiftData en DTO pour l'envoi vers la Watch
    func toDTO() -> WingDTO {
        WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: photoData)
    }

    /// Convertit en DTO avec photo compressée pour la Watch (max 50KB)
    func toDTOForWatch() -> WingDTO {
        var compressedPhotoData: Data? = nil

        if let originalData = photoData, let image = UIImage(data: originalData) {
            // Redimensionner l'image pour la Watch (max 100x100)
            let maxSize: CGFloat = 100
            let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

            // Utiliser UIGraphicsImageRenderer pour conserver la transparence
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let resizedImage = renderer.image { context in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }

            // Utiliser PNG pour conserver la transparence (pas JPEG)
            compressedPhotoData = resizedImage.pngData()

            if let data = compressedPhotoData {
                print("📸 Compressed photo from \(originalData.count / 1024)KB to \(data.count / 1024)KB (PNG with transparency)")
            }
        }

        return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: compressedPhotoData)
    }

    /// Convertit en DTO sans photo (fallback si la sync avec images échoue)
    func toDTOWithoutPhoto() -> WingDTO {
        return WingDTO(id: id, name: name, size: size, type: type, color: color, photoData: nil)
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
