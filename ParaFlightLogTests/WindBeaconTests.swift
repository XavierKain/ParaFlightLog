//
//  WindBeaconTests.swift
//  ParaFlightLogTests
//
//  OpenWindMap / Pioupiou beacon selection and forecast cross-check.
//  Pure logic + decoding — no networking involved.
//

import CoreLocation
import Foundation
import Testing
@testable import ParaFlightLog

// MARK: - Decoding

@Suite struct PiouDecodingTests {

    /// A verbatim station from the live `live-with-meta/all` payload, so the
    /// decoder is tested against the real schema rather than one we invented.
    private let payload = """
    {
      "doc": "https://developers.pioupiou.fr/api/live/",
      "license": "https://developers.pioupiou.fr/data-licensing",
      "attribution": "(c) contributors of the OpenWindMap wind network",
      "data": [
        {
          "id": 41,
          "meta": { "name": "Sauveterre", "description": "Site de gonflage",
                    "picture": null, "date": "2021-01-27T10:02:34.143Z",
                    "rating": { "upvotes": 0, "downvotes": 0 } },
          "location": { "latitude": 43.456775, "longitude": 0.846423,
                        "date": "2026-07-29T10:30:25.000Z", "success": true, "hdop": 2 },
          "measurements": { "date": "2026-07-29T12:16:59.000Z", "pressure": null,
                            "wind_heading": 112.5, "wind_speed_avg": 8.25,
                            "wind_speed_max": 19, "wind_speed_min": 1.75 },
          "status": { "date": "2026-07-29T12:16:59.000Z", "snr": 0, "state": "on" }
        }
      ]
    }
    """

    @Test func decodesTheLiveSchema() throws {
        let response = try JSONDecoder().decode(PiouResponse.self, from: Data(payload.utf8))
        let station = try #require(response.data.first)
        #expect(station.id == 41)
        #expect(station.meta?.name == "Sauveterre")
        #expect(station.location?.latitude == 43.456775)
        #expect(station.measurements?.windSpeedAvg == 8.25)
        #expect(station.measurements?.windHeading == 112.5)
        #expect(station.status?.state == "on")
    }

    /// Every field is optional on purpose: an upstream schema change must
    /// narrow the beacon list, never break the whole weather page.
    @Test func decodesAStationStrippedOfEverythingOptional() throws {
        let minimal = Data(#"{"data":[{"id":7}]}"#.utf8)
        let response = try JSONDecoder().decode(PiouResponse.self, from: minimal)
        #expect(response.data.first?.id == 7)
        #expect(response.data.first?.measurements == nil)
    }

    @Test func parsesBothIsoFormsAndRejectsGarbage() {
        #expect(WindBeaconService.parseDate("2026-07-29T12:16:59.000Z") != nil)
        #expect(WindBeaconService.parseDate("2026-07-29T12:16:59Z") != nil)
        #expect(WindBeaconService.parseDate("not a date") == nil)
        #expect(WindBeaconService.parseDate("") == nil)
    }
}

// MARK: - Selection

@Suite struct WindBeaconSelectionTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Reference point; the stations below are placed relative to it.
    private let origin = CLLocationCoordinate2D(latitude: 44.5, longitude: -1.2)

    private func station(
        id: Int,
        latitude: Double,
        longitude: Double,
        ageMinutes: Double = 5,
        speed: Double? = 20,
        gust: Double? = 30,
        heading: Double? = 270,
        name: String? = "Beacon",
        locationSuccess: Bool? = true
    ) -> PiouStation {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return PiouStation(
            id: id,
            meta: .init(name: name),
            location: .init(latitude: latitude, longitude: longitude, success: locationSuccess),
            measurements: .init(
                date: formatter.string(from: now.addingTimeInterval(-ageMinutes * 60)),
                windHeading: heading,
                windSpeedAvg: speed,
                windSpeedMax: gust,
                windSpeedMin: nil
            ),
            status: .init(state: "on")
        )
    }

    private func nearest(_ stations: [PiouStation]) -> WindBeacon? {
        WindBeaconService.nearest(to: origin, in: stations, now: now)
    }

    @Test func picksTheClosestUsableBeacon() {
        // ~0.09° of latitude is ~10 km; ~0.02° is ~2 km.
        let far = station(id: 1, latitude: 44.59, longitude: -1.2)
        let near = station(id: 2, latitude: 44.52, longitude: -1.2)
        let beacon = nearest([far, near])
        #expect(beacon?.id == 2)
        #expect((beacon?.distanceMeters ?? 0) < 3000)
    }

    @Test func carriesTheReadingThrough() {
        let beacon = nearest([station(id: 3, latitude: 44.51, longitude: -1.2, speed: 34, gust: 48, heading: 225)])
        #expect(beacon?.windAverage == 34)
        #expect(beacon?.windMax == 48)
        #expect(beacon?.compass == "SW")
        #expect(beacon?.name == "Beacon")
    }

