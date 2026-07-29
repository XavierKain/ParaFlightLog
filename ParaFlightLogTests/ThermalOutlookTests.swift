//
//  ThermalOutlookTests.swift
//  ParaFlightLogTests
//
//  The thermal picture derived from the enriched Open-Meteo call.
//  Pure static logic — no networking involved.
//

import Foundation
import Testing
@testable import ParaFlightLog

@Suite struct CloudBaseTests {

    private func hour(temperature: Double?, dewPoint: Double?) -> HourForecast {
        HourForecast(
            time: Date(timeIntervalSince1970: 0),
            windSpeed: nil, windGusts: nil, windDirectionDeg: nil,
            precipProbability: nil, temperature: temperature, dewPoint: dewPoint,
            cape: nil, boundaryLayerHeight: nil
        )
    }

    @Test func cloudBaseIs125MetresPerDegreeOfSpread() {
        #expect(hour(temperature: 24, dewPoint: 12).cloudBaseMeters == 1500)
        #expect(hour(temperature: 30, dewPoint: 10).cloudBaseMeters == 2500)
    }

    /// Saturated or supersaturated air has no meaningful lifting condensation
    /// level to quote — better nothing than a negative altitude.
    @Test func noSpreadMeansNoCloudBase() {
        #expect(hour(temperature: 15, dewPoint: 15).cloudBaseMeters == nil)
        #expect(hour(temperature: 12, dewPoint: 14).cloudBaseMeters == nil)
    }

    @Test func missingInputsMeanNoCloudBase() {
        #expect(hour(temperature: nil, dewPoint: 12).cloudBaseMeters == nil)
        #expect(hour(temperature: 24, dewPoint: nil).cloudBaseMeters == nil)
    }
}

@Suite struct ThermalOutlookTests {

    /// A day of hourly entries at `day`, one per hour from 00:00 UTC.
    private func day(
        _ reference: Date,
        tops: [Double?],
        temperature: Double = 25,
        dewPoint: Double = 10,
        cape: Double? = nil
    ) -> [HourForecast] {
        tops.enumerated().map { index, top in
            HourForecast(
                time: reference.addingTimeInterval(Double(index) * 3600),
                windSpeed: nil, windGusts: nil, windDirectionDeg: nil,
                precipProbability: nil, temperature: temperature, dewPoint: dewPoint,
                cape: cape, boundaryLayerHeight: top
            )
        }
    }

    /// Midday-anchored so every generated hour lands on the same local day in
    /// any timezone the tests run in.
    private var reference: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
    }

    @Test func theOutlookDescribesTheDeepestHourNotTheAverage() {
        let hours = day(reference, tops: [600, 1400, 2200, 1900])
        let outlook = WeatherService.thermalOutlook(from: hours, on: reference)
        #expect(outlook?.thermalTopMeters == 2200)
        #expect(outlook?.time == reference.addingTimeInterval(2 * 3600))
    }

    /// 25 °C / 10 °C spread puts condensation at 1875 m. With a 2200 m ceiling
    /// thermals reach it, so there is a cloud base to quote.
    @Test func cumulusFormsWhenThermalsReachTheCondensationLevel() {
        let outlook = WeatherService.thermalOutlook(from: day(reference, tops: [2200]), on: reference)
        #expect(outlook?.cloudBaseMeters == 1875)
        #expect(outlook?.isBlue == false)
    }

    /// Same air, a shallower day: thermals top out below condensation, so no
    /// cumulus can form and quoting a base would send pilots looking for cloud
    /// that never appears.
    @Test func aCondensationLevelAboveTheCeilingIsABlueDay() {
        let outlook = WeatherService.thermalOutlook(from: day(reference, tops: [1200]), on: reference)
        #expect(outlook?.cloudBaseMeters == nil)
        #expect(outlook?.isBlue == true)
        #expect(outlook?.thermalTopMeters == 1200)
    }

    @Test func shallowDaysProduceNoOutlookAtAll() {
        #expect(WeatherService.thermalOutlook(from: day(reference, tops: [120, 300, 499]), on: reference) == nil)
        // The threshold itself still counts as a thermal day.
        #expect(WeatherService.thermalOutlook(from: day(reference, tops: [500]), on: reference) != nil)
    }

    @Test func missingBoundaryLayerDataProducesNoOutlook() {
        #expect(WeatherService.thermalOutlook(from: day(reference, tops: [nil, nil]), on: reference) == nil)
        #expect(WeatherService.thermalOutlook(from: [], on: reference) == nil)
    }

    /// Hours from other days must not leak into today's outlook.
    @Test func onlyTheRequestedDayIsConsidered() {
        let today = day(reference, tops: [900])
        let tomorrow = day(reference.addingTimeInterval(86400), tops: [3000])
        let outlook = WeatherService.thermalOutlook(from: today + tomorrow, on: reference)
        #expect(outlook?.thermalTopMeters == 900)
    }

    @Test func overdevelopmentRiskTracksCape() {
        let calm = WeatherService.thermalOutlook(from: day(reference, tops: [1800], cape: 200), on: reference)
        #expect(calm?.hasOverdevelopmentRisk == false)

        let unstable = WeatherService.thermalOutlook(from: day(reference, tops: [1800], cape: 1400), on: reference)
        #expect(unstable?.hasOverdevelopmentRisk == true)

        // Absent CAPE is not a risk signal — it is an absence of information.
        let unknown = WeatherService.thermalOutlook(from: day(reference, tops: [1800], cape: nil), on: reference)
        #expect(unknown?.hasOverdevelopmentRisk == false)
    }
}
