//
//  WeatherService.swift
//  ParaFlightLog
//
//  Open-Meteo forecast client for per-spot weather + weather-at-takeoff
//  snapshots (Step B). Pure networking/parsing + compass/flyability helpers;
//  all UI formatting stays in the views.
//
//  Weather data by Open-Meteo (https://open-meteo.com) — free for
//  non-commercial use, no API key required, attribution appreciated.
//  Target: iOS only
//

import Foundation

// MARK: - Public models

/// Current conditions + 48h hourly + 10-day daily forecast for one location.
/// All values use km/h (wind), °C (temperature), mm (precipitation), m
/// (heights, above ground level) and degrees (wind direction = direction the
/// wind comes FROM).
struct SpotWeather {
    // Current conditions (tolerant: any field the API omits stays nil)
    let windSpeed: Double?
    let windGusts: Double?
    let windDirectionDeg: Double?
    let temperature: Double?
    let precipitation: Double?
    let cloudCover: Double?
    let time: Date

    /// Next 48 hours
    let hourly: [HourForecast]
    /// Next 10 days
    let daily: [DayForecast]
}

/// One hourly forecast entry.
struct HourForecast: Identifiable {
    var id: Date { time }
    let time: Date
    let windSpeed: Double?
    let windGusts: Double?
    let windDirectionDeg: Double?
    let precipProbability: Double?
    /// Requested alongside the wind fields so takeoff snapshots can reuse
    /// the exact same endpoint/decoding path.
    let temperature: Double?
    /// Dew point (°C) — only requested so cloud base can be derived; see
    /// `cloudBaseMeters`.
    let dewPoint: Double?
    /// Convective available potential energy, J/kg. High values mean an
    /// unstable, potentially overdeveloping day.
    let cape: Double?
    /// Depth of the mixed layer, m above ground — in practice the thermal
    /// ceiling.
    let boundaryLayerHeight: Double?

    /// Cumulus base, m above ground, from Espy's approximation
    /// (125 m per °C of spread between temperature and dew point).
    ///
    /// Open-Meteo's forecast endpoint ACCEPTS a `cloud_base` hourly variable
    /// and answers 200 — with a unit of "undefined" and every value null. So
    /// it is derived here rather than requested: a variable that always returns
    /// nothing is worse than no variable, because it looks like it works.
    var cloudBaseMeters: Double? {
        guard let temperature, let dewPoint else { return nil }
        let spread = temperature - dewPoint
        guard spread > 0 else { return nil }
        return 125 * spread
    }
}

/// One daily forecast entry.
struct DayForecast: Identifiable {
    var id: Date { date }
    let date: Date
    let windSpeedMax: Double?
    let windGustsMax: Double?
    let windDirectionDominantDeg: Double?
    let precipProbabilityMax: Double?
    let tempMax: Double?
    let sunrise: Date?
    let sunset: Date?
}

/// The thermal picture for one day, at its best hour.
///
/// Deliberately narrow. These variables matter to mountain thermal flying and
/// are close to meaningless for coastal ridge soaring, which is our primary
/// audience — so they get one compact row on the spot page and nothing on the
/// dashboard, and the row hides itself entirely on days with no thermal to
/// speak of.
struct ThermalOutlook: Equatable {
    /// The hour this outlook describes — the day's deepest mixed layer.
    let time: Date
    /// Thermal ceiling, m above ground.
    let thermalTopMeters: Double
    /// Cumulus base, m above ground. Nil on a blue day: when the condensation
    /// level sits ABOVE the thermal ceiling, thermals never reach it and no
    /// cumulus forms — there is no cloud base to quote.
    let cloudBaseMeters: Double?
    /// CAPE at that hour, J/kg.
    let cape: Double?

    /// No cumulus to mark the thermals.
    var isBlue: Bool { cloudBaseMeters == nil }

