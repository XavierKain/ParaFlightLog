//
//  WingMaintenanceTests.swift
//  ParaFlightLogTests
//
//  Pure trim/maintenance schedule logic (WingMaintenance): totals with and
//  without pre-app hours, counter resets by service events, ok/dueSoon/overdue
//  thresholds (5 h / 1 month), and the dual hours-or-months deadline
//  ("whichever occurs first"). No SwiftData involved.
//

import Foundation
import Testing
@testable import ParaFlightLog

@Suite struct WingMaintenanceTests {

    /// Fixed reference date so every test is deterministic.
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calendar = Calendar(identifier: .gregorian)

    func days(_ count: Double) -> TimeInterval { count * 86_400 }
    func daysAgo(_ count: Double) -> Date { now.addingTimeInterval(-days(count)) }

    // MARK: - Totals

    @Test func totalHoursWithoutPreviousHours() {
        let snapshot = WingMaintenanceSnapshot(flights: [
            MaintenanceFlight(date: daysAgo(2), hours: 1.5),
            MaintenanceFlight(date: daysAgo(1), hours: 2.0)
        ])
        #expect(WingMaintenance.totalHours(snapshot) == 3.5)
    }

    @Test func totalHoursIncludesPreviousHours() {
        let snapshot = WingMaintenanceSnapshot(
            previousHours: 45,
            flights: [MaintenanceFlight(date: daysAgo(1), hours: 2)]
        )
        #expect(WingMaintenance.totalHours(snapshot) == 47)
    }

    @Test func totalHoursOfEmptySnapshotIsZero() {
        #expect(WingMaintenance.totalHours(WingMaintenanceSnapshot()) == 0)
    }

    // MARK: - Hours since last service

    @Test func serviceEventResetsCounterByHoursAtService() {
        let snapshot = WingMaintenanceSnapshot(
            previousHours: 10,
            serviceLog: [WingServiceEvent(date: daysAgo(30), type: .smallTrim, note: nil, hoursAtService: 12)],
            flights: [MaintenanceFlight(date: daysAgo(10), hours: 5)]
        )
        // Total 15 h, trimmed at 12 h -> 3 h on the counter
        #expect(WingMaintenance.hoursSinceService(.smallTrim, in: snapshot) == 3)
    }

    @Test func serviceEventWithoutHoursCountsFlightsAfterItsDate() {
        let snapshot = WingMaintenanceSnapshot(
            previousHours: 40,
            serviceLog: [WingServiceEvent(date: daysAgo(30), type: .fullTrim, note: nil, hoursAtService: nil)],
            flights: [
                MaintenanceFlight(date: daysAgo(60), hours: 4), // before the trim
                MaintenanceFlight(date: daysAgo(10), hours: 2),
                MaintenanceFlight(date: daysAgo(5), hours: 1.5)
            ]
        )
        #expect(WingMaintenance.hoursSinceService(.fullTrim, in: snapshot) == 3.5)
    }

    @Test func fullTrimResetsSmallTrimCounterToo() {
        let snapshot = WingMaintenanceSnapshot(
            serviceLog: [
                WingServiceEvent(date: daysAgo(90), type: .smallTrim, note: nil, hoursAtService: 5),
                WingServiceEvent(date: daysAgo(20), type: .fullTrim, note: nil, hoursAtService: 20)
            ],
            flights: [MaintenanceFlight(date: daysAgo(1), hours: 22)]
        )
        // The later full trim (at 20 h) governs the small counter: 22 - 20 = 2
        #expect(WingMaintenance.hoursSinceService(.smallTrim, in: snapshot) == 2)
    }

    @Test func smallTrimDoesNotResetFullTrimCounter() {
        let snapshot = WingMaintenanceSnapshot(
            serviceLog: [WingServiceEvent(date: daysAgo(10), type: .smallTrim, note: nil, hoursAtService: 18)],
            flights: [MaintenanceFlight(date: daysAgo(1), hours: 20)]
        )
        #expect(WingMaintenance.hoursSinceService(.smallTrim, in: snapshot) == 2)
        // No full trim ever: the full counter still carries every known hour
        #expect(WingMaintenance.hoursSinceService(.fullTrim, in: snapshot) == 20)
    }

    @Test func checkEventResetsNothing() {
        let snapshot = WingMaintenanceSnapshot(
            serviceLog: [WingServiceEvent(date: daysAgo(5), type: .check, note: nil, hoursAtService: 9)],
            flights: [MaintenanceFlight(date: daysAgo(1), hours: 10)]
        )
        #expect(WingMaintenance.hoursSinceService(.smallTrim, in: snapshot) == 10)
        #expect(WingMaintenance.hoursSinceService(.fullTrim, in: snapshot) == 10)
    }

