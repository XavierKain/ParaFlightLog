//
//  ReserveMaintenance.swift
//  ParaFlightLog
//
//  Repack deadlines for reserve parachutes, and the local reminders that go
//  with them.
//
//  Deliberately a sibling of WingMaintenance rather than an extension of it:
//  a wing's trim is driven by HOURS FLOWN, a reserve's repack by the CALENDAR
//  alone — it comes due sitting in a cupboard. Sharing one deadline engine
//  would mean one of the two lying about what drives it.
//
//  Target: iOS only
//

import Foundation
import UserNotifications

// MARK: - Status

nonisolated enum RepackStatus: Sendable {
    /// No repack recorded yet, so there is no deadline to judge.
    case unknown
    case ok
    case dueSoon
    case overdue
}

nonisolated struct RepackDeadline: Sendable {
    let status: RepackStatus
    /// Nil only when `status == .unknown`.
    let dueDate: Date?
    /// Whole days until the deadline; negative once it has passed.
    let daysRemaining: Int?
}

// MARK: - ReserveMaintenance

nonisolated enum ReserveMaintenance {

    /// How long before the deadline a repack starts being flagged. A month is
    /// what it realistically takes to get a slot with a packer.
    static let dueSoonMonths = 1

    static func deadline(for reserve: Reserve, now: Date = Date(), calendar: Calendar = .current) -> RepackDeadline {
        guard let dueDate = reserve.nextRepackDate else {
            return RepackDeadline(status: .unknown, dueDate: nil, daysRemaining: nil)
        }

        // Compare whole days: a repack due "today" is not overdue, and the
        // clock-time component of the stored dates is meaningless here.
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDue = calendar.startOfDay(for: dueDate)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfDue).day ?? 0

        let status: RepackStatus
        if days < 0 {
            status = .overdue
        } else if let threshold = calendar.date(byAdding: .month, value: -dueSoonMonths, to: startOfDue),
                  startOfToday >= calendar.startOfDay(for: threshold) {
            status = .dueSoon
        } else {
            status = .ok
        }

        return RepackDeadline(status: status, dueDate: dueDate, daysRemaining: days)
    }
}

// MARK: - Reminders

extension ReserveMaintenance {

    /// Stable identifier so each run replaces the previous reminder for the
    /// same reserve instead of stacking another copy.
    static func reminderIdentifier(reserveId: UUID) -> String {
        "repack-\(reserveId.uuidString)"
    }

    private static let reminderIdentifierPrefix = "repack-"

    /// (Re)schedules the local repack reminders.
    ///
    /// Same contract as WingMaintenance.scheduleTrimReminders: every
    /// "repack-" notification is cleared first so repeated calls replace
    /// rather than stack, and authorization is requested ONLY when something
    /// actually needs scheduling — a pilot who never recorded a repack is
    /// never prompted. Denials and failures only log.
    @MainActor
    static func scheduleRepackReminders(reserves: [Reserve]) async {
        let now = Date()
        let calendar = Calendar.current
        var requests: [UNNotificationRequest] = []

        for reserve in reserves where !reserve.isArchived {
            let state = deadline(for: reserve, now: now, calendar: calendar)
            guard let dueDate = state.dueDate else { continue }

            let content = UNMutableNotificationContent()
            content.sound = .default
            var trigger: UNNotificationTrigger?

            switch state.status {
            case .unknown:
                break
            case .overdue:
                content.title = String(localized: "Reserve repack overdue")
                content.body = String(localized: "\(reserve.name) was due for a repack on \(dueDate.formatted(date: .abbreviated, time: .omitted)).")
                // An hour out rather than immediately: this runs on app launch
                // and after edits, and a notification firing while the pilot is
                // looking at the screen that caused it is just noise.
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
            case .dueSoon:
                content.title = String(localized: "Reserve repack due soon")
                content.body = String(localized: "\(reserve.name) needs its repack by \(dueDate.formatted(date: .abbreviated, time: .omitted)). Book a packer.")
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
            case .ok:
                // Fire on the day it turns dueSoon, at 9am local — a reminder
                // that arrives at 3am is a reminder that gets dismissed.
                if let fireDay = calendar.date(byAdding: .month, value: -dueSoonMonths, to: dueDate),
                   let fireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: fireDay),
                   fireDate > now {
                    content.title = String(localized: "Reserve repack due soon")
                    content.body = String(localized: "\(reserve.name) needs its repack by \(dueDate.formatted(date: .abbreviated, time: .omitted)). Book a packer.")
                    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                }
            }

            if let trigger {
                requests.append(UNNotificationRequest(
                    identifier: reminderIdentifier(reserveId: reserve.id),
                    content: content,
                    trigger: trigger
                ))
            }
        }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let staleIds = pending.map(\.identifier).filter { $0.hasPrefix(reminderIdentifierPrefix) }
        if !staleIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIds)
        }

        guard !requests.isEmpty else { return }

        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard granted else {
                logInfo("Repack reminder authorization declined", category: .dataController)
                return
            }
        case .denied:
            return
        default:
            break
        }

        for request in requests {
            try? await center.add(request)
        }
        logInfo("Scheduled \(requests.count) repack reminder(s)", category: .dataController)
    }
}