    /// Enough instability that the day can overdevelop. 800 J/kg is the usual
    /// free-flight rule of thumb for "watch the sky", not a hard danger line —
    /// hence "risk", and hence it is never allowed to drive a flyability
    /// verdict on its own.
    var hasOverdevelopmentRisk: Bool { (cape ?? 0) >= 800 }
}

/// Weather at a flight's takeoff time (hourly entry nearest the start date).
struct TakeoffWeather {
    let windSpeed: Double?
    let windGusts: Double?
    let windDirectionDeg: Double?
    let temperature: Double?
}

/// Flyability of given wind conditions against a spot's launch directions.
enum Flyability {
    case good
    case marginal
    case bad
    /// No launch directions configured, or no wind data.
    case unknown
}

enum WeatherError: LocalizedError {
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not build the weather request."
        case .invalidResponse:
            return "The weather service returned an invalid response."
        }
    }
}

// MARK: - Service

@Observable @MainActor
final class WeatherService {
    static let shared = WeatherService()

    /// In-memory forecast cache keyed by coordinate rounded to 3 decimals
    /// (~110 m), 15-minute TTL.
    private struct CacheEntry {
        let weather: SpotWeather
        let fetchedAt: Date
    }
    private var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 15 * 60

    /// The forecast endpoint serves up to 92 past days; older snapshots fall
    /// back to the Open-Meteo ARCHIVE (ERA5) API, which covers decades back
    /// but lags real time by ~5 days — safe here since we only reach for it
    /// beyond 90 days.
    private static let maxSnapshotAge: TimeInterval = 90 * 24 * 3600

    private init() {}

