//
//  GeoHashTests.swift
//  ParaFlightLogTests
//
//  GeoHash encoder vectors + CommunitySpotKey identity rules.
//  Pure functions, no dependencies.
//

import Testing
@testable import ParaFlightLog

// MARK: - GeoHash encoder

@Suite struct GeoHashTests {

    @Test func encodesKnownVectors() {
        // Canonical reference values (geohash.org / Wikipedia)
        #expect(GeoHash.encode(latitude: 57.64911, longitude: 10.40744, precision: 11) == "u4pruydqqvj")
        #expect(GeoHash.encode(latitude: 48.669, longitude: -4.329, precision: 5) == "gbsuv")
        // Paris
        #expect(GeoHash.encode(latitude: 48.8566, longitude: 2.3522, precision: 6) == "u09tvw")
        // Tarifa
        #expect(GeoHash.encode(latitude: 36.0143, longitude: -5.6044, precision: 6) == "eykhbk")
    }

    @Test func encodesEquatorMeridianOrigin() {
        #expect(GeoHash.encode(latitude: 0, longitude: 0, precision: 6) == "s00000")
    }

    @Test func encodesNegativeLatitudeAndLongitude() {
        // Sydney: negative latitude
        #expect(GeoHash.encode(latitude: -33.8688, longitude: 151.2093, precision: 6) == "r3gx2f")
        // Both negative: the world's south-west corner
        #expect(GeoHash.encode(latitude: -90, longitude: -180, precision: 6) == "000000")
        // North-east corner
        #expect(GeoHash.encode(latitude: 90, longitude: 180, precision: 6) == "zzzzzz")
    }

    @Test func precisionControlsLength() {
        let full = GeoHash.encode(latitude: 48.8566, longitude: 2.3522, precision: 8)
        #expect(full.count == 8)
        for precision in 1...8 {
            let hash = GeoHash.encode(latitude: 48.8566, longitude: 2.3522, precision: precision)
            #expect(hash.count == precision)
            // A shorter geohash is always a prefix of a longer one for the same point
            #expect(full.hasPrefix(hash))
        }
        #expect(GeoHash.encode(latitude: 48.8566, longitude: 2.3522, precision: 6) == "u09tvw")
    }

    @Test func clampsOutOfRangeInput() {
        #expect(GeoHash.encode(latitude: 95, longitude: 2.3522, precision: 6)
                == GeoHash.encode(latitude: 90, longitude: 2.3522, precision: 6))
        #expect(GeoHash.encode(latitude: -100, longitude: 2.3522, precision: 6)
                == GeoHash.encode(latitude: -90, longitude: 2.3522, precision: 6))
        #expect(GeoHash.encode(latitude: 48.8566, longitude: 200, precision: 6)
                == GeoHash.encode(latitude: 48.8566, longitude: 180, precision: 6))
        #expect(GeoHash.encode(latitude: 48.8566, longitude: -200, precision: 6)
                == GeoHash.encode(latitude: 48.8566, longitude: -180, precision: 6))
    }

    @Test func rejectsInvalidInput() {
        #expect(GeoHash.encode(latitude: 48.8566, longitude: 2.3522, precision: 0) == "")
        #expect(GeoHash.encode(latitude: 48.8566, longitude: 2.3522, precision: -3) == "")
        #expect(GeoHash.encode(latitude: Double.nan, longitude: 2.3522, precision: 6) == "")
        #expect(GeoHash.encode(latitude: 48.8566, longitude: Double.infinity, precision: 6) == "")
    }
}

// MARK: - CommunitySpotKey

@Suite struct CommunitySpotKeyTests {

    @Test func keyFormatIsGeohash6DashSlug() throws {
        let key = try #require(CommunitySpotKey.make(name: "Punta Paloma", latitude: 36.0143, longitude: -5.6044))
        #expect(key == "eykhbk-punta-paloma")
        // Structural invariants: geohash prefix + "-" separator
        #expect(key.hasPrefix("eykhbk-"))
        #expect(key.count <= CommunitySpotKey.maxLength)
    }

