//
//  WeatherBackfillService.swift
//  ParaFlightLog
//
//  Historical takeoff-weather backfill. Learned flyability
//  (SpotIntelligenceService) needs each flight's `takeoffWindSpeed/Direction`,
//  but those are only captured at save-time since the weather feature shipped —
//  imported and pre-feature flights carry coordinates but NO wind, so the
//  learned window renders empty. This service walks those flights and fills the
//  four `takeoff*` fields from Open-Meteo (forecast window + archive fallback,
//  see WeatherService.takeoffSnapshot).
//
//  Best-effort and Open-Meteo-friendly: paced ~600ms between calls, saved in
//  small batches, cancellable, skip-and-continue on per-flight errors, and a
//  UserDefaults flag once a full pass completes so app launch only auto-runs it
//  once. Mirrors the fail-soft style of WeatherService/CommunityService.
//  Target: iOS only
//

import Foundation

@Observable @MainActor
final class WeatherBackfillService {
    static let shared = WeatherBackfillService()
    private init() {}

    // MARK: - Published progress (observed by the Settings row)

    /// True while a pass is running.
    private(set) var isRunning = false
    /// Flights processed so far in the current/last pass.
    private(set) var progressDone = 0
    /// Candidates in the current/last pass (0 when idle before a run).
    private(set) var progressTotal = 0

    /// True once a full pass finished without cancellation (persisted).
    var hasCompletedPass: Bool {
        UserDefaults.standard.bool(forKey: Self.completedKey)
    }

    // MARK: - Tuning / keys

    /// Delay between Open-Meteo calls — keeps the free endpoint happy.
    private static let pacing: TimeInterval = 0.6
    /// Save the context every N processed flights (bounds data loss on kill).
    private static let saveEvery = 10

    /// Local UserDefaults flag (Constants.swift is owned elsewhere): set once a
    /// full backfill pass completes, so launch auto-run fires only once ever.
    private static let completedKey = "weatherBackfillCompleted"

    /// The pieces needed per flight, snapshotted up front so nothing SwiftData
    /// is held across the network suspension points.
    private struct Candidate {
        let id: UUID
        let latitude: Double
        let longitude: Double
        let date: Date
    }

    // MARK: - Backfill

    /// Fills missing takeoff weather on flights that have coordinates but no
    /// `takeoffWindSpeed`, recent-first (oldest processed last). Paced,
    /// cancellable, skip-and-continue; saves every ~10 flights and marks a full
    /// pass complete on success. Never throws.
    func backfillMissingTakeoffWeather(dataController: DataController) async {
        guard !isRunning else { return }

        // Recent-first (fetchFlights sorts startDate descending). A flight's own
        // coordinates, or its spot's as a fallback — same rule as captureSnapshot.
        let candidates: [Candidate] = dataController.fetchFlights().compactMap { flight in
            guard flight.takeoffWindSpeed == nil,
                  let latitude = flight.latitude ?? flight.spot?.latitude,
                  let longitude = flight.longitude ?? flight.spot?.longitude else { return nil }
            return Candidate(id: flight.id, latitude: latitude, longitude: longitude, date: flight.startDate)
        }

        guard !candidates.isEmpty else {
            // Nothing to do — still record that a pass has effectively completed.
            markCompleted()
            return
        }

        isRunning = true
        progressTotal = candidates.count
        progressDone = 0
        defer {
            isRunning = false
            progressTotal = 0
        }

        logInfo("Weather backfill started for \(candidates.count) flights", category: .weather)

        var sinceLastSave = 0
        var filled = 0
        for candidate in candidates {
            if Task.isCancelled { break }

            // Pace between network calls (skip the wait before the first).
            if progressDone > 0 {
                try? await Task.sleep(nanoseconds: UInt64(Self.pacing * 1_000_000_000))
                if Task.isCancelled { break }
            }

            do {
                let snapshot = try await WeatherService.shared.takeoffSnapshot(
                    latitude: candidate.latitude,
                    longitude: candidate.longitude,
                    at: candidate.date
                )
                // Re-fetch: the flight may have been deleted mid-pass, and a
                // concurrent captureSnapshot may have won — never overwrite.
                if let flight = dataController.findFlight(byId: candidate.id),
                   flight.takeoffWindSpeed == nil {
                    flight.takeoffWindSpeed = snapshot.windSpeed
                    flight.takeoffWindGusts = snapshot.windGusts
                    flight.takeoffWindDirection = snapshot.windDirectionDeg
                    flight.takeoffTemperature = snapshot.temperature
                    filled += 1
                    sinceLastSave += 1
                }
            } catch {
                // Skip-and-continue: one bad coordinate/date never stalls the pass.
                logDebug("Weather backfill skipped flight \(candidate.id): \(error.localizedDescription)", category: .weather)
            }

            progressDone += 1
            if sinceLastSave >= Self.saveEvery {
                dataController.saveContext()
                sinceLastSave = 0
            }
        }

        dataController.saveContext()

        if Task.isCancelled {
            logInfo("Weather backfill cancelled at \(progressDone)/\(candidates.count) (\(filled) filled)", category: .weather)
        } else {
            markCompleted()
            logInfo("Weather backfill completed: \(filled) of \(candidates.count) flights filled", category: .weather)
            // SpotIntelligenceService exposes no cache-invalidation API; its
            // 15-minute per-spot TTL self-heals the learned windows shortly
            // after this pass, so no explicit invalidation is needed.
        }
    }

    private func markCompleted() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }
}
