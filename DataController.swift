//
//  DataController.swift
//  ParaFlightLog
//
//  SwiftData ModelContainer management + CRUD helpers + on-demand stats.
//  Target: iOS only
//

import Foundation
import SwiftData
import CoreLocation
import UIKit  // For ImageCacheManager

// MARK: - FlightStats
/// Aggregated statistics computed in a single pass over all flights.
/// Use `DataController.computeStats()` instead of calling per-row helpers in list views.
struct FlightStats {
    var totalHours: Double = 0
    var totalCount: Int = 0
    var hoursByWing: [UUID: Double] = [:]
    var countByWing: [UUID: Int] = [:]
    var hoursBySpot: [String: Double] = [:]
    var countBySpot: [String: Int] = [:]
}

@Observable
final class DataController {
    var modelContainer: ModelContainer
    var modelContext: ModelContext

    // Reference to the WatchConnectivityManager for automatic sync
    weak var watchConnectivityManager: WatchConnectivityManager?

    // True when the store is backed by CloudKit (iCloud sync enabled).
    private(set) var isCloudSyncActive: Bool = false

    // True when we had to fall back to an in-memory database (data won't persist)
    private(set) var isUsingFallbackDatabase: Bool = false

    /// Master switch for iCloud/CloudKit sync.
    ///
    /// Currently OFF: the CloudKit container `iCloud.com.xavierkain.ParaFlightLog2`
    /// has not been created on the Apple developer portal yet, so `.automatic`
    /// succeeds locally but then spams "Bad Container" errors while trying to
    /// sync in the background. iCloud sync is a deferred feature (see README),
    /// so we run local-only until the container exists.
    ///
    /// To re-enable: create the CloudKit container in Xcode ▸ Signing &
    /// Capabilities (iCloud ▸ CloudKit), then flip this to `true`.
    nonisolated private static let enableCloudKit = false

    /// Synchronous init (previews / non-launch callers). Builds the container
    /// on the current thread. The app launch path uses `makeAsync()` instead.
    ///
    /// IMPORTANT: uses the container's `mainContext` — the SAME context the
    /// SwiftUI `@Query`s use. A separate `ModelContext(container)` caused
    /// "Illegal attempt to insert a model in to a different model context"
    /// whenever a @Query-fetched Wing was attached to a Flight saved here.
    init() {
        let built = Self.makeContainer()
        self.modelContainer = built.container
        self.modelContext = built.container.mainContext
        self.isCloudSyncActive = built.isCloudSync
        self.isUsingFallbackDatabase = built.isFallback
    }

    /// Init from an already-built container (created off the main thread by
    /// `makeAsync`), so this step is instant.
    private init(prebuilt: ContainerResult) {
        self.modelContainer = prebuilt.container
        self.modelContext = prebuilt.container.mainContext
        self.isCloudSyncActive = prebuilt.isCloudSync
        self.isUsingFallbackDatabase = prebuilt.isFallback
    }

    /// Builds the (heavy, ~1s+) ModelContainer OFF the main thread so app launch
    /// can show a loading view immediately instead of a black screen.
    static func makeAsync() async -> DataController {
        let built = await Task.detached(priority: .userInitiated) {
            makeContainer()
        }.value
        return DataController(prebuilt: built)
    }

    private struct ContainerResult: @unchecked Sendable {
        let container: ModelContainer
        let isCloudSync: Bool
        let isFallback: Bool
    }

    /// The actual ModelContainer creation. `nonisolated` so it can run off the
    /// main actor (this is the ~1200 ms cost measured at launch).
    nonisolated private static func makeContainer() -> ContainerResult {
        let start = Date()
        logInfo("ModelContainer build started", category: .dataController)
        let schema = Schema([Wing.self, Flight.self])
        defer {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            logInfo("ModelContainer build finished in \(ms) ms", category: .dataController)
        }

        // CloudKit path (currently disabled; see enableCloudKit).
        if enableCloudKit {
            let cloudConfiguration = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .automatic
            )
            if let container = try? ModelContainer(for: schema, configurations: [cloudConfiguration]) {
                logInfo("ModelContainer created with CloudKit sync", category: .dataController)
                return ContainerResult(container: container, isCloudSync: true, isFallback: false)
            }
            logWarning("CloudKit container unavailable. Using local store.", category: .dataController)
        } else {
            logInfo("CloudKit disabled by configuration. Using local store.", category: .dataController)
        }

