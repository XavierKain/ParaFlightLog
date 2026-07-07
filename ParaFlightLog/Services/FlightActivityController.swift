//
//  FlightActivityController.swift
//  ParaFlightLog
//
//  Thin, fail-soft wrapper around ActivityKit for the phone-tracked flight
//  Live Activity. The visible timer ticks by itself on the Lock Screen
//  (Text(timerInterval:) anchored to startDate), so pushes are only needed
//  for altitude / vario / spot changes and are throttled to one every 15 s —
//  except spot changes, which go through immediately.
//
//  Every entry point is best-effort: a Live Activity failure must NEVER
//  affect the flight flow (start, tick, save).
//  Target: iOS
//

import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class FlightActivityController {
    static let shared = FlightActivityController()

    /// Minimum delay between two content pushes (spot changes bypass it).
    private static let minimumPushInterval: TimeInterval = 15

    /// Every push carries a staleDate of takeoff + 12 h: if the app stops
    /// pushing (crash / force-quit mid-flight), the system marks the
    /// activity stale instead of showing a live-looking timer forever.
    private static let staleInterval: TimeInterval = 12 * 3600

    #if canImport(ActivityKit)
    private var activity: Activity<FlightActivityAttributes>?
    #endif
    private var startDate: Date = .distantPast
    private var lastPushDate: Date = .distantPast
    private var lastSpotName: String = ""

    private init() {}

    /// Starts the Live Activity for a new flight. No-op (with a log) when
    /// Live Activities are disabled or unavailable.
    func start(wingName: String, flightType: String, spotName: String, startDate: Date) {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logInfo("Live Activities are disabled — skipping flight activity", category: .ui)
            return
        }

        // Defensive: never leak a previous activity (e.g. stale state) —
        // including orphans from an earlier process this instance never
        // tracked (crash / force-quit while an activity was live).
        end()
        endAllOrphans()

        self.startDate = startDate
        let attributes = FlightActivityAttributes(wingName: wingName, flightType: flightType)
        let state = FlightActivityAttributes.ContentState(
            elapsedSeconds: 0,
            altitude: nil,
            verticalSpeed: nil,
            spotName: spotName,
            startDate: startDate
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: startDate.addingTimeInterval(Self.staleInterval))
            )
            lastPushDate = Date()
            lastSpotName = spotName
            logInfo("Flight Live Activity started (\(wingName), \(spotName))", category: .ui)
        } catch {
            logError("Failed to start flight Live Activity: \(error.localizedDescription)", category: .ui)
        }
        #endif
    }

    /// Pushes fresh in-flight data. Called from the 1 s timer tick; the
    /// throttle keeps actual pushes ≥15 s apart unless the spot changed.
    func update(elapsedSeconds: Int, altitude: Double?, verticalSpeed: Double?, spotName: String) {
        #if canImport(ActivityKit)
        guard let activity else { return }

        let spotChanged = spotName != lastSpotName
        guard spotChanged || Date().timeIntervalSince(lastPushDate) >= Self.minimumPushInterval else {
            return
        }

        lastPushDate = Date()
        lastSpotName = spotName

        let state = FlightActivityAttributes.ContentState(
            elapsedSeconds: elapsedSeconds,
            altitude: altitude,
            verticalSpeed: verticalSpeed,
            spotName: spotName,
            startDate: startDate
        )

        let staleDate = startDate.addingTimeInterval(Self.staleInterval)
        Task {
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
        }
        #endif
    }

    /// Ends and immediately dismisses the Live Activity (flight stopped or
    /// cancelled). Safe to call when no activity is running.
    func end() {
        #if canImport(ActivityKit)
        guard let activity else { return }
        self.activity = nil
        lastSpotName = ""
        lastPushDate = .distantPast

        Task {
            await activity.end(activity.content, dismissalPolicy: .immediate)
        }
        logInfo("Flight Live Activity ended", category: .ui)
        #endif
    }

    /// Ends EVERY Live Activity of the flight attributes type, including
    /// orphans this instance never tracked (left behind by a crash or
    /// force-quit mid-flight). Called once at app startup — no real flight
    /// can be running before the UI is up — and defensively from start().
    /// Fail-soft and free when there is nothing to clean.
    func endAllOrphans() {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let orphans = Activity<FlightActivityAttributes>.activities
        guard !orphans.isEmpty else { return }

        Task {
            for orphan in orphans {
                await orphan.end(orphan.content, dismissalPolicy: .immediate)
            }
            logInfo("Ended \(orphans.count) orphaned flight Live Activity(ies)", category: .ui)
        }
        #endif
    }
}