    @Test func lastTrimDateAnchorsCountersWhenNoServiceLog() {
        // Used wing: 45 h before the app, last known trim 30 days ago,
        // 6 h flown since. Pre-app hours are assumed before that trim.
        let snapshot = WingMaintenanceSnapshot(
            previousHours: 45,
            lastTrimDate: daysAgo(30),
            flights: [
                MaintenanceFlight(date: daysAgo(40), hours: 3), // before the trim
                MaintenanceFlight(date: daysAgo(10), hours: 6)
            ]
        )
        #expect(WingMaintenance.hoursSinceService(.fullTrim, in: snapshot) == 6)
    }

    @Test func withoutAnyAnchorEveryKnownHourCounts() {
        let snapshot = WingMaintenanceSnapshot(
            previousHours: 45,
            flights: [MaintenanceFlight(date: daysAgo(1), hours: 5)]
        )
        #expect(WingMaintenance.hoursSinceService(.fullTrim, in: snapshot) == 50)
    }

    @Test func purchaseDateAnchorIncludesPreAppHours() {
        // Bought new: the pre-app hours were flown after the factory trim.
        let snapshot = WingMaintenanceSnapshot(
            previousHours: 8,
            purchaseDate: daysAgo(300),
            flights: [MaintenanceFlight(date: daysAgo(10), hours: 4)]
        )
        #expect(WingMaintenance.hoursSinceService(.fullTrim, in: snapshot) == 12)
    }

    // MARK: - Status thresholds (5 h / 1 month)

    @Test func statusOkWhenPlentyRemains() {
        #expect(WingMaintenance.status(hoursRemaining: 50, dueDate: nil, now: now, calendar: calendar) == .ok)
        #expect(WingMaintenance.status(hoursRemaining: 5, dueDate: nil, now: now, calendar: calendar) == .ok)
    }

    @Test func statusDueSoonUnderFiveHours() {
        #expect(WingMaintenance.status(hoursRemaining: 4.9, dueDate: nil, now: now, calendar: calendar) == .dueSoon)
        #expect(WingMaintenance.status(hoursRemaining: 0.1, dueDate: nil, now: now, calendar: calendar) == .dueSoon)
    }

    @Test func statusOverdueAtOrBelowZeroHours() {
        #expect(WingMaintenance.status(hoursRemaining: 0, dueDate: nil, now: now, calendar: calendar) == .overdue)
        #expect(WingMaintenance.status(hoursRemaining: -3, dueDate: nil, now: now, calendar: calendar) == .overdue)
    }

    @Test func statusDueSoonWithinOneMonthOfDueDate() {
        let dueIn20Days = now.addingTimeInterval(days(20))
        #expect(WingMaintenance.status(hoursRemaining: nil, dueDate: dueIn20Days, now: now, calendar: calendar) == .dueSoon)

        let dueIn45Days = now.addingTimeInterval(days(45))
        #expect(WingMaintenance.status(hoursRemaining: nil, dueDate: dueIn45Days, now: now, calendar: calendar) == .ok)
    }

    @Test func statusOverdueWhenDueDatePassed() {
        let yesterday = now.addingTimeInterval(-days(1))
        #expect(WingMaintenance.status(hoursRemaining: nil, dueDate: yesterday, now: now, calendar: calendar) == .overdue)
    }

    @Test func worstDimensionWins() {
        // Plenty of hours left, but the calendar deadline already passed
        let yesterday = now.addingTimeInterval(-days(1))
        #expect(WingMaintenance.status(hoursRemaining: 190, dueDate: yesterday, now: now, calendar: calendar) == .overdue)
        // Date is far away, but fewer than 5 h remain
        let farAway = now.addingTimeInterval(days(400))
        #expect(WingMaintenance.status(hoursRemaining: 2, dueDate: farAway, now: now, calendar: calendar) == .dueSoon)
    }

    // MARK: - Due states

    @Test func dueStateNilWhenNothingConfigured() {
        let snapshot = WingMaintenanceSnapshot(flights: [MaintenanceFlight(date: daysAgo(1), hours: 12)])
        #expect(WingMaintenance.dueState(for: .smallTrim, in: snapshot, now: now, calendar: calendar) == nil)
        #expect(WingMaintenance.dueState(for: .fullTrim, in: snapshot, now: now, calendar: calendar) == nil)
    }

    @Test func smallTrimDueStateReportsRemainingHours() {
        let snapshot = WingMaintenanceSnapshot(
            smallTrimIntervalHours: 10,
            flights: [MaintenanceFlight(date: daysAgo(1), hours: 7)]
        )
        let state = WingMaintenance.dueState(for: .smallTrim, in: snapshot, now: now, calendar: calendar)
        #expect(state == TrimDueState(status: .dueSoon, hoursRemaining: 3, dueDate: nil))
    }

