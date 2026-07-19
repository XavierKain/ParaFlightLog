//
//  WingMaintenance.swift
//  ParaFlightLog
//
//  Wing trim / maintenance schedule logic:
//    - pure, testable math (totals, hours since last trim, due statuses) over
//      a value snapshot of a wing, so the tests never touch SwiftData;
//    - manufacturer-recommended intervals keyed by model-name substring;
//    - local trim reminders (UNUserNotificationCenter), fail-soft like
//      ForecastAlertService: denied authorization or scheduling failures
//      never affect the caller.
//  Target: iOS only
//

import Foundation
import UserNotifications

// MARK: - Status types

/// Urgency of a trim deadline.
nonisolated enum TrimStatus: String, Sendable, Equatable {
    case ok
    case dueSoon
    case overdue
}

/// Resolved state of one trim deadline (small or full).
nonisolated struct TrimDueState: Sendable, Equatable {
    var status: TrimStatus
    /// Hours left before the hour-based interval is reached (negative when
    /// overdue). nil when no hour interval is configured.
    var hoursRemaining: Double?
    /// Calendar deadline of the month-based interval. nil when no month
    /// interval is configured or no anchor date is known.
    var dueDate: Date?
}

/// One logged flight reduced to the two values the maintenance math needs.
nonisolated struct MaintenanceFlight: Sendable {
    var date: Date
    var hours: Double
}

/// Value snapshot of everything maintenance-related on a Wing, so the logic
/// below stays pure and testable without SwiftData.
nonisolated struct WingMaintenanceSnapshot: Sendable {
    var previousHours: Double? = nil
    var purchaseDate: Date? = nil
    var lastTrimDate: Date? = nil
    var serviceLog: [WingServiceEvent] = []
    var smallTrimIntervalHours: Double? = nil
    var fullTrimIntervalHours: Double? = nil
    var fullTrimIntervalMonths: Int? = nil
    var flights: [MaintenanceFlight] = []
}

/// Manufacturer-recommended service intervals (see
/// `WingMaintenance.manufacturerDefaults`).
nonisolated struct MaintenanceDefaults: Sendable, Equatable {
    var smallTrimIntervalHours: Double? = nil
    var fullTrimIntervalHours: Double? = nil
    var fullTrimIntervalMonths: Int? = nil
}

// MARK: - Pure schedule logic

