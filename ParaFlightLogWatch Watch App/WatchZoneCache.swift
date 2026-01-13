//
//  WatchZoneCache.swift
//  ParaFlightLogWatch Watch App
//
//  Cache local des zones de spots pour la Watch
//  Synchronisé depuis l'iPhone via WatchConnectivity
//  Target: Watch only
//

import Foundation
import CoreLocation

// MARK: - Zone Cache Entry (léger pour Watch)

/// Version légère d'une zone pour la Watch
struct WatchZoneEntry: Codable, Identifiable {
    let id: String
    let name: String
    let centerLat: Double
    let centerLon: Double
    let radiusMeters: Double  // Approximation circulaire pour simplifier
    let boundingBox: WatchBoundingBox

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
    }

    /// Vérifie si une coordonnée est dans cette zone (approximation circulaire)
    func contains(coordinate: CLLocationCoordinate2D) -> Bool {
        // Pré-filtrage bounding box
        guard boundingBox.contains(coordinate: coordinate) else {
            return false
        }

        // Test circulaire
        let centerLocation = CLLocation(latitude: centerLat, longitude: centerLon)
        let pointLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return pointLocation.distance(from: centerLocation) <= radiusMeters
    }
}

/// Bounding box pour pré-filtrage rapide
struct WatchBoundingBox: Codable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    func contains(coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLat &&
        coordinate.latitude <= maxLat &&
        coordinate.longitude >= minLon &&
        coordinate.longitude <= maxLon
    }
}

// MARK: - Watch Zone Cache

@Observable
final class WatchZoneCache {
    static let shared = WatchZoneCache()

    private(set) var zones: [WatchZoneEntry] = []
    private(set) var lastUpdated: Date?

    private let userDefaultsKey = "watchZoneCache"
    private let userDefaultsDateKey = "watchZoneCacheDate"

    private init() {
        loadFromDisk()
    }

    // MARK: - Zone Matching

    /// Trouve le nom du spot correspondant à une coordonnée
    func findSpotName(at coordinate: CLLocationCoordinate2D) -> String? {
        // Filtrer les zones dont la bounding box contient le point
        let candidates = zones.filter { $0.boundingBox.contains(coordinate: coordinate) }

        // Tester chaque candidat
        for zone in candidates {
            if zone.contains(coordinate: coordinate) {
                return zone.name
            }
        }

        return nil
    }

    /// Vérifie si le cache contient des zones près d'une coordonnée
    func hasZonesNear(coordinate: CLLocationCoordinate2D, radiusKm: Double = 100) -> Bool {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return zones.contains { zone in
            let zoneLocation = CLLocation(latitude: zone.centerLat, longitude: zone.centerLon)
            return location.distance(from: zoneLocation) <= radiusKm * 1000
        }
    }

    // MARK: - Cache Update

    /// Met à jour le cache avec de nouvelles zones (appelé depuis WatchConnectivity)
    func updateZones(_ newZones: [WatchZoneEntry]) {
        zones = newZones
        lastUpdated = Date()
        saveToDisk()
        watchLogInfo("Zone cache updated with \(newZones.count) zones", category: .watchSync)
    }

    /// Met à jour depuis un dictionnaire reçu via WatchConnectivity
    func updateFromDictionary(_ data: [[String: Any]]) {
        let newZones = data.compactMap { dict -> WatchZoneEntry? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String,
                  let centerLat = dict["centerLat"] as? Double,
                  let centerLon = dict["centerLon"] as? Double,
                  let radiusMeters = dict["radiusMeters"] as? Double,
                  let bbDict = dict["boundingBox"] as? [String: Double],
                  let minLat = bbDict["minLat"],
                  let maxLat = bbDict["maxLat"],
                  let minLon = bbDict["minLon"],
                  let maxLon = bbDict["maxLon"] else {
                return nil
            }

            return WatchZoneEntry(
                id: id,
                name: name,
                centerLat: centerLat,
                centerLon: centerLon,
                radiusMeters: radiusMeters,
                boundingBox: WatchBoundingBox(
                    minLat: minLat,
                    maxLat: maxLat,
                    minLon: minLon,
                    maxLon: maxLon
                )
            )
        }

        updateZones(newZones)
    }

    // MARK: - Persistence

    private func saveToDisk() {
        Task.detached(priority: .background) { [zones, lastUpdated] in
            if let encoded = try? JSONEncoder().encode(zones) {
                UserDefaults.standard.set(encoded, forKey: "watchZoneCache")
            }
            if let date = lastUpdated {
                UserDefaults.standard.set(date, forKey: "watchZoneCacheDate")
            }
        }
    }

    private func loadFromDisk() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([WatchZoneEntry].self, from: data) {
            zones = decoded
        }

        lastUpdated = UserDefaults.standard.object(forKey: userDefaultsDateKey) as? Date
    }

    /// Efface le cache
    func clearCache() {
        zones = []
        lastUpdated = nil
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsDateKey)
    }
}
