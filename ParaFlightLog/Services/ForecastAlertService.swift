//
//  ForecastAlertService.swift
//  ParaFlightLog
//
//  Smart notification defaults (client-side, no server):
//
//  1. SpotAutoFollowService — auto-follows the community spots a pilot actually
//     flies, so condition-report pushes reach them without hunting for a bell.
//     Additions-only and idempotent: every flown spot is handled exactly once
//     (a persisted key set), so a later manual unsubscribe always sticks.
//
//  2. ForecastAlertService — schedules a LOCAL notification (no backend) for
//     tomorrow morning when a followed spot's forecast looks flyable, using the
//     learned window via WeatherService.flyabilityV2.
//
//  Both are best-effort and fail-soft, mirroring WeatherService/PushService:
//  signed out, notifications denied, or an offline server must never affect the
//  app. English-only strings.
//  Target: iOS only
//

import Foundation
import UserNotifications

// MARK: - Auto-follow flown spots

@Observable @MainActor
final class SpotAutoFollowService {
    static let shared = SpotAutoFollowService()
    private init() {}

    /// Master toggle (default ON): gate auto-following the spots I fly. Read as
    /// "unset means enabled" (the `object(forKey:)` pattern), matching
    /// WeatherService.autoSnapshotEnabled.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Local UserDefaults keys (Constants.swift is owned elsewhere).
    nonisolated static let enabledKey = "autoFollowFlownSpots"
    private static let handledKeysKey = "autoFollowedSpotKeys"

    private var isReconciling = false

    /// Subscribes to the community spots the pilot flies that haven't been
    /// auto-handled yet. Additions-only: a flown spot is processed exactly once
    /// (recorded in a persisted set), so a later manual unsubscribe is never
    /// re-added. No-op when signed out or the toggle is off.
    func reconcile(dataController: DataController) async {
        guard !isReconciling else { return }
        guard Self.isEnabled else { return }
        guard AuthService.shared.state.isSignedIn else { return }
        isReconciling = true
        defer { isReconciling = false }

        // Flown spots (≥1 flight) with a resolvable community key + name.
        var flown: [(key: String, name: String)] = []
        for spot in dataController.fetchSpots() {
            guard !(spot.flights?.isEmpty ?? true) else { continue }
            guard let key = spot.communitySpotKey
                    ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude)
            else { continue }
            flown.append((key, spot.name))
        }
        guard !flown.isEmpty else { return }

        var handled = Self.loadHandledKeys()
        var added = 0
        for spot in flown where !handled.contains(spot.key) {
            // Mark handled up front (regardless of outcome) so this spot is
            // never auto-touched again — that's what makes unsubscribes stick.
            handled.insert(spot.key)

            // Leave anything the pilot already follows (manual or a prior run)
            // exactly as-is.
            if await ConditionReportService.shared.isSubscribed(spotKey: spot.key) { continue }

            do {
                try await ConditionReportService.shared.subscribe(spotKey: spot.key, spotName: spot.name)
                added += 1
            } catch {
                // Roll back the marker so a transient failure retries next launch.
                handled.remove(spot.key)
                logDebug("Auto-follow skipped \(spot.key): \(error.localizedDescription)", category: .community)
            }
        }
        Self.saveHandledKeys(handled)
        if added > 0 {
            logInfo("Auto-followed \(added) flown spot(s)", category: .community)
        }
    }

    private static func loadHandledKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: handledKeysKey) ?? [])
    }

    private static func saveHandledKeys(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys), forKey: handledKeysKey)
    }
}

// MARK: - Forecast alerts

@Observable @MainActor
final class ForecastAlertService {
    static let shared = ForecastAlertService()
    private init() {}

    /// Master toggle (default OFF): schedule local "flyable tomorrow" alerts.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Local UserDefaults key (Constants.swift is owned elsewhere).
    nonisolated static let enabledKey = "forecastAlertsEnabled"

