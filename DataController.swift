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
    /// Currently OFF: the CloudKit container `iCloud.com.xavierkain.SoarX`
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
        let schema = Schema([Wing.self, Flight.self, Spot.self])
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
        // Attach to the nearest spot when the track gives us coordinates;
        // the deferred geocode (updateFlightLocation) completes it otherwise.
        if flight.latitude == nil, let firstPoint = dto.gpsTrack?.first {
            flight.latitude = firstPoint.latitude
            flight.longitude = firstPoint.longitude
        }
        assignSpot(to: flight)
        let saved = saveContext()
        if saved {
            logInfo("Flight saved: \(flight.durationFormatted) with \(wing?.name ?? "no wing")", category: .flight)
            // Opt-in community share. Fire-and-forget: never affects the
            // save/ACK path (same pattern as the weather snapshot).
            CommunityService.shared.shareFlightIfEnabled(flight, dataController: self)
            // The wing's hour counters moved — refresh the trim reminders.
            refreshTrimReminders()
        }
        return saved
    }

    /// Adds a flight directly (for flights created on the iPhone).
    /// - Returns: the inserted flight, so callers can run post-save
    ///   enrichment (e.g. the takeoff weather snapshot).
    @discardableResult
    func addFlight(wing: Wing, startDate: Date, endDate: Date, durationSeconds: Int, location: CLLocation?, spotName: String?, spot: Spot? = nil, flightType: String? = nil, notes: String? = nil) -> Flight {
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
        if let spot {
            // Explicitly chosen in the UI — takes precedence over auto-resolution
            flight.spot = spot
            flight.spotName = spot.name
        } else {
            assignSpot(to: flight)
        }
        saveContext()

        logInfo("Flight saved: \(flight.durationFormatted) at \(flight.spotName ?? "Unknown")", category: .flight)
        // Opt-in community share. Fire-and-forget: never affects the save path.
        CommunityService.shared.shareFlightIfEnabled(flight, dataController: self)
        // The wing's hour counters moved — refresh the trim reminders.
        refreshTrimReminders()
        return flight
    }

    /// Updates a flight's location info after background reverse geocoding.
    /// Safe to call any time: the flight is already persisted.
    func updateFlightLocation(flightId: UUID, location: CLLocation?, spotName: String?) {
        guard let flight = findFlight(byId: flightId) else {
            logWarning("Cannot update location: flight \(flightId) not found", category: .flight)
            return
        }

        // Deferred geocoding can run long after the flight happened (e.g. a
        // Watch flight delivered hours later, geocoded from the iPhone's
        // CURRENT position). Never overwrite takeoff coordinates the flight
        // already has (e.g. from its first GPS track point) — only fill blanks.
        if flight.latitude == nil, let location = location {
            flight.latitude = location.coordinate.latitude
            flight.longitude = location.coordinate.longitude
        }
        // Don't fight an existing spot link: the geocoded locality only fills
        // flights that aren't attached to a real spot yet.
        if flight.spot == nil, let spotName = spotName {
            flight.spotName = spotName
        }
        assignSpot(to: flight)
        saveContext()
        logInfo("Flight \(flightId) location updated: \(flight.spotName ?? "no spot")", category: .flight)

        // A spot may only have been resolved by this late geocode — give the
        // opt-in community share a second chance. Idempotent (doc ID = flight
        // id) and fire-and-forget: never affects this update path.
        if flight.spot != nil {
            CommunityService.shared.shareFlightIfEnabled(flight, dataController: self)
        }
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

    // MARK: - Spots

    /// UserDefaults flag: set once the one-time launch migration linking legacy
    /// spotName-only flights to Spot entities has run. It must NOT re-run on
    /// every launch: after `deleteSpot`, flights keep their spotName but stay
    /// unlinked (the durable, documented behavior), and a repeated migration
    /// would resurrect the deleted spot from those kept names.
    private static let spotMigrationCompletedKey = "spotMigrationCompleted"

    /// All spots, most-flown first.
    func fetchSpots() -> [Spot] {
        Self.popularityOrder(fetchAllSpots())
    }

    /// Most-flown-first ordering. Shared by `fetchSpots()` and the spots
    /// management list so both always sort the same way.
    static func popularityOrder(_ spots: [Spot]) -> [Spot] {
        spots.sorted { ($0.flights?.count ?? 0) > ($1.flights?.count ?? 0) }
    }

    /// Plain fetch of every spot (name-sorted). Hot paths (nearest lookup,
    /// batch linking) use this instead of `fetchSpots()`: the most-flown
    /// ordering faults every spot's flights relationship, which they don't need.
    private func fetchAllSpots() -> [Spot] {
        let descriptor = FetchDescriptor<Spot>(sortBy: [SortDescriptor(\.name)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Lowercased-name lookup used by the batch spot-resolution paths.
    private static func makeNameIndex(_ spots: [Spot]) -> [String: Spot] {
        Dictionary(spots.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Nearest existing spot within `radius` meters of a coordinate.
    func nearestSpot(to coordinate: CLLocationCoordinate2D, within radius: Double = 1500) -> Spot? {
        nearestSpot(to: coordinate, within: radius, among: fetchAllSpots())
    }

    /// Batch variant of `nearestSpot`: works over a pre-fetched spot array so
    /// callers linking many flights don't re-fetch all spots per flight.
    private func nearestSpot(to coordinate: CLLocationCoordinate2D, within radius: Double, among spots: [Spot]) -> Spot? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (spot: Spot, distance: Double)?
        for spot in spots {
            guard let lat = spot.latitude, let lon = spot.longitude else { continue }
            let distance = target.distance(from: CLLocation(latitude: lat, longitude: lon))
            if distance <= radius && (best == nil || distance < best!.distance) {
                best = (spot, distance)
            }
        }
        return best?.spot
    }

    /// Finds a spot by exact name (case-insensitive) or creates one.
    /// A newly created spot gets `city = name` when no city is known —
    /// geocoding only yields the locality, so both fields start equal.
    @discardableResult
    func findOrCreateSpot(named name: String, city: String? = nil, coordinate: CLLocationCoordinate2D? = nil) -> Spot {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = fetchSpots().first(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            // Opportunistically fill missing data
            if existing.latitude == nil, let coordinate {
                existing.latitude = coordinate.latitude
                existing.longitude = coordinate.longitude
            }
            if existing.city == nil, let city { existing.city = city }
            return existing
        }

        let spot = Spot(
            name: trimmed,
            city: city ?? trimmed,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        )
        modelContext.insert(spot)
        logInfo("Spot created: \(trimmed)", category: .flight)
        return spot
    }

    /// Attaches a flight to a spot. Precedence — a flight's own non-empty
    /// spotName is never renamed:
    /// 1. Non-empty spotName matching an existing spot (case-insensitive) → link.
    /// 2. Unnamed flight with GPS → nearest existing spot within 1.5 km (so a
    ///    split spot like "Punta Paloma" captures future flights there).
    /// 3. Non-empty spotName with no match → create a spot with that name.
    /// Skips flights already linked — a manual reassignment is never fought.
    func assignSpot(to flight: Flight) {
        var spots = fetchAllSpots()
        var nameIndex = Self.makeNameIndex(spots)
        assignSpot(to: flight, spots: &spots, nameIndex: &nameIndex)
    }

    /// Batch variant of `assignSpot(to:)`: works over pre-fetched spots and a
    /// lowercased-name index, appending any spot it creates to both — one
    /// fetch serves a whole migration/import pass instead of O(flights × spots).
    private func assignSpot(to flight: Flight, spots: inout [Spot], nameIndex: inout [String: Spot]) {
        guard flight.spot == nil else { return }

        let name = (flight.spotName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinate = flight.latitude.flatMap { lat in
            flight.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) }
        }

        // 1. The flight's own name wins — GPS proximity must never silently
        //    rename a hand-labeled flight.
        if !name.isEmpty, let match = nameIndex[name.lowercased()] {
            // Opportunistically fill missing coordinates from the flight
            if match.latitude == nil, let coordinate {
                match.latitude = coordinate.latitude
                match.longitude = coordinate.longitude
            }
            flight.spot = match
            flight.spotName = match.name
            return
        }

        // 2. Unnamed flight: GPS-nearest existing spot within 1.5 km.
        if name.isEmpty {
            if let coordinate, let nearby = nearestSpot(to: coordinate, within: 1500, among: spots) {
                flight.spot = nearby
                flight.spotName = nearby.name
            }
            return
        }

        // 3. Named flight with no matching spot: create it (city starts equal
        //    to the name — same convention as findOrCreateSpot).
        let spot = Spot(name: name, city: name, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        modelContext.insert(spot)
        spots.append(spot)
        nameIndex[name.lowercased()] = spot
        flight.spot = spot
        flight.spotName = spot.name
        logInfo("Spot created: \(name)", category: .flight)
    }

    /// Links every unlinked flight that still carries a spotName to a Spot
    /// entity. Called explicitly after backup imports (intentional), and once
    /// ever at first launch via `runSpotMigrationIfNeeded()`. Groups by
    /// spotName so "Tarifa" becomes ONE spot with city "Tarifa" that can then
    /// be renamed or split from the spot manager. Fetches the spot list once
    /// and reuses it for every flight.
    func linkUnlinkedFlights() {
        let unlinked = fetchFlights().filter { $0.spot == nil && !($0.spotName ?? "").isEmpty }
        guard !unlinked.isEmpty else { return }

        var spots = fetchAllSpots()
        var nameIndex = Self.makeNameIndex(spots)
        for flight in unlinked {
            assignSpot(to: flight, spots: &spots, nameIndex: &nameIndex)
        }
        saveContext()
        logInfo("Linked \(unlinked.count) flights to spots", category: .flight)
    }

    /// One-time launch migration: links legacy spotName-only flights to Spot
    /// entities, then never runs again (persisted flag). Deliberately NOT
    /// repeated per launch: after `deleteSpot`, flights keep their spotName
    /// but stay unlinked — re-running would resurrect the deleted spot.
    /// Backup imports still call `linkUnlinkedFlights()` explicitly.
    func runSpotMigrationIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.spotMigrationCompletedKey) else { return }
        linkUnlinkedFlights()
        UserDefaults.standard.set(true, forKey: Self.spotMigrationCompletedKey)
        logInfo("One-time spot migration completed", category: .flight)
    }

    /// Renames a spot (name and/or city) and rewrites the denormalized
    /// spotName on all its flights.
    func updateSpot(_ spot: Spot, name: String, city: String?, coordinate: CLLocationCoordinate2D?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        spot.name = trimmedName
        // City semantics: nil = leave unchanged, explicit empty string = clear.
        if let trimmedCity = city?.trimmingCharacters(in: .whitespacesAndNewlines) {
            spot.city = trimmedCity.isEmpty ? nil : trimmedCity
        }
        if let coordinate {
            spot.latitude = coordinate.latitude
            spot.longitude = coordinate.longitude
        }
        for flight in spot.flights ?? [] {
            flight.spotName = trimmedName
        }
        saveContext()
        logInfo("Spot updated: \(trimmedName) (\(spot.flights?.count ?? 0) flights renamed)", category: .flight)
    }

    /// Moves flights to another spot (used to split a city-spot into real
    /// launches). Updates the denormalized name on every moved flight.
    func reassignFlights(_ flights: [Flight], to spot: Spot) {
        for flight in flights {
            flight.spot = spot
            flight.spotName = spot.name
        }
        // A spot without coordinates inherits them from its first flight
        if spot.latitude == nil,
           let first = flights.first(where: { $0.latitude != nil && $0.longitude != nil }) {
            spot.latitude = first.latitude
            spot.longitude = first.longitude
        }
        saveContext()
        logInfo("\(flights.count) flights reassigned to \(spot.name)", category: .flight)
    }

    /// Deletes a spot; its flights keep their spotName but lose the link and
    /// STAY unlinked (the launch migration runs only once, so the deleted spot
    /// is not resurrected on the next launch). They can be reassigned manually,
    /// and a backup import's explicit link pass may re-link them by name.
    func deleteSpot(_ spot: Spot) {
        modelContext.delete(spot)
        saveContext()
    }

    // MARK: - Spot Splitting (GPS clustering)

    /// Groups flights into clusters of nearby GPS positions: a flight joins a
    /// cluster when it is within `radius` meters of the cluster's (running)
    /// centroid, otherwise it starts a new one. Flights without coordinates
    /// are ignored. Clusters come back largest-first.
    func clusterFlightsByLocation(_ flights: [Flight], radius: Double = 1000) -> [[Flight]] {
        var clusters: [(lat: Double, lon: Double, flights: [Flight])] = []

        for flight in flights {
            guard let lat = flight.latitude, let lon = flight.longitude else { continue }
            let location = CLLocation(latitude: lat, longitude: lon)

            var placed = false
            for i in clusters.indices {
                let center = CLLocation(latitude: clusters[i].lat, longitude: clusters[i].lon)
                if location.distance(from: center) <= radius {
                    clusters[i].flights.append(flight)
                    // Running centroid update
                    let n = Double(clusters[i].flights.count)
                    clusters[i].lat += (lat - clusters[i].lat) / n
                    clusters[i].lon += (lon - clusters[i].lon) / n
                    placed = true
                    break
                }
            }
            if !placed {
                clusters.append((lat, lon, [flight]))
            }
        }

        return clusters
            .sorted { $0.flights.count > $1.flights.count }
            .map(\.flights)
    }

    /// Result of a spot split.
    struct SpotSplitResult {
        let createdNames: [String]
        let movedFlights: Int
        let keptWithoutLocation: Int
        let originalDeleted: Bool
    }

    /// Splits a spot into GPS clusters: each cluster becomes a new spot named
    /// "<name> 1", "<name> 2", ... (largest first, city inherited, coordinates
    /// = cluster centroid) ready to be renamed to the real launch. Flights
    /// without GPS stay in the original spot; if none remain, it is deleted.
    /// Returns nil when everything already sits within one cluster.
    @discardableResult
    func splitSpotByLocation(_ spot: Spot, radius: Double = 1000) -> SpotSplitResult? {
        // Same ordering as the UI preview (SpotDetailView sorts startDate
        // descending): greedy clustering is order-dependent, so the preview
        // and the actual split must feed the clusterer the same sequence.
        let allFlights = (spot.flights ?? []).sorted { $0.startDate > $1.startDate }
        let clusters = clusterFlightsByLocation(allFlights, radius: radius)
        guard clusters.count >= 2 else { return nil }

        // Unique numbered names (skip names already taken by other spots)
        var takenNames = Set(fetchSpots().map { $0.name.lowercased() })
        let city = spot.city ?? spot.name

        var createdNames: [String] = []
        var moved = 0
        var counter = 1

        for cluster in clusters {
            var name = "\(spot.name) \(counter)"
            while takenNames.contains(name.lowercased()) {
                counter += 1
                name = "\(spot.name) \(counter)"
            }
            counter += 1
            takenNames.insert(name.lowercased())

            let centroidLat = cluster.compactMap(\.latitude).reduce(0, +) / Double(cluster.count)
            let centroidLon = cluster.compactMap(\.longitude).reduce(0, +) / Double(cluster.count)

            let newSpot = Spot(name: name, city: city, latitude: centroidLat, longitude: centroidLon)
            modelContext.insert(newSpot)

            for flight in cluster {
                flight.spot = newSpot
                flight.spotName = name
            }
            moved += cluster.count
            createdNames.append(name)
        }

        // Flights without GPS stay behind; delete the original only when empty.
        // Count from the input minus the moved flights instead of re-reading
        // the in-memory inverse relationship, which may not be refreshed yet.
        let remaining = allFlights.count - moved
        var originalDeleted = false
        if remaining == 0 {
            modelContext.delete(spot)
            originalDeleted = true
        }

        saveContext()
        logInfo("Spot split: \(createdNames.count) spots created from \(spot.name), \(moved) flights moved", category: .flight)

        return SpotSplitResult(
            createdNames: createdNames,
            movedFlights: moved,
            keptWithoutLocation: remaining,
            originalDeleted: originalDeleted
        )
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

    // MARK: - Trim reminders

    /// Fire-and-forget refresh of the local trim reminders after something
    /// changed a wing's hour counters (flight saved, service logged, wing
    /// edited). Fail-soft: never affects the save path (same spirit as the
    /// community share).
    func refreshTrimReminders() {
        let wings = fetchWings()
        Task { await WingMaintenance.scheduleTrimReminders(wings: wings) }
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
