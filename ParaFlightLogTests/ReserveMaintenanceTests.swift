//
//  ReserveMaintenanceTests.swift
//  ParaFlightLogTests
//
//  The repack deadline. A reserve comes due on the calendar alone, and the
//  whole point of the feature is that the reminder arrives BEFORE the
//  deadline rather than after it — so the boundaries are what matter here.
//

import Foundation
import SwiftData
import Testing
@testable import ParaFlightLog

@Suite("Reserve repack deadline")
struct ReserveMaintenanceTests {

    private let container: ModelContainer

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Reserve.self, configurations: configuration)
    }

    /// A reserve whose last repack was `monthsAgo` months before `now`.
    private func reserve(monthsAgo: Int?, interval: Int = 12, daysOffset: Int = 0) -> Reserve {
        let calendar = Calendar.current
        var last: Date?
        if let monthsAgo {
            let base = calendar.date(byAdding: .month, value: -monthsAgo, to: Self.now)!
            last = calendar.date(byAdding: .day, value: daysOffset, to: base)!
        }
        let r = Reserve(
            name: "Test",
            repackLog: last.map { [RepackEvent(date: $0)] } ?? [],
            repackIntervalMonths: interval
        )
        container.mainContext.insert(r)
        return r
    }

    /// Fixed "today" so the suite does not drift with the calendar.
    private static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!

    @Test func noRepackRecordedHasNoDeadline() {
        let state = ReserveMaintenance.deadline(for: reserve(monthsAgo: nil), now: Self.now)
        #expect(state.status == .unknown)
        #expect(state.dueDate == nil)
        #expect(state.daysRemaining == nil)
    }

    @Test func freshRepackIsOk() {
        let state = ReserveMaintenance.deadline(for: reserve(monthsAgo: 1), now: Self.now)
        #expect(state.status == .ok)
        #expect((state.daysRemaining ?? 0) > 300)
    }

    /// The month before the deadline is when the pilot still has time to book
    /// a packer — that is the whole reason the threshold exists.
    @Test func oneMonthBeforeTheDeadlineIsDueSoon() {
        let state = ReserveMaintenance.deadline(for: reserve(monthsAgo: 11), now: Self.now)
        #expect(state.status == .dueSoon)
    }

    @Test func pastTheDeadlineIsOverdue() {
        let state = ReserveMaintenance.deadline(for: reserve(monthsAgo: 13), now: Self.now)
        #expect(state.status == .overdue)
        #expect((state.daysRemaining ?? 0) < 0)
    }

    /// Due today is NOT overdue: the pilot has the day to get it done, and
    /// flagging it red a day early would cry wolf.
    @Test func dueTodayIsNotOverdue() {
        let state = ReserveMaintenance.deadline(for: reserve(monthsAgo: 12), now: Self.now)
        #expect(state.status == .dueSoon)
        #expect(state.daysRemaining == 0)
    }

    /// One day past is overdue — the boundary has to fall somewhere exact.
    @Test func oneDayPastTheDeadlineIsOverdue() {
        let state = ReserveMaintenance.deadline(for: reserve(monthsAgo: 12, daysOffset: -1), now: Self.now)
        #expect(state.status == .overdue)
        #expect(state.daysRemaining == -1)
    }

    /// A six-month interval is a real manufacturer requirement, not decoration:
    /// the same repack date must come due twice as fast.
    @Test func sixMonthIntervalComesDueTwiceAsFast() {
        let sixMonths = ReserveMaintenance.deadline(for: reserve(monthsAgo: 7, interval: 6), now: Self.now)
        let twelveMonths = ReserveMaintenance.deadline(for: reserve(monthsAgo: 7, interval: 12), now: Self.now)
        #expect(sixMonths.status == .overdue)
        #expect(twelveMonths.status == .ok)
    }

    /// The deadline the UI shows must be the repack date plus the interval,
    /// not an approximation in days — "every 12 months" means the same day of
    /// the month, whatever its length.
    @Test func dueDateIsTheRepackDatePlusTheInterval() throws {
        let calendar = Calendar.current
        let last = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        let r = Reserve(name: "Test", repackLog: [RepackEvent(date: last)], repackIntervalMonths: 12)
        container.mainContext.insert(r)

        let due = try #require(r.nextRepackDate)
        let components = calendar.dateComponents([.year, .month, .day], from: due)
        #expect(components.year == 2027)
        #expect(components.month == 1)
        #expect(components.day == 31)
    }

    @Test func ageIsReportedInWholeYears() throws {
        let calendar = Calendar.current
        let made = calendar.date(byAdding: .month, value: -30, to: Date())!
        let r = Reserve(name: "Test", manufactureDate: made)
        container.mainContext.insert(r)
        #expect(r.ageInYears == 2)
    }
}

// MARK: - Repack history

@Suite("Reserve repack history")
struct ReserveRepackLogTests {

    private let container: ModelContainer

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Reserve.self, configurations: configuration)
    }

    private func make(_ dates: [Date]) -> Reserve {
        let r = Reserve(name: "Test", repackLog: dates.map { RepackEvent(date: $0) })
        container.mainContext.insert(r)
        return r
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// Entries come back newest first whatever order they went in, because the
    /// deadline reads the first one.
    @Test func historyIsOrderedNewestFirst() {
        let r = make([day(2024, 3, 1), day(2026, 5, 10), day(2025, 4, 2)])
        let dates = r.repackLog.map(\.date)
        #expect(dates == [day(2026, 5, 10), day(2025, 4, 2), day(2024, 3, 1)])
    }

    /// The deadline must follow the NEWEST entry, not the last one appended —
    /// a pilot backfilling an old repack must not reset their deadline.
    @Test func backfillingAnOlderRepackDoesNotMoveTheDeadline() {
        let r = make([day(2026, 5, 10)])
        r.repackLog.append(RepackEvent(date: day(2023, 1, 1)))
        #expect(r.lastRepackDate == day(2026, 5, 10))
    }

    @Test func loggingANewerRepackMovesTheDeadline() {
        let r = make([day(2025, 5, 10)])
        r.repackLog.append(RepackEvent(date: day(2026, 6, 1)))
        #expect(r.lastRepackDate == day(2026, 6, 1))
        #expect(r.repackLog.count == 2)
    }

    /// An empty history means no deadline at all, not a deadline in 1970.
    @Test func emptyHistoryHasNoDeadline() {
        let r = make([])
        #expect(r.lastRepackDate == nil)
        #expect(r.nextRepackDate == nil)
        #expect(ReserveMaintenance.deadline(for: r).status == .unknown)
    }

    /// The packer survives a round trip through the encoded payload — it is
    /// the half of the record that matters when a reserve changes hands.
    @Test func packerAndNoteSurviveEncoding() throws {
        let r = make([])
        r.repackLog = [RepackEvent(date: day(2026, 2, 3), packer: "Aero Rigging", note: "Lines checked")]
        let entry = try #require(r.repackLog.first)
        #expect(entry.packer == "Aero Rigging")
        #expect(entry.note == "Lines checked")
    }
}
