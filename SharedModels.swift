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

    init(id: UUID, name: String, size: String? = nil, type: String? = nil, color: String? = nil, photoData: Data? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.type = type
        self.color = color
        self.photoData = photoData
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

    init(id: UUID = UUID(), wingId: UUID, startDate: Date, endDate: Date, durationSeconds: Int, createdAt: Date = Date()) {
        self.id = id
        self.wingId = wingId
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}
