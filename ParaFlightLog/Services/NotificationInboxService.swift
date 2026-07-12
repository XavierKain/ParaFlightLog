//
//  NotificationInboxService.swift
//  ParaFlightLog
//
//  In-app notification center (v1, local-first): a persisted inbox of the
//  push notifications this device received, plus the ones it *missed* (never
//  delivered or never tapped) recovered on app open from the community
//  condition-report backend.
//
//  Two sources feed the inbox:
//    1. Live pushes — every push the AppDelegate sees (foreground `willPresent`
//       and a background tap `didReceive`) is appended via `record(...)`.
//    2. `syncMissed(dataController:)` — on app open, pulls the recent reports
//       (< 24 h, and still live server-side) for the spots the pilot follows
//       and appends any that post-date the last sync and aren't already in the
//       inbox. This is what recovers a report whose push was dropped by APNs or
//       simply never tapped.
//
//  Everything is best-effort and fail-soft: no backend, signed out, or an
//  offline server must never crash or block — the inbox just shows what it has.
//  Persisted to a JSON file in Documents (cap 200, newest first). Unread count
//  is published and mirrored onto the app icon badge.
//
//  Target: iOS only
//

import Foundation
import UserNotifications

// MARK: - Model

/// One entry in the notification center. `nonisolated`: plain data, so its
/// Codable conformance stays actor-free under MainActor-default isolation.
nonisolated enum InboxKind: String, Codable, Sendable {
    case report
    case kudos
    case follow
    case forecast
    case system

    /// SF Symbol shown on the row.
    var symbol: String {
        switch self {
        case .report: return "megaphone.fill"
        case .kudos: return "hand.thumbsup.fill"
        case .follow: return "person.fill.badge.plus"
        case .forecast: return "cloud.sun.fill"
        case .system: return "bell.fill"
        }
    }
}

/// A single received/missed notification, persisted in the inbox.
/// `nonisolated`: plain data, Codable stays actor-free (see InboxKind).
nonisolated struct InboxItem: Identifiable, Codable, Equatable, Sendable {
    /// Stable identity used for de-duplication across sources (the report row
    /// id when known, otherwise a deterministic key from the payload).
    let id: String
    var kind: InboxKind
    var title: String
    var body: String
    /// Community spot key to deep-link to when the row is tapped, if any.
    var spotKey: String?
    var date: Date
    var isRead: Bool
}

// MARK: - Service

@Observable @MainActor
final class NotificationInboxService {
    static let shared = NotificationInboxService()

    /// Newest-first inbox. Persisted to Documents.
    private(set) var items: [InboxItem] = []

    /// Number of unread items — drives the bell badge and the app icon badge.
    var unreadCount: Int { items.reduce(0) { $0 + ($1.isRead ? 0 : 1) } }

    /// Hard cap on stored items (newest kept).
    private static let cap = 200

    /// Persisted watermark: reports created at/after this were already ingested
    /// by a previous `syncMissed`, so they are not re-added.
    private static let lastSyncDefaultsKey = "notificationInboxLastSync"

    private init() {
        items = Self.load()
        updateBadge()
    }

    // MARK: - Ingesting live pushes

    /// Records a push the AppDelegate observed. `markRead` is true for a
    /// background tap (the pilot engaged with it) and false for a foreground
    /// banner (shown while using the app, so still "new" in the center).
    /// De-duplicates against reports already recovered by `syncMissed`.
    func record(
        title: String,
        body: String,
        spotKey: String?,
        reportId: String?,
        kindRaw: String?,
        date: Date,
        markRead: Bool
    ) {
        let kind = kindRaw.flatMap(InboxKind.init(rawValue:)) ?? (spotKey != nil ? .report : .system)
        let id = reportId?.isEmpty == false
            ? reportId!
            : "\(spotKey ?? "")|\(title)|\(body)"
        let item = InboxItem(
            id: id,
            kind: kind,
            title: title.isEmpty ? "Notification" : title,
            body: body,
            spotKey: spotKey,
            date: date,
            isRead: markRead
        )
        append(item)
        logInfo("Inbox recorded push (\(kind.rawValue), read=\(markRead))", category: .community)
    }

