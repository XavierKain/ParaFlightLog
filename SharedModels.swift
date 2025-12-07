//
//  SharedModels.swift
//  ParaFlightLog
//
//  DTO (Data Transfer Objects) partagés entre iOS et Watch
//  Target: iOS + Watch
//

import Foundation

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
         maxGForce: Double? = nil) {
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
    }
}
