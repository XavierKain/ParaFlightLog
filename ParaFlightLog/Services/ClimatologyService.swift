//
//  ClimatologyService.swift
//  ParaFlightLog
//
//  Per-spot monthly wind/temperature climatology from the Open-Meteo ERA5
//  archive (free, no key): "when does this spot fly?" for trip planning.
//  Fetches ~3 years of daily reanalysis once per spot, aggregates it into
//  12 monthly profiles (wind-band day counts, per-sector flyable-day counts,
//  average day/night temperature) and caches the result on disk for 30 days.
//
//  The flyable share is computed on demand from the cached aggregates and
//  the spot's launch directions, so editing the directions never requires a
//  re-fetch. Everything fails soft — a network/decode failure just leaves
//  the climatology section hidden.
//  Target: iOS only
//

import Foundation

// MARK: - Models

/// One month's aggregated climatology (all years combined).
/// `nonisolated` + Sendable: decoded from the disk cache and safe to hand
/// across concurrency domains (project default isolation is MainActor).
nonisolated struct MonthClimatology: Codable, Identifiable, Sendable {
    /// 1 = January … 12 = December.
    let month: Int
    /// Days observed for this month across all fetched years.
    let dayCount: Int
    /// Day counts per wind band of the DAILY MAX wind (km/h):
    /// [<10, 10–20, 20–30, 30–40, ≥40] — always 5 entries.
    let bandDayCounts: [Int]
    /// Per 8-point compass sector (N..NW clockwise): days whose dominant wind
    /// direction fell in that sector AND whose daily max wind was in the
    /// broadly-flyable 10–35 km/h range.
    let flyableCandidatesBySector: [Int]
    /// Mean daily max / min temperature (°C).
    let tempMaxAvg: Double?
    let tempMinAvg: Double?

    var id: Int { month }

    /// The 5 wind bands' day counts as shares of the month (sum ≤ 1).
    var bandShares: [Double] {
        guard dayCount > 0 else { return Array(repeating: 0, count: 5) }
        return bandDayCounts.map { Double($0) / Double(dayCount) }
    }

    /// Share of days that look flyable for a spot launching from `directions`
    /// (8-point labels): dominant direction in a selected sector or one of
    /// its neighbours (≈ ±67.5°), with max wind 10–35 km/h. Nil when the
    /// spot has no directions configured.
    /// 8-point compass order matching `flyableCandidatesBySector` (same
    /// clockwise-from-N convention as WeatherService.compassPoints; kept
    /// local so this nonisolated type doesn't touch the MainActor service).
    private static let compassPoints = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    func flyableShare(directions: [String]) -> Double? {
        guard dayCount > 0, !directions.isEmpty else { return nil }
        let selected = Set(directions.compactMap { Self.compassPoints.firstIndex(of: $0) })
        guard !selected.isEmpty else { return nil }

        var days = 0
        for (sector, count) in flyableCandidatesBySector.enumerated() {
            let neighbours = [sector, (sector + 1) % 8, (sector + 7) % 8]
            if neighbours.contains(where: selected.contains) {
                days += count
            }
        }
        return Double(days) / Double(dayCount)
    }
}

// MARK: - Service

@Observable @MainActor
final class ClimatologyService {
    static let shared = ClimatologyService()

    /// Years of ERA5 history to aggregate (payload ~1100 daily rows).
    private static let yearsBack = 3
    /// ERA5 lags real time by ~5 days; stay clear of the gap.
    private static let archiveLag: TimeInterval = 7 * 24 * 3600
    /// Disk cache lifetime — climatology moves on geological timescales.
    private static let cacheTTL: TimeInterval = 30 * 24 * 3600

    /// In-memory cache per rounded coordinate (backed by the disk cache).
    private var memoryCache: [String: [MonthClimatology]] = [:]
    /// Coordinates with a fetch in flight, so a re-rendered section doesn't
    /// fire a duplicate ~1100-row archive request.
    private var inFlight: Set<String> = []

    private init() {}

    /// Monthly climatology for a location — memory, then disk, then one
    /// ERA5 archive fetch. Returns nil while another fetch for the same
    /// location is already running (the caller just retries via its cache).
    func climatology(latitude: Double, longitude: Double) async throws -> [MonthClimatology]? {
        let key = Self.cacheKey(latitude: latitude, longitude: longitude)
        if let cached = memoryCache[key] {
            return cached
        }
        if let disk = Self.loadFromDisk(key: key) {
            memoryCache[key] = disk
            return disk
        }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let months = try await fetchAndAggregate(latitude: latitude, longitude: longitude)
        memoryCache[key] = months
        Self.saveToDisk(months, key: key)
        return months
    }

    // MARK: - Fetch + aggregate

