//
//  SpotIntelligenceService.swift
//  ParaFlightLog
//
//  Phase 2 — Learned flyability. Turns real takeoff-wind observations
//  (local flights + community shares) into a per-spot "flying window"
//  (which wind SECTORS the spot works with + a sensible speed range), and
//  rates a forecast against it (`flyabilityV2`).
//
//  Fallback chain when a spot has too little of its own data:
//    1. learned    — ≥ 5 observations (local + community, de-duplicated)
//    2. seeded      — ParaglidingEarth site orientations (0/1/2), cached
//                     aggressively in UserDefaults (PGE is a small community
//                     server — one fetch per spot, 30-day TTL)
//    3. configured  — the spot's manually configured launch directions
//
//  Everything is best-effort: the community fetch and the PGE seed use
//  `try?`, so a missing backend or an offline device simply narrows the
//  window rather than failing. Mirrors WeatherService/CommunityService.
//  Target: iOS only
//

import Foundation

@Observable @MainActor
final class SpotIntelligenceService {
    static let shared = SpotIntelligenceService()
    private init() {}

    // MARK: - Public model

    /// A spot's learned "flying window": which compass sectors it works with,
    /// a plausible wind-speed range, and where the knowledge came from.
    struct LearnedWindow {
        /// Provenance of the window, surfaced to the pilot as a caption.
        enum Source {
            case learned    // real observations (this spot's flights + community)
            case seeded     // ParaglidingEarth site orientations
            case configured // the spot's manually configured launch directions
        }

        /// Compass point ("N"…"NW") → supporting weight. For `.learned` this
        /// is a flight COUNT; for `.seeded` it is the PGE rating (1 or 2);
        /// for `.configured` it is 1 per selected direction.
        var sectors: [String: Int]
        /// 10th–90th percentile of observed wind speed (km/h). Nil for a
        /// seeded/configured window with no observed speeds behind it.
        var speedRange: ClosedRange<Double>?
        /// Number of real observations behind the window (0 for seeded/configured).
        var totalFlights: Int
        var source: Source

        /// Empty windows carry no direction information at all.
        var isEmpty: Bool { sectors.isEmpty }
    }

    // MARK: - Tuning

    /// A window needs at least this many real observations to be `.learned`
    /// outright; below it we prefer a ParaglidingEarth seed.
    private static let minLearnedFlights = 5

    /// In-memory window cache TTL (per spot key), matching WeatherService.
    private static let cacheTTL: TimeInterval = 15 * 60

    /// ParaglidingEarth seed cache TTL — site orientations are static, so we
    /// cache for 30 days to stay gentle on their small community server.
    private static let seedCacheTTL: TimeInterval = 30 * 24 * 3600

    /// Speed-band padding applied around the learned p10–p90 range.
    private static let speedPad = 0.20

    // MARK: - Cache

    private var cache: [String: (window: LearnedWindow, at: Date)] = [:]

    /// One takeoff observation (plain values — safe across suspension points).
    private struct WindSample {
        let dir: Double
        let speed: Double
        let date: Date
    }

    // MARK: - Learned window (spot detail / dashboard)

    /// The learned flying window for a local spot: merges this spot's own
    /// flights (with a takeoff-wind snapshot) with community observations,
    /// then falls back to a ParaglidingEarth seed and finally to the spot's
    /// configured launch directions. Never throws — best-effort.
    func learnedWindow(for spot: Spot, dataController: DataController) async -> LearnedWindow {
        let cacheKey = Self.cacheKey(for: spot)
        let communityKey = spot.communitySpotKey
            ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude)

        // LOCAL observations: this spot's flights that carry a takeoff snapshot.
        // Fetched through the DataController (never a stale relationship).
        let spotId = spot.id
        let localObs: [WindSample] = dataController.fetchFlights().compactMap { flight in
            guard flight.spot?.id == spotId,
                  let dir = flight.takeoffWindDirection,
                  let speed = flight.takeoffWindSpeed else { return nil }
            return WindSample(dir: dir, speed: speed, date: flight.startDate)
        }