    /// Notification identifier prefix so every run can clear its own alerts.
    private static let identifierPrefix = "forecast-"
    /// Cap on spots checked per run (bounds Open-Meteo calls + notifications).
    private static let maxSpots = 10
    /// Small pause between forecast fetches (most hit the 15-min cache anyway).
    private static let pacing: TimeInterval = 0.25

    private var isRefreshing = false

    /// Reschedules the forecast alerts. Always clears the previous run's alerts
    /// first; when enabled, checks up to ~10 followed spots and schedules a
    /// tomorrow-08:00 local notification for each whose forecast looks `.good`.
    /// No-op (beyond the clear) when disabled or signed out. Never throws.
    func refreshAlerts(dataController: DataController) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Cancel previously scheduled forecast notifications before rescheduling.
        await cancelScheduledForecastAlerts()

        guard Self.isEnabled else { return }
        // Local notifications still need UNUserNotificationCenter authorization;
        // reuse the push permission entry point (prompts only when undetermined).
        await PushService.shared.ensureAuthorized()
        guard AuthService.shared.state.isSignedIn else { return }

        // Followed spots with coordinates (community key resolvable), capped.
        var candidates: [(spot: Spot, key: String)] = []
        for spot in dataController.fetchSpots() {
            guard spot.latitude != nil, spot.longitude != nil else { continue }
            guard let key = spot.communitySpotKey
                    ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude)
            else { continue }
            guard await ConditionReportService.shared.isSubscribed(spotKey: key) else { continue }
            candidates.append((spot, key))
            if candidates.count >= Self.maxSpots { break }
        }
        guard !candidates.isEmpty else { return }

        var scheduled = 0
        for (index, candidate) in candidates.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: UInt64(Self.pacing * 1_000_000_000))
            }
            guard let latitude = candidate.spot.latitude,
                  let longitude = candidate.spot.longitude else { continue }

            do {
                let weather = try await WeatherService.shared.weather(latitude: latitude, longitude: longitude)
                guard let tomorrow = Self.tomorrowForecast(in: weather.daily) else { continue }

                let flyability = await WeatherService.shared.flyabilityV2(
                    for: candidate.spot,
                    windDirectionDeg: tomorrow.windDirectionDominantDeg,
                    windSpeed: tomorrow.windSpeedMax,
                    windGusts: tomorrow.windGustsMax,
                    dataController: dataController
                )
                guard flyability == .good else { continue }

                scheduleAlert(spotName: candidate.spot.name, spotKey: candidate.key, day: tomorrow)
                scheduled += 1
            } catch {
                logDebug("Forecast alert skipped for \(candidate.key): \(error.localizedDescription)", category: .weather)
            }
        }
        if scheduled > 0 {
            logInfo("Scheduled \(scheduled) forecast alert(s) for tomorrow", category: .weather)
        }
    }

    // MARK: - Scheduling

    /// Schedules ONE local notification for tomorrow at 08:00 local, replacing
    /// any existing alert for the same spot (stable `forecast-<spotKey>` id).
    private func scheduleAlert(spotName: String, spotKey: String, day: DayForecast) {
        let compass = day.windDirectionDominantDeg.map(WeatherService.degreesToCompass) ?? "—"
        let speed = day.windSpeedMax.map { Int($0.rounded()) } ?? 0

        let content = UNMutableNotificationContent()
        content.title = "Flyable tomorrow"
        content.body = "Tomorrow looks flyable at \(spotName) — \(compass) \(speed) km/h"
        content.sound = .default
        content.userInfo = ["spotKey": spotKey]

        // Tomorrow (local) at 08:00, non-repeating.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 8
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + spotKey,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Removes every pending notification this service scheduled.
    private func cancelScheduledForecastAlerts() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// The forecast entry for tomorrow (local calendar day) from a daily array.
    private static func tomorrowForecast(in daily: [DayForecast]) -> DayForecast? {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return nil }
        return daily.first { Calendar.current.isDate($0.date, inSameDayAs: tomorrow) }
    }
}