    private func fetchAndAggregate(latitude: Double, longitude: Double) async throws -> [MonthClimatology] {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let end = Date().addingTimeInterval(-Self.archiveLag)
        let start = Calendar.current.date(byAdding: .year, value: -Self.yearsBack, to: end) ?? end

        var components = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "start_date", value: dayFormatter.string(from: start)),
            URLQueryItem(name: "end_date", value: dayFormatter.string(from: end)),
            URLQueryItem(name: "daily", value: "wind_speed_10m_max,wind_direction_10m_dominant,temperature_2m_max,temperature_2m_min"),
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
        let decoded: ArchiveResponse
        do {
            decoded = try JSONDecoder().decode(ArchiveResponse.self, from: data)
        } catch {
            logWarning("Climatology decoding failed: \(error.localizedDescription)", category: .weather)
            throw WeatherError.invalidResponse
        }

        guard let daily = decoded.daily, let times = daily.time, !times.isEmpty else {
            throw WeatherError.invalidResponse
        }

        // Aggregation accumulators, index 0 = January.
        var dayCount = Array(repeating: 0, count: 12)
        var bands = Array(repeating: Array(repeating: 0, count: 5), count: 12)
        var sectors = Array(repeating: Array(repeating: 0, count: 8), count: 12)
        var tempMaxSum = Array(repeating: 0.0, count: 12)
        var tempMaxN = Array(repeating: 0, count: 12)
        var tempMinSum = Array(repeating: 0.0, count: 12)
        var tempMinN = Array(repeating: 0, count: 12)

        for (index, dayString) in times.enumerated() {
            // "yyyy-MM-dd" — the month is characters 5..6; string parsing
            // avoids 1100 DateFormatter round trips.
            guard dayString.count >= 7,
                  let month = Int(dayString.dropFirst(5).prefix(2)),
                  (1...12).contains(month) else { continue }
            let m = month - 1

            guard let wind = Self.value(daily.windSpeed10mMax, at: index) else { continue }
            dayCount[m] += 1

            let band: Int
            switch wind {
            case ..<10: band = 0
            case ..<20: band = 1
            case ..<30: band = 2
            case ..<40: band = 3
            default: band = 4
            }
            bands[m][band] += 1

            if (10...35).contains(wind),
               let direction = Self.value(daily.windDirection10mDominant, at: index) {
                let normalized = (direction.truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                let sector = Int((normalized + 22.5) / 45) % 8
                sectors[m][sector] += 1
            }

            if let tempMax = Self.value(daily.temperature2mMax, at: index) {
                tempMaxSum[m] += tempMax
                tempMaxN[m] += 1
            }
            if let tempMin = Self.value(daily.temperature2mMin, at: index) {
                tempMinSum[m] += tempMin
                tempMinN[m] += 1
            }
        }

        let months = (0..<12).map { m in
            MonthClimatology(
                month: m + 1,
                dayCount: dayCount[m],
                bandDayCounts: bands[m],
                flyableCandidatesBySector: sectors[m],
                tempMaxAvg: tempMaxN[m] > 0 ? tempMaxSum[m] / Double(tempMaxN[m]) : nil,
                tempMinAvg: tempMinN[m] > 0 ? tempMinSum[m] / Double(tempMinN[m]) : nil
            )
        }
        logInfo("Climatology aggregated (\(times.count) days)", category: .weather)
        return months
    }

    // MARK: - Disk cache

    private static func cacheKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f_%.2f", latitude, longitude)
    }

    private static func cacheURL(key: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("climatology-\(key).json")
    }

    private nonisolated struct DiskEnvelope: Codable {
        let fetchedAt: Date
        let months: [MonthClimatology]
    }

    private static func loadFromDisk(key: String) -> [MonthClimatology]? {
        guard let url = cacheURL(key: key),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(DiskEnvelope.self, from: data),
              Date().timeIntervalSince(envelope.fetchedAt) < cacheTTL else {
            return nil
        }
        return envelope.months
    }

    private static func saveToDisk(_ months: [MonthClimatology], key: String) {
        guard let url = cacheURL(key: key),
              let data = try? JSONEncoder().encode(DiskEnvelope(fetchedAt: Date(), months: months)) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func value(_ array: [Double?]?, at index: Int) -> Double? {
        guard let array, index < array.count else { return nil }
        return array[index]
    }
}

// MARK: - Archive raw response (daily parallel arrays)

private nonisolated struct ArchiveResponse: Decodable {
    let daily: Daily?

    struct Daily: Decodable {
        let time: [String]?
        let windSpeed10mMax: [Double?]?
        let windDirection10mDominant: [Double?]?
        let temperature2mMax: [Double?]?
        let temperature2mMin: [Double?]?

        enum CodingKeys: String, CodingKey {
            case time
            case windSpeed10mMax = "wind_speed_10m_max"
            case windDirection10mDominant = "wind_direction_10m_dominant"
            case temperature2mMax = "temperature_2m_max"
            case temperature2mMin = "temperature_2m_min"
        }
    }
}