        return await computeWindow(
            cacheKey: cacheKey,
            communityKey: communityKey,
            latitude: spot.latitude,
            longitude: spot.longitude,
            localObs: localObs,
            configuredDirections: spot.windDirections,
            allowSeed: true
        )
    }

    /// The learned flying window for a community spot known only by key +
    /// coordinates (Explore map/list). No local flights and no configured
    /// directions, and — to stay gentle on ParaglidingEarth when colouring
    /// many pins at once — NO seed fetch: a spot with no community wind data
    /// simply gets an empty window (→ `.unknown`, activity colouring).
    func learnedWindow(spotKey: String, latitude: Double, longitude: Double) async -> LearnedWindow {
        await computeWindow(
            cacheKey: spotKey,
            communityKey: spotKey,
            latitude: latitude,
            longitude: longitude,
            localObs: [],
            configuredDirections: [],
            allowSeed: false
        )
    }

    /// Core merge + fallback pipeline shared by both entry points.
    private func computeWindow(
        cacheKey: String,
        communityKey: String?,
        latitude: Double?,
        longitude: Double?,
        localObs: [WindSample],
        configuredDirections: [String],
        allowSeed: Bool
    ) async -> LearnedWindow {
        if let entry = cache[cacheKey], Date().timeIntervalSince(entry.at) < Self.cacheTTL {
            return entry.window
        }

        // Merge community observations, de-duplicating against local flights
        // (a shared flight of MINE appears in both lists with identical
        // wind/date — counting it twice would over-weight my own spots).
        var observations = localObs
        let localSignatures = Set(localObs.map(Self.signature))
        if let communityKey,
           let community = try? await CommunityService.shared.communityWindObservations(forSpotKey: communityKey) {
            for entry in community {
                let obs = WindSample(dir: entry.windDirectionDeg, speed: entry.windSpeed, date: entry.date)
                if !localSignatures.contains(Self.signature(obs)) {
                    observations.append(obs)
                }
            }
        }

        let learned = Self.buildLearnedWindow(from: observations)

        let result: LearnedWindow
        if learned.totalFlights >= Self.minLearnedFlights {
            result = learned
        } else if allowSeed,
                  let seeded = await seededWindow(
                      cacheKey: cacheKey,
                      latitude: latitude,
                      longitude: longitude,
                      learnedSpeedRange: learned.speedRange
                  ) {
            result = seeded
        } else if !learned.isEmpty {
            // 1–4 real flights but no seed available: still better than nothing.
            result = learned
        } else {
            result = Self.configuredWindow(directions: configuredDirections)
        }

        cache[cacheKey] = (result, Date())
        return result
    }

    // MARK: - Window building

    /// Buckets observations into 8 compass sectors (count each) and derives a
    /// p10–p90 speed range. `.learned` source; empty when there are none.
    private static func buildLearnedWindow(from observations: [WindSample]) -> LearnedWindow {
        guard !observations.isEmpty else {
            return LearnedWindow(sectors: [:], speedRange: nil, totalFlights: 0, source: .learned)
        }
        var sectors: [String: Int] = [:]
        for obs in observations {
            let point = WeatherService.degreesToCompass(obs.dir)
            sectors[point, default: 0] += 1
        }
        let speeds = observations.map(\.speed).sorted()
        let range = percentileRange(sortedSpeeds: speeds, low: 0.10, high: 0.90)
        return LearnedWindow(sectors: sectors, speedRange: range, totalFlights: observations.count, source: .learned)
    }

    /// A window from a spot's manually configured launch directions (weight 1
    /// each). Empty sectors when no directions are set.
    private static func configuredWindow(directions: [String]) -> LearnedWindow {
        var sectors: [String: Int] = [:]
        for direction in directions where WeatherService.compassPoints.contains(direction) {
            sectors[direction] = 1
        }
        return LearnedWindow(sectors: sectors, speedRange: nil, totalFlights: 0, source: .configured)
    }

    /// p10–p90 range from ascending speeds. Too few (< 3) to trust a
    /// percentile: use the plain min…max instead.
    private static func percentileRange(sortedSpeeds: [Double], low: Double, high: Double) -> ClosedRange<Double>? {
        guard let first = sortedSpeeds.first, let last = sortedSpeeds.last else { return nil }
        guard sortedSpeeds.count >= 3 else { return first...last }
        let lo = percentile(sortedSpeeds, low)
        let hi = percentile(sortedSpeeds, high)
        return lo <= hi ? lo...hi : first...last
    }

    /// Linear-interpolation percentile of an ascending array.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        guard sorted.count > 1 else { return first }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + min(sorted[upper], last) * weight
    }

    /// Coarse observation signature (hour + rounded dir/speed) for the local↔
    /// community de-duplication. Two rows of the SAME flight share it.
    private static func signature(_ obs: WindSample) -> String {
        let hourBucket = Int(obs.date.timeIntervalSince1970 / 3600)
        return "\(hourBucket)|\(Int(obs.dir.rounded()))|\(Int(obs.speed.rounded()))"
    }

    private static func cacheKey(for spot: Spot) -> String {
        spot.communitySpotKey
            ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude)
            ?? spot.id.uuidString
    }

    // MARK: - Flyability v2

    /// Rates a forecast against a learned window.
    /// - direction good: the wind's 8-point compass sector is a learned sector
    ///   (±22.5°); marginal: an ADJACENT learned sector (up to ±67.5°).
    /// - speed good: inside the learned range padded ±20% (gusts ≤ 1.5× the
    ///   padded high); marginal: just outside; bad: well outside. When the
    ///   window has no learned speed range, the old WeatherService thresholds
    ///   apply.
    /// - `.unknown` when the window is empty or wind data is missing.
    func flyabilityV2(
        windDirectionDeg: Double?,
        windSpeed: Double?,
        windGusts: Double?,
        window: LearnedWindow
    ) -> Flyability {
        guard !window.sectors.isEmpty else { return .unknown }
        guard let direction = windDirectionDeg, let speed = windSpeed else { return .unknown }
        let gusts = windGusts ?? speed

        // Direction against the learned sectors, via the 8-point buckets.
        let windPoint = WeatherService.degreesToCompass(direction)
        let directionOK = window.sectors[windPoint] != nil
        let index = WeatherService.compassPoints.firstIndex(of: windPoint) ?? 0
        let left = WeatherService.compassPoints[(index + 7) % 8]
        let right = WeatherService.compassPoints[(index + 1) % 8]
        let directionBorderline = directionOK
            || window.sectors[left] != nil
            || window.sectors[right] != nil

        let (goodSpeeds, marginalSpeeds) = Self.speedFit(speed: speed, gusts: gusts, range: window.speedRange)

        if directionOK && goodSpeeds { return .good }
        if (directionOK && marginalSpeeds) || (directionBorderline && goodSpeeds) { return .marginal }
        return .bad
    }

    /// Spot overload: when the window is empty (no learned data, no seed, no
    /// configured directions), fall back to the classic WeatherService rating
    /// against the spot's configured directions so behaviour never regresses.
    func flyabilityV2(
        spot: Spot,
        windDirectionDeg: Double?,
        windSpeed: Double?,
        windGusts: Double?,
        window: LearnedWindow
    ) -> Flyability {
        guard !window.sectors.isEmpty else {
            return WeatherService.flyability(
                windDirectionDeg: windDirectionDeg,
                windSpeed: windSpeed,
                windGusts: windGusts,
                spotDirections: spot.windDirections
            )
        }
        return flyabilityV2(
            windDirectionDeg: windDirectionDeg,
            windSpeed: windSpeed,
            windGusts: windGusts,
            window: window
        )
    }

    /// (good, marginal) speed verdicts. With a learned range: good inside the
    /// ±20%-padded band (gusts ≤ 1.5× padded high), marginal a bit either side.
    /// Without one: the classic WeatherService thresholds.
    private static func speedFit(speed: Double, gusts: Double, range: ClosedRange<Double>?) -> (good: Bool, marginal: Bool) {
        guard let range else {
            return (speed <= 25 && gusts <= 40, speed <= 35 && gusts <= 55)
        }
        let padLow = max(0, range.lowerBound * (1 - speedPad))
        let padHigh = range.upperBound * (1 + speedPad)
        let good = speed >= padLow && speed <= padHigh && gusts <= padHigh * 1.5
        let marginal = speed >= padLow * 0.6 && speed <= padHigh * 1.4 && gusts <= padHigh * 2.0
        return (good, marginal)
    }

    // MARK: - ParaglidingEarth seed

    /// A seeded window from the nearest ParaglidingEarth site's orientations,
    /// cached aggressively in UserDefaults per spot key. Returns nil when the
    /// spot has no coordinates, when the fetch fails (NOT cached, so we retry
    /// later), or when no nearby site has any usable orientation.
    private func seededWindow(
        cacheKey: String,
        latitude: Double?,
        longitude: Double?,
        learnedSpeedRange: ClosedRange<Double>?
    ) async -> LearnedWindow? {
        guard let latitude, let longitude else { return nil }

        let sectors: [String: Int]
        if let cached = Self.loadSeedCache(key: cacheKey) {
            // Cached hit (even an empty result is cached to avoid re-fetching).
            sectors = cached
        } else if let fetched = try? await Self.fetchParaglidingEarthOrientations(latitude: latitude, longitude: longitude) {
            Self.saveSeedCache(key: cacheKey, sectors: fetched)
            sectors = fetched
        } else {
            return nil // network/parse failure — leave uncached for a retry
        }

        guard !sectors.isEmpty else { return nil }
        // Keep any learned speed range we already have (1–4 flights) as a hint.
        return LearnedWindow(sectors: sectors, speedRange: learnedSpeedRange, totalFlights: 0, source: .seeded)
    }

    /// GET the GeoJSON `getAroundLatLngSites` endpoint (5 km / 5 sites) and
    /// return the nearest site with any orientation rated ≥ 1, as
    /// compass-point → rating (1 possible, 2 good).
    private static func fetchParaglidingEarthOrientations(latitude: Double, longitude: Double) async throws -> [String: Int] {
        var components = URLComponents(string: "https://www.paraglidingearth.com/api/geojson/getAroundLatLngSites.php")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.5f", latitude)),
            URLQueryItem(name: "lng", value: String(format: "%.5f", longitude)),
            URLQueryItem(name: "distance", value: "5"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { throw WeatherError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = WeatherConstants.networkTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(PGEFeatureCollection.self, from: data)
        // Features come ordered by distance — take the nearest one that
        // actually carries orientation data.
        for feature in decoded.features {
            let sectors = feature.properties.orientationSectors()
            if !sectors.isEmpty { return sectors }
        }
        return [:]
    }

    // MARK: - Seed cache (UserDefaults)

    private struct SeedCacheEntry: Codable {
        let sectors: [String: Int]
        let fetchedAt: Date
    }

    private static func seedCacheKey(_ spotKey: String) -> String { "spotSeed_" + spotKey }

    /// Cached seed sectors (possibly empty — an empty entry still means
    /// "already fetched, nothing usable nearby"), or nil when absent/stale.
    private static func loadSeedCache(key spotKey: String) -> [String: Int]? {
        guard let data = UserDefaults.standard.data(forKey: seedCacheKey(spotKey)),
              let entry = try? JSONDecoder().decode(SeedCacheEntry.self, from: data),
              Date().timeIntervalSince(entry.fetchedAt) < seedCacheTTL else { return nil }
        return entry.sectors
    }

    private static func saveSeedCache(key spotKey: String, sectors: [String: Int]) {
        let entry = SeedCacheEntry(sectors: sectors, fetchedAt: Date())
        if let data = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(data, forKey: seedCacheKey(spotKey))
        }
    }
}

