//
//  ConditionReportService.swift
//  ParaFlightLog
//
//  Community CONDITION REPORTS (Phase 3 of the community loop): short-lived,
//  crowd-sourced "is it flyable right now?" posts, plus per-spot push
//  subscriptions.
//
//  - `spot_reports`: one row per report, TTL 3 h (expiresAt), read by anyone,
//    editable/deletable only by its author. A server function fans out push
//    notifications on creation — this client only writes the row.
//  - `spot_subscriptions_v20`: one PRIVATE row per (user, spot) the pilot
//    follows (deterministic doc ID), read/write restricted to the owner.
//
//  Everything is best-effort and fail-soft, mirroring CommunityService: a
//  backend without these tables (backendNotConfigured) must make the UI
//  hide its report/subscription sections silently, never crash or block.
//
//  TablesDB access goes through AppwriteService.shared; the row parsing and
//  error mapping mirror CommunityService's style locally (that file is not
//  edited from here).
//  Target: iOS only
//

import Foundation
import SwiftUI // ReportStatus/WindForce carry a display Color
import CoreLocation // distance-sorting local spots for the "near me" view
import CryptoKit // deterministic subscription document IDs
import Appwrite // re-exports JSONCodable (AnyCodable), Query, ID, Permission, Role

// MARK: - Errors

/// Short, user-facing error messages for condition-report failures.
enum ConditionReportError: LocalizedError {
    case notSignedIn
    case backendNotConfigured
    case rateLimited
    case reportCooldown
    case network
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You must be signed in to report conditions."
        case .backendNotConfigured:
            return "Condition reports are not available yet. Please try again later."
        case .rateLimited:
            return "Too many requests. Please try again in a minute."
        case .reportCooldown:
            return "You already reported conditions here recently."
        case .network:
            return "Network error. Check your connection and try again."
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Report status & wind force

// `ReportStatus` and `WindForce` themselves live in the root-level
// SharedModels.swift: the Apple Watch posts condition reports too, and that
// file is the only source compiled into both the iOS app and the Watch app.
// Everything that needs SwiftUI (or the iPhone-only WindUnit preference)
// stays here, as iOS-only extensions.

extension ReportStatus {
    /// Accent color for chips, consensus banners and list rows.
    var color: Color {
        switch self {
        case .flying: return .green
        case .goingToFly: return .teal
        case .flyable: return .blue
        case .notFlyable: return .orange
        case .tooStrong: return .red
        }
    }
}

/// Unit a pilot reads wind strength in. Persisted as a local @AppStorage
/// preference (Constants.swift is owned elsewhere, so the key lives here).
/// Default is km/h.
enum WindUnit: String, CaseIterable, Identifiable, Sendable {
    case kmh
    case knots

    var id: String { rawValue }

    /// Local UserDefaults / @AppStorage key for the wind-unit preference.
    static let storageKey = "windUnitPreference"

    /// km/h → 1 kt = 1.852 km/h.
    static let kmhPerKnot = 1.852

    /// Picker row label.
    var label: String {
        switch self {
        case .kmh: return "km/h"
        case .knots: return "knots"
        }
    }

    /// Compact suffix used in range hints ("20–33 km/h" / "11–18 kt").
    var shortLabel: String {
        switch self {
        case .kmh: return "km/h"
        case .knots: return "kt"
        }
    }