    /// True unless the pilot disabled automatic takeoff snapshots in Settings.
    /// Default TRUE: the key is considered enabled while it has never been set.
    static var autoSnapshotEnabled: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.autoWeatherSnapshot) as? Bool ?? true
    }

    // MARK: - Forecast (spot detail / dashboard)

    /// How many days ahead the spot forecast covers. Ten is what the free
    /// Open-Meteo tier serves usefully and what pilots compare against
    /// elsewhere; beyond it the models are decorative.
    static let forecastDayCount = 10

    /// Current conditions + 48h hourly + 10-day daily forecast, cached 15 min
    /// per rounded coordinate.
    func weather(latitude: Double, longitude: Double, forceRefresh: Bool = false) async throws -> SpotWeather {
        let key = Self.cacheKey(latitude: latitude, longitude: longitude)
        if !forceRefresh,
           let entry = cache[key],
           Date().timeIntervalSince(entry.fetchedAt) < Self.cacheTTL {
            return entry.weather
        }

        let response = try await fetchForecast(latitude: latitude, longitude: longitude, pastDays: 0, forecastDays: Self.forecastDayCount)
        let weather = Self.mapSpotWeather(from: response)
        cache[key] = CacheEntry(weather: weather, fetchedAt: Date())
        return weather
    }

    // MARK: - Takeoff snapshot

    /// Wind/temperature at a given past (or current) instant, returning the
    /// hourly entry nearest to it. Dates within the last 90 days come from the
    /// forecast endpoint's `past_days` window; older dates fall back to the
    /// Open-Meteo archive (ERA5) API so historical/imported flights can still
    /// be back-filled. Never `.tooOld` — the archive covers decades back.
    func takeoffSnapshot(latitude: Double, longitude: Double, at date: Date) async throws -> TakeoffWeather {
        let age = Date().timeIntervalSince(date)

        let response: OpenMeteoResponse
        if age <= Self.maxSnapshotAge {
            // +1 day guards timezone/midnight edges; clamped to the API maximum.
            let pastDays = min(max(Int(age / 86400) + 1, 1), 92)
            response = try await fetchForecast(latitude: latitude, longitude: longitude, pastDays: pastDays, forecastDays: 1)
        } else {
            response = try await fetchArchive(latitude: latitude, longitude: longitude, at: date)
        }

        return try Self.nearestHour(in: response, to: date)
    }

    /// Picks the hourly entry closest to `date` from a decoded Open-Meteo
    /// response (shared by the forecast and archive snapshot paths).
    private static func nearestHour(in response: OpenMeteoResponse, to date: Date) throws -> TakeoffWeather {
        let offsetSeconds = response.utcOffsetSeconds ?? 0
        let hourFormatter = makeFormatter(format: "yyyy-MM-dd'T'HH:mm", offsetSeconds: offsetSeconds)

        guard let hourly = response.hourly, let times = hourly.time, !times.isEmpty else {
            throw WeatherError.invalidResponse
        }

        var bestIndex: Int?
        var bestDelta = Double.greatestFiniteMagnitude
        for (index, timeString) in times.enumerated() {
            guard let time = hourFormatter.date(from: timeString) else { continue }
            let delta = abs(time.timeIntervalSince(date))
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }
        guard let index = bestIndex else {
            throw WeatherError.invalidResponse
        }

        return TakeoffWeather(
            windSpeed: value(hourly.windSpeed10m, at: index),
            windGusts: value(hourly.windGusts10m, at: index),
            windDirectionDeg: value(hourly.windDirection10m, at: index),
            temperature: value(hourly.temperature2m, at: index)
        )
    }

    /// Best-effort takeoff snapshot for an already-persisted flight: fetches
    /// wind/temperature at the flight's start date and fills the four
    /// `takeoff*` fields. Fire-and-forget — respects the auto-snapshot
    /// setting, never throws, never blocks the save path that calls it.
    func captureSnapshot(for flightId: UUID, dataController: DataController) {
        guard Self.autoSnapshotEnabled else { return }

        Task { [weak dataController] in
            guard let dataController,
                  let flight = dataController.findFlight(byId: flightId),
                  flight.takeoffWindSpeed == nil,
                  // The flight's own coordinates, or its spot's as a fallback
                  let latitude = flight.latitude ?? flight.spot?.latitude,
                  let longitude = flight.longitude ?? flight.spot?.longitude else { return }
            let startDate = flight.startDate

            do {
                let snapshot = try await self.takeoffSnapshot(latitude: latitude, longitude: longitude, at: startDate)
                // Re-fetch: the flight may have been deleted while the request
                // ran. Re-check takeoffWindSpeed too — two triggers can race
                // past the initial guard (e.g. geocode + import paths), and
                // the loser must not overwrite the winner's snapshot.
                guard let flight = dataController.findFlight(byId: flightId),
                      flight.takeoffWindSpeed == nil else { return }
                flight.takeoffWindSpeed = snapshot.windSpeed
                flight.takeoffWindGusts = snapshot.windGusts
                flight.takeoffWindDirection = snapshot.windDirectionDeg
                flight.takeoffTemperature = snapshot.temperature
                dataController.saveContext()
                logInfo("Takeoff weather recorded for flight \(flightId)", category: .weather)
            } catch {
                logInfo("Weather snapshot skipped for flight \(flightId): \(error.localizedDescription)", category: .weather)
            }
        }
    }

    // MARK: - Thermal outlook

    /// Below this mixed-layer depth there is no thermal day worth describing,
    /// and the row that shows it hides itself. Our primary audience flies
    /// coastal ridge and sea breeze, where these numbers say nothing useful —
    /// showing "thermals to 120 m" every day would be clutter dressed as data.
    static let minThermalTopMeters: Double = 500

    /// The thermal picture for one local day, taken at its DEEPEST hour rather
    /// than averaged: what a pilot wants to know is how good the best part of
    /// the day gets, not what the mean of a night-time inversion looks like.
    ///
    /// Returns nil when the day has no boundary-layer data or never gets deep
    /// enough to be a thermal day.
    static func thermalOutlook(from hours: [HourForecast], on date: Date, calendar: Calendar = .current) -> ThermalOutlook? {
        let best = hours
            .filter { calendar.isDate($0.time, inSameDayAs: date) }
            .compactMap { hour -> (hour: HourForecast, top: Double)? in
                guard let top = hour.boundaryLayerHeight else { return nil }
                return (hour, top)
            }
            .max { $0.top < $1.top }

        guard let best, best.top >= minThermalTopMeters else { return nil }

        // A condensation level ABOVE the thermal ceiling means thermals never
        // reach it: blue day, no cloud base to quote. Quoting it anyway would
        // send pilots looking for cumulus that cannot form.
        let condensationLevel = best.hour.cloudBaseMeters
        let cloudBase = condensationLevel.flatMap { $0 < best.top ? $0 : nil }

        return ThermalOutlook(
            time: best.hour.time,
            thermalTopMeters: best.top,
            cloudBaseMeters: cloudBase,
            cape: best.hour.cape
        )
    }

    // MARK: - Compass helpers

    /// The 8 compass points a launch can be configured with, clockwise from N.
    static let compassPoints = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    /// 8-point compass label for a bearing in degrees (e.g. 200 -> "SW").
    static func degreesToCompass(_ degrees: Double) -> String {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((normalized + 22.5) / 45) % 8
        return compassPoints[index]
    }

    /// Bearing in degrees for an 8-point compass label ("SW" -> 225).
    /// Unknown labels map to 0 (N).
    static func compassToDegrees(_ point: String) -> Double {
        Double(compassPoints.firstIndex(of: point) ?? 0) * 45
    }

    // MARK: - Flyability

    /// Classic speed/gust thresholds, in km/h: the value each severity step
    /// crosses. A verdict quotes the limit it actually broke — saying "40 km/h,
    /// over the 25 km/h limit" when the red was triggered at 35 would be
    /// technically true and practically misleading.
    static let goodSpeedLimit: Double = 25
    static let marginalSpeedLimit: Double = 35
    static let goodGustLimit: Double = 40
    static let marginalGustLimit: Double = 55

    /// Rates wind conditions against a spot's configured launch directions.
    /// - direction OK: within ±45° of any selected compass point's bearing
    /// - direction borderline: within ±67.5°
    /// - good: direction OK, wind ≤ 25 km/h and gusts ≤ 40 km/h
    /// - marginal: direction OK with wind ≤ 35 / gusts ≤ 55, or borderline
    ///   direction with good speeds
    /// - unknown: no launch directions configured, or no wind data
    static func flyability(windDirectionDeg: Double?, windSpeed: Double?, windGusts: Double?, spotDirections: [String]) -> Flyability {
        verdict(windDirectionDeg: windDirectionDeg, windSpeed: windSpeed,
                windGusts: windGusts, spotDirections: spotDirections).rating
    }

    /// The same rating as `flyability`, plus the reason for it: which single
    /// factor is limiting, and that the limits are the pilot's own configured
    /// directions rather than anything learned. The rating is derived from this
    /// method, so the two can never disagree.
    static func verdict(windDirectionDeg: Double?, windSpeed: Double?, windGusts: Double?, spotDirections: [String]) -> FlyabilityVerdict {
        guard !spotDirections.isEmpty else { return .unknown }
        guard let direction = windDirectionDeg, let speed = windSpeed else {
            return .noWindData(basis: .configured)
        }
        let gusts = windGusts ?? speed

        let delta = spotDirections
            .map { angularDistance(direction, compassToDegrees($0)) }
            .min() ?? 180
        let windPoint = degreesToCompass(direction)

        // Keep unrecognised labels visible rather than silently dropping them:
        // the rating already tolerates them (they read as N), so the caption
        // must not claim a cleaner configuration than the spot really has.
        let ordered = FlyabilityVerdict.orderedPoints(spotDirections)
        let worksWith = ordered.isEmpty ? spotDirections : ordered

        let directionSeverity: FlyabilityVerdict.Severity = delta <= 45 ? .ok : (delta <= 67.5 ? .marginal : .breaking)
        let speedSeverity: FlyabilityVerdict.Severity = speed <= goodSpeedLimit ? .ok : (speed <= marginalSpeedLimit ? .marginal : .breaking)
        let gustSeverity: FlyabilityVerdict.Severity = gusts <= goodGustLimit ? .ok : (gusts <= marginalGustLimit ? .marginal : .breaking)

        return FlyabilityVerdict.make(
            direction: .init(directionSeverity, .direction(from: windPoint, worksWith: worksWith)),
            speed: .init(speedSeverity, .windTooStrong(
                kmh: speed,
                band: nil,
                defaultLimit: speedSeverity == .breaking ? marginalSpeedLimit : goodSpeedLimit
            )),
            gusts: .init(gustSeverity, .gusts(
                kmh: gusts,
                limit: gustSeverity == .breaking ? marginalGustLimit : goodGustLimit,
                isLearned: false
            )),
            basis: .configured,
            windFrom: windPoint,
            windSpeed: speed
        )
    }

    /// Learned-flyability entry point (Phase 2): obtains the spot's learned
    /// flying window from `SpotIntelligenceService` and rates the given wind
    /// against it, so a UI caller switches from the static `flyability` to the
    /// learned rating with a single call. Falls back internally to the classic
    /// thresholds when the spot has no learned/seeded/configured window.
    /// The static `flyability` above is intentionally left untouched.
    func flyabilityV2(
        for spot: Spot,
        windDirectionDeg: Double?,
        windSpeed: Double?,
        windGusts: Double?,
        dataController: DataController
    ) async -> Flyability {
        await verdictV2(
            for: spot,
            windDirectionDeg: windDirectionDeg,
            windSpeed: windSpeed,
            windGusts: windGusts,
            dataController: dataController
        ).rating
    }

    /// Same as `flyabilityV2` but keeping the reason: the limiting factor and
    /// whether the limits are learned, seeded or configured. This is the entry
    /// point every UI that shows a badge should use — the badge stays a colour,
    /// but the caption underneath can finally say why.
    func verdictV2(
        for spot: Spot,
        windDirectionDeg: Double?,
        windSpeed: Double?,
        windGusts: Double?,
        dataController: DataController
    ) async -> FlyabilityVerdict {
        let window = await SpotIntelligenceService.shared.learnedWindow(for: spot, dataController: dataController)
        return SpotIntelligenceService.shared.verdictV2(
            spot: spot,
            windDirectionDeg: windDirectionDeg,
            windSpeed: windSpeed,
            windGusts: windGusts,
            window: window
        )
    }

    /// Smallest angle between two bearings (0...180).
    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }

    // MARK: - Networking

    /// GET https://api.open-meteo.com/v1/forecast with the fixed variable set
    /// used by both the forecast and the takeoff-snapshot paths.
    private func fetchForecast(latitude: Double, longitude: Double, pastDays: Int, forecastDays: Int) async throws -> OpenMeteoResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m,temperature_2m,precipitation,cloud_cover"),
            // dew_point_2m/cape/boundary_layer_height feed `ThermalOutlook`.
            // NOT `cloud_base`: the endpoint accepts it and returns 200 with
            // every value null, so cloud base is derived from the spread.
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m,precipitation_probability,temperature_2m,dew_point_2m,cape,boundary_layer_height"),
            URLQueryItem(name: "daily", value: "wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant,precipitation_probability_max,temperature_2m_max,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
            URLQueryItem(name: "wind_speed_unit", value: "kmh")
        ]
        if pastDays > 0 {
            queryItems.append(URLQueryItem(name: "past_days", value: String(pastDays)))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw WeatherError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = WeatherConstants.networkTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WeatherError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        } catch {
            logWarning("Open-Meteo decoding failed: \(error.localizedDescription)", category: .weather)
            throw WeatherError.invalidResponse
        }
    }

    /// GET https://archive-api.open-meteo.com/v1/archive for a single past
    /// instant older than the forecast window. Requests a ±1-day date range
    /// (the spot's timezone is resolved server-side via `timezone=auto`, so a
    /// wide window guarantees the nearest-hour search has the target covered)
    /// and decodes into the SAME `OpenMeteoResponse` shape as the forecast —
    /// the archive payload carries the identical hourly parallel-array layout.
    private func fetchArchive(latitude: Double, longitude: Double, at date: Date) async throws -> OpenMeteoResponse {
        // Date-only bounds in UTC; the ±1-day pad absorbs the unknown local
        // offset so the target hour is always inside the returned range.
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let startDate = dayFormatter.string(from: date.addingTimeInterval(-86400))
        let endDate = dayFormatter.string(from: date.addingTimeInterval(86400))

        var components = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m,temperature_2m"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh")
        ]

        guard let url = components?.url else {
            throw WeatherError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = WeatherConstants.networkTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WeatherError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        } catch {
            logWarning("Open-Meteo archive decoding failed: \(error.localizedDescription)", category: .weather)
            throw WeatherError.invalidResponse
        }
    }

    // MARK: - Mapping (parallel arrays -> structs)

    private static func mapSpotWeather(from response: OpenMeteoResponse) -> SpotWeather {
        let offsetSeconds = response.utcOffsetSeconds ?? 0
        // timezone=auto returns local ISO times WITHOUT seconds ("2026-07-06T14:00")
        let hourFormatter = makeFormatter(format: "yyyy-MM-dd'T'HH:mm", offsetSeconds: offsetSeconds)
        let dayFormatter = makeFormatter(format: "yyyy-MM-dd", offsetSeconds: offsetSeconds)

        // Hourly: next 48 hours (skip already-elapsed hours)
        var hourly: [HourForecast] = []
        if let h = response.hourly, let times = h.time {
            let cutoff = Date().addingTimeInterval(-3600)
            for (index, timeString) in times.enumerated() {
                guard let time = hourFormatter.date(from: timeString), time >= cutoff else { continue }
                hourly.append(HourForecast(
                    time: time,
                    windSpeed: value(h.windSpeed10m, at: index),
                    windGusts: value(h.windGusts10m, at: index),
                    windDirectionDeg: value(h.windDirection10m, at: index),
                    precipProbability: value(h.precipitationProbability, at: index),
                    temperature: value(h.temperature2m, at: index),
                    dewPoint: value(h.dewPoint2m, at: index),
                    cape: value(h.cape, at: index),
                    boundaryLayerHeight: value(h.boundaryLayerHeight, at: index)
                ))
                if hourly.count >= 48 { break }
            }
        }

        // Daily: up to 10 days
        var daily: [DayForecast] = []
        if let d = response.daily, let times = d.time {
            for (index, dayString) in times.enumerated() {
                guard let date = dayFormatter.date(from: dayString) else { continue }
                daily.append(DayForecast(
                    date: date,
                    windSpeedMax: value(d.windSpeed10mMax, at: index),
                    windGustsMax: value(d.windGusts10mMax, at: index),
                    windDirectionDominantDeg: value(d.windDirection10mDominant, at: index),
                    precipProbabilityMax: value(d.precipitationProbabilityMax, at: index),
                    tempMax: value(d.temperature2mMax, at: index),
                    sunrise: stringValue(d.sunrise, at: index).flatMap { hourFormatter.date(from: $0) },
                    sunset: stringValue(d.sunset, at: index).flatMap { hourFormatter.date(from: $0) }
                ))
                if daily.count >= forecastDayCount { break }
            }
        }

        let current = response.current
        let currentTime = current?.time.flatMap { hourFormatter.date(from: $0) } ?? Date()

        return SpotWeather(
            windSpeed: current?.windSpeed10m,
            windGusts: current?.windGusts10m,
            windDirectionDeg: current?.windDirection10m,
            temperature: current?.temperature2m,
            precipitation: current?.precipitation,
            cloudCover: current?.cloudCover,
            time: currentTime,
            hourly: hourly,
            daily: daily
        )
    }

    /// Safe parallel-array access: Open-Meteo pads shorter arrays with nulls,
    /// but a missing or short array must never crash the mapping.
    private static func value(_ array: [Double?]?, at index: Int) -> Double? {
        guard let array, index < array.count else { return nil }
        return array[index]
    }

    /// Same tolerant access for string arrays (sunrise/sunset ISO times).
    private static func stringValue(_ array: [String?]?, at index: Int) -> String? {
        guard let array, index < array.count else { return nil }
        return array[index]
    }

    /// Formatter in the response's local timezone (utc_offset_seconds).
    private static func makeFormatter(format: String, offsetSeconds: Int) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? .current
        formatter.dateFormat = format
        return formatter
    }

    private static func cacheKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.3f,%.3f", latitude, longitude)
    }
}

