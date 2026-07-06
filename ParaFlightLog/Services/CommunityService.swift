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

    /// Shares one flight summary: upserts the community spot, then the
    /// shared flight document (ID = flight UUID, so re-sharing is
    /// idempotent). Returns the community spot key on success, nil when the
    /// flight is not eligible (no spot, or spot without coordinates). Does
    /// NOT touch the local models — the caller records `communitySpotKey`
    /// and saves the context.
    private func share(flight: Flight, userId: String) async throws -> String? {
        guard let spot = flight.spot,
              let latitude = spot.latitude,
              let longitude = spot.longitude,
              let spotKey = CommunitySpotKey.make(name: spot.name, latitude: latitude, longitude: longitude) else {
            return nil
        }

        // Snapshot everything BEFORE the awaits: SwiftData models must not
        // be trusted across suspension points (the flight/spot could be
        // deleted while a request runs).
        let spotName = spot.name
        var document: [String: Any] = [
            "userId": userId,
            "pilotName": effectivePilotName,
            "spotKey": spotKey,
            "spotName": String(spotName.prefix(128)),
            "latitude": Self.round2(latitude),
            "longitude": Self.round2(longitude),
            "date": Self.isoString(from: flight.startDate),
            "durationSeconds": flight.durationSeconds
        ]
        if let flightType = flight.flightType {
            document["flightType"] = String(flightType.prefix(32))
        }
        let flightId = flight.id

        try await ensureCommunitySpot(key: spotKey, name: spotName, latitude: latitude, longitude: longitude, userId: userId)

        // Upsert = idempotent re-share; the doc is owned by this user only.
        _ = try await tablesDB.upsertRow(
            databaseId: AppwriteConfig.databaseId,
            tableId: AppwriteConfig.sharedFlightsCollectionId,
            rowId: Self.rowId(for: flightId.uuidString),
            data: document,
            permissions: Self.sharedDocumentPermissions(userId: userId)
        )

        statsCache.removeValue(forKey: spotKey)
        return spotKey
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
    /// enabling sharing). Sequential with a small pause every 10 documents
    /// to stay well under Appwrite's rate limit. Reports progress as
    /// (done, totalEligible) and returns the number of flights shared.
    /// NOTE: sets `communitySpotKey` on shared spots — the caller should
    /// `dataController.saveContext()` once this returns.
    func shareHistory(flights: [Flight], progress: @escaping (Int, Int) -> Void) async throws -> Int {
        guard isSharingEnabled else { return 0 }
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw CommunityError.notSignedIn
        }

        let eligible = flights.filter { flight in
            guard let spot = flight.spot else { return false }
            return CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude) != nil
        }
        guard !eligible.isEmpty else { return 0 }

        var shared = 0
        for (index, flight) in eligible.enumerated() {
            do {
                if let spotKey = try await share(flight: flight, userId: userId) {
                    shared += 1
                    if let spot = flight.spot, spot.communitySpotKey != spotKey {
                        spot.communitySpotKey = spotKey
                    }
                }
            } catch {
                logWarning("History share stopped at \(shared)/\(eligible.count): \(error)", category: .community)
                throw Self.mapError(error)
            }
            progress(index + 1, eligible.count)

            if (index + 1) % 10 == 0 && index + 1 < eligible.count {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            }
        }
        logInfo("History backfill shared \(shared)/\(eligible.count) flights", category: .community)
        return shared
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
    /// 2-hour TTL expires the heartbeat anyway (which also covers the pilot
    /// who disables presence mid-flight, skipped here to avoid pointless
    /// network calls on every flight receipt).
    func endPresence() {
        guard isPresenceEnabled else { return }
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

    // MARK: - Community stats (C3, client-side v1)

    /// Community activity for one spot, aggregated on device from up to 400
    /// shared flights this year + live presence. Cached in memory for 15
    /// minutes per spot key.
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
            let flightsPage = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.sharedFlightsCollectionId,
                queries: [
                    Query.equal("spotKey", value: spotKey),
                    Query.greaterThanEqual("date", value: Self.isoString(from: startOfYear)),
                    Query.orderDesc("date"),
                    Query.limit(400)
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

            for row in flightsPage.rows {
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

    /// True for "document already exists" conflicts (create-or-ignore path).
    private static func isAlreadyExists(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 409
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