    /// The preference as currently stored (default km/h). Views prefer an
    /// @AppStorage binding; this static reader is for non-View contexts.
    static var current: WindUnit {
        WindUnit(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .kmh
    }

    /// Converts a knots value into this unit, rounded to a whole number.
    func fromKnots(_ knots: Int) -> Int {
        switch self {
        case .knots: return knots
        case .kmh: return Int((Double(knots) * Self.kmhPerKnot).rounded())
        }
    }
}

extension WindForce {
    /// Range hint rendered in the chosen unit, e.g. "11–18 kt" or "20–33 km/h".
    /// iPhone-only: `WindUnit` is a local @AppStorage preference the Watch does
    /// not receive, so the Watch shows `knotsHint` instead.
    func rangeHint(in unit: WindUnit) -> String {
        let (lower, upper) = knotsRange
        let suffix = unit.shortLabel
        switch (lower, upper) {
        case let (nil, upper?):
            return "< \(unit.fromKnots(upper)) \(suffix)"
        case let (lower?, nil):
            return "> \(unit.fromKnots(lower)) \(suffix)"
        case let (lower?, upper?):
            return "\(unit.fromKnots(lower))–\(unit.fromKnots(upper)) \(suffix)"
        case (nil, nil):
            return ""
        }
    }
}

// MARK: - Models

/// One condition report at a spot (parsed from a `spot_reports` row).
struct SpotReport: Identifiable, Sendable {
    /// Appwrite row ID.
    let id: String
    let spotKey: String
    let userId: String
    let pilotName: String
    let status: ReportStatus
    let windForce: WindForce?
    /// Wind direction the report gives (degrees the wind comes FROM), if any.
    let windDirectionDeg: Double?
    let wingSize: String?
    let note: String?
    let createdAt: Date
    let expiresAt: Date
}

/// The current "consensus" at a spot: the freshest report plus how many of
/// the recent fresh reports concur with its status.
struct ReportConsensus: Sendable {
    /// Freshest fresh report (drives the banner).
    let latest: SpotReport
    /// How many recent fresh reports share `latest.status` (includes `latest`).
    let concurringCount: Int
    /// Total recent fresh reports considered.
    let totalCount: Int
}

extension Array where Element == SpotReport {
    /// Consensus from a recent, freshest-first list of reports: the latest one
    /// plus the count of concurring statuses. Nil when the list is empty.
    var consensus: ReportConsensus? {
        guard let latest = first else { return nil }
        let concurring = self.reduce(0) { $0 + ($1.status == latest.status ? 1 : 0) }
        return ReportConsensus(latest: latest, concurringCount: concurring, totalCount: count)
    }
}

// MARK: - Service

@Observable @MainActor
final class ConditionReportService {
    static let shared = ConditionReportService()

    /// Own TablesDB handle (same client/singleton as CommunityService).
    private var tablesDB: TablesDB { AppwriteService.shared.tablesDB }

    /// Appwrite table IDs for this phase. Kept local (Constants/AppwriteConfig
    /// is owned elsewhere) — the tables already exist in the same database.
    private static let reportsTableId = "spot_reports"
    private static let subscriptionsTableId = "spot_subscriptions_v20"

    /// Report TTL: a report is relevant for 3 hours after it is posted.
    private static let reportTTL: TimeInterval = 3 * 3600

    /// Recent-reports cache per spot key, 5-minute TTL.
    private var reportsCache: [String: (reports: [SpotReport], fetchedAt: Date)] = [:]
    private static let reportsCacheTTL: TimeInterval = 5 * 60

    /// The signed-in user's followed spot keys, 15-minute TTL. A single entry
    /// (per user) mutated in place on subscribe/unsubscribe.
    private var subscriptionCache: (keys: Set<String>, fetchedAt: Date)?
    private static let subscriptionCacheTTL: TimeInterval = 15 * 60

    /// Client-side submit cooldown: after a successful report, further reports
    /// for the SAME spot are blocked for this long. Guards against report (and
    /// the downstream push fan-out) spam. Survives relaunch via UserDefaults.
    private static let submitCooldown: TimeInterval = 10 * 60
    private static let cooldownDefaultsKey = "conditionReportCooldownUntil"

    /// In-memory mirror of the per-spot cooldown-until dates, lazily seeded
    /// from UserDefaults so it survives an app relaunch.
    private var cooldownCache: [String: Date]?

    private init() {}

    // MARK: - Submit a report

    /// Posts one condition report (row TTL 3 h). Read by anyone, editable and
    /// deletable only by its author. `spot` is accepted for API symmetry with
    /// the rest of the community layer; the write uses `spotKey`/`spotName`.
    /// - Parameter dataController: when given, the posted report is also
    ///   archived locally so it can be shown on the flight card months later,
    ///   long after the server row's 3-hour TTL has passed.
    func submitReport(
        spot: Spot?,
        spotKey: String,
        spotName: String,
        status: ReportStatus,
        windForce: WindForce,
        windDirectionDeg: Double?,
        wingSize: String?,
        note: String?,
        bypassCooldown: Bool = false,
        dataController: DataController? = nil
    ) async throws {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw ConditionReportError.notSignedIn
        }

        // Client-side cooldown: block a fresh report for a spot the pilot just
        // reported on (in-memory + persisted), so a double-tap or an over-eager
        // pilot can't spam the spot's followers with push notifications.
        // A post-flight report is exempt: it supersedes the one the same pilot
        // filed before launching, and it is the better of the two.
        guard bypassCooldown || submitCooldownRemaining(forSpotKey: spotKey) <= 0 else {
            throw ConditionReportError.reportCooldown
        }

        let now = Date()
        let expiresAt = now.addingTimeInterval(Self.reportTTL)

