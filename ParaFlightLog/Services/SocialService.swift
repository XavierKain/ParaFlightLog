//
//  SocialService.swift
//  ParaFlightLog
//
//  Community SOCIAL LOOP (Phase 4): pilot profiles, follow graph, a
//  followed-pilots activity feed, per-flight kudos and per-spot
//  leaderboards. Built on the same Appwrite database as CommunityService
//  and ConditionReportService, reading the existing `shared_flights` rows
//  and three new v20 tables.
//
//  - `profiles_v20`: one public profile per user (row ID = user ID),
//    read by anyone, editable/deletable only by its owner.
//  - `follows_v20`: one public row per (follower, followed) edge
//    (deterministic doc ID), read by anyone, deletable by the follower.
//  - `flight_kudos_v20`: one public row per (flight, user) like
//    (deterministic doc ID), read by anyone, deletable by its author.
//
//  Everything is best-effort and fail-soft, mirroring CommunityService: a
//  backend without these tables (backendNotConfigured) must make the UI
//  hide its social sections silently, never crash or block. TablesDB access
//  goes through AppwriteService.shared; row parsing and error mapping mirror
//  CommunityService's style locally (that file is not edited from here).
//  Target: iOS only
//

import Foundation
import CryptoKit // deterministic follow / kudos document IDs
import Appwrite // re-exports JSONCodable (AnyCodable), Query, ID, Permission, Role

// MARK: - Errors

/// Short, user-facing error messages for social-loop failures.
enum SocialError: LocalizedError {
    case notSignedIn
    case backendNotConfigured
    case rateLimited
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You must be signed in to use the community."
        case .backendNotConfigured:
            return "The community feed is not available yet. Please try again later."
        case .rateLimited:
            return "Too many requests. Please try again in a minute."
        case .network:
            return "Network error. Check your connection and try again."
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Models

/// A public pilot profile (parsed from a `profiles_v20` row).
struct PilotProfile: Identifiable {
    let userId: String
    let pilotName: String
    let bio: String?
    let homeSpotKey: String?
    let homeSpotName: String?
    let statsPublic: Bool

    var id: String { userId }
}

/// One shared flight in the social feed or a profile's recent activity.
/// Decorated on device with the kudos count and whether the current user
/// has kudoed it.
struct FeedItem: Identifiable {
    /// `shared_flights` row ID.
    let id: String
    let userId: String
    let pilotName: String
    let spotName: String
    let spotKey: String
    let date: Date
    let durationSeconds: Int
    let flightType: String?
    var kudosCount: Int
    var hasKudoed: Bool
}

/// One row of a per-spot leaderboard, aggregated on device from
/// `shared_flights`.
struct LeaderboardEntry: Identifiable {
    /// The pilot's user ID.
    let id: String
    let pilotName: String
    let totalSeconds: Int
    let flightCount: Int
    let longestSeconds: Int
}

/// Leaderboard time window.
enum LeaderboardPeriod {
    case today
    case week
    case allTime
}

// MARK: - Service

@Observable @MainActor
final class SocialService {
    static let shared = SocialService()

    /// Own TablesDB handle (same client/singleton as CommunityService).
    private var tablesDB: TablesDB { AppwriteService.shared.tablesDB }

    /// Appwrite table IDs for this phase. Kept local (AppwriteConfig is owned
    /// elsewhere) — the tables already exist in the same database.
    private static let profilesTableId = "profiles_v20"
    private static let followsTableId = "follows_v20"
    private static let kudosTableId = "flight_kudos_v20"
    private var sharedFlightsTableId: String { AppwriteConfig.sharedFlightsCollectionId }

    /// Appwrite `Query.equal` with a value array performs an IN match. Servers
    /// clamp very large arrays, so followed-id / flight-id lists are queried
    /// in chunks of this size and merged on device.
    private static let queryChunkSize = 50

    /// The signed-in user's followed IDs, 15-minute TTL. A single entry (per
    /// user) mutated in place on follow/unfollow.
    private var followedCache: (ids: Set<String>, fetchedAt: Date)?
    private static let followedCacheTTL: TimeInterval = 15 * 60

