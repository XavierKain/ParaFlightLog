//
//  LiveActivityController.swift
//  SoarX
//
//  Pilote la Live Activity « vol en cours » (écran verrouillé + Dynamic Island).
//  No-op silencieux si les Live Activities sont désactivées par l'utilisateur.
//  Target: iOS only
//

import Foundation
import ActivityKit

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private init() {}

    private var activity: Activity<FlightActivityAttributes>?

    /// Démarre la Live Activity au décollage.
    func start(wingName: String, flightType: String?, startDate: Date, spotName: String?) {
        // Respecte le réglage système (Réglages > Face ID/Activités en direct)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Une seule activité à la fois
        if activity != nil { end() }

        let attributes = FlightActivityAttributes(wingName: wingName, flightType: flightType)
        let state = FlightActivityAttributes.ContentState(
            startDate: startDate, altitude: nil, verticalSpeed: nil, spotName: spotName
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            logInfo("Live Activity started", category: .flight)
        } catch {
            logError("Live Activity start failed: \(error.localizedDescription)", category: .flight)
        }
    }

    /// Met à jour les données en vol (altitude, Vz, spot).
    func update(startDate: Date, altitude: Double?, verticalSpeed: Double?, spotName: String?) {
        guard let activity else { return }
        let state = FlightActivityAttributes.ContentState(
            startDate: startDate, altitude: altitude, verticalSpeed: verticalSpeed, spotName: spotName
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// Termine la Live Activity à l'atterrissage.
    func end() {
        guard let activity else { return }
        let final = activity
        self.activity = nil
        Task { await final.end(nil, dismissalPolicy: .immediate) }
        logInfo("Live Activity ended", category: .flight)
    }

    var isActive: Bool { activity != nil }
}
