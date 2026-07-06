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

        // Defensive: never leak a previous activity (e.g. stale state)
        end()

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
                content: ActivityContent(state: state, staleDate: nil)
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

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
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
}
