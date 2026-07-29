//
//  WindBeaconService.swift
//  ParaFlightLog
//
//  Live wind from the OpenWindMap / Pioupiou beacon network — the honest
//  cross-check on a forecast. A model saying 20 km/h W and a real anemometer
//  6 km away reading 34 km/h is the single most useful thing an app can tell a
//  pilot at 7am, and it is the thing that makes them believe the rest.
//
//  Deliberately NOT wired into the flyability rating. A beacon can be 15 km
//  away in different terrain; letting it silently re-rate a spot would trade a
//  transparent verdict for an opaque one. It is shown ALONGSIDE the verdict,
//  with its distance and its age, and it is allowed to contradict it out loud.
//
//  Coverage is the known weakness: beacons cluster on official paragliding
//  sites, and our soaring-first bet is precisely about spots that aren't one.
//  On many of our target spots there will be no beacon — which is the argument
//  for the community condition reports, not a bug. The UI must say so plainly.
//
//  Data (c) contributors of the OpenWindMap wind network <https://openwindmap.org>,
//  Community License — free for any use including commercial, attribution
//  required. No API key.
//  Target: iOS only
//

import CoreLocation
import Foundation

// MARK: - Public models

/// One live beacon reading, already resolved against a spot.
struct WindBeacon: Identifiable, Equatable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    /// When the beacon took this measurement.
    let measuredAt: Date
    /// Sustained wind, km/h (the network reports km/h natively).
    let windAverage: Double
    /// Gust, km/h.
    let windMax: Double
    /// Direction the wind comes FROM, degrees.
    let directionDeg: Double?
    /// Distance from the spot the beacon was looked up for, metres.
    let distanceMeters: Double

    /// 8-point compass label, matching the rest of the app.
    var compass: String? {
        directionDeg.map(WeatherService.degreesToCompass)
    }
}

/// A forecast, checked against a real anemometer.
struct LiveWindCheck: Equatable {
    /// How the beacon compares to the forecast at the same moment.
    enum Agreement: Equatable {
        case agrees
        /// It is blowing harder than forecast.
        case windierThanForecast
        /// It is blowing lighter than forecast.
        case lighterThanForecast
    }

    let beacon: WindBeacon
    /// The forecast speed compared against, km/h. Nil when there was nothing
    /// to compare and the beacon is shown on its own.
    let forecastSpeed: Double?
    let agreement: Agreement
}

// MARK: - Service

@Observable @MainActor
final class WindBeaconService {
    static let shared = WindBeaconService()
    private init() {}

    // MARK: Tuning

    /// The network has no geographic query of ANY kind — no bbox, no radius,
    /// no lat/lon parameter. The only way to find a nearby beacon is to fetch
    /// every station and filter locally. That is ~750 stations / ~650 KB, so
    /// the snapshot is cached hard and shared by every caller.
    private static let allStationsURL = "https://api.pioupiou.fr/v1/live-with-meta/all"

    /// Snapshot TTL. The publisher asks for no more than one request per
    /// minute; five is polite and still well inside the useful lifetime of a
    /// reading.
    private static let cacheTTL: TimeInterval = 5 * 60

    /// Older than this and a reading is not a "live" cross-check any more, so
    /// the beacon is dropped rather than shown with a caveat. Measured on the
    /// live network: ~89% of stations report within 15 minutes, so an hour is
    /// generous rather than restrictive.
    static let maxReadingAge: TimeInterval = 60 * 60

    /// Beyond this a beacon is describing different weather. The distance is
    /// always shown so the pilot can discount it themselves, but past 20 km
    /// there is nothing left to discount.
    static let maxDistanceMeters: Double = 20_000

    /// Physically implausible for a surface anemometer; guards against the
    /// network's own test rigs (station id 1 reports 231 km/h). The age filter
    /// already removes those, so this is a belt-and-braces check.
    static let maxPlausibleSpeed: Double = 200

    /// Required attribution, shown wherever beacon data appears.
    static let attribution = "Live wind © contributors of the OpenWindMap network"
    static let attributionURL = URL(string: "https://openwindmap.org")!

    // MARK: Cache

    private var snapshot: (stations: [PiouStation], fetchedAt: Date)?
    /// In-flight fetch, so two spot pages opening at once share one 650 KB
    /// download instead of racing.
    private var inFlight: Task<[PiouStation], Error>?

    // MARK: Lookup

    /// The nearest usable beacon to a coordinate, or nil when there is none —
    /// which is a normal, expected answer, not a failure.
    func nearestBeacon(latitude: Double, longitude: Double) async -> WindBeacon? {
        guard let stations = try? await stations() else { return nil }
        return Self.nearest(
            to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            in: stations,
            now: Date()
        )
    }

    /// The nearest beacon, compared against a forecast speed. Nil when no
    /// beacon covers this spot.
    func liveCheck(latitude: Double, longitude: Double, forecastSpeed: Double?) async -> LiveWindCheck? {
        guard let beacon = await nearestBeacon(latitude: latitude, longitude: longitude) else { return nil }
        return LiveWindCheck(
            beacon: beacon,
            forecastSpeed: forecastSpeed,
            agreement: Self.agreement(beaconSpeed: beacon.windAverage, forecastSpeed: forecastSpeed)
        )
    }

    // MARK: Snapshot