    /// The signed-in user's feed, 5-minute TTL. Stores the limit it was built
    /// with so a request for a bigger page refreshes instead of truncating.
    private var feedCache: (items: [FeedItem], limit: Int, fetchedAt: Date)?
    private static let feedCacheTTL: TimeInterval = 5 * 60

    /// Leaderboard cache per (spotKey, period) key, 5-minute TTL.
    private var leaderboardCache: [String: (entries: [LeaderboardEntry], fetchedAt: Date)] = [:]
    private static let leaderboardCacheTTL: TimeInterval = 5 * 60

    private init() {}

    // MARK: - Current user

    /// The signed-in user's ID, or nil when signed out.
    private var currentUserId: String? {
        if case .signedIn(let userId, _) = AuthService.shared.state {
            return userId
        }
        return nil
    }

    // MARK: - Profiles

    /// The signed-in user's own profile, or nil when signed out / not created.
    func myProfile() async throws -> PilotProfile? {
        guard let userId = currentUserId else { return nil }
        return try await profile(userId: userId)
    }

    /// One pilot's public profile, or nil when it doesn't exist yet.
    func profile(userId: String) async throws -> PilotProfile? {
        do {
            let row = try await tablesDB.getRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.profilesTableId,
                rowId: Self.rowId(for: userId)
            )
            return Self.parseProfile(row)
        } catch {
            // A missing row means "no profile yet" — not an error for the UI.
            if Self.isNotFound(error) { return nil }
            logInfo("Profile unavailable for \(userId): \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// Creates or updates the signed-in user's profile (row ID = user ID).
    /// Read by anyone, editable/deletable only by its owner. Also mirrors the
    /// pilot name into `CommunityService.pilotDisplayName` so shared flights,
    /// reports and the profile all read consistently.
    func upsertMyProfile(
        pilotName: String,
        bio: String?,
        homeSpotKey: String?,
        homeSpotName: String?,
        statsPublic: Bool
    ) async throws {
        guard let userId = currentUserId else {
            throw SocialError.notSignedIn
        }

        let trimmedName = pilotName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = trimmedName.isEmpty ? "A pilot" : String(trimmedName.prefix(64))

        var data: [String: Any] = [
            "pilotName": effectiveName,
            "statsPublic": statsPublic,
            "createdAt": Self.isoString(from: Date())
        ]
        if let bio = bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
            data["bio"] = String(bio.prefix(280))
        }
        if let homeSpotKey = homeSpotKey?.trimmingCharacters(in: .whitespacesAndNewlines), !homeSpotKey.isEmpty {
            data["homeSpotKey"] = String(homeSpotKey.prefix(40))
        }
        if let homeSpotName = homeSpotName?.trimmingCharacters(in: .whitespacesAndNewlines), !homeSpotName.isEmpty {
            data["homeSpotName"] = String(homeSpotName.prefix(128))
        }

        do {
            _ = try await tablesDB.upsertRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.profilesTableId,
                rowId: Self.rowId(for: userId),
                data: data,
                permissions: [
                    Permission.read(Role.any()),
                    Permission.update(Role.user(userId)),
                    Permission.delete(Role.user(userId))
                ]
            )
            // Keep the community display name in sync with the profile name so
            // shares/reports stay consistent (CommunityService is not edited).
            CommunityService.shared.pilotDisplayName = effectiveName
            logInfo("Profile saved for \(userId)", category: .community)
        } catch {
            logInfo("Profile save failed for \(userId): \(Self.mapError(error).localizedDescription)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Follow graph

    /// Whether the signed-in user follows this pilot. Signed-out or a backend
    /// failure resolves to `false` (fail-soft).
    func isFollowing(_ userId: String) async -> Bool {
        await followedIds().contains(userId)
    }

    /// The signed-in user's followed IDs, cached 15 minutes. Fails soft to an
    /// empty set (signed out or backend unavailable).
    func followedIds() async -> Set<String> {
        guard let followerId = currentUserId else { return [] }
        if let cache = followedCache,
           Date().timeIntervalSince(cache.fetchedAt) < Self.followedCacheTTL {
            return cache.ids
        }
        do {
            let rows = try await listAllRows(
                tableId: Self.followsTableId,
                queries: [
                    Query.equal("followerId", value: followerId),
                    Query.select(["followedId", "$id"])
                ]
            )
            let ids = Set(rows.compactMap { $0.data["followedId"]?.value as? String })
            followedCache = (ids, Date())
            return ids
        } catch {
            logInfo("Followed list unavailable: \(error)", category: .community)
            return []
        }
    }

    /// Follows a pilot: upserts a public `follows_v20` edge (deterministic doc
    /// ID) readable by anyone, deletable by the follower. `pilotName` is stored
    /// for cheap follower/following list rendering. Idempotent.
    func follow(_ userId: String, pilotName: String) async throws {
        guard let followerId = currentUserId else {
            throw SocialError.notSignedIn
        }
        guard userId != followerId else { return } // no self-follow

        let data: [String: Any] = [
            "followerId": followerId,
            "followedId": userId,
            "createdAt": Self.isoString(from: Date())
        ]

        do {
            _ = try await tablesDB.upsertRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.followsTableId,
                rowId: Self.followRowId(followerId: followerId, followedId: userId),
                data: data,
                permissions: [
                    Permission.read(Role.any()),
                    Permission.update(Role.user(followerId)),
                    Permission.delete(Role.user(followerId))
                ]
            )
            if followedCache != nil {
                followedCache?.ids.insert(userId)
            }
            feedCache = nil // the feed's follow set changed
            logInfo("Followed \(userId)", category: .community)
        } catch {
            logInfo("Follow failed for \(userId): \(Self.mapError(error).localizedDescription)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// Unfollows a pilot: deletes the edge (idempotent — a missing row is fine).
    func unfollow(_ userId: String) async throws {
        guard let followerId = currentUserId else {
            throw SocialError.notSignedIn
        }

        do {
            _ = try await tablesDB.deleteRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.followsTableId,
                rowId: Self.followRowId(followerId: followerId, followedId: userId)
            )
            if followedCache != nil {
                followedCache?.ids.remove(userId)
            }
            feedCache = nil
            logInfo("Unfollowed \(userId)", category: .community)
        } catch {
            if Self.isNotFound(error) {
                followedCache?.ids.remove(userId)
                feedCache = nil
                return
            }
            logInfo("Unfollow failed for \(userId): \(Self.mapError(error).localizedDescription)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// How many pilots follow this user (fail-soft 0).
    func followerCount(of userId: String) async -> Int {
        await count(tableId: Self.followsTableId, attribute: "followedId", value: userId)
    }

    /// How many pilots this user follows (fail-soft 0).
    func followingCount(of userId: String) async -> Int {
        await count(tableId: Self.followsTableId, attribute: "followerId", value: userId)
    }

    // MARK: - Feed

    /// The signed-in user's activity feed: shared flights from followed pilots,
    /// newest first, decorated with kudos counts. Empty when the user follows
    /// no one. Cached in memory for 5 minutes.
    func feed(limit: Int = 50) async throws -> [FeedItem] {
        if let cache = feedCache,
           cache.limit >= limit,
           Date().timeIntervalSince(cache.fetchedAt) < Self.feedCacheTTL {
            return Array(cache.items.prefix(limit))
        }

        let ids = Array(await followedIds())
        guard !ids.isEmpty else {
            feedCache = ([], limit, Date())
            return []
        }

        do {
            // One IN query per chunk of followed IDs; each returns up to `limit`
            // newest rows, then the merged set is re-sorted and truncated.
            var rows: [Row<[String: AnyCodable]>] = []
            for chunk in ids.chunked(into: Self.queryChunkSize) {
                let page = try await tablesDB.listRows(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: sharedFlightsTableId,
                    queries: [
                        Query.equal("userId", value: chunk),
                        Query.orderDesc("date"),
                        Query.limit(max(1, min(limit, 100)))
                    ]
                )
                rows.append(contentsOf: page.rows)
            }

            var items = rows.compactMap(Self.parseFeedItem)
            items.sort { $0.date > $1.date }
            items = Array(items.prefix(limit))

            items = await decorateWithKudos(items)
            feedCache = (items, limit, Date())
            return items
        } catch {
            logInfo("Feed unavailable: \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// One pilot's recent shared flights (profile page), newest first,
    /// decorated with kudos counts. Not cached — a profile view is transient.
    func recentFlights(of userId: String, limit: Int = 30) async throws -> [FeedItem] {
        do {
            let page = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: sharedFlightsTableId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.orderDesc("date"),
                    Query.limit(max(1, min(limit, 100)))
                ]
            )
            let items = page.rows.compactMap(Self.parseFeedItem)
            return await decorateWithKudos(items)
        } catch {
            logInfo("Recent flights unavailable for \(userId): \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// Batch-fetches kudos for the given feed items and fills in `kudosCount`
    /// and `hasKudoed`. Fail-soft: on any error the items are returned with
    /// zero counts rather than failing the whole feed.
    private func decorateWithKudos(_ items: [FeedItem]) async -> [FeedItem] {
        guard !items.isEmpty else { return items }
        let flightIds = items.map(\.id)
        let me = currentUserId

        var countByFlight: [String: Int] = [:]
        var kudoedByMe: Set<String> = []
        do {
            for chunk in flightIds.chunked(into: Self.queryChunkSize) {
                let rows = try await listAllRows(
                    tableId: Self.kudosTableId,
                    queries: [
                        Query.equal("flightRowId", value: chunk),
                        Query.select(["flightRowId", "userId", "$id"])
                    ]
                )
                for row in rows {
                    guard let flightRowId = row.data["flightRowId"]?.value as? String else { continue }
                    countByFlight[flightRowId, default: 0] += 1
                    if let me, row.data["userId"]?.value as? String == me {
                        kudoedByMe.insert(flightRowId)
                    }
                }
            }
        } catch {
            logInfo("Kudos counts unavailable: \(error)", category: .community)
            return items // zero counts, still show the feed
        }

        return items.map { item in
            var decorated = item
            decorated.kudosCount = countByFlight[item.id] ?? 0
            decorated.hasKudoed = kudoedByMe.contains(item.id)
            return decorated
        }
    }

    // MARK: - Kudos

    /// Kudos a flight: creates a public `flight_kudos_v20` row (deterministic
    /// doc ID) readable by anyone, deletable by its author. Idempotent (an
    /// existing kudos is a success). Optimistically updates the cached feed.
    func kudo(flightRowId: String) async throws {
        guard let userId = currentUserId else {
            throw SocialError.notSignedIn
        }

        let data: [String: Any] = [
            "flightRowId": String(flightRowId.prefix(40)),
            "userId": userId,
            "pilotName": Self.effectivePilotName
        ]

        do {
            _ = try await tablesDB.createRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.kudosTableId,
                rowId: Self.kudoRowId(flightRowId: flightRowId, userId: userId),
                data: data,
                permissions: [
                    Permission.read(Role.any()),
                    Permission.delete(Role.user(userId))
                ]
            )
            applyKudoChange(flightRowId: flightRowId, kudoed: true)
            logInfo("Kudoed flight \(flightRowId)", category: .community)
        } catch {
            // Already kudoed (deterministic ID conflict) is a success.
            if Self.isAlreadyExists(error) {
                applyKudoChange(flightRowId: flightRowId, kudoed: true)
                return
            }
            logInfo("Kudo failed for \(flightRowId): \(Self.mapError(error).localizedDescription)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// Removes the signed-in user's kudos from a flight (idempotent — a missing
    /// row is a success). Optimistically updates the cached feed.
    func unkudo(flightRowId: String) async throws {
        guard let userId = currentUserId else {
            throw SocialError.notSignedIn
        }

        do {
            _ = try await tablesDB.deleteRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.kudosTableId,
                rowId: Self.kudoRowId(flightRowId: flightRowId, userId: userId)
            )
            applyKudoChange(flightRowId: flightRowId, kudoed: false)
            logInfo("Un-kudoed flight \(flightRowId)", category: .community)
        } catch {
            if Self.isNotFound(error) {
                applyKudoChange(flightRowId: flightRowId, kudoed: false)
                return
            }
            logInfo("Un-kudo failed for \(flightRowId): \(Self.mapError(error).localizedDescription)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// Optimistically reflects a kudos change in the cached feed so the UI
    /// updates without a round trip.
    private func applyKudoChange(flightRowId: String, kudoed: Bool) {
        guard var cache = feedCache else { return }
        var changed = false
        cache.items = cache.items.map { item in
            guard item.id == flightRowId, item.hasKudoed != kudoed else { return item }
            var updated = item
            updated.hasKudoed = kudoed
            updated.kudosCount = max(0, updated.kudosCount + (kudoed ? 1 : -1))
            changed = true
            return updated
        }
        if changed { feedCache = cache }
    }

    // MARK: - Leaderboards

    /// Top pilots at one spot for a period, aggregated on device from
    /// `shared_flights` and sorted by total airtime (top 20). Cached in memory
    /// for 5 minutes per (spotKey, period).
    func leaderboard(spotKey: String, period: LeaderboardPeriod) async throws -> [LeaderboardEntry] {
        let cacheKey = "\(spotKey)|\(Self.periodKey(period))"
        if let entry = leaderboardCache[cacheKey],
           Date().timeIntervalSince(entry.fetchedAt) < Self.leaderboardCacheTTL {
            return entry.entries
        }

        var queries = [
            Query.equal("spotKey", value: spotKey),
            Query.orderDesc("date"),
            Query.select(["userId", "pilotName", "durationSeconds", "date", "$id"])
        ]
        if let start = Self.periodStart(period) {
            queries.append(Query.greaterThanEqual("date", value: Self.isoString(from: start)))
        }

        do {
            let rows = try await listAllRows(tableId: sharedFlightsTableId, queries: queries)

            var totalByPilot: [String: Int] = [:]
            var countByPilot: [String: Int] = [:]
            var longestByPilot: [String: Int] = [:]
            var nameByPilot: [String: String] = [:]

            for row in rows {
                let data = row.data
                guard let userId = data["userId"]?.value as? String, !userId.isEmpty else { continue }
                let seconds = Self.intValue(data["durationSeconds"])
                totalByPilot[userId, default: 0] += seconds
                countByPilot[userId, default: 0] += 1
                longestByPilot[userId] = max(longestByPilot[userId] ?? 0, seconds)
                if nameByPilot[userId] == nil,
                   let name = data["pilotName"]?.value as? String, !name.isEmpty {
                    nameByPilot[userId] = name
                }
            }

            let entries = totalByPilot
                .sorted { $0.value > $1.value }
                .prefix(20)
                .map { pair in
                    LeaderboardEntry(
                        id: pair.key,
                        pilotName: nameByPilot[pair.key] ?? "A pilot",
                        totalSeconds: pair.value,
                        flightCount: countByPilot[pair.key] ?? 0,
                        longestSeconds: longestByPilot[pair.key] ?? 0
                    )
                }

            leaderboardCache[cacheKey] = (Array(entries), Date())
            return Array(entries)
        } catch {
            logInfo("Leaderboard unavailable for \(spotKey): \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Counting

    /// Total rows matching one `equal` filter, read from the list response's
    /// `total`. Fail-soft to 0.
    private func count(tableId: String, attribute: String, value: String) async -> Int {
        do {
            let page = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: tableId,
                queries: [
                    Query.equal(attribute, value: value),
                    Query.limit(1)
                ]
            )
            return page.total
        } catch {
            logInfo("Count unavailable (\(tableId).\(attribute)): \(error)", category: .community)
            return 0
        }
    }

    // MARK: - Paginated listing

    /// Lists rows with a cursorAfter loop in pages of 100 (servers clamp larger
    /// limits to 100, which would silently truncate), collecting at most
    /// `maxTotal` rows (~1000 default as a client-side aggregation cap).
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
            guard page.rows.count == 100, let last = page.rows.last else { break }
            cursor = last.id
        }
        return rows
    }

    // MARK: - Row parsing

    /// Parses one `profiles_v20` row into a `PilotProfile`.
    private static func parseProfile(_ row: Row<[String: AnyCodable]>) -> PilotProfile {
        let data = row.data
        let pilotName = (data["pilotName"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A pilot"
        // statsPublic defaults TRUE (matches the table default).
        let statsPublic = (data["statsPublic"]?.value as? Bool) ?? true
        return PilotProfile(
            userId: row.id,
            pilotName: pilotName,
            bio: (data["bio"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 },
            homeSpotKey: (data["homeSpotKey"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 },
            homeSpotName: (data["homeSpotName"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 },
            statsPublic: statsPublic
        )
    }

    /// Parses one `shared_flights` row into an un-decorated `FeedItem` (kudos
    /// filled in later), or nil when required fields are missing/unparseable.
    private static func parseFeedItem(_ row: Row<[String: AnyCodable]>) -> FeedItem? {
        let data = row.data
        guard let dateString = data["date"]?.value as? String,
              let date = parseISODate(dateString) else {
            return nil
        }
        let pilotName = (data["pilotName"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A pilot"
        return FeedItem(
            id: row.id,
            userId: data["userId"]?.value as? String ?? "",
            pilotName: pilotName,
            spotName: (data["spotName"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A spot",
            spotKey: data["spotKey"]?.value as? String ?? "",
            date: date,
            durationSeconds: intValue(data["durationSeconds"]),
            flightType: (data["flightType"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 },
            kudosCount: 0,
            hasKudoed: false
        )
    }

    // MARK: - Helpers

    /// The public name attached to kudos — reuses the pilot's community display
    /// name so social rows read consistently.
    private static var effectivePilotName: String {
        let trimmed = CommunityService.shared.pilotDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A pilot" : String(trimmed.prefix(64))
    }

    /// Deterministic Appwrite row ID from a user ID (a-z, 0-9, hyphen; max 36).
    private static func rowId(for identifier: String) -> String {
        String(identifier.lowercased().prefix(36))
    }

    /// Deterministic ≤36-char follow document ID from followerId + followedId
    /// (SHA-256 hex, truncated). The same edge always maps to the same row.
    private static func followRowId(followerId: String, followedId: String) -> String {
        deterministicId("\(followerId)_\(followedId)")
    }

    /// Deterministic ≤36-char kudos document ID from flightRowId + userId.
    private static func kudoRowId(flightRowId: String, userId: String) -> String {
        deterministicId("\(flightRowId)_\(userId)")
    }

    private static func deterministicId(_ seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(36))
    }

    /// Stable cache-key fragment for a leaderboard period.
    private static func periodKey(_ period: LeaderboardPeriod) -> String {
        switch period {
        case .today: return "today"
        case .week: return "week"
        case .allTime: return "all"
        }
    }

    /// The start date of a period, or nil for all-time (no date filter).
    private static func periodStart(_ period: LeaderboardPeriod) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now).addingTimeInterval(-6 * 24 * 3600)
        case .allTime:
            return nil
        }
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

    /// True for "document already exists" conflicts (idempotent create path).
    private static func isAlreadyExists(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 409
    }

    /// True for "row not found" (HTTP 404) — idempotent delete / missing profile.
    private static func isNotFound(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 404
    }

    /// Maps Appwrite errors to short English user-facing messages. A missing
    /// database/table means the backend isn't configured yet — callers hide
    /// their sections on `.backendNotConfigured`.
    private static func mapError(_ error: Error) -> SocialError {
        if let socialError = error as? SocialError {
            return socialError
        }
        guard let appwriteError = error as? AppwriteError else {
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
            if appwriteError.code == 429 {
                return .rateLimited
            }
            return .unknown(appwriteError.message)
        }
    }
}

// MARK: - Chunking

private extension Array {
    /// Splits the array into consecutive chunks of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