// MARK: - Open-Meteo raw response (parallel-array JSON)

/// Tolerant decode of the Open-Meteo forecast payload: every field is
/// optional so a partial response never fails the whole request.
/// Explicit snake_case CodingKeys (no strategy) for deterministic decoding.
private nonisolated struct OpenMeteoResponse: Decodable {
    let utcOffsetSeconds: Int?
    let current: Current?
    let hourly: Hourly?
    let daily: Daily?

    enum CodingKeys: String, CodingKey {
        case utcOffsetSeconds = "utc_offset_seconds"
        case current, hourly, daily
    }

    struct Current: Decodable {
        let time: String?
        let windSpeed10m: Double?
        let windGusts10m: Double?
        let windDirection10m: Double?
        let temperature2m: Double?
        let precipitation: Double?
        let cloudCover: Double?

        enum CodingKeys: String, CodingKey {
            case time
            case windSpeed10m = "wind_speed_10m"
            case windGusts10m = "wind_gusts_10m"
            case windDirection10m = "wind_direction_10m"
            case temperature2m = "temperature_2m"
            case precipitation
            case cloudCover = "cloud_cover"
        }
    }

    struct Hourly: Decodable {
        let time: [String]?
        let windSpeed10m: [Double?]?
        let windGusts10m: [Double?]?
        let windDirection10m: [Double?]?
        let precipitationProbability: [Double?]?
        let temperature2m: [Double?]?
        let dewPoint2m: [Double?]?
        let cape: [Double?]?
        let boundaryLayerHeight: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case windSpeed10m = "wind_speed_10m"
            case windGusts10m = "wind_gusts_10m"
            case windDirection10m = "wind_direction_10m"
            case precipitationProbability = "precipitation_probability"
            case temperature2m = "temperature_2m"
            case dewPoint2m = "dew_point_2m"
            case cape
            case boundaryLayerHeight = "boundary_layer_height"
        }
    }

    struct Daily: Decodable {
        let time: [String]?
        let windSpeed10mMax: [Double?]?
        let windGusts10mMax: [Double?]?
        let windDirection10mDominant: [Double?]?
        let precipitationProbabilityMax: [Double?]?
        let temperature2mMax: [Double?]?
        let sunrise: [String?]?
        let sunset: [String?]?

        enum CodingKeys: String, CodingKey {
            case time
            case windSpeed10mMax = "wind_speed_10m_max"
            case windGusts10mMax = "wind_gusts_10m_max"
            case windDirection10mDominant = "wind_direction_10m_dominant"
            case precipitationProbabilityMax = "precipitation_probability_max"
            case temperature2mMax = "temperature_2m_max"
            case sunrise, sunset
        }
    }
}