    private func stations() async throws -> [PiouStation] {
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < Self.cacheTTL {
            return snapshot.stations
        }
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task<[PiouStation], Error> {
            try await Self.fetchAllStations()
        }
        inFlight = task
        defer { inFlight = nil }

        do {
            let stations = try await task.value
            snapshot = (stations, Date())
            return stations
        } catch {
            logDebug("Wind beacon snapshot failed: \(error.localizedDescription)", category: .weather)
            // Keep serving the previous snapshot if we have one; the age filter
            // downstream will drop anything that has gone stale meanwhile.
            if let snapshot { return snapshot.stations }
            throw error
        }
    }

    private static func fetchAllStations() async throws -> [PiouStation] {
        guard let url = URL(string: allStationsURL) else { throw WeatherError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = WeatherConstants.networkTimeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeatherError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(PiouResponse.self, from: data).data
        } catch {
            logWarning("Pioupiou decoding failed: \(error.localizedDescription)", category: .weather)
            throw WeatherError.invalidResponse
        }
    }

    // MARK: - Pure logic (unit-tested)

    /// Nearest usable beacon, or nil. A station is usable when it has
    /// coordinates, a wind reading, a recent measurement and a plausible speed.
    ///
    /// `location.success` is deliberately NOT required: on the live network 62
    /// of the 63 stations reporting a failed fix still carry coordinates, and a
    /// beacon is a fixed mast — a failed GPS attempt says nothing about where
    /// it is. Requiring it would drop 8% of the network for no gain.
    static func nearest(to coordinate: CLLocationCoordinate2D, in stations: [PiouStation], now: Date) -> WindBeacon? {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return stations
            .compactMap { station -> WindBeacon? in
                guard let latitude = station.location?.latitude,
                      let longitude = station.location?.longitude,
                      latitude.isFinite, longitude.isFinite,
                      let measurements = station.measurements,
                      let measuredAt = measurements.date.flatMap(parseDate),
                      let average = measurements.windSpeedAvg else { return nil }

                let age = now.timeIntervalSince(measuredAt)
                guard age >= 0, age <= maxReadingAge else { return nil }
                guard average >= 0, average <= maxPlausibleSpeed else { return nil }

                let distance = origin.distance(from: CLLocation(latitude: latitude, longitude: longitude))
                guard distance <= maxDistanceMeters else { return nil }

                return WindBeacon(
                    id: station.id,
                    name: station.meta?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        ?? "Beacon \(station.id)",
                    latitude: latitude,
                    longitude: longitude,
                    measuredAt: measuredAt,
                    windAverage: average,
                    windMax: measurements.windSpeedMax ?? average,
                    directionDeg: measurements.windHeading,
                    distanceMeters: distance
                )
            }
            .min { $0.distanceMeters < $1.distanceMeters }
    }

    /// Does the beacon back the forecast up, or contradict it?
    ///
    /// The tolerance is the larger of 8 km/h and 40% of the forecast, so a
    /// disagreement has to be big enough to change a decision before it is
    /// called one. Crying wolf over 3 km/h would make the whole cross-check
    /// worthless.
    static func agreement(beaconSpeed: Double, forecastSpeed: Double?) -> LiveWindCheck.Agreement {
        guard let forecastSpeed else { return .agrees }
        let tolerance = max(8, forecastSpeed * 0.4)
        let delta = beaconSpeed - forecastSpeed
        if delta > tolerance { return .windierThanForecast }
        if delta < -tolerance { return .lighterThanForecast }
        return .agrees
    }

    /// The network emits ISO 8601 UTC with fractional seconds throughout
    /// ("2026-07-29T12:16:59.000Z"), but the plain form is accepted too so a
    /// format change upstream degrades to "no beacon" rather than a crash.
    static func parseDate(_ string: String) -> Date? {
        if let date = fractionalFormatter.date(from: string) { return date }
        return plainFormatter.date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Pioupiou raw response

/// Tolerant decode of `live-with-meta/all`. Every field optional: a schema
/// wobble upstream must narrow the beacon list, never break the weather page.
nonisolated struct PiouResponse: Decodable {
    let data: [PiouStation]
}

nonisolated struct PiouStation: Decodable {
    let id: Int
    let meta: Meta?
    let location: Location?
    let measurements: Measurements?
    let status: Status?

    struct Meta: Decodable {
        let name: String?
    }

    struct Location: Decodable {
        let latitude: Double?
        let longitude: Double?
        /// Whether the LAST GPS fix attempt succeeded — not whether the
        /// coordinates are known. See `WindBeaconService.nearest`.
        let success: Bool?
    }

    struct Measurements: Decodable {
        let date: String?
        let windHeading: Double?
        let windSpeedAvg: Double?
        let windSpeedMax: Double?
        let windSpeedMin: Double?

        enum CodingKeys: String, CodingKey {
            case date
            case windHeading = "wind_heading"
            case windSpeedAvg = "wind_speed_avg"
            case windSpeedMax = "wind_speed_max"
            case windSpeedMin = "wind_speed_min"
        }
    }

    struct Status: Decodable {
        /// "on" / "off". Necessary but NOT sufficient: the network's test rig
        /// reports "on" with a measurement from 2017. Freshness is judged on
        /// `measurements.date`, never on this.
        let state: String?
    }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