    @Test func stripsDiacritics() throws {
        // Saint-André-les-Alpes (real coordinates)
        let hash = GeoHash.encode(latitude: 43.9647, longitude: 6.5079, precision: 6)
        let key = try #require(CommunitySpotKey.make(name: "Saint-André-les-Alpes", latitude: 43.9647, longitude: 6.5079))
        #expect(key == "\(hash)-saint-andre-les-alpes")
    }

    @Test func cjkOnlyNameFallsBackToBareGeohash() throws {
        let key = try #require(CommunitySpotKey.make(name: "東京タワー", latitude: 35.6586, longitude: 139.7454))
        #expect(key == GeoHash.encode(latitude: 35.6586, longitude: 139.7454, precision: 6))
        #expect(key.count == 6)
        #expect(!key.contains("-"))
    }

    @Test func nilWithoutCoordinates() {
        #expect(CommunitySpotKey.make(name: "Punta Paloma", latitude: nil, longitude: -5.6044) == nil)
        #expect(CommunitySpotKey.make(name: "Punta Paloma", latitude: 36.0143, longitude: nil) == nil)
        #expect(CommunitySpotKey.make(name: "Punta Paloma", latitude: nil, longitude: nil) == nil)
        #expect(CommunitySpotKey.make(name: "Punta Paloma", latitude: Double.nan, longitude: -5.6044) == nil)
        #expect(CommunitySpotKey.make(name: "Punta Paloma", latitude: 36.0143, longitude: Double.infinity) == nil)
    }

    @Test func longNameIsTruncatedTo36AndNeverEndsWithDash() throws {
        let key = try #require(CommunitySpotKey.make(
            name: String(repeating: "a", count: 100),
            latitude: 36.0143, longitude: -5.6044
        ))
        #expect(key.count == CommunitySpotKey.maxLength)
        #expect(!key.hasSuffix("-"))
    }

    @Test func truncationLandingOnSeparatorIsTrimmed() throws {
        // slug budget = 36 - 6 (geohash) - 1 (separator) = 29 characters.
        // 28 "a"s + " b": the slug would be "aaa…a-b" (30) -> cut at 29 lands
        // exactly on the "-" -> must be trimmed away.
        let name = String(repeating: "a", count: 28) + " b"
        let key = try #require(CommunitySpotKey.make(name: name, latitude: 36.0143, longitude: -5.6044))
        #expect(!key.hasSuffix("-"))
        #expect(key == "eykhbk-" + String(repeating: "a", count: 28))
        #expect(key.count <= CommunitySpotKey.maxLength)
    }

    @Test func slugCollapsesSeparatorRuns() {
        #expect(CommunitySpotKey.slug(from: "Punta Paloma", maxLength: 29) == "punta-paloma")
        #expect(CommunitySpotKey.slug(from: " Saint-Gervais ", maxLength: 29) == "saint-gervais")
        #expect(CommunitySpotKey.slug(from: "Col du Télégraphe", maxLength: 29) == "col-du-telegraphe")
        #expect(CommunitySpotKey.slug(from: "A  --  B", maxLength: 29) == "a-b")
        #expect(CommunitySpotKey.slug(from: "Site 42", maxLength: 29) == "site-42")
        #expect(CommunitySpotKey.slug(from: "TARIFA", maxLength: 29) == "tarifa")
    }

    @Test func slugEdgeCases() {
        #expect(CommunitySpotKey.slug(from: "  --  ", maxLength: 29) == "")
        #expect(CommunitySpotKey.slug(from: "anything", maxLength: 0) == "")
        // Truncation that would leave a trailing "-" gets re-trimmed
        #expect(CommunitySpotKey.slug(from: "abc def", maxLength: 4) == "abc")
        #expect(CommunitySpotKey.slug(from: "abcdef ghij", maxLength: 6) == "abcdef")
    }
}
