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
    // CloudKit : toutes les propriétés ont une valeur par défaut (exigence de la sync iCloud)
    var id: UUID = UUID()
    var name: String = ""    // Nom du modèle (ex: "Moustache M1")
    var brand: String?       // Marque/fabricant (ex: "Flare")
    var size: String?
    var type: String?        // ex: "Soaring", "Cross", "Acro"
    var color: String?       // texte libre ou hex
    var photoData: Data?     // Photo de la voile stockée en Data
    var isArchived: Bool = false  // Voile archivée (masquée par défaut)
    var createdAt: Date = Date()
    var displayOrder: Int = 0     // Ordre d'affichage personnalisé (0 = premier)

    // MARK: - Propriété & maintenance
    // Distinction clé de SoarX : les heures MATÉRIEL (voile possédée → retrim,
    // révision, revente) vs les heures d'EXPÉRIENCE pilote (toute voile volée).
    var isOwned: Bool = true            // À moi (true) ou empruntée/testée (false)
    var purchaseDate: Date?             // Date d'achat (voiles possédées)
    var soldDate: Date?                 // Date de revente (la voile reste dans l'historique)
    var initialHours: Double = 0        // Heures déjà au compteur à l'achat (occasion)
    var maintenanceIntervalHours: Double?   // Intervalle conseillé entre révisions (h), nil = pas de suivi
    var lastMaintenanceHours: Double = 0    // Compteur total (initialHours incluses) à la dernière révision
    var lastMaintenanceDate: Date?      // Date de la dernière révision/retrim

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

    // MARK: - Compteurs matériel (voiles possédées)

    /// Heures de vol enregistrées dans SoarX avec cette voile
    var loggedHours: Double {
        Double((flights ?? []).reduce(0) { $0 + $1.durationSeconds }) / 3600.0
    }

    /// Compteur TOTAL de la voile (heures à l'achat + heures enregistrées).
    /// C'est la valeur qui compte pour la maintenance et la revente.
    var totalAirframeHours: Double {
        initialHours + loggedHours
    }

    /// Heures depuis la dernière révision/retrim
    var hoursSinceMaintenance: Double {
        max(0, totalAirframeHours - lastMaintenanceHours)
    }

    /// True si l'intervalle de maintenance est dépassé (voiles possédées avec suivi)
    var isMaintenanceDue: Bool {
        guard isOwned, soldDate == nil, let interval = maintenanceIntervalHours, interval > 0 else { return false }
        return hoursSinceMaintenance >= interval
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
    // CloudKit : toutes les propriétés ont une valeur par défaut (exigence de la sync iCloud)
    var id: UUID = UUID()
    var startDate: Date = Date()
    var endDate: Date = Date()
    var durationSeconds: Int = 0
    var spotName: String?    // ex: "Cumbuco", "Saint-Gervais-les-Bains"
    var latitude: Double?
    var longitude: Double?
    var flightType: String?  // ex: "Soaring", "Thermique", "Gonflage"
    var notes: String?
    var createdAt: Date = Date()

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
