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
        // NOTE: Migration désactivée - la base de données est maintenant persistante
        // Self.deleteOldDatabaseIfNeeded()

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
                // Ce cas ne devrait jamais arriver en pratique
                logError("Critical: Could not create fallback container: \(error)", category: .dataController)
                // Force le container in-memory sans configuration
                // swiftlint:disable:next force_try
                let minimalContainer = try! ModelContainer(for: schema)
                self.modelContainer = minimalContainer
                self.modelContext = ModelContext(minimalContainer)
                self.isUsingFallbackDatabase = true
                statsCache.dataController = self
            }
        }
    }

    /// Supprime l'ancienne base de données si elle existe (migration forcée)
    private static func deleteOldDatabaseIfNeeded() {
        let fileManager = FileManager.default

        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let storeURL = appSupportURL.appendingPathComponent("default.store")

        if fileManager.fileExists(atPath: storeURL.path) {
            do {
                try fileManager.removeItem(at: storeURL)
                logInfo("Old database deleted for migration", category: .dataController)
            } catch {
                logWarning("Could not delete old database: \(error)", category: .dataController)
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
            gpsTrackData = try? JSONEncoder().encode(gpsTrack)
            logDebug("GPS track with \(gpsTrack.count) points", category: .flight)
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
    }

    /// Supprime un vol
    func deleteFlight(_ flight: Flight) {
        modelContext.delete(flight)
        saveContext()

        // Invalider le cache de stats après suppression d'un vol
        statsCache.invalidate()
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
