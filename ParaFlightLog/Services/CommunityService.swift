//
//  CommunityService.swift
//  ParaFlightLog
//
//  Opt-in community sharing to Appwrite (roadmap Step C, data layer).
//  - C0/C1: shares flight SUMMARIES only (spot ref, date, duration, type —
//    never the GPS track or notes) into `shared_flights`, and seeds the
//    global `community_spots` collection keyed by CommunitySpotKey.
//  - C2: live presence heartbeat in `presence` (doc ID = user ID, 2h TTL).
//  - C3 (client-side v1): per-spot community stats aggregated on device.
//
//  Everything here is best-effort: sharing OFF, signed out, or a backend
//  with the collections not created yet must never affect the app — the
//  fire-and-forget entry points only log, mirroring WeatherService.
//
//  Console setup: see APPWRITE_COMMUNITY_SETUP.md at the repo root.
//  Target: iOS only
//

import Foundation
import Appwrite // re-exports JSONCodable (AnyCodable)

// MARK: - Errors

/// Short, user-facing error messages for community sharing failures
enum CommunityError: LocalizedError {
    case notSignedIn
    case backendNotConfigured
    case rateLimited
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You must be signed in to share flights."
        case .backendNotConfigured:
            return "Community sharing is not available yet. Please try again later."
        case .rateLimited:
            return "Too many requests. Please try again in a minute."
        case .network:
            return "Network error. Check your connection and try again."
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Community Stats (C3, client-side v1)

/// Aggregated community activity for one spot, computed on device from
/// `shared_flights` + `presence`. Cheap v1 — an Appwrite function can take
/// over the aggregation later without changing this shape.
struct SpotCommunityStats {
    var flightsThisMonth: Int
    var pilotsThisMonth: Int
    var hoursThisYear: Double
    /// Up to 3 pilots by hours this year at this spot.
    var topPilots: [(name: String, hours: Double)]
    /// Pilots with a live (non-expired) presence heartbeat at this spot.
    var pilotsFlyingNow: Int
}

// MARK: - Explore models (Step D, client-side v1)

/// One community spot on the Explore map/list: identity + coordinates from
/// `community_spots`, decorated with recent activity (shared flights in the
/// last 30 days) and live presence, both aggregated on device.
struct CommunitySpotSummary: Identifiable {
    let spotKey: String
    let name: String
    let latitude: Double
    let longitude: Double
    var flightsLast30Days: Int
    var pilotsFlyingNow: Int

    var id: String { spotKey }
}

/// One shared flight in a spot's recent-activity feed (Explore detail sheet).
struct SharedFlightSummary: Identifiable {
    /// Appwrite row ID (the shared flight's UUID, lowercased).
    let id: String
    let pilotName: String
    let date: Date
    let durationSeconds: Int
    /// Raw flight-type string as shared (maps onto `FlightType` when known).
    let flightType: String?
}

/// One community takeoff-wind observation used by the learned-flyability
/// engine (Phase 2): a shared flight's wind AT TAKEOFF. Only rows that
/// carried both a wind speed and a wind direction become observations.
struct WindObservation {
    /// km/h at takeoff.
    let windSpeed: Double
    /// Degrees, direction the wind comes FROM.
    let windDirectionDeg: Double
    let date: Date
    /// Raw flight-type string as shared (maps onto `FlightType` when known).
    let flightType: String?
}

// MARK: - Service

@Observable @MainActor
final class CommunityService {
    static let shared = CommunityService()

    private var tablesDB: TablesDB { AppwriteService.shared.tablesDB }

    /// Community spot documents already created/verified this session, so
    /// repeated shares at the same spot skip the extra round trip.
    private var ensuredSpotKeys: Set<String> = []

    /// In-memory stats cache per spot key, 15-minute TTL.
    private var statsCache: [String: (stats: SpotCommunityStats, fetchedAt: Date)] = [:]
    private static let statsCacheTTL: TimeInterval = 15 * 60

    /// Explore screen cache (all community spots + activity), 15-minute TTL.
    /// Single entry: the whole screen is built from one aggregate fetch.
    private var exploreCache: (spots: [CommunitySpotSummary], fetchedAt: Date)?

