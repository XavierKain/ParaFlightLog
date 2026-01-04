//
//  DataController.swift
//  ParaFlightLog
//
//  Gestion du ModelContainer SwiftData + helpers CRUD + calcul des stats
//  Target: iOS only
//

import Foundation
import SwiftData
import CoreLocation
import UIKit  // Pour ImageCacheManager

@Observable
final class DataController {
    var modelContainer: ModelContainer
    var modelContext: ModelContext

    // Référence au WatchConnectivityManager pour la synchronisation automatique
    weak var watchConnectivityManager: WatchConnectivityManager?

    // Cache des statistiques - invalidé automatiquement lors des modifications de vols
    let statsCache = StatsCache()

    // Indique si on utilise une base in-memory (fallback après erreur)
    private(set) var isUsingFallbackDatabase: Bool = false

    init() {
        // Configuration du schema SwiftData
        let schema = Schema([
            Wing.self,
            Flight.self
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.modelContainer = container
            self.modelContext = ModelContext(container)

            // Configurer le cache de statistiques
            statsCache.dataController = self

            logInfo("ModelContainer created successfully", category: .dataController)
        } catch {
            // Fallback: utiliser une base de données in-memory
            // Les données ne seront pas persistées, mais l'app ne crashera pas
            logError("Could not create ModelContainer: \(error). Using in-memory fallback.", category: .dataController)

            let fallbackConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )

            do {
                let fallbackContainer = try ModelContainer(for: schema, configurations: [fallbackConfiguration])
                self.modelContainer = fallbackContainer
                self.modelContext = ModelContext(fallbackContainer)
                self.isUsingFallbackDatabase = true

                // Configurer le cache de statistiques
                statsCache.dataController = self

                logWarning("Using in-memory database - data will not persist", category: .dataController)
            } catch {
                // Dernier recours: créer un container minimal
                // Si même cela échoue, l'app ne peut pas fonctionner du tout
                logError("Critical: Could not create fallback container: \(error)", category: .dataController)

                do {
                    let minimalContainer = try ModelContainer(for: schema)
                    self.modelContainer = minimalContainer
                    self.modelContext = ModelContext(minimalContainer)
                    self.isUsingFallbackDatabase = true
                    statsCache.dataController = self
                } catch {
                    fatalError("Unable to create any ModelContainer - app cannot function: \(error)")
                }
            }
        }
    }

    // MARK: - Wings CRUD