        var data: [String: Any] = [
            "spotKey": String(spotKey.prefix(40)),
            "spotName": String(spotName.prefix(128)),
            "userId": userId,
            "pilotName": Self.effectivePilotName,
            "status": status.rawValue,
            "windForce": windForce.rawValue,
            "createdAt": Self.isoString(from: now),
            "expiresAt": Self.isoString(from: expiresAt)
        ]
        if let direction = windDirectionDeg, direction.isFinite {
            // Normalize to 0..<360 so the fan-out/consumers get a clean bearing.
            let normalized = (direction.truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360)
            data["windDirectionDeg"] = normalized
        }
        if let wingSize = wingSize?.trimmingCharacters(in: .whitespacesAndNewlines), !wingSize.isEmpty {
            data["wingSize"] = String(wingSize.prefix(48))
        }
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            data["note"] = String(note.prefix(280))
        }

        do {
            let row = try await tablesDB.createRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.reportsTableId,
                rowId: ID.unique(),
                data: data,
                permissions: [
                    Permission.read(Role.any()),
                    Permission.update(Role.user(userId)),
                    Permission.delete(Role.user(userId))
                ]
            )
            // Keep the pilot's own report for good: this is the one they will
            // look for on the flight card, and the server copy is gone in 3 h.
            if let dataController {
                dataController.archiveConditionReports([
                    ArchivedSpotReport(
                        id: row.id,
                        spotKey: spotKey,
                        spotName: spotName,
                        userId: userId,
                        pilotName: Self.effectivePilotName,
                        status: status.rawValue,
                        windForce: windForce.rawValue,
                        windDirectionDeg: data["windDirectionDeg"] as? Double,
                        wingSize: data["wingSize"] as? String,
                        note: data["note"] as? String,
                        createdAt: now,
                        isMine: true
                    )
                ])
            }
            // Freshest data next read — the pilot expects to see their report.
            reportsCache.removeValue(forKey: spotKey)
            // Start the anti-spam cooldown for this spot.
            recordSubmitCooldown(forSpotKey: spotKey)
            logInfo("Condition report posted at \(spotKey) (\(status.rawValue))", category: .community)
        } catch {
            logInfo("Condition report failed for \(spotKey): \(Self.mapError(error).localizedDescription)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Submit cooldown

    /// Remaining submit cooldown for a spot in seconds (0 when the pilot is
    /// free to report). The UI checks this on the report sheet's appearance to
    /// disable the Post button and show a countdown hint.
    func submitCooldownRemaining(forSpotKey spotKey: String) -> TimeInterval {
        guard let until = cooldowns()[spotKey] else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    /// Marks a spot as just-reported, blocking further submits for
    /// `submitCooldown`. Persisted so it survives an app relaunch.
    private func recordSubmitCooldown(forSpotKey spotKey: String) {
        var current = cooldowns()
        current[spotKey] = Date().addingTimeInterval(Self.submitCooldown)
        cooldownCache = current
        Self.persistCooldowns(current)
    }

    /// The live cooldown map (expired entries pruned), lazily seeded from
    /// UserDefaults on first access.
    private func cooldowns() -> [String: Date] {
        let now = Date()
        let source = cooldownCache ?? Self.loadCooldowns()
        let live = source.filter { $0.value > now }
        cooldownCache = live
        return live
    }

    /// Loads persisted cooldown-until dates, dropping any already expired.
    private static func loadCooldowns() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: cooldownDefaultsKey) as? [String: Double] else {
            return [:]
        }
        let now = Date()
        var result: [String: Date] = [:]
        for (key, epoch) in raw {
            let date = Date(timeIntervalSince1970: epoch)
            if date > now { result[key] = date }
        }
        return result
    }

    private static func persistCooldowns(_ cooldowns: [String: Date]) {
        let raw = cooldowns.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: cooldownDefaultsKey)
    }

    // MARK: - Recent reports

