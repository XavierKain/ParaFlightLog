//
//  GeoHash.swift
//  ParaFlightLog
//
//  Standard base32 geohash encoder + the global community spot key
//  derived from it (roadmap Step C0: spots must match across users).
//  Pure functions, no dependencies.
//  Target: iOS only
//

import Foundation

// MARK: - GeoHash

/// Standard geohash encoder (Gustavo Niemeyer's base32 alphabet).
///
/// Verified against canonical reference values:
///   encode(57.64911, 10.40744, 11) == "u4pruydqqvj"   (geohash.org example)
///   encode(48.669,   -4.329,    5) == "gbsuv"          (Wikipedia example)
///   encode(48.8566,   2.3522,   6) == "u09tvw"         (Paris)
///   encode(36.0143,  -5.6044,   6) == "eykhbk"         (Tarifa)
///   encode(-33.8688, 151.2093,  6) == "r3gx2f"         (Sydney)
///   encode(0, 0, 6)                == "s00000"
///   encode(-90, -180, 6)           == "000000"
///   encode(90, 180, 6)             == "zzzzzz"
nonisolated enum GeoHash {
    /// Geohash base32 alphabet (no "a", "i", "l", "o").
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// Encodes a coordinate as a geohash of `precision` characters.
    /// Precision 6 is a ~1.2 km x 0.6 km cell — the community spot
    /// granularity. Out-of-range inputs are clamped to valid ranges.
    static func encode(latitude: Double, longitude: Double, precision: Int) -> String {
        guard precision > 0, latitude.isFinite, longitude.isFinite else { return "" }

        let lat = min(max(latitude, -90), 90)
        let lon = min(max(longitude, -180), 180)

        var latRange = (min: -90.0, max: 90.0)
        var lonRange = (min: -180.0, max: 180.0)
        var hash = ""
        var evenBit = true // geohash interleaves bits starting with longitude
        var bit = 0
        var value = 0

        while hash.count < precision {
            if evenBit {
                let mid = (lonRange.min + lonRange.max) / 2
                if lon >= mid {
                    value = (value << 1) | 1
                    lonRange.min = mid
                } else {
                    value = value << 1
                    lonRange.max = mid
                }
            } else {
                let mid = (latRange.min + latRange.max) / 2
                if lat >= mid {
                    value = (value << 1) | 1
                    latRange.min = mid
                } else {
                    value = value << 1
                    latRange.max = mid
                }
            }
            evenBit.toggle()
            bit += 1
            if bit == 5 {
                hash.append(base32[value])
                bit = 0
                value = 0
            }
        }
        return hash
    }
}

// MARK: - CommunitySpotKey

/// Global identity of a flying spot across all users (roadmap Step C0):
/// `"<geohash precision 6>-<name slug>"`, e.g. "eykhbk-punta-paloma".
///
/// The key doubles as the Appwrite document ID of the shared community
/// spot, so it must satisfy Appwrite's ID rules: max 36 characters,
/// only a-z / 0-9 / hyphen here, and it must not start with a special
/// character (a geohash always starts with a base32 character).
nonisolated enum CommunitySpotKey {
    /// Geohash precision used for spot identity (~1 km cell).
    static let geohashPrecision = 6

    /// Appwrite document IDs are limited to 36 characters.
    static let maxLength = 36

    /// Builds the community key for a spot. Returns nil when the spot has
    /// no coordinates — a spot without a location can't be shared.
    static func make(name: String, latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else {
            return nil
        }

        let hash = GeoHash.encode(latitude: latitude, longitude: longitude, precision: geohashPrecision)
        guard !hash.isEmpty else { return nil }

        let slug = slug(from: name, maxLength: maxLength - hash.count - 1)
        return slug.isEmpty ? hash : "\(hash)-\(slug)"
    }

    /// Lowercased, diacritics-stripped slug: any run of non-alphanumeric
    /// (ASCII) characters collapses to a single "-", trimmed at both ends,
    /// truncated to `maxLength` (then re-trimmed so it never ends in "-").
    /// "Punta Paloma" -> "punta-paloma", "Saint-Gervais " -> "saint-gervais".
    /// May be empty (e.g. a name with no ASCII-representable characters).
    static func slug(from name: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }

        let folded = name
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var result = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            let isAlphanumeric = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAlphanumeric {
                if pendingSeparator && !result.isEmpty {
                    result.append("-")
                }
                pendingSeparator = false
                result.append(Character(scalar))
            } else {
                pendingSeparator = true
            }
            if result.count >= maxLength {
                break
            }
        }

        // A separator + character append can overshoot by one, and the cut
        // may then land on the separator — truncate first, trim after so
        // the slug never ends in "-".
        var truncated = String(result.prefix(maxLength))
        while truncated.hasSuffix("-") {
            truncated.removeLast()
        }
        return truncated
    }
}