    /// Récupère toutes les voiles triées par ordre d'affichage personnalisé
    /// - Parameter includeArchived: Si true, inclut les voiles archivées (défaut: false)
    func fetchWings(includeArchived: Bool = false) -> [Wing] {
        var descriptor = FetchDescriptor<Wing>(sortBy: [SortDescriptor(\.displayOrder)])

        // Filtrer les voiles archivées par défaut
        if !includeArchived {
            descriptor.predicate = #Predicate<Wing> { !$0.isArchived }
        }

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            logError("Error fetching wings: \(error)", category: .dataController)
            return []
        }
    }

    /// Récupère uniquement les voiles archivées
    func fetchArchivedWings() -> [Wing] {
        var descriptor = FetchDescriptor<Wing>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.predicate = #Predicate<Wing> { $0.isArchived }

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            logError("Error fetching archived wings: \(error)", category: .dataController)
            return []
        }
    }

    /// Ajoute une nouvelle voile
    func addWing(name: String, size: String? = nil, type: String? = nil, color: String? = nil) {
        // Calculer le displayOrder automatiquement (dernier + 1)
        let existingWings = fetchWings(includeArchived: true)
        let maxOrder = existingWings.map(\.displayOrder).max() ?? -1

        let wing = Wing(name: name, size: size, type: type, color: color, displayOrder: maxOrder + 1)
        modelContext.insert(wing)
        saveContext()
        // Synchronisation automatique vers la Watch
        syncWingsToWatch()
    }

    /// Supprime une voile (les vols associés seront supprimés en cascade)
    func deleteWing(_ wing: Wing) {
        // Invalider le cache d'image avant suppression
        ImageCacheManager.shared.invalidate(key: wing.id.uuidString)

        modelContext.delete(wing)
        saveContext()

        // Invalider le cache de stats (les vols associés sont supprimés en cascade)
        statsCache.invalidate()

        // Synchronisation automatique vers la Watch
        syncWingsToWatch()
    }

    /// Met à jour une voile existante
    func updateWing(_ wing: Wing, name: String, size: String?, type: String?, color: String?) {
        wing.name = name
        wing.size = size
        wing.type = type
        wing.color = color
        saveContext()
        // Synchronisation automatique vers la Watch
        syncWingsToWatch()
    }

    /// Archive une voile (masquée par défaut mais données préservées)
    func archiveWing(_ wing: Wing) {
        wing.isArchived = true
        saveContext()
        // Synchronisation automatique vers la Watch
        syncWingsToWatch()
    }

    /// Désarchive une voile (la rend visible à nouveau)
    func unarchiveWing(_ wing: Wing) {
        wing.isArchived = false
        saveContext()
        // Synchronisation automatique vers la Watch
        syncWingsToWatch()
    }

    /// Supprime définitivement une voile (et tous ses vols en cascade)
    /// ⚠️ Cette action est irréversible !
    func permanentlyDeleteWing(_ wing: Wing) {
        modelContext.delete(wing)
        saveContext()

        // Invalider le cache de stats (les vols associés sont supprimés en cascade)
        statsCache.invalidate()

        // Synchronisation automatique vers la Watch
        syncWingsToWatch()
    }

    /// Trouve une voile par son UUID
    func findWing(byId id: UUID) -> Wing? {
        let descriptor = FetchDescriptor<Wing>(predicate: #Predicate { $0.id == id })
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            logError("Error finding wing: \(error)", category: .dataController)
            return nil
        }
    }

    // MARK: - Flights CRUD

    /// Récupère tous les vols triés par date de début (plus récents en premier)
    func fetchFlights() -> [Flight] {
        let descriptor = FetchDescriptor<Flight>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            logError("Error fetching flights: \(error)", category: .dataController)
            return []
        }
    }

    /// Ajoute un nouveau vol à partir d'un FlightDTO (reçu de la Watch)
    func addFlight(from dto: FlightDTO, location: CLLocation?, spotName: String?) {
        guard let wing = findWing(byId: dto.wingId) else {
            logError("Wing not found for flight: \(dto.wingId)", category: .flight)
            return
        }

        // Encoder la trace GPS si présente
        var gpsTrackData: Data? = nil
        if let gpsTrack = dto.gpsTrack, !gpsTrack.isEmpty {
            do {
                gpsTrackData = try JSONEncoder().encode(gpsTrack)
                logDebug("GPS track with \(gpsTrack.count) points", category: .flight)
            } catch {
                logError("Failed to encode GPS track: \(error.localizedDescription)", category: .flight)
            }
        }

        let flight = Flight(
            id: dto.id,
            wing: wing,
            startDate: dto.startDate,
            endDate: dto.endDate,
            durationSeconds: dto.durationSeconds,
            spotName: spotName,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            createdAt: dto.createdAt,
            startAltitude: dto.startAltitude,
            maxAltitude: dto.maxAltitude,
            endAltitude: dto.endAltitude,
            totalDistance: dto.totalDistance,
            maxSpeed: dto.maxSpeed,
            maxGForce: dto.maxGForce,
            gpsTrackData: gpsTrackData
        )

        modelContext.insert(flight)
        saveContext()

        // Invalider le cache de stats après ajout d'un vol
        statsCache.invalidate()

        logInfo("Flight saved: \(flight.durationFormatted) with \(wing.name)", category: .flight)

        // Synchroniser automatiquement vers le cloud si l'utilisateur est connecté
        syncFlightToCloudIfNeeded(flight)
    }

    /// Ajoute un vol directement (pour les vols créés depuis l'iPhone)
    func addFlight(wing: Wing, startDate: Date, endDate: Date, durationSeconds: Int, location: CLLocation?, spotName: String?, flightType: String? = nil, notes: String? = nil) {
        let flight = Flight(
            wing: wing,
            startDate: startDate,
            endDate: endDate,
            durationSeconds: durationSeconds,
            spotName: spotName,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            flightType: flightType,
            notes: notes
        )

        modelContext.insert(flight)
        saveContext()

        // Invalider le cache de stats après ajout d'un vol
        statsCache.invalidate()

        logInfo("Flight saved: \(flight.durationFormatted) at \(spotName ?? "Unknown")", category: .flight)

        // Synchroniser automatiquement vers le cloud si l'utilisateur est connecté
        syncFlightToCloudIfNeeded(flight)
    }

    // MARK: - Cloud Sync

    /// Synchronise automatiquement un vol vers le cloud si l'utilisateur est authentifié
    private func syncFlightToCloudIfNeeded(_ flight: Flight) {
        // Vérifier si l'utilisateur est authentifié avec un vrai compte (pas skipped)
        guard AuthService.shared.isAuthenticated,
              UserService.shared.currentUserProfile != nil else {
            logDebug("Skipping cloud sync - user not authenticated", category: .sync)
            return
        }

        // Lancer la synchronisation en arrière-plan
        Task {
            do {
                let cloudFlight = try await FlightSyncService.shared.uploadFlight(flight)

                // Mettre à jour le vol local avec les infos cloud sur le main thread
                await MainActor.run {
                    flight.cloudId = cloudFlight.id
                    flight.cloudSyncedAt = Date()
                    flight.needsSync = false
                    flight.hasGpsTrackInCloud = cloudFlight.hasGpsTrack
                    self.saveContext()
                    logInfo("Flight auto-synced to cloud: \(cloudFlight.id)", category: .sync)
                }
            } catch {
                logWarning("Auto-sync failed for flight: \(error.localizedDescription)", category: .sync)
                // Le vol reste marqué needsSync = true, sera synchronisé lors de la prochaine sync manuelle
            }
        }
    }

    /// Supprime un vol
    func deleteFlight(_ flight: Flight) {
        modelContext.delete(flight)
        saveContext()

        // Invalider le cache de stats après suppression d'un vol
        statsCache.invalidate()
    }

    // MARK: - Spot Detection

    /// Structure représentant un spot local avec ses statistiques
    struct LocalSpot: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let latitude: Double
        let longitude: Double
        let flightCount: Int
        let totalFlightSeconds: Int

        var formattedTotalTime: String {
            let hours = totalFlightSeconds / 3600
            let minutes = (totalFlightSeconds % 3600) / 60
            if hours > 0 {
                return "\(hours)h\(String(format: "%02d", minutes))"
            }
            return "\(minutes) min"
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
        }

        static func == (lhs: LocalSpot, rhs: LocalSpot) -> Bool {
            lhs.name == rhs.name
        }
    }

    /// Trouve les spots existants dans un rayon donné (en mètres) autour d'une coordonnée
    /// Retourne les spots triés par distance
    func findNearbySpots(latitude: Double, longitude: Double, radiusMeters: Double = 1000) -> [LocalSpot] {
        let flights = fetchFlights()

        // Grouper les vols par nom de spot et calculer la position moyenne
        var spotGroups: [String: (flights: [Flight], avgLat: Double, avgLon: Double)] = [:]

        for flight in flights {
            guard let spotName = flight.spotName,
                  let lat = flight.latitude,
                  let lon = flight.longitude else { continue }

            if var group = spotGroups[spotName] {
                group.flights.append(flight)
                // Recalculer la moyenne
                let count = Double(group.flights.count)
                let prevCount = count - 1
                group.avgLat = (group.avgLat * prevCount + lat) / count
                group.avgLon = (group.avgLon * prevCount + lon) / count
                spotGroups[spotName] = group
            } else {
                spotGroups[spotName] = (flights: [flight], avgLat: lat, avgLon: lon)
            }
        }

        // Filtrer par distance et créer les LocalSpot
        var nearbySpots: [(spot: LocalSpot, distance: Double)] = []

        for (name, group) in spotGroups {
            let distance = haversineDistance(
                lat1: latitude, lon1: longitude,
                lat2: group.avgLat, lon2: group.avgLon
            )

            if distance <= radiusMeters {
                let totalSeconds = group.flights.reduce(0) { $0 + $1.durationSeconds }
                let spot = LocalSpot(
                    name: name,
                    latitude: group.avgLat,
                    longitude: group.avgLon,
                    flightCount: group.flights.count,
                    totalFlightSeconds: totalSeconds
                )
                nearbySpots.append((spot: spot, distance: distance))
            }
        }

        // Trier par distance
        return nearbySpots.sorted { $0.distance < $1.distance }.map { $0.spot }
    }

    /// Trouve tous les spots uniques dans les vols existants
    func getAllSpots() -> [LocalSpot] {
        let flights = fetchFlights()

        var spotGroups: [String: (flights: [Flight], avgLat: Double, avgLon: Double)] = [:]

        for flight in flights {
            guard let spotName = flight.spotName else { continue }
            let lat = flight.latitude ?? 0
            let lon = flight.longitude ?? 0

            if var group = spotGroups[spotName] {
                group.flights.append(flight)
                if lat != 0 && lon != 0 {
                    let count = Double(group.flights.filter { $0.latitude != nil }.count)
                    if count > 0 {
                        let prevCount = count - 1
                        group.avgLat = (group.avgLat * prevCount + lat) / count
                        group.avgLon = (group.avgLon * prevCount + lon) / count
                    }
                }
                spotGroups[spotName] = group
            } else {
                spotGroups[spotName] = (flights: [flight], avgLat: lat, avgLon: lon)
            }
        }

        return spotGroups.map { name, group in
            let totalSeconds = group.flights.reduce(0) { $0 + $1.durationSeconds }
            return LocalSpot(
                name: name,
                latitude: group.avgLat,
                longitude: group.avgLon,
                flightCount: group.flights.count,
                totalFlightSeconds: totalSeconds
            )
        }.sorted { $0.flightCount > $1.flightCount }
    }

    /// Renomme un spot dans tous les vols existants
    func renameSpot(from oldName: String, to newName: String) {
        let flights = fetchFlights()
        var renamedCount = 0

        for flight in flights {
            if flight.spotName == oldName {
                flight.spotName = newName
                flight.needsSync = true  // Marquer pour re-sync
                renamedCount += 1
            }
        }

        if renamedCount > 0 {
            saveContext()
            logInfo("Renamed spot '\(oldName)' to '\(newName)' in \(renamedCount) flights", category: .dataController)
        }
    }

    /// Calcule la distance en mètres entre deux coordonnées (formule de Haversine)
    private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6371000.0 // mètres

        let lat1Rad = lat1 * .pi / 180
        let lat2Rad = lat2 * .pi / 180
        let deltaLat = (lat2 - lat1) * .pi / 180
        let deltaLon = (lon2 - lon1) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2) +
                cos(lat1Rad) * cos(lat2Rad) *
                sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadius * c
    }

    // MARK: - Stats

    /// Calcule le total d'heures de vol par voile
    /// Retourne un dictionnaire [UUID: Double] où la valeur est en heures (ex: 12.5 = 12h30)
    func totalHoursByWing() -> [UUID: Double] {
        let flights = fetchFlights()
        var result: [UUID: Double] = [:]

        for flight in flights {
            guard let wingId = flight.wing?.id else { continue }
            let hours = Double(flight.durationSeconds) / 3600.0
            result[wingId, default: 0.0] += hours
        }

        return result
    }

    /// Calcule le total d'heures de vol par spot
    /// Retourne un dictionnaire [String: Double] où la valeur est en heures
    func totalHoursBySpot() -> [String: Double] {
        let flights = fetchFlights()
        var result: [String: Double] = [:]

        for flight in flights {
            let spot = flight.spotName ?? "Unknown"
            let hours = Double(flight.durationSeconds) / 3600.0
            result[spot, default: 0.0] += hours
        }

        return result
    }

    /// Calcule le nombre total de vols par voile
    func flightCountByWing() -> [UUID: Int] {
        let flights = fetchFlights()
        var result: [UUID: Int] = [:]

        for flight in flights {
            guard let wingId = flight.wing?.id else { continue }
            result[wingId, default: 0] += 1
        }

        return result
    }

    /// Calcule le nombre total de vols par spot
    func flightCountBySpot() -> [String: Int] {
        let flights = fetchFlights()
        var result: [String: Int] = [:]

        for flight in flights {
            let spot = flight.spotName ?? "Unknown"
            result[spot, default: 0] += 1
        }

        return result
    }

    /// Calcule le total d'heures de vol tous vols confondus
    func totalFlightHours() -> Double {
        let flights = fetchFlights()
        let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
        return Double(totalSeconds) / 3600.0
    }

    /// Formatte un nombre d'heures en string lisible (ex: 12.5 → "12h30")
    func formatHours(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return m > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(h)h"
    }

    // MARK: - Context Management

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            logError("Error saving context: \(error)", category: .dataController)
        }
    }

    // MARK: - Watch Sync

    /// Synchronise automatiquement les voiles vers la Watch
    private func syncWingsToWatch() {
        // Synchroniser vers la Watch si disponible
        watchConnectivityManager?.sendWingsToWatch()
    }
}