    /// Freshest-first, non-expired reports for one spot (limit 25). Cached in
    /// memory for 5 minutes per spot key. `forceRefresh` bypasses the cache.
    func recentReports(forSpotKey spotKey: String, forceRefresh: Bool = false) async throws -> [SpotReport] {
        if !forceRefresh,
           let entry = reportsCache[spotKey],
           Date().timeIntervalSince(entry.fetchedAt) < Self.reportsCacheTTL {
            // A report can expire during the 5-minute cache window; drop any
            // now-expired entry so it never lingers in the consensus banner.
            let now = Date()
            return entry.reports.filter { $0.expiresAt > now }
        }

        do {
            let page = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.reportsTableId,
                queries: [
                    Query.equal("spotKey", value: spotKey),
                    Query.greaterThan("expiresAt", value: Self.isoString(from: Date())),
                    Query.orderDesc("createdAt"),
                    Query.limit(25)
                ]
            )
            let reports = page.rows.compactMap(Self.parseReport)
            reportsCache[spotKey] = (reports, Date())
            return reports
        } catch {
            logInfo("Recent reports unavailable for \(spotKey): \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Archiving reports against a flight

    /// Fire-and-forget: copies the condition reports that describe a flight's
    /// air into the local archive, so the flight card can show them for good.
    ///
    /// Called right after a flight is saved, which is the only moment the
    /// other pilots' reports for that session are still readable — the server
    /// drops them 3 hours after they were filed. Reports outside the flight's
    /// window are ignored: what matters is the air that was flown, not
    /// whatever someone posted at the same spot the next morning.
    ///
    /// Silent on every failure. A flight must save whether or not the
    /// community is reachable.
    func archiveReports(for flight: Flight, dataController: DataController) {
        // Plain values captured BEFORE the awaits — the flight is a SwiftData
        // model and must not be touched across a suspension point.
        guard let spotKey = dataController.communitySpotKey(for: flight) else { return }
        let window = ArchivedSpotReport.flightMatchWindow
        let from = flight.startDate.addingTimeInterval(-window)
        let to = flight.endDate.addingTimeInterval(window)
        let myUserId: String? = {
            if case .signedIn(let userId, _) = AuthService.shared.state { return userId }
            return nil
        }()

        Task { [weak dataController] in
            // forceRefresh: the 5-minute cache may well have been filled
            // before takeoff, and would then be missing the very reports —
            // including the pilot's own post-flight one — this exists to keep.
            guard let reports = try? await self.recentReports(forSpotKey: spotKey, forceRefresh: true) else { return }
            let matching = reports
                .filter { $0.createdAt >= from && $0.createdAt <= to }
                .map { report in
                    ArchivedSpotReport(
                        id: report.id,
                        spotKey: report.spotKey,
                        spotName: nil,
                        userId: report.userId,
                        pilotName: report.pilotName,
                        status: report.status.rawValue,
                        windForce: report.windForce?.rawValue,
                        windDirectionDeg: report.windDirectionDeg,
                        wingSize: report.wingSize,
                        note: report.note,
                        createdAt: report.createdAt,
                        isMine: myUserId != nil && report.userId == myUserId
                    )
                }
            guard let dataController, !matching.isEmpty else { return }
            let archived = dataController.archiveConditionReports(matching)
            if archived > 0 {
                logInfo("Archived \(archived) condition report(s) for a flight at \(spotKey)", category: .community)
            }
        }
    }

    // MARK: - Nearby spots (local, "report near me")

    /// Local spots sorted by great-circle distance from `origin`, nearest first
    /// and capped at `limit`. Spots without coordinates are dropped. Pure and
    /// read-only (no network) so the "spots near me" view stays thin — uses the
    /// same `CLLocation.distance` metric as `DataController.nearestSpot`.
    func nearbySpots(
        from origin: CLLocationCoordinate2D,
        spots: [Spot],
        limit: Int = 15
    ) -> [(spot: Spot, distanceMeters: Double)] {
        let target = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        return spots
            .compactMap { spot -> (spot: Spot, distanceMeters: Double)? in
                guard let lat = spot.latitude, let lon = spot.longitude else { return nil }
                let distance = target.distance(from: CLLocation(latitude: lat, longitude: lon))
                return (spot, distance)
            }
            .sorted { $0.distanceMeters < $1.distanceMeters }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Subscriptions (follow a spot)

    /// Whether the signed-in user follows this spot. Signed-out or a backend
    /// failure resolves to `false` (fail-soft — the bell just reads "off").
    func isSubscribed(spotKey: String) async -> Bool {
        guard AuthService.shared.state.isSignedIn else { return false }
        do {
            return try await subscriptionKeys().contains(spotKey)
        } catch {
            return false
        }
    }

    /// Follows a spot: upserts a PRIVATE `spot_subscriptions_v20` row
    /// (deterministic doc ID) restricted to the owner. Notification delivery
    /// itself is handled by the server fan-out function.
    func subscribe(spotKey: String, spotName: String) async throws {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw ConditionReportError.notSignedIn
        }

        let data: [String: Any] = [
            "userId": userId,
            "spotKey": String(spotKey.prefix(40)),
            "spotName": String(spotName.prefix(128)),
            "notifyReports": true,
            "notifyPresence": true,
            "createdAt": Self.isoString(from: Date())
        ]

        do {
            _ = try await tablesDB.upsertRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.subscriptionsTableId,
                rowId: Self.subscriptionRowId(userId: userId, spotKey: spotKey),
                data: data,
                permissions: [
                    Permission.read(Role.user(userId)),
                    Permission.update(Role.user(userId)),
                    Permission.delete(Role.user(userId))
                ]
            )
            // Keep the cached set in sync without another round trip.
            if subscriptionCache != nil {
                subscriptionCache?.keys.insert(spotKey)
            }
            logInfo("Subscribed to spot \(spotKey)", category: .community)
        } catch {
            logInfo("Subscribe failed for \(spotKey): \(Self.mapError(error).localizedDescription)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// Unfollows a spot: deletes the subscription row (idempotent — a missing
    /// row is a success).
    func unsubscribe(spotKey: String) async throws {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw ConditionReportError.notSignedIn
        }

        do {
            _ = try await tablesDB.deleteRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.subscriptionsTableId,
                rowId: Self.subscriptionRowId(userId: userId, spotKey: spotKey)
            )
            if subscriptionCache != nil {
                subscriptionCache?.keys.remove(spotKey)
            }
            logInfo("Unsubscribed from spot \(spotKey)", category: .community)
        } catch {
            // A missing row (404) means "already not following" — that's fine.
            if Self.isNotFound(error) {
                subscriptionCache?.keys.remove(spotKey)
                return
            }
            logInfo("Unsubscribe failed for \(spotKey): \(Self.mapError(error).localizedDescription)", category: .community)
            throw Self.mapError(error)
        }
    }

    /// The signed-in user's followed spot keys, cached 15 minutes.
    private func subscriptionKeys() async throws -> Set<String> {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw ConditionReportError.notSignedIn
        }
        if let cache = subscriptionCache,
           Date().timeIntervalSince(cache.fetchedAt) < Self.subscriptionCacheTTL {
            return cache.keys
        }

        do {
            let page = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: Self.subscriptionsTableId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.select(["spotKey", "$id"]),
                    Query.limit(100)
                ]
            )
            let keys = Set(page.rows.compactMap { $0.data["spotKey"]?.value as? String })
            subscriptionCache = (keys, Date())
            return keys
        } catch {
            logInfo("Subscription list unavailable: \(error)", category: .community)
            throw Self.mapError(error)
        }
    }

    // MARK: - Row parsing

    /// Parses one `spot_reports` row into a `SpotReport`, or nil when required
    /// fields are missing/unparseable (tolerant, mirrors CommunityService).
    private static func parseReport(_ row: Row<[String: AnyCodable]>) -> SpotReport? {
        let data = row.data
        guard let statusRaw = data["status"]?.value as? String,
              let status = ReportStatus(rawValue: statusRaw),
              let createdString = data["createdAt"]?.value as? String,
              let createdAt = parseISODate(createdString),
              let expiresString = data["expiresAt"]?.value as? String,
              let expiresAt = parseISODate(expiresString) else {
            return nil
        }
        let windForce = (data["windForce"]?.value as? String).flatMap(WindForce.init(rawValue:))
        let pilotName = (data["pilotName"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A pilot"
        return SpotReport(
            id: row.id,
            spotKey: data["spotKey"]?.value as? String ?? "",
            userId: data["userId"]?.value as? String ?? "",
            pilotName: pilotName,
            status: status,
            windForce: windForce,
            windDirectionDeg: doubleValue(data["windDirectionDeg"]),
            wingSize: (data["wingSize"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 },
            note: (data["note"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 },
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    // MARK: - Helpers

    /// The public name attached to reports — reuses the pilot's community
    /// display name so reports and shared flights read consistently.
    private static var effectivePilotName: String {
        let trimmed = CommunityService.shared.pilotDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A pilot" : String(trimmed.prefix(64))
    }

    /// Deterministic ≤36-char subscription document ID from userId + spotKey
    /// (SHA-256 hex, truncated). Same (user, spot) always maps to the same row.
    private static func subscriptionRowId(userId: String, spotKey: String) -> String {
        let digest = SHA256.hash(data: Data("\(userId)_\(spotKey)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(36))
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

    /// Tolerant Double extraction from an Appwrite row value (Double or Int).
    private static func doubleValue(_ value: AnyCodable?) -> Double? {
        if let double = value?.value as? Double { return double }
        if let int = value?.value as? Int { return Double(int) }
        return nil
    }

    /// True for "row not found" (HTTP 404) — an idempotent unsubscribe case.
    private static func isNotFound(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 404
    }

    /// Maps Appwrite errors to short English user-facing messages. A missing
    /// database/table means the backend isn't configured yet — callers hide
    /// their sections on `.backendNotConfigured`.
    private static func mapError(_ error: Error) -> ConditionReportError {
        if let reportError = error as? ConditionReportError {
            return reportError
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
