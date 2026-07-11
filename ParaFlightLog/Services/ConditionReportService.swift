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

/// What a pilot reports about a spot right now. Raw values are the exact
/// strings stored in `spot_reports.status`.
enum ReportStatus: String, CaseIterable, Identifiable, Sendable {
    case flying
    case goingToFly
    case flyable
    case notFlyable
    case tooStrong

    var id: String { rawValue }

    /// Emoji shown on the status chip.
    var emoji: String {
        switch self {
        case .flying: return "🪂"
        case .goingToFly: return "🚗"
        case .flyable: return "✅"
        case .notFlyable: return "🚫"
        case .tooStrong: return "💨"
        }
    }

    /// Short chip label.
    var label: String {
        switch self {
        case .flying: return "Flying now"
        case .goingToFly: return "Going to fly"
        case .flyable: return "Flyable"
        case .notFlyable: return "Not flyable"
        case .tooStrong: return "Too strong"
        }
    }

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

/// Rough wind strength reported alongside the status. Raw values are the
/// exact strings stored in `spot_reports.windForce`.
enum WindForce: String, CaseIterable, Identifiable, Sendable {
    case calm
    case light
    case moderate
    case strong
    case tooMuch

    var id: String { rawValue }

    /// Short chip label.
    var label: String {
        switch self {
        case .calm: return "Calm"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .strong: return "Strong"
        case .tooMuch: return "Too much"
        }
    }

    /// Rough km/h hint shown under the label (indicative, not authoritative).
    var kmhHint: String {
        switch self {
        case .calm: return "0–5"
        case .light: return "5–15"
        case .moderate: return "15–25"
        case .strong: return "25–35"
        case .tooMuch: return "35+"
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
    func submitReport(
        spot: Spot?,
        spotKey: String,
        spotName: String,
        status: ReportStatus,
        windForce: WindForce,
        windDirectionDeg: Double?,
        wingSize: String?,
        note: String?
    ) async throws {
        guard case .signedIn(let userId, _) = AuthService.shared.state else {
            throw ConditionReportError.notSignedIn
        }

        // Client-side cooldown: block a fresh report for a spot the pilot just
        // reported on (in-memory + persisted), so a double-tap or an over-eager
        // pilot can't spam the spot's followers with push notifications.
        guard submitCooldownRemaining(forSpotKey: spotKey) <= 0 else {
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
            data["wingSize"] = String(wingSize.prefix(16))
        }
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            data["note"] = String(note.prefix(280))
        }

        do {
            _ = try await tablesDB.createRow(
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