nonisolated enum WingMaintenance {

    /// "Due soon" thresholds requested by Xavier: fewer than 5 flight hours
    /// or less than 1 month remaining.
    static let dueSoonHoursThreshold: Double = 5
    static let dueSoonMonthsThreshold: Int = 1

    // MARK: Totals

    /// Total hours on the wing: hours flown before the app + logged flights.
    static func totalHours(_ snapshot: WingMaintenanceSnapshot) -> Double {
        (snapshot.previousHours ?? 0) + snapshot.flights.reduce(0) { $0 + $1.hours }
    }

    // MARK: Hours since last service

    /// Hours flown since the last service that resets `type`'s counter.
    ///
    /// The small-trim counter resets on smallTrim AND fullTrim events (a full
    /// trim includes the small one); the full-trim counter resets on fullTrim
    /// only; `check` events reset nothing. A resetting event with
    /// `hoursAtService` resets by hours (total - hoursAtService), otherwise
    /// by date (logged flights after the event).
    ///
    /// Fallback chain when no resetting event exists:
    ///   - `lastTrimDate`: logged flights after that date (pre-app hours are
    ///     assumed flown before that last KNOWN trim);
    ///   - `purchaseDate`: a factory-new wing is trimmed at purchase, and the
    ///     pre-app hours were flown after it, so they count;
    ///   - otherwise every known hour counts (previousHours + all flights) —
    ///     we prefer over-counting to silently missing a trim.
    static func hoursSinceService(_ type: WingServiceType, in snapshot: WingMaintenanceSnapshot) -> Double {
        let resetTypes: Set<WingServiceType> = type == .smallTrim ? [.smallTrim, .fullTrim] : [type]
        if let event = snapshot.serviceLog
            .filter({ resetTypes.contains($0.type) })
            .max(by: { $0.date < $1.date }) {
            if let hoursAtService = event.hoursAtService {
                return max(0, totalHours(snapshot) - hoursAtService)
            }
            return flightHours(after: event.date, in: snapshot)
        }
        if let lastTrimDate = snapshot.lastTrimDate {
            return flightHours(after: lastTrimDate, in: snapshot)
        }
        if let purchaseDate = snapshot.purchaseDate {
            return (snapshot.previousHours ?? 0) + flightHours(after: purchaseDate, in: snapshot)
        }
        return totalHours(snapshot)
    }

    /// Sum of logged flight hours strictly after `date`.
    private static func flightHours(after date: Date, in snapshot: WingMaintenanceSnapshot) -> Double {
        snapshot.flights.filter { $0.date > date }.reduce(0) { $0 + $1.hours }
    }

    /// Baseline date for the month-based full-trim deadline: last full-trim
    /// event, else the last known trim date, else the purchase date, else the
    /// first logged flight (first known hour). nil when nothing is known.
    static func fullTrimAnchorDate(in snapshot: WingMaintenanceSnapshot) -> Date? {
        if let event = snapshot.serviceLog
            .filter({ $0.type == .fullTrim })
            .max(by: { $0.date < $1.date }) {
            return event.date
        }
        return snapshot.lastTrimDate
            ?? snapshot.purchaseDate
            ?? snapshot.flights.map(\.date).min()
    }

    // MARK: Deadlines

    /// Deadline state for one trim type; nil when no interval is configured
    /// for that type. For the full trim, the hour and month intervals combine
    /// as "whichever comes first".
    static func dueState(
        for type: WingServiceType,
        in snapshot: WingMaintenanceSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrimDueState? {
        var hoursRemaining: Double?
        var dueDate: Date?

        switch type {
        case .smallTrim:
            if let interval = snapshot.smallTrimIntervalHours {
                hoursRemaining = interval - hoursSinceService(.smallTrim, in: snapshot)
            }
        case .fullTrim:
            if let interval = snapshot.fullTrimIntervalHours {
                hoursRemaining = interval - hoursSinceService(.fullTrim, in: snapshot)
            }
            if let months = snapshot.fullTrimIntervalMonths,
               let anchor = fullTrimAnchorDate(in: snapshot) {
                dueDate = calendar.date(byAdding: .month, value: months, to: anchor)
            }
        case .check:
            break // plain checks carry no schedule
        }

        guard hoursRemaining != nil || dueDate != nil else { return nil }
        let status = status(hoursRemaining: hoursRemaining, dueDate: dueDate, now: now, calendar: calendar)
        return TrimDueState(status: status, hoursRemaining: hoursRemaining, dueDate: dueDate)
    }

    /// Combines an hour-based and a date-based deadline: first reached wins.
    static func status(
        hoursRemaining: Double?,
        dueDate: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrimStatus {
        if let hoursRemaining, hoursRemaining <= 0 { return .overdue }
        if let dueDate, dueDate <= now { return .overdue }
        if let hoursRemaining, hoursRemaining < dueSoonHoursThreshold { return .dueSoon }
        if let dueDate,
           let soon = calendar.date(byAdding: .month, value: dueSoonMonthsThreshold, to: now),
           dueDate <= soon {
            return .dueSoon
        }
        return .ok
    }

    /// Both deadlines at once — what the detail view consumes.
    static func dueStates(
        in snapshot: WingMaintenanceSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (small: TrimDueState?, full: TrimDueState?) {
        (dueState(for: .smallTrim, in: snapshot, now: now, calendar: calendar),
         dueState(for: .fullTrim, in: snapshot, now: now, calendar: calendar))
    }

    /// The worst status across both deadlines; nil when nothing is scheduled
    /// (drives the discreet badge in the wing list).
    static func worstStatus(
        in snapshot: WingMaintenanceSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrimStatus? {
        let states = dueStates(in: snapshot, now: now, calendar: calendar)
        let statuses = [states.small, states.full].compactMap { $0?.status }
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(.overdue) { return .overdue }
        if statuses.contains(.dueSoon) { return .dueSoon }
        return .ok
    }

    // MARK: Manufacturer defaults

    /// Manufacturer-recommended service intervals, keyed by a case-insensitive
    /// substring matched against "<brand> <model>".
    ///
    /// Sources (checked 2026-07):
    ///  - "moustache": FLARE Moustache user manual, §12 "Maintenance-Check"
    ///    (manualslib.com/manual/3308105, p.54): "it has to undergo a
    ///    maintenance check after 24 months or after 200 flight hours
    ///    (whichever occurs first)". No small-trim interval is published.
    ///  - "bandit": FLARE Bandit user manual, edition 1.0/10_2025
    ///    (go-flare.com), §10 "Maintenance": "THE TRIM IS A DOUBLE LOOP
    ///    BETWEEN THE B-MAIN LINES AND THE SHACKLE AND SHOULD BE REMOVED
    ///    AFTER APPROXIMATELY 10 FLIGHT HOURS" -> small trim 10 h; and §12
    ///    "Maintenance Check": after 24 months or 200 flight hours,
    ///    whichever occurs first.
    ///  - "mullet": no Mullet/MulletX-specific manual found; Flow-wide
    ///    guidance (Flow Future / RPM user manuals, flowparagliders.com.au):
    ///    checked "at least once every two years, or after 100 hours".
    ///  - "dudek": Dudek service documents (dudek.eu / dudek-paragliders.de):
    ///    Full Inspection every 24 months or 150 hours airtime, whichever
    ///    comes first (non-commercial use).
    static let manufacturerDefaults: [String: MaintenanceDefaults] = [
        "moustache": MaintenanceDefaults(fullTrimIntervalHours: 200, fullTrimIntervalMonths: 24),
        "bandit": MaintenanceDefaults(smallTrimIntervalHours: 10, fullTrimIntervalHours: 200, fullTrimIntervalMonths: 24),
        "mullet": MaintenanceDefaults(fullTrimIntervalHours: 100, fullTrimIntervalMonths: 24), // also matches "MulletX"
        "dudek": MaintenanceDefaults(fullTrimIntervalHours: 150, fullTrimIntervalMonths: 24),
    ]

    /// The defaults whose key appears in `name` (case-insensitive), e.g.
    /// "Flare Bandit 13" matches the "bandit" entry. nil when nothing matches.
    static func defaults(matching name: String) -> MaintenanceDefaults? {
        let lowered = name.lowercased()
        return manufacturerDefaults.first { lowered.contains($0.key) }?.value
    }
}

// MARK: - Wing bridge (main actor: reads the SwiftData model)

extension Wing {
    /// Value snapshot of this wing's maintenance state for the pure logic above.
    var maintenanceSnapshot: WingMaintenanceSnapshot {
        WingMaintenanceSnapshot(
            previousHours: previousHours,
            purchaseDate: purchaseDate,
            lastTrimDate: lastTrimDate,
            serviceLog: serviceLog,
            smallTrimIntervalHours: smallTrimIntervalHours,
            fullTrimIntervalHours: fullTrimIntervalHours,
            fullTrimIntervalMonths: fullTrimIntervalMonths,
            flights: (flights ?? []).map {
                MaintenanceFlight(date: $0.startDate, hours: Double($0.durationSeconds) / 3600.0)
            }
        )
    }
}

// MARK: - Trim reminders (local notifications)

extension WingMaintenance {

    /// Stable notification identifier ("trim-<wingId>-<type>") so every run
    /// replaces the previous reminder for the same wing/type.
    static func reminderIdentifier(wingId: UUID, type: WingServiceType) -> String {
        "trim-\(wingId.uuidString)-\(type.rawValue)"
    }

    private static let reminderIdentifierPrefix = "trim-"

    /// (Re)schedules the local trim reminders for `wings`:
    ///   - a deadline that is dueSoon/overdue NOW fires a reminder ~1 hour
    ///     from now (immediate-ish, but off the save path);
    ///   - an ok deadline with a known calendar due date is scheduled at
    ///     (due date - 1 month), i.e. the moment it turns dueSoon.
    /// Every "trim-" notification is cleared first, so repeated calls
    /// replace, never stack. Fail-soft (same pattern as PushService.register
    /// / ForecastAlertService): prompts for authorization only when
    /// undetermined AND something needs scheduling; denied or failures only
    /// log. Not reusing PushService.ensureAuthorized to avoid its APNs
    /// push-target side effects — these reminders are purely local.
    @MainActor
    static func scheduleTrimReminders(wings: [Wing]) async {
        let now = Date()
        let calendar = Calendar.current
        var requests: [UNNotificationRequest] = []

        for wing in wings where !wing.isArchived {
            let snapshot = wing.maintenanceSnapshot
            for type in [WingServiceType.smallTrim, .fullTrim] {
                guard let state = dueState(for: type, in: snapshot, now: now, calendar: calendar) else { continue }

                let content = UNMutableNotificationContent()
                content.sound = .default
                var trigger: UNNotificationTrigger?

                switch state.status {
                case .overdue:
                    content.title = "Wing service overdue"
                    content.body = "\(wing.name) is overdue for a \(type.label.lowercased())."
                    trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
                case .dueSoon:
                    content.title = "Wing service due soon"
                    content.body = "\(wing.name): \(type.label.lowercased()) is coming up. Plan it before your next flights."
                    trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
                case .ok:
                    // Schedule at the moment the calendar deadline turns dueSoon.
                    if let dueDate = state.dueDate,
                       let fireDate = calendar.date(byAdding: .month, value: -dueSoonMonthsThreshold, to: dueDate),
                       fireDate > now {
                        content.title = "Wing service due soon"
                        content.body = "\(wing.name): \(type.label.lowercased()) is due by \(dueDate.formatted(date: .abbreviated, time: .omitted))."
                        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                        trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    }
                }

                if let trigger {
                    requests.append(UNNotificationRequest(
                        identifier: reminderIdentifier(wingId: wing.id, type: type),
                        content: content,
                        trigger: trigger
                    ))
                }
            }
        }

        // Always clear the previous run's reminders (stable replace).
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let staleIds = pending.map(\.identifier).filter { $0.hasPrefix(reminderIdentifierPrefix) }
        if !staleIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIds)
        }

        guard !requests.isEmpty else { return }

        // Fail-soft authorization: only reached when something needs
        // scheduling, so a pilot who never configured intervals is never
        // prompted.
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else {
                logInfo("Trim reminder authorization declined", category: .dataController)
                return
            }
        case .denied:
            return
        default:
            break // authorized / provisional / ephemeral
        }

        for request in requests {
            center.add(request)
        }
        logInfo("Scheduled \(requests.count) trim reminder(s)", category: .dataController)
    }
}