    @Test func fullTrimHoursOrMonthsFirstReachedWins() {
        // Barely 10 h on a 200 h interval, but purchased ~26 months ago with
        // a 24-month interval -> the calendar deadline decides: overdue.
        let snapshot = WingMaintenanceSnapshot(
            purchaseDate: daysAgo(800),
            fullTrimIntervalHours: 200,
            fullTrimIntervalMonths: 24,
            flights: [MaintenanceFlight(date: daysAgo(10), hours: 10)]
        )
        let state = WingMaintenance.dueState(for: .fullTrim, in: snapshot, now: now, calendar: calendar)
        #expect(state?.status == .overdue)
        #expect(state?.hoursRemaining == 190)
        let dueDate = calendar.date(byAdding: .month, value: 24, to: daysAgo(800))
        #expect(state?.dueDate == dueDate)
    }

    @Test func fullTrimMonthsAnchorPrefersLatestFullTrimEvent() {
        // A full trim 30 days ago restarts the 24-month clock even though the
        // wing was purchased long ago.
        let snapshot = WingMaintenanceSnapshot(
            purchaseDate: daysAgo(900),
            serviceLog: [WingServiceEvent(date: daysAgo(30), type: .fullTrim, note: nil, hoursAtService: 50)],
            fullTrimIntervalMonths: 24,
            flights: [MaintenanceFlight(date: daysAgo(5), hours: 2)]
        )
        let state = WingMaintenance.dueState(for: .fullTrim, in: snapshot, now: now, calendar: calendar)
        #expect(state?.status == .ok)
        #expect(state?.dueDate == calendar.date(byAdding: .month, value: 24, to: daysAgo(30)))
    }

    @Test func monthsOnlyDeadlineFallsBackToFirstFlightAnchor() {
        // No purchase or trim date: the clock starts at the first known hour.
        let firstFlight = daysAgo(100)
        let snapshot = WingMaintenanceSnapshot(
            fullTrimIntervalMonths: 24,
            flights: [
                MaintenanceFlight(date: firstFlight, hours: 1),
                MaintenanceFlight(date: daysAgo(2), hours: 1)
            ]
        )
        let state = WingMaintenance.dueState(for: .fullTrim, in: snapshot, now: now, calendar: calendar)
        #expect(state?.dueDate == calendar.date(byAdding: .month, value: 24, to: firstFlight))
        #expect(state?.status == .ok)
    }

    @Test func dueStatesAndWorstStatus() {
        // Small trim overdue (12 h flown on a 10 h interval), full trim ok.
        let snapshot = WingMaintenanceSnapshot(
            smallTrimIntervalHours: 10,
            fullTrimIntervalHours: 200,
            flights: [MaintenanceFlight(date: daysAgo(1), hours: 12)]
        )
        let states = WingMaintenance.dueStates(in: snapshot, now: now, calendar: calendar)
        #expect(states.small?.status == .overdue)
        #expect(states.full?.status == .ok)
        #expect(WingMaintenance.worstStatus(in: snapshot, now: now, calendar: calendar) == .overdue)
    }

    @Test func worstStatusNilWithoutAnySchedule() {
        #expect(WingMaintenance.worstStatus(in: WingMaintenanceSnapshot(), now: now, calendar: calendar) == nil)
    }

    // MARK: - Manufacturer defaults

    @Test func manufacturerDefaultsMatchBySubstring() {
        let bandit = WingMaintenance.defaults(matching: "FLARE Bandit 13")
        #expect(bandit?.smallTrimIntervalHours == 10)
        #expect(bandit?.fullTrimIntervalHours == 200)
        #expect(bandit?.fullTrimIntervalMonths == 24)

        let moustache = WingMaintenance.defaults(matching: "Flare MOUSTACHE M2")
        #expect(moustache?.smallTrimIntervalHours == nil)
        #expect(moustache?.fullTrimIntervalHours == 200)
        #expect(moustache?.fullTrimIntervalMonths == 24)

        // "MulletX" contains "mullet"
        #expect(WingMaintenance.defaults(matching: "Flow MulletX")?.fullTrimIntervalHours == 100)

        #expect(WingMaintenance.defaults(matching: "Ozone Rush 6") == nil)
    }

    @Test func reminderIdentifierIsStable() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        #expect(WingMaintenance.reminderIdentifier(wingId: id, type: .smallTrim)
                == "trim-11111111-1111-1111-1111-111111111111-smallTrim")
    }
}