        // Local-only store.
        let localConfiguration = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none
        )
        if let container = try? ModelContainer(for: schema, configurations: [localConfiguration]) {
            logInfo("ModelContainer created (local only)", category: .dataController)
            return ContainerResult(container: container, isCloudSync: false, isFallback: false)
        }

        // Last resort: in-memory (data won't persist, but the app still runs).
        logError("Could not create a persistent ModelContainer. Using in-memory fallback.", category: .dataController)
        let fallbackConfiguration = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        do {
            let fallbackContainer = try ModelContainer(for: schema, configurations: [fallbackConfiguration])
            logWarning("Using in-memory database - data will not persist", category: .dataController)
            return ContainerResult(container: fallbackContainer, isCloudSync: false, isFallback: true)
        } catch {
            fatalError("Unable to create any ModelContainer - app cannot function: \(error)")
        }
    }

    // MARK: - Wings CRUD

    /// Fetches all wings sorted by custom display order
    /// - Parameter includeArchived: if true, includes archived wings (default: false)
    func fetchWings(includeArchived: Bool = false) -> [Wing] {
        var descriptor = FetchDescriptor<Wing>(sortBy: [SortDescriptor(\.displayOrder)])

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

    /// Fetches only archived wings
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

    /// Adds a new wing
    func addWing(name: String, size: String? = nil, type: String? = nil, color: String? = nil) {
        // Assign displayOrder automatically (last + 1)
        let existingWings = fetchWings(includeArchived: true)
        let maxOrder = existingWings.map(\.displayOrder).max() ?? -1

        let wing = Wing(name: name, size: size, type: type, color: color, displayOrder: maxOrder + 1)
        modelContext.insert(wing)
        saveContext()
        syncWingsToWatch()
    }

    /// Deletes a wing (associated flights are cascade-deleted)
    func deleteWing(_ wing: Wing) {
        // Invalidate the image cache before deletion
        ImageCacheManager.shared.invalidate(key: wing.id.uuidString)

        modelContext.delete(wing)
        saveContext()
        syncWingsToWatch()
    }

    /// Updates an existing wing
    func updateWing(_ wing: Wing, name: String, size: String?, type: String?, color: String?) {
        wing.name = name
        wing.size = size
        wing.type = type
        wing.color = color
        saveContext()
        syncWingsToWatch()
    }

    /// Archives a wing (hidden by default but data is preserved)
    func archiveWing(_ wing: Wing) {
        wing.isArchived = true
        saveContext()
        syncWingsToWatch()
    }

    /// Unarchives a wing (makes it visible again)
    func unarchiveWing(_ wing: Wing) {
        wing.isArchived = false
        saveContext()
        syncWingsToWatch()
    }

    /// Permanently deletes a wing (and all its flights, cascade).
    /// Warning: this action is irreversible!
    func permanentlyDeleteWing(_ wing: Wing) {
        ImageCacheManager.shared.invalidate(key: wing.id.uuidString)
        modelContext.delete(wing)
        saveContext()
        syncWingsToWatch()
    }

    /// Finds a wing by its UUID
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

    /// Fetches all flights sorted by start date (most recent first)
    func fetchFlights() -> [Flight] {
        let descriptor = FetchDescriptor<Flight>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            logError("Error fetching flights: \(error)", category: .dataController)
            return []
        }
    }

    /// Finds a flight by its UUID
    func findFlight(byId id: UUID) -> Flight? {
        let descriptor = FetchDescriptor<Flight>(predicate: #Predicate { $0.id == id })
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            logError("Error finding flight: \(error)", category: .dataController)
            return nil
        }
    }

    /// Returns true when a flight with this id is already stored.
    /// Used for deduplication of flights received from the Watch.
    func flightExists(id: UUID) -> Bool {
        var descriptor = FetchDescriptor<Flight>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetchCount(descriptor) > 0
        } catch {
            logError("Error checking flight existence: \(error)", category: .dataController)
            return false
        }
    }

    /// Adds a new flight from a FlightDTO (received from the Watch).
    /// Idempotent: if a flight with the same id already exists, nothing is inserted.
    /// If the wing is unknown, the flight is saved anyway with wing = nil (never drop user data).
    /// - Returns: true when the flight is persisted (or already was), false when saving failed.
    @discardableResult
    func addFlight(from dto: FlightDTO, location: CLLocation?, spotName: String?) -> Bool {
        // Deduplication: the Watch may deliver the same flight through several channels
        if flightExists(id: dto.id) {
            logInfo("Flight \(dto.id) already exists - skipping duplicate", category: .flight)
            return true
        }

        let wing = findWing(byId: dto.wingId)
        if wing == nil {
            logWarning("Wing \(dto.wingId) not found - saving flight without a wing", category: .flight)
        }

        // Encode the GPS track if present
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
            flightType: dto.flightType,
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
        let saved = saveContext()
        if saved {
            logInfo("Flight saved: \(flight.durationFormatted) with \(wing?.name ?? "no wing")", category: .flight)
        }
        return saved
    }

    /// Adds a flight directly (for flights created on the iPhone)
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

        logInfo("Flight saved: \(flight.durationFormatted) at \(spotName ?? "Unknown")", category: .flight)
    }

    /// Updates a flight's location info after background reverse geocoding.
    /// Safe to call any time: the flight is already persisted.
    func updateFlightLocation(flightId: UUID, location: CLLocation?, spotName: String?) {
        guard let flight = findFlight(byId: flightId) else {
            logWarning("Cannot update location: flight \(flightId) not found", category: .flight)
            return
        }

        if let location = location {
            flight.latitude = location.coordinate.latitude
            flight.longitude = location.coordinate.longitude
        }
        if let spotName = spotName {
            flight.spotName = spotName
        }
        saveContext()
        logInfo("Flight \(flightId) location updated: \(spotName ?? "no spot")", category: .flight)
    }

    /// Deletes a flight
    func deleteFlight(_ flight: Flight) {
        modelContext.delete(flight)
        saveContext()
    }

    /// Bulk-assigns a flight type (nil clears it). One save for the whole batch.
    /// - Returns: the number of flights actually changed.
    @discardableResult
    func setFlightType(_ type: FlightType?, for flights: [Flight]) -> Int {
        let newValue = type?.rawValue
        var changed = 0
        for flight in flights where flight.flightType != newValue {
            flight.flightType = newValue
            changed += 1
        }
        if changed > 0 {
            saveContext()
            logInfo("Bulk flight-type update: \(changed) flights set to \(newValue ?? "none")", category: .flight)
        }
        return changed
    }

    // MARK: - Stats

    /// Computes all aggregate statistics in a single pass over the flights.
    /// Prefer this over the per-dictionary helpers when a view needs several stats at once.
    func computeStats() -> FlightStats {
        computeStats(from: fetchFlights())
    }

    /// Aggregates stats from an already-loaded flight array (no fetch). Views
    /// that already hold a `@Query` of flights should pass it in to avoid a
    /// redundant fetch.
    func computeStats(from flights: [Flight]) -> FlightStats {
        var stats = FlightStats()

        for flight in flights {
            let hours = Double(flight.durationSeconds) / 3600.0
            stats.totalHours += hours
            stats.totalCount += 1

            if let wingId = flight.wing?.id {
                stats.hoursByWing[wingId, default: 0.0] += hours
                stats.countByWing[wingId, default: 0] += 1
            }

            let spot = flight.spotName ?? "Unknown"
            stats.hoursBySpot[spot, default: 0.0] += hours
            stats.countBySpot[spot, default: 0] += 1
        }

        return stats
    }

    /// Total flight hours per wing ([UUID: Double], value in hours; 12.5 = 12h30)
    func totalHoursByWing() -> [UUID: Double] {
        computeStats().hoursByWing
    }

    /// Total flight hours per spot
    func totalHoursBySpot() -> [String: Double] {
        computeStats().hoursBySpot
    }

    /// Total number of flights per wing
    func flightCountByWing() -> [UUID: Int] {
        computeStats().countByWing
    }

    /// Total number of flights per spot
    func flightCountBySpot() -> [String: Int] {
        computeStats().countBySpot
    }

    /// Total flight hours across all flights
    func totalFlightHours() -> Double {
        computeStats().totalHours
    }

    /// Formats a number of hours as a readable string (e.g. 12.5 -> "12h30")
    func formatHours(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return m > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(h)h"
    }

    // MARK: - Context Management

    @discardableResult
    func saveContext() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            logError("Error saving context: \(error)", category: .dataController)
            return false
        }
    }

    // MARK: - Watch Sync

    /// Automatically syncs wings to the Watch
    private func syncWingsToWatch() {
        watchConnectivityManager?.sendWingsToWatch()
    }
}