    // MARK: - Recovering missed reports

    /// Recovers reports whose push was never delivered/tapped: for each followed
    /// spot, appends recent (< 24 h) reports newer than the last sync that
    /// aren't already in the inbox. Marked unread so they surface in the center.
    ///
    /// Only reports still live server-side (TTL 3 h) are visible, so this
    /// realistically recovers the last ~3 h of activity — enough to catch a
    /// push that slipped through while the phone was off/offline.
    func syncMissed(dataController: DataController) async {
        guard case .signedIn(let currentUserId, _) = AuthService.shared.state else { return }

        // First run ever: set the watermark to "now" so we never retroactively
        // flood the inbox with everything currently live.
        guard let lastSync = Self.lastSyncDate else {
            Self.lastSyncDate = Date()
            return
        }

        let now = Date()
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let service = ConditionReportService.shared

        for spot in dataController.fetchSpots() {
            let key = spot.communitySpotKey
                ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude)
            guard let key else { continue }
            guard await service.isSubscribed(spotKey: key) else { continue }

            let reports = (try? await service.recentReports(forSpotKey: key)) ?? []
            for report in reports where report.createdAt > cutoff
                && report.createdAt > lastSync
                && report.userId != currentUserId {
                append(InboxItem(
                    id: report.id,
                    kind: .report,
                    title: spot.name,
                    body: Self.reportBody(report),
                    spotKey: key,
                    date: report.createdAt,
                    isRead: false
                ))
            }
        }

        Self.lastSyncDate = now
    }

    // MARK: - Mutations

    /// Inserts newest-first, de-duplicating by `id`, capping at `cap`.
    private func append(_ item: InboxItem) {
        if let existing = items.firstIndex(where: { $0.id == item.id }) {
            // Keep the earlier read-state so a re-sync doesn't un-read an item.
            var merged = item
            merged.isRead = items[existing].isRead || item.isRead
            items[existing] = merged
        } else {
            items.append(item)
        }
        items.sort { $0.date > $1.date }
        if items.count > Self.cap { items.removeLast(items.count - Self.cap) }
        persist()
        updateBadge()
    }

    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isRead else { return }
        items[index].isRead = true
        persist()
        updateBadge()
    }

    func markAllRead() {
        guard items.contains(where: { !$0.isRead }) else { return }
        for index in items.indices { items[index].isRead = true }
        persist()
        updateBadge()
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        persist()
        updateBadge()
    }

    // MARK: - Badge

    /// Mirrors the unread count onto the app icon badge.
    private func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(unreadCount) { _ in }
    }

    // MARK: - Report body formatting

    /// "<pilot>: <status> — <force> <dir>" — mirrors the server fan-out text so
    /// a recovered report reads the same as its push would have.
    private static func reportBody(_ report: SpotReport) -> String {
        var tail = report.windForce?.label.lowercased() ?? ""
        if let deg = report.windDirectionDeg {
            let dir = WeatherService.degreesToCompass(deg)
            tail = tail.isEmpty ? dir : "\(tail) \(dir)"
        }
        let head = "\(report.pilotName): \(report.status.label.lowercased())"
        return tail.isEmpty ? head : "\(head) — \(tail)"
    }

    // MARK: - Persistence

    /// JSON file backing the inbox.
    private static var fileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("notifications_inbox.json")
    }

    private func persist() {
        do {
            let data = try JSONEncoder.inboxCoder.encode(items)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            logWarning("Inbox persist failed: \(error)", category: .community)
        }
    }

    private static func load() -> [InboxItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            let decoded = try JSONDecoder.inboxCoder.decode([InboxItem].self, from: data)
            return decoded.sorted { $0.date > $1.date }
        } catch {
            logWarning("Inbox load failed: \(error)", category: .community)
            return []
        }
    }

    /// Persisted `syncMissed` watermark (nil until the first sync established a
    /// baseline).
    private static var lastSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: lastSyncDefaultsKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastSyncDefaultsKey) }
    }
}

// MARK: - Coders

private extension JSONEncoder {
    static let inboxCoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let inboxCoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