    /// Recent shared flights per spot key (Explore detail sheet), 15-minute TTL.
    private var recentFlightsCache: [String: (flights: [SharedFlightSummary], fetchedAt: Date)] = [:]

    /// Community takeoff-wind observations per spot key (Phase 2 learning),
    /// 15-minute TTL. Read by SpotIntelligenceService.
    private var windObsCache: [String: (obs: [WindObservation], fetchedAt: Date)] = [:]

    /// Presence heartbeats expire 2 hours after takeoff.
    private static let presenceTTL: TimeInterval = 2 * 3600

    private init() {}

    // MARK: - Settings (UserDefaults-backed)

    /// Master opt-in for uploading flight summaries. Default FALSE.
    var isSharingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.communitySharingEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.communitySharingEnabled) }
    }

    /// Opt-in for the live presence heartbeat. Default FALSE.
    var isPresenceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.presenceEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.presenceEnabled) }
    }

    /// Public display name attached to shared flights. Empty -> "A pilot".
    var pilotDisplayName: String {
        get { UserDefaults.standard.string(forKey: UserDefaultsKeys.pilotDisplayName) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.pilotDisplayName) }
    }

    /// The name written into shared documents.
    private var effectivePilotName: String {
        let trimmed = pilotDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A pilot" : String(trimmed.prefix(64))
    }

    // MARK: - Share (C1)

    /// Fire-and-forget share of one flight, called after every successful
    /// flight save (same pattern as WeatherService.captureSnapshot). Silently
    /// does nothing unless sharing is ON, the user is signed in and the
    /// flight has a spot with coordinates. Never throws, never blocks the
    /// save/ACK path that calls it.
    func shareFlightIfEnabled(_ flight: Flight, dataController: DataController) {
        guard isSharingEnabled else { return }
        guard case .signedIn(let userId, _) = AuthService.shared.state else { return }
        let flightId = flight.id

        Task { [weak dataController] in
            guard let dataController,
                  let flight = dataController.findFlight(byId: flightId) else { return }
            do {
                guard let spotKey = try await self.share(flight: flight, userId: userId) else { return }
                // Re-fetch after the awaits: the flight (or its spot) may
                // have been deleted while the requests ran.
                if let flight = dataController.findFlight(byId: flightId),
                   let spot = flight.spot,
                   spot.communitySpotKey != spotKey {
                    spot.communitySpotKey = spotKey
                    dataController.saveContext()
                }
                logInfo("Flight \(flightId) shared to the community (\(spotKey))", category: .community)
            } catch {
                logInfo("Community share skipped for flight \(flightId): \(Self.mapError(error).localizedDescription)", category: .community)
            }
        }
    }

    /// Plain-value snapshot of one eligible flight, captured BEFORE any
    /// await so no SwiftData model is ever dereferenced across a suspension
    /// point (the flight/spot could be deleted or faulted out while a
    /// request runs).
    private struct FlightShareSnapshot {
        let flightId: UUID
        let startDate: Date
        let durationSeconds: Int
        let flightType: String?
        let spotName: String
        let latitude: Double
        let longitude: Double
        let spotKey: String
        // Weather at takeoff (Phase 2 learning) — best-effort, any may be nil.
        let takeoffWindSpeed: Double?
        let takeoffWindGusts: Double?
        let takeoffWindDirection: Double?
    }

    /// Snapshots the shareable values of a flight, or nil when the flight
    /// is not eligible (no spot, or spot without coordinates / key).
    private static func makeSnapshot(of flight: Flight) -> FlightShareSnapshot? {
        guard let spot = flight.spot,
              let latitude = spot.latitude,
              let longitude = spot.longitude,
              let spotKey = CommunitySpotKey.make(name: spot.name, latitude: latitude, longitude: longitude) else {
            return nil
        }
        return FlightShareSnapshot(
            flightId: flight.id,
            startDate: flight.startDate,
            durationSeconds: flight.durationSeconds,
            flightType: flight.flightType,
            spotName: spot.name,
            latitude: latitude,
            longitude: longitude,
            spotKey: spotKey,
            takeoffWindSpeed: flight.takeoffWindSpeed,
            takeoffWindGusts: flight.takeoffWindGusts,
            takeoffWindDirection: flight.takeoffWindDirection
        )
    }

    /// Shares one flight summary: upserts the community spot, then the
    /// shared flight document (ID = flight UUID, so re-sharing is
    /// idempotent). Returns the community spot key on success, nil when the
    /// flight is not eligible (no spot, or spot without coordinates). Does
    /// NOT touch the local models — the caller records `communitySpotKey`
    /// and saves the context.
    private func share(flight: Flight, userId: String) async throws -> String? {
        // Snapshot everything BEFORE the awaits: SwiftData models must not
        // be trusted across suspension points.
        guard let snapshot = Self.makeSnapshot(of: flight) else { return nil }
        return try await share(snapshot: snapshot, userId: userId)
    }

    /// Uploads one snapshotted flight summary (spot upsert + flight upsert).
    /// Pure plain values: safe to run long after the source models changed.
    /// `skipSpotUpsert` lets a batch backfill upsert each community spot once
    /// for the whole run rather than once per flight.
    private func share(snapshot: FlightShareSnapshot, userId: String, skipSpotUpsert: Bool = false) async throws -> String {
        var document: [String: Any] = [
            "userId": userId,
            "pilotName": effectivePilotName,
            "spotKey": snapshot.spotKey,
            "spotName": String(snapshot.spotName.prefix(128)),
            "latitude": Self.round2(snapshot.latitude),
            "longitude": Self.round2(snapshot.longitude),
            "date": Self.isoString(from: snapshot.startDate),
            "durationSeconds": snapshot.durationSeconds
        ]
        if let flightType = snapshot.flightType {
            document["flightType"] = String(flightType.prefix(32))
        }
        // Takeoff wind (Phase 2 learning) — only written when present, so a
        // flight without a weather snapshot never overwrites the column with 0.
        if let windSpeed = snapshot.takeoffWindSpeed {
            document["takeoffWindSpeed"] = windSpeed
        }
        if let windGusts = snapshot.takeoffWindGusts {
            document["takeoffWindGusts"] = windGusts
        }
        if let windDirection = snapshot.takeoffWindDirection {
            document["takeoffWindDirection"] = windDirection
        }

        if !skipSpotUpsert {
            try await ensureCommunitySpot(
                key: snapshot.spotKey,
                name: snapshot.spotName,
                latitude: snapshot.latitude,
                longitude: snapshot.longitude,
                userId: userId
            )
        }

        // Upsert = idempotent re-share; the doc is owned by this user only.
        _ = try await tablesDB.upsertRow(
            databaseId: AppwriteConfig.databaseId,
            tableId: AppwriteConfig.sharedFlightsCollectionId,
            rowId: Self.rowId(for: snapshot.flightId.uuidString),
            data: document,
            permissions: Self.sharedDocumentPermissions(userId: userId)
        )

        statsCache.removeValue(forKey: snapshot.spotKey)
        recentFlightsCache.removeValue(forKey: snapshot.spotKey)
        windObsCache.removeValue(forKey: snapshot.spotKey)
        exploreCache = nil
        return snapshot.spotKey
    }

    /// Creates the shared community spot document if it doesn't exist yet
    /// (document ID = spot key). An "already exists" conflict is a success —
    /// another pilot seeded the spot first.
    private func ensureCommunitySpot(key: String, name: String, latitude: Double, longitude: Double, userId: String) async throws {
        guard !ensuredSpotKeys.contains(key) else { return }

        do {
            _ = try await tablesDB.createRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.communitySpotsCollectionId,
                rowId: key,
                data: [
                    "name": String(name.prefix(128)),
                    "latitude": Self.round2(latitude),
                    "longitude": Self.round2(longitude),
                    "createdBy": userId
                ],
                permissions: Self.sharedDocumentPermissions(userId: userId)
            )
            logInfo("Community spot created: \(key)", category: .community)
        } catch {
            guard Self.isAlreadyExists(error) else { throw error }
        }
        ensuredSpotKeys.insert(key)
    }

    /// Batched backfill of the user's flight history (Settings action after
    /// enabling sharing). Sequential with a steady ~300 ms pace between
    /// flights, exponential-backoff retries on rate limits, and one community
    /// spot upsert per spot for the whole run (not per flight) to stay well
    /// under Appwrite's rate limit. Reports progress as (done, totalEligible)
    /// and returns the number of flights shared.
    /// Per-row permission failures (rows owned by a previous account after
    /// an account switch) are skipped, not fatal.
    /// NOTE: sets `communitySpotKey` on shared spots — the caller should
    /// `dataController.saveContext()` once this returns.
    func shareHistory(flights: [Flight], progress: @escaping (Int, Int) -> Void) async throws -> Int {
        guard isSharingEnabled else { return 0 }
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw CommunityError.notSignedIn
        }

        // Snapshot ALL eligible flights up front, as plain values: the loop
        // below suspends on every iteration and must never dereference a
        // SwiftData model that could have been deleted/faulted meanwhile.
        let snapshots = flights.compactMap(Self.makeSnapshot(of:))
        guard !snapshots.isEmpty else { return 0 }

        // Spots upserted during THIS run: the per-flight spot upsert is the
        // main request cost, so each community spot is written at most once
        // for the whole backfill (the session-level `ensuredSpotKeys` cache
        // guarantees the same, but this makes the intent local and explicit).
        var upsertedSpotKeys: Set<String> = []

        var shared = 0
        var skippedPermission = 0
        for (index, snapshot) in snapshots.enumerated() {
            do {
                // Retry the SAME item with exponential backoff on rate limits
                // instead of aborting the whole backfill halfway through.
                let spotKey = try await withRateLimitRetry {
                    try await self.share(
                        snapshot: snapshot,
                        userId: userId,
                        skipSpotUpsert: upsertedSpotKeys.contains(snapshot.spotKey)
                    )
                }
                upsertedSpotKeys.insert(spotKey)
                shared += 1
                // Re-fetch the flight through the live DataController (never
                // a stale model reference) to record its community spot key.
                if let dataController = WatchConnectivityManager.shared.dataController,
                   let flight = dataController.findFlight(byId: snapshot.flightId),
                   let spot = flight.spot,
                   spot.communitySpotKey != spotKey {
                    spot.communitySpotKey = spotKey
                }
            } catch let error where Self.isPermissionDenied(error) {
                // Account-switch case: this row was created by a previous
                // account and can't be overwritten. Skip it, keep going.
                skippedPermission += 1
                logWarning("History share skipped flight \(snapshot.flightId): row owned by another account", category: .community)
            } catch {
                logWarning("History share stopped at \(shared)/\(snapshots.count): \(error)", category: .community)
                throw Self.mapError(error)
            }
            progress(index + 1, snapshots.count)

            // Steady pace between shared flights to stay under the rate limit.
            if index + 1 < snapshots.count {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 s
            }
        }
        if skippedPermission > 0 {
            logWarning("History backfill skipped \(skippedPermission) flight(s) owned by another account", category: .community)
        }
        logInfo("History backfill shared \(shared)/\(snapshots.count) flights", category: .community)
        return shared
    }

    /// Runs `operation`, retrying on Appwrite rate-limit errors with
    /// exponential backoff (2 s, 4 s, 8 s) up to `maxAttempts` total tries.
    /// Any non-rate-limit error, or an exhausted budget, propagates.
    private func withRateLimitRetry<T>(
        maxAttempts: Int = 4,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch where Self.isRateLimited(error) && attempt < maxAttempts - 1 {
                let delaySeconds = pow(2.0, Double(attempt + 1)) // 2, 4, 8
                logWarning("Community rate-limited; backing off \(Int(delaySeconds))s (attempt \(attempt + 1)/\(maxAttempts))", category: .community)
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                attempt += 1
            }
        }
    }

    /// Deletes every shared flight owned by the current user, plus the live
    /// presence document (Settings "Stop & delete my shared data" action).
    /// Community spot documents stay — they belong to the community.
    func unshareAllMyFlights() async throws {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw CommunityError.notSignedIn
        }

        do {
            var deleted = 0
            // Delete-as-you-list pagination; hard cap as an infinite-loop guard.
            for _ in 0..<100 {
                let page = try await tablesDB.listRows(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.sharedFlightsCollectionId,
                    queries: [
                        Query.equal("userId", value: userId),
                        Query.limit(100)
                    ]
                )
                guard !page.rows.isEmpty else { break }
                for row in page.rows {
                    _ = try await tablesDB.deleteRow(
                        databaseId: AppwriteConfig.databaseId,
                        tableId: AppwriteConfig.sharedFlightsCollectionId,
                        rowId: row.id
                    )
                    deleted += 1
                }
            }

            // Best-effort presence cleanup; the 2h TTL covers a failure here.
            _ = try? await tablesDB.deleteRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.presenceCollectionId,
                rowId: Self.rowId(for: userId)
            )

            statsCache.removeAll()
            recentFlightsCache.removeAll()
            windObsCache.removeAll()
            exploreCache = nil
            logInfo("Deleted \(deleted) shared flights for user \(userId)", category: .community)
        } catch {
            logWarning("Unshare-all failed: \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Presence (C2)

    /// Fire-and-forget presence heartbeat when a flight starts (triggered by
    /// the Watch's `flightStarted` message). One document per user (ID =
    /// user ID), overwritten on every takeoff, expiring 2 hours later.
    /// - Parameter spotKey: canonical community key of the resolved spot;
    ///   when nil it is derived from the given name + coordinates.
    func startPresence(latitude: Double, longitude: Double, spotName: String, spotKey: String? = nil) {
        guard isPresenceEnabled else { return }
        guard case .signedIn(let userId, _) = AuthService.shared.state else { return }

        let key = spotKey
            ?? CommunitySpotKey.make(name: spotName, latitude: latitude, longitude: longitude)
        guard let key else { return }

        let now = Date()
        let document: [String: Any] = [
            "spotKey": key,
            "spotName": String(spotName.prefix(128)),
            "latitude": Self.round2(latitude),
            "longitude": Self.round2(longitude),
            "startedAt": Self.isoString(from: now),
            "expiresAt": Self.isoString(from: now.addingTimeInterval(Self.presenceTTL))
        ]

        Task {
            do {
                _ = try await self.tablesDB.upsertRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.presenceCollectionId,
                    rowId: Self.rowId(for: userId),
                    data: document,
                    permissions: Self.sharedDocumentPermissions(userId: userId)
                )
                logInfo("Presence started at \(key)", category: .community)
            } catch {
                logInfo("Presence heartbeat skipped: \(Self.mapError(error).localizedDescription)", category: .community)
            }
        }
    }

    /// Fire-and-forget removal of the user's presence document (flight
    /// landed). Best-effort: a missing document or a failure is fine — the
    /// 2-hour TTL expires the heartbeat anyway. Deliberately NOT gated on
    /// `isPresenceEnabled`: deleting is idempotent and cheap, and a pilot
    /// who disables the toggle mid-flight still wants the stale heartbeat
    /// cleaned up on landing.
    func endPresence() {
        guard case .signedIn(let userId, _) = AuthService.shared.state else { return }

        Task {
            do {
                _ = try await self.tablesDB.deleteRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.presenceCollectionId,
                    rowId: Self.rowId(for: userId)
                )
                logInfo("Presence ended", category: .community)
            } catch {
                logDebug("Presence cleanup skipped: \(Self.mapError(error).localizedDescription)", category: .community)
            }
        }
    }

    // MARK: - Paginated listing

    /// Lists rows with a cursorAfter loop in pages of 100 (many servers
    /// clamp larger limits to 100, which would silently truncate a single
    /// big-limit query), collecting at most `maxTotal` rows (~1000 default
    /// as a client-side aggregation cap).
    private func listAllRows(
        tableId: String,
        queries baseQueries: [String],
        maxTotal: Int = 1000
    ) async throws -> [Row<[String: AnyCodable]>] {
        var rows: [Row<[String: AnyCodable]>] = []
        var cursor: String?
        while rows.count < maxTotal {
            var queries = baseQueries
            queries.append(Query.limit(min(100, maxTotal - rows.count)))
            if let cursor {
                queries.append(Query.cursorAfter(cursor))
            }
            let page = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: tableId,
                queries: queries
            )
            rows.append(contentsOf: page.rows)
            // A short page means the results ran out.
            guard page.rows.count == 100, let last = page.rows.last else { break }
            cursor = last.id
        }
        return rows
    }

    // MARK: - Community stats (C3, client-side v1)

    /// Community activity for one spot, aggregated on device from up to
    /// ~1000 shared flights this year + live presence. Cached in memory for
    /// 15 minutes per spot key.
    func communityStats(forSpotKey spotKey: String) async throws -> SpotCommunityStats {
        if let entry = statsCache[spotKey],
           Date().timeIntervalSince(entry.fetchedAt) < Self.statsCacheTTL {
            return entry.stats
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let startOfYear = calendar.dateInterval(of: .year, for: now)?.start ?? now

        do {
            let flightRows = try await listAllRows(
                tableId: AppwriteConfig.sharedFlightsCollectionId,
                queries: [
                    Query.equal("spotKey", value: spotKey),
                    Query.greaterThanEqual("date", value: Self.isoString(from: startOfYear)),
                    Query.orderDesc("date")
                ]
            )

            let presencePage = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.presenceCollectionId,
                queries: [
                    Query.equal("spotKey", value: spotKey),
                    Query.greaterThan("expiresAt", value: Self.isoString(from: now)),
                    Query.limit(100)
                ]
            )

            var flightsThisMonth = 0
            var pilotsThisMonth: Set<String> = []
            var hoursThisYear: Double = 0
            var hoursByPilot: [String: Double] = [:]
            var nameByPilot: [String: String] = [:]

            for row in flightRows {
                let data = row.data
                let userId = data["userId"]?.value as? String ?? ""
                let hours = Double(Self.intValue(data["durationSeconds"])) / 3600

                hoursThisYear += hours
                if !userId.isEmpty {
                    hoursByPilot[userId, default: 0] += hours
                    if nameByPilot[userId] == nil, let name = data["pilotName"]?.value as? String, !name.isEmpty {
                        nameByPilot[userId] = name
                    }
                }
                if let dateString = data["date"]?.value as? String,
                   let date = Self.parseISODate(dateString),
                   date >= startOfMonth {
                    flightsThisMonth += 1
                    if !userId.isEmpty {
                        pilotsThisMonth.insert(userId)
                    }
                }
            }

            let topPilots: [(name: String, hours: Double)] = hoursByPilot
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { (name: nameByPilot[$0.key] ?? "A pilot", hours: $0.value) }

            let stats = SpotCommunityStats(
                flightsThisMonth: flightsThisMonth,
                pilotsThisMonth: pilotsThisMonth.count,
                hoursThisYear: hoursThisYear,
                topPilots: topPilots,
                pilotsFlyingNow: presencePage.rows.count
            )
            statsCache[spotKey] = (stats, Date())
            return stats
        } catch {
            logInfo("Community stats unavailable for \(spotKey): \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Explore (Step D, client-side v1)

    /// All community spots with recent activity for the Explore screen:
    /// lists `community_spots` (paginated, ~500 cap), then a paginated query
    /// on `shared_flights` (last 30 days, ~1000 cap) and one on `presence`
    /// (non-expired, ~1000 cap), both grouped by spot key on device. The spots list is authoritative —
    /// the two activity queries are decoration and fail soft to zero counts.
    /// Cached in memory for 15 minutes (single entry); `forceRefresh` is the
    /// pull-to-refresh bypass.
    func exploreSpots(forceRefresh: Bool = false) async throws -> [CommunitySpotSummary] {
        if !forceRefresh,
           let cache = exploreCache,
           Date().timeIntervalSince(cache.fetchedAt) < Self.statsCacheTTL {
            return cache.spots
        }

        // 1. All community spots (cursor pagination, capped at ~500 —
        //    server-side aggregation takes over before that matters).
        var summaries: [CommunitySpotSummary] = []
        var indexByKey: [String: Int] = [:]
        do {
            var cursor: String?
            for _ in 0..<5 {
                var queries = [Query.limit(100)]
                if let cursor {
                    queries.append(Query.cursorAfter(cursor))
                }
                let page = try await tablesDB.listRows(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.communitySpotsCollectionId,
                    queries: queries
                )
                for row in page.rows {
                    let data = row.data
                    // A spot without coordinates can't be explored — skip it.
                    guard let latitude = Self.doubleValue(data["latitude"]),
                          let longitude = Self.doubleValue(data["longitude"]) else { continue }
                    let name = (data["name"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? row.id
                    indexByKey[row.id] = summaries.count
                    summaries.append(CommunitySpotSummary(
                        spotKey: row.id,
                        name: name,
                        latitude: latitude,
                        longitude: longitude,
                        flightsLast30Days: 0,
                        pilotsFlyingNow: 0
                    ))
                }
                guard page.rows.count == 100, let last = page.rows.last else { break }
                cursor = last.id
            }
        } catch {
            logInfo("Explore spots unavailable: \(error)", category: .community)
            throw Self.mapError(error)
        }

        // 2. Shared flights in the last 30 days, grouped by spot key.
        //    Query.select keeps the payload tiny ("$id" kept explicitly —
        //    cursor pagination and row decoding both need it).
        do {
            let since = Self.isoString(from: Date().addingTimeInterval(-30 * 24 * 3600))
            let flightRows = try await listAllRows(
                tableId: AppwriteConfig.sharedFlightsCollectionId,
                queries: [
                    Query.greaterThan("date", value: since),
                    Query.select(["spotKey", "$id"])
                ]
            )
            for row in flightRows {
                guard let key = row.data["spotKey"]?.value as? String,
                      let index = indexByKey[key] else { continue }
                summaries[index].flightsLast30Days += 1
            }
        } catch {
            logInfo("Explore flight counts unavailable: \(error)", category: .community)
        }

        // 3. Live presence (non-expired heartbeats), grouped by spot key.
        do {
            let presenceRows = try await listAllRows(
                tableId: AppwriteConfig.presenceCollectionId,
                queries: [
                    Query.greaterThan("expiresAt", value: Self.isoString(from: Date())),
                    Query.select(["spotKey", "$id"])
                ]
            )
            for row in presenceRows {
                guard let key = row.data["spotKey"]?.value as? String,
                      let index = indexByKey[key] else { continue }
                summaries[index].pilotsFlyingNow += 1
            }
        } catch {
            logInfo("Explore presence unavailable: \(error)", category: .community)
        }

        summaries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        exploreCache = (summaries, Date())
        logInfo("Explore loaded \(summaries.count) community spots", category: .community)
        return summaries
    }

    /// Most recent shared flights at one community spot (Explore detail
    /// sheet), newest first. Cached in memory for 15 minutes per spot key.
    func recentFlights(forSpotKey spotKey: String, limit: Int = 20) async throws -> [SharedFlightSummary] {
        if let entry = recentFlightsCache[spotKey],
           Date().timeIntervalSince(entry.fetchedAt) < Self.statsCacheTTL {
            return Array(entry.flights.prefix(limit))
        }

        do {
            let page = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.sharedFlightsCollectionId,
                queries: [
                    Query.equal("spotKey", value: spotKey),
                    Query.orderDesc("date"),
                    Query.limit(max(1, min(limit, 100)))
                ]
            )
            let flights: [SharedFlightSummary] = page.rows.compactMap { row in
                let data = row.data
                guard let dateString = data["date"]?.value as? String,
                      let date = Self.parseISODate(dateString) else { return nil }
                let pilotName = (data["pilotName"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A pilot"
                return SharedFlightSummary(
                    id: row.id,
                    pilotName: pilotName,
                    date: date,
                    durationSeconds: Self.intValue(data["durationSeconds"]),
                    flightType: data["flightType"]?.value as? String
                )
            }
            recentFlightsCache[spotKey] = (flights, Date())
            return flights
        } catch {
            logInfo("Recent community flights unavailable for \(spotKey): \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Wind observations (Phase 2 learning)

    /// Community takeoff-wind observations at one spot, for the learned
    /// flyability engine (SpotIntelligenceService). Reads `shared_flights`
    /// rows (cursor-paginated, capped at ~500), keeping only those that
    /// carry BOTH a takeoff wind speed and a takeoff wind direction. Cached
    /// in memory for 15 minutes per spot key; fails soft via `mapError`.
    func communityWindObservations(forSpotKey spotKey: String) async throws -> [WindObservation] {
        if let entry = windObsCache[spotKey],
           Date().timeIntervalSince(entry.fetchedAt) < Self.statsCacheTTL {
            return entry.obs
        }

        do {
            // Newest first, so the ~500 cap keeps the most recent flights when
            // a very busy spot has more history than we aggregate on device.
            let rows = try await listAllRows(
                tableId: AppwriteConfig.sharedFlightsCollectionId,
                queries: [
                    Query.equal("spotKey", value: spotKey),
                    Query.orderDesc("date"),
                    Query.select(["takeoffWindSpeed", "takeoffWindDirection", "date", "flightType", "$id"])
                ],
                maxTotal: 500
            )

            let observations: [WindObservation] = rows.compactMap { row in
                let data = row.data
                // A row without both wind fields can't teach direction × force.
                guard let speed = Self.doubleValue(data["takeoffWindSpeed"]),
                      let direction = Self.doubleValue(data["takeoffWindDirection"]),
                      let dateString = data["date"]?.value as? String,
                      let date = Self.parseISODate(dateString) else { return nil }
                return WindObservation(
                    windSpeed: speed,
                    windDirectionDeg: direction,
                    date: date,
                    flightType: data["flightType"]?.value as? String
                )
            }
            windObsCache[spotKey] = (observations, Date())
            return observations
        } catch {
            logInfo("Community wind observations unavailable for \(spotKey): \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Helpers

    /// Read/write permissions for a community document: anyone can read,
    /// only the owner can change or delete it.
    private static func sharedDocumentPermissions(userId: String) -> [String] {
        [
            Permission.read(Role.any()),
            Permission.update(Role.user(userId)),
            Permission.delete(Role.user(userId))
        ]
    }

    /// Deterministic Appwrite row ID from a UUID string or user ID
    /// (a-z, 0-9, hyphen; max 36 chars — same convention as CloudBackupService).
    private static func rowId(for identifier: String) -> String {
        String(identifier.lowercased().prefix(36))
    }

    /// Rounds a coordinate to 2 decimals (~1.1 km) — enough for community
    /// features, coarse enough to avoid exposing precise takeoff points.
    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Parses Appwrite/ISO 8601 timestamps with or without fractional seconds.
    private static func parseISODate(_ string: String) -> Date? {
        if let date = isoFormatter.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Tolerant Int extraction from an Appwrite row value (Int or Double).
    private static func intValue(_ value: AnyCodable?) -> Int {
        if let int = value?.value as? Int { return int }
        if let double = value?.value as? Double { return Int(double) }
        return 0
    }

    /// Tolerant Double extraction from an Appwrite row value (Double or Int).
    private static func doubleValue(_ value: AnyCodable?) -> Double? {
        if let double = value?.value as? Double { return double }
        if let int = value?.value as? Int { return Double(int) }
        return nil
    }

    /// True for "document already exists" conflicts (create-or-ignore path).
    private static func isAlreadyExists(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 409
    }

    /// True for per-document permission denials (HTTP 401): after an
    /// account switch, rows created by the previous account can't be
    /// overwritten by the new one — a per-row condition, not a fatal one.
    private static func isPermissionDenied(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 401
    }

    /// True for Appwrite rate-limit errors: HTTP 429 or an error type that
    /// mentions "rate_limit" (e.g. `general_rate_limit_exceeded`).
    private static func isRateLimited(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 429 || (appwriteError.type?.contains("rate_limit") ?? false)
    }

    /// Maps Appwrite errors to short English user-facing messages.
    /// A missing database/collection means the backend isn't configured yet
    /// — the app must keep working, so callers log-and-continue on it.
    private static func mapError(_ error: Error) -> CommunityError {
        if let communityError = error as? CommunityError {
            return communityError
        }
        guard let appwriteError = error as? AppwriteError else {
            // Transport-level failure (no server response)
            return .network
        }
        switch appwriteError.type {
        case "database_not_found", "collection_not_found", "table_not_found":
            return .backendNotConfigured
        case "user_unauthorized", "general_unauthorized_scope", "general_unauthorized":
            return .notSignedIn
        case "general_rate_limit_exceeded":
            return .rateLimited
        default:
            return .unknown(appwriteError.message)
        }
    }
}