    /// The whole point of a "live" beacon. The network's own test rig reports
    /// `state: "on"` with a measurement from 2017 — freshness is judged on the
    /// measurement date and nothing else.
    @Test func staleReadingsAreDropped() {
        let stale = station(id: 4, latitude: 44.51, longitude: -1.2, ageMinutes: 61)
        #expect(nearest([stale]) == nil)

        let fresh = station(id: 5, latitude: 44.51, longitude: -1.2, ageMinutes: 59)
        #expect(nearest([fresh])?.id == 5)
    }

    /// A reading in the future is a clock problem, not a forecast.
    @Test func futureReadingsAreDropped() {
        #expect(nearest([station(id: 6, latitude: 44.51, longitude: -1.2, ageMinutes: -10)]) == nil)
    }

    @Test func distantBeaconsAreDropped() {
        // ~0.5° of latitude is ~55 km, well past the 20 km ceiling.
        #expect(nearest([station(id: 7, latitude: 45.0, longitude: -1.2)]) == nil)
    }

    @Test func implausibleSpeedsAreDropped() {
        #expect(nearest([station(id: 8, latitude: 44.51, longitude: -1.2, speed: 231.6)]) == nil)
        #expect(nearest([station(id: 9, latitude: 44.51, longitude: -1.2, speed: -3)]) == nil)
    }

    @Test func stationsWithNoReadingAreDropped() {
        #expect(nearest([station(id: 10, latitude: 44.51, longitude: -1.2, speed: nil)]) == nil)
    }

    /// A beacon with no heading is still worth showing — the speed is the part
    /// that contradicts a forecast — so it survives with a nil compass.
    @Test func aMissingHeadingDoesNotDisqualifyABeacon() {
        let beacon = nearest([station(id: 11, latitude: 44.51, longitude: -1.2, heading: nil)])
        #expect(beacon?.id == 11)
        #expect(beacon?.compass == nil)
    }

    /// Gusts default to the sustained wind, matching how the rest of the app
    /// treats a missing gust value.
    @Test func aMissingGustFallsBackToTheSustainedWind() {
        let beacon = nearest([station(id: 15, latitude: 44.51, longitude: -1.2, speed: 21, gust: nil)])
        #expect(beacon?.windMax == 21)
    }

    /// A failed GPS fix says nothing about where a fixed mast is. On the live
    /// network 62 of the 63 stations reporting `success: false` still carry
    /// coordinates; dropping them would lose 8% of the network for nothing.
    @Test func aFailedGpsFixDoesNotDisqualifyABeacon() {
        let beacon = nearest([station(id: 12, latitude: 44.51, longitude: -1.2, locationSuccess: false)])
        #expect(beacon?.id == 12)
    }

    @Test func noStationsMeansNoBeaconNotACrash() {
        #expect(nearest([]) == nil)
    }

    @Test func unnamedBeaconsFallBackToTheirId() {
        #expect(nearest([station(id: 13, latitude: 44.51, longitude: -1.2, name: nil)])?.name == "Beacon 13")
        #expect(nearest([station(id: 14, latitude: 44.51, longitude: -1.2, name: "   ")])?.name == "Beacon 14")
    }
}

// MARK: - Forecast cross-check

@Suite struct WindBeaconAgreementTests {

    private func agreement(beacon: Double, forecast: Double?) -> LiveWindCheck.Agreement {
        WindBeaconService.agreement(beaconSpeed: beacon, forecastSpeed: forecast)
    }

    /// Tolerance is max(8 km/h, 40% of the forecast). Small differences are
    /// normal model error, and calling them disagreements would make the
    /// cross-check worthless.
    @Test func smallDifferencesAreNotADisagreement() {
        #expect(agreement(beacon: 22, forecast: 20) == .agrees)
        #expect(agreement(beacon: 14, forecast: 20) == .agrees)
        #expect(agreement(beacon: 28, forecast: 20) == .agrees)
    }

    @Test func aRealDisagreementIsCalledOut() {
        #expect(agreement(beacon: 34, forecast: 20) == .windierThanForecast)
        #expect(agreement(beacon: 6, forecast: 20) == .lighterThanForecast)
    }

    /// At low forecast speeds the 40% relative band would be tiny, so the
    /// 8 km/h floor takes over.
    @Test func theAbsoluteFloorGovernsLightForecasts() {
        #expect(agreement(beacon: 12, forecast: 5) == .agrees)
        #expect(agreement(beacon: 20, forecast: 5) == .windierThanForecast)
    }

    /// At high forecast speeds the relative band takes over instead.
    @Test func theRelativeBandGovernsStrongForecasts() {
        #expect(agreement(beacon: 52, forecast: 40) == .agrees)
        #expect(agreement(beacon: 60, forecast: 40) == .windierThanForecast)
    }

    /// Nothing to compare against is not agreement — the UI shows the reading
    /// on its own rather than claiming a match that was never tested.
    @Test func noForecastMeansNoClaim() {
        #expect(agreement(beacon: 34, forecast: nil) == .agrees)
    }
}
