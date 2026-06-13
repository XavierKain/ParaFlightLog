//
//  IGCExporterTests.swift
//  ParaFlightLogTests
//
//  Tests du générateur de fichiers IGC (format FAI).
//

import XCTest
@testable import ParaFlightLog

final class IGCExporterTests: XCTestCase {

    /// Le self-test interne (encodage lat/lon sur des valeurs connues) doit passer.
    func testInternalSelfTest() {
        XCTAssertTrue(IGCExporter._selfTest(), "L'encodage lat/lon IGC doit être correct")
    }

    /// Un vol sans trace GPS ne produit pas de fichier.
    func testReturnsNilWithoutTrack() {
        let flight = Flight(startDate: Date(), endDate: Date(), durationSeconds: 600)
        XCTAssertNil(IGCExporter.exportIGC(flight: flight, pilotName: "Xavier"))
    }

    /// Un vol avec une trace de 2 points produit un fichier IGC valide.
    func testProducesValidIGCFile() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let flight = Flight(startDate: start, endDate: start.addingTimeInterval(120), durationSeconds: 120,
                            spotName: "Tarifa")
        let points = [
            GPSTrackPoint(timestamp: start, latitude: 36.06, longitude: -5.71, altitude: 50, speed: 8),
            GPSTrackPoint(timestamp: start.addingTimeInterval(60), latitude: 36.061, longitude: -5.712, altitude: 120, speed: 9),
            GPSTrackPoint(timestamp: start.addingTimeInterval(120), latitude: 36.062, longitude: -5.713, altitude: 95, speed: 7)
        ]
        flight.setGPSTrack(points)

        let url = try XCTUnwrap(IGCExporter.exportIGC(flight: flight, pilotName: "Xavier Kain"))
        XCTAssertEqual(url.pathExtension, "igc")

        let content = try String(contentsOf: url, encoding: .ascii)
        // En-tête A obligatoire
        XCTAssertTrue(content.hasPrefix("A"), "Le fichier doit commencer par un record A")
        // Un B record par point GPS
        let bRecords = content.split(separator: "\r\n").filter { $0.hasPrefix("B") }
        XCTAssertEqual(bRecords.count, 3, "Un B record par point GPS")
        // Le pilote figure dans les headers
        XCTAssertTrue(content.contains("Xavier Kain"))
        // Format d'un B record : B + HHMMSS + lat(8) + lon(9) + A/V + 5 + 5 chiffres
        let firstB = String(try XCTUnwrap(bRecords.first))
        XCTAssertGreaterThanOrEqual(firstB.count, 35)
        XCTAssertTrue(firstB.contains("N"), "La latitude nord doit être marquée N")
        XCTAssertTrue(firstB.contains("W"), "La longitude ouest doit être marquée W")

        try? FileManager.default.removeItem(at: url)
    }
}