// MARK: - ParaglidingEarth GeoJSON

/// Minimal decode of the PGE `getAroundLatLngSites` GeoJSON response. Only the
/// per-site orientation ratings are needed; every field is optional and the
/// ratings are decoded flexibly (the API emits them as strings like "2", but
/// numbers are accepted too) so a schema wobble never fails the whole seed.
private nonisolated struct PGEFeatureCollection: Decodable {
    let features: [PGEFeature]
}

private nonisolated struct PGEFeature: Decodable {
    let properties: PGEProperties
}

private nonisolated struct PGEProperties: Decodable {
    let N: Int?
    let NE: Int?
    let E: Int?
    let SE: Int?
    let S: Int?
    let SW: Int?
    let W: Int?
    let NW: Int?

    private enum CodingKeys: String, CodingKey {
        case N, NE, E, SE, S, SW, W, NW
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func rating(_ key: CodingKeys) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            if let string = try? container.decodeIfPresent(String.self, forKey: key) { return Int(string) }
            return nil
        }
        N = rating(.N); NE = rating(.NE); E = rating(.E); SE = rating(.SE)
        S = rating(.S); SW = rating(.SW); W = rating(.W); NW = rating(.NW)
    }

    /// Compass point → rating for every orientation rated ≥ 1 (possible/good).
    func orientationSectors() -> [String: Int] {
        var sectors: [String: Int] = [:]
        let ratings: [(String, Int?)] = [
            ("N", N), ("NE", NE), ("E", E), ("SE", SE),
            ("S", S), ("SW", SW), ("W", W), ("NW", NW)
        ]
        for (point, rating) in ratings where (rating ?? 0) >= 1 {
            sectors[point] = rating
        }
        return sectors
    }
}
