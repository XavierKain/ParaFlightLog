//
//  FlightModelTests.swift
//  ParaFlightLogTests
//
//  Flight/Wing model logic: duration formatting, flight-type bridging,
//  GPS track (de)coding, CloudKit-safe defaults, and shared DTO helpers.
//
//  Note on "constructible with no args": @Model classes only expose their
//  declared initializers, so CloudKit safety is asserted through the inline
//  defaults reachable via the minimal initializers (every stored attribute
//  optional or defaulted).
//

import Foundation
import SwiftData
import Testing
@testable import ParaFlightLog

private nonisolated func utcDate(_ year: Int, _ month: Int, _ day: Int,
                     _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

@Suite struct FlightModelTests {

    let container: ModelContainer

    init() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Wing.self, Flight.self, Spot.self,
                                       configurations: configuration)
    }

    private func makeFlight(durationSeconds: Int = 0) -> Flight {
        let start = utcDate(2026, 7, 4, 10, 0, 0)
        let flight = Flight(
            startDate: start,
            endDate: start.addingTimeInterval(Double(durationSeconds)),
            durationSeconds: durationSeconds
        )
        container.mainContext.insert(flight)
        return flight
    }

    // MARK: - durationFormatted

    @Test func durationFormattedUsesHoursWithZeroPaddedMinutes() {
        #expect(makeFlight(durationSeconds: 3900).durationFormatted == "1h05")
        #expect(makeFlight(durationSeconds: 3600).durationFormatted == "1h00")
        #expect(makeFlight(durationSeconds: 7380).durationFormatted == "2h03")
        #expect(makeFlight(durationSeconds: 36_000).durationFormatted == "10h00")
    }

    @Test func durationFormattedUsesMinutesUnderOneHour() {
        #expect(makeFlight(durationSeconds: 2700).durationFormatted == "45min")
        #expect(makeFlight(durationSeconds: 60).durationFormatted == "1min")
        #expect(makeFlight(durationSeconds: 0).durationFormatted == "0min")
        // Leftover seconds are truncated, not rounded
        #expect(makeFlight(durationSeconds: 119).durationFormatted == "1min")
        #expect(makeFlight(durationSeconds: 3659).durationFormatted == "1h00")
    }

    // MARK: - flightTypeEnum bridge

    @Test func flightTypeEnumBridgesRawStorage() {
        let flight = makeFlight()

        flight.flightType = "Soaring"
        #expect(flight.flightTypeEnum == .soaring)

        flight.flightTypeEnum = .groundHandling
        #expect(flight.flightType == "Ground Handling")

        flight.flightTypeEnum = nil
        #expect(flight.flightType == nil)
        #expect(flight.flightTypeEnum == nil)

        // Unknown raw value bridges to nil without touching storage
        flight.flightType = "Wingsuit"
        #expect(flight.flightTypeEnum == nil)
        #expect(flight.flightType == "Wingsuit")
    }

    @Test func flightTypeRawValuesRoundTrip() {
        #expect(FlightType.allCases.count == 6)
        for type in FlightType.allCases {
            #expect(FlightType(rawValue: type.rawValue) == type)
            #expect(type.id == type.rawValue)
        }
    }

    // MARK: - GPS track storage

    @Test func gpsTrackEncodesAndDecodesLosslessly() throws {
        let flight = makeFlight(durationSeconds: 10)
        let points = [
            GPSTrackPoint(timestamp: utcDate(2026, 7, 4, 10, 0, 0), latitude: 45.9, longitude: 6.1, altitude: 1000, speed: 9.5),
            GPSTrackPoint(timestamp: utcDate(2026, 7, 4, 10, 0, 10), latitude: 45.905, longitude: 6.105, altitude: nil, speed: nil)
        ]
        flight.setGPSTrack(points)

        let decoded = try #require(flight.gpsTrack)
        #expect(decoded.count == 2)
        #expect(decoded[0].id == points[0].id)
        #expect(decoded[0].latitude == 45.9)
        #expect(decoded[0].altitude == 1000)
        #expect(decoded[0].speed == 9.5)
        // Optionals survive as nil, order is preserved
        #expect(decoded[1].altitude == nil)
        #expect(decoded[1].speed == nil)
        #expect(decoded[1].timestamp > decoded[0].timestamp)
    }

    @Test func gpsTrackIsNilWithoutData() {
        let flight = makeFlight()
        #expect(flight.gpsTrackData == nil)
        #expect(flight.gpsTrack == nil)
    }

    // MARK: - CloudKit-safe defaults

    @Test func wingMinimalInitAppliesSafeDefaults() {
        let wing = Wing(name: "Test Wing")
        container.mainContext.insert(wing)

        #expect(wing.name == "Test Wing")
        #expect(wing.isArchived == false)
        #expect(wing.displayOrder == 0)
        #expect(wing.brand == nil)
        #expect(wing.size == nil)
        #expect(wing.photoData == nil)
        #expect((wing.flights ?? []).isEmpty)
    }

    @Test func flightMinimalInitAppliesSafeDefaults() {
        let flight = makeFlight(durationSeconds: 60)

        #expect(flight.wing == nil)
        #expect(flight.spot == nil)
        #expect(flight.spotName == nil)
        #expect(flight.flightType == nil)
        #expect(flight.notes == nil)
        #expect(flight.maxAltitude == nil)
        #expect(flight.takeoffWindSpeed == nil)
        #expect(flight.gpsTrackData == nil)
    }

    @Test func spotMinimalInitAppliesSafeDefaults() {
        let spot = Spot(name: "Punta Paloma")
        container.mainContext.insert(spot)

        #expect(spot.city == nil)
        #expect(spot.latitude == nil)
        #expect(spot.windDirections.isEmpty)
        #expect(spot.communitySpotKey == nil)
    }

    @Test func distinctModelInstancesGetDistinctIds() {
        #expect(makeFlight().id != makeFlight().id)
        let wingA = Wing(name: "A")
        let wingB = Wing(name: "B")
        #expect(wingA.id != wingB.id)
    }

    // MARK: - Relationships

    @Test func wingFlightInverseRelationship() throws {
        let wing = Wing(name: "Moustache M1")
        container.mainContext.insert(wing)
        let flight = makeFlight(durationSeconds: 600)

        flight.wing = wing
        let flights = try #require(wing.flights)
        #expect(flights.count == 1)
        #expect(flights.first?.id == flight.id)
    }

    // MARK: - Shared DTO helpers

    @Test func wingDTOShortNameStripsLongBrandPrefix() {
        let base = WingDTO(id: UUID(), name: "Moustache M1 2025")
        #expect(base.shortName == "M1 2025")
        let other = WingDTO(id: UUID(), name: "Ozone Rush 6")
        #expect(other.shortName == "Ozone Rush 6")
    }

    @Test func wingToDTOWithoutPhotoDropsThePhoto() {
        let wing = Wing(name: "Moustache M1", size: "18", type: "Soaring",
                        photoData: Data([1, 2, 3]), displayOrder: 4)
        container.mainContext.insert(wing)
        let dto = wing.toDTOWithoutPhoto()

        #expect(dto.id == wing.id)
        #expect(dto.name == "Moustache M1")
        #expect(dto.size == "18")
        #expect(dto.photoData == nil)
        #expect(dto.displayOrder == 4)
    }
}
