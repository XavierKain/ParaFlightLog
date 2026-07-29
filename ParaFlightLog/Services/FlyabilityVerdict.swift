//
//  FlyabilityVerdict.swift
//  ParaFlightLog
//
//  The EXPLAINED flyability verdict.
//
//  `Flyability` alone says green/orange/red. That is the least interesting part
//  of what we already compute: by the time a rating comes out we also know which
//  single factor decided it, and — crucially — WHOSE limit that factor breaks.
//  A red because the wind is 40 km/h at a spot where the pilot has flown 8-22
//  km/h is a completely different message from a red against a generic 35 km/h
//  threshold, and only one of the two is worth trusting.
//
//  So a verdict carries:
//    - the rating (unchanged semantics — see `FlyabilityVerdict.make`)
//    - the ONE limiting factor, never a list: naming three things at once is
//      the same as naming none
//    - the basis: learned observations / ParaglidingEarth seed / the pilot's
//      configured directions / nothing
//
//  Pure value logic, no actor isolation, no networking — so the rules stay
//  directly unit-testable (see `FlyabilityTests`).
//  Target: iOS only
//

import Foundation

// MARK: - Basis

/// Where the limits a verdict was rated against come from — the "whose limit is
/// this" half of an explained verdict.
enum FlyabilityBasis: Equatable {
    /// Real takeoff-wind observations at this spot (the pilot's own flights
    /// merged with community shares — hence "recorded", never "your").
    case learned(flights: Int)
    /// The nearest ParaglidingEarth site's declared orientations.
    case seeded
    /// The launch directions the pilot configured on the spot.
    case configured
    /// Nothing spot-specific is known.
    case unknown
}

// MARK: - Limiting factor

/// The single factor that decides a verdict. Deliberately one case per *reason*
/// a pilot would give out loud, not one per variable.
enum FlyabilityFactor: Equatable {
    /// The wind is coming from a sector this spot does not work with.
    /// `worksWith` is in compass order (N → NW).
    case direction(from: String, worksWith: [String])
    /// Sustained wind over the top of the band.
    /// `band` is the learned speed range when there is one; without it the
    /// verdict falls back to `defaultLimit` (the classic threshold).
    case windTooStrong(kmh: Double, band: ClosedRange<Double>?, defaultLimit: Double)
    /// Sustained wind under the bottom of a LEARNED band. Only a learned band
    /// has a floor — the classic thresholds are one-sided, so this never comes
    /// from a seeded or configured window.
    case windTooLight(kmh: Double, band: ClosedRange<Double>)
    /// Gusts over the limit, with the limit's provenance.
    case gusts(kmh: Double, limit: Double, isLearned: Bool)
}

// MARK: - Verdict

/// A flyability rating plus the reason for it.
struct FlyabilityVerdict: Equatable {
    let rating: Flyability
    /// The one factor that decides the rating. Nil when the rating is `.good`
    /// (nothing is limiting) or `.unknown` (nothing is known).
    let limitingFactor: FlyabilityFactor?
    let basis: FlyabilityBasis
    /// Compass point the rated wind blows FROM, for the good-case headline.
    let windFrom: String?
    /// Sustained wind the verdict rated, km/h.
    let windSpeed: Double?

    /// A verdict for a spot nothing is known about.
    static let unknown = FlyabilityVerdict(
        rating: .unknown, limitingFactor: nil, basis: .unknown, windFrom: nil, windSpeed: nil
    )

    /// A verdict for a spot we DO know, rated against wind data we don't have.
    static func noWindData(basis: FlyabilityBasis) -> FlyabilityVerdict {
        FlyabilityVerdict(rating: .unknown, limitingFactor: nil, basis: basis, windFrom: nil, windSpeed: nil)
    }
}

// MARK: - Assembling a verdict

extension FlyabilityVerdict {

    /// How badly one input breaks its limit.
    enum Severity: Int, Comparable {
        case ok = 0
        case marginal = 1
        case breaking = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One rated input: how bad it is, and how to phrase it if it turns out to
    /// be the limiting one. `factor` is nil for an input that cannot be blamed.
    struct Candidate {
        let severity: Severity
        let factor: FlyabilityFactor?

        init(_ severity: Severity, _ factor: FlyabilityFactor?) {
            self.severity = severity
            self.factor = factor
        }
    }

    /// Combines the three rated inputs into a rating and picks the single factor
    /// to blame.
    ///
    /// The rating rule is EXACTLY the one both engines have always used —
    /// `speed` and `gusts` are the two halves of what used to be a single
    /// `goodSpeeds`/`marginalSpeeds` pair, and `max` of the two reproduces it:
    ///   - good:     direction OK and both speeds OK
    ///   - marginal: direction OK with marginal speeds, or a borderline
    ///               direction with good speeds
    ///   - bad:      anything else
    /// Splitting them is what makes it possible to say *which* one is limiting.
    ///
    /// Blame goes to the worst input; ties break direction → gusts → speed,
    /// because that is the order in which a pilot would call the flight off.
    static func make(
        direction: Candidate,
        speed: Candidate,
        gusts: Candidate,
        basis: FlyabilityBasis,
        windFrom: String?,
        windSpeed: Double?
    ) -> FlyabilityVerdict {
        let speedsCombined = max(speed.severity, gusts.severity)

        let rating: Flyability
        if direction.severity == .ok && speedsCombined == .ok {
            rating = .good
        } else if (direction.severity == .ok && speedsCombined == .marginal)
                    || (direction.severity <= .marginal && speedsCombined == .ok) {
            rating = .marginal
        } else {
            rating = .bad
        }

        // Strictly-greater keeps the first of equals, so the array order IS the
        // tie-break rule.
        var limiting: Candidate?
        for candidate in [direction, gusts, speed] where candidate.severity != .ok {
            if candidate.severity > (limiting?.severity ?? .ok) {
                limiting = candidate
            }
        }

        return FlyabilityVerdict(
            rating: rating,
            limitingFactor: rating == .good ? nil : limiting?.factor,
            basis: basis,
            windFrom: windFrom,
            windSpeed: windSpeed
        )
    }
}

// MARK: - Wording

extension FlyabilityVerdict {

    /// One sentence naming the reason. Never a list — the whole point is that a
    /// pilot walks away with a single thing to check.
    var headline: String {
        if rating == .unknown {
            if case .unknown = basis {
                return String(localized: "No launch directions set for this spot yet.")
            }
            return String(localized: "No wind data for this moment.")
        }

        if let limitingFactor {
            return Self.phrase(limitingFactor, basis: basis)
        }

        // Good, with nothing limiting.
        guard let windFrom, let windSpeed else {
            return String(localized: "Conditions look flyable.")
        }
        return String(
            localized: "Wind from the \(Self.longName(windFrom)) at \(Self.kmh(windSpeed)) km/h — inside the window."
        )
    }

    /// Where the limits came from, for a caption under the headline. This is
    /// the line that makes the verdict trustworthy — or honestly weak.
    var basisNote: String? {
        switch basis {
        case .learned(let flights):
            // "recorded", not "your": the window merges the pilot's own flights
            // with community observations at the same spot.
            return String(localized: "Learned from \(flights) flights recorded at this spot.")
        case .seeded:
            return String(localized: "From this site's orientations on ParaglidingEarth.")
        case .configured:
            return String(localized: "From the launch directions you set for this spot.")
        case .unknown:
            return nil
        }
    }

    /// Phrasing for one factor. The direction wording changes with the basis so
    /// the sentence never implies more authority than the data has.
    private static func phrase(_ factor: FlyabilityFactor, basis: FlyabilityBasis) -> String {
        switch factor {
        case .direction(let from, let worksWith):
            let source = Self.longName(from)
            let list = Self.list(worksWith)
            switch basis {
            case .learned:
                return String(localized: "Wind is from the \(source) — you fly here in \(list).")
            case .seeded:
                return String(localized: "Wind is from the \(source) — this site faces \(list).")
            case .configured, .unknown:
                return String(localized: "Wind is from the \(source) — you set this launch to \(list).")
            }

        case .windTooStrong(let kmh, let band, let defaultLimit):
            if let band {
                return String(
                    localized: "\(Self.kmh(kmh)) km/h — stronger than the \(Self.kmh(band.lowerBound))–\(Self.kmh(band.upperBound)) km/h flown here."
                )
            }
            return String(localized: "\(Self.kmh(kmh)) km/h — over the \(Self.kmh(defaultLimit)) km/h limit.")

        case .windTooLight(let kmh, let band):
            return String(
                localized: "\(Self.kmh(kmh)) km/h — lighter than the \(Self.kmh(band.lowerBound))–\(Self.kmh(band.upperBound)) km/h flown here."
            )

        case .gusts(let kmh, let limit, let isLearned):
            if isLearned {
                return String(localized: "Gusting \(Self.kmh(kmh)) km/h — above what flights here suggest (\(Self.kmh(limit)) km/h).")
            }
            return String(localized: "Gusting \(Self.kmh(kmh)) km/h — over the \(Self.kmh(limit)) km/h limit.")
        }
    }

    // MARK: Formatting helpers

    private static func kmh(_ value: Double) -> Int { Int(value.rounded()) }

    /// Spoken compass name — "South", not "S". Worth the table: the headline is
    /// a sentence, and a sentence with a bare "S" in it reads like a code.
    static func longName(_ point: String) -> String {
        switch point {
        case "N": return String(localized: "North")
        case "NE": return String(localized: "North-East")
        case "E": return String(localized: "East")
        case "SE": return String(localized: "South-East")
        case "S": return String(localized: "South")
        case "SW": return String(localized: "South-West")
        case "W": return String(localized: "West")
        case "NW": return String(localized: "North-West")
        default: return point
        }
    }

    /// "W", "W and NW", "W, NW and N" — compass points already in compass order.
    static func list(_ points: [String]) -> String {
        switch points.count {
        case 0: return String(localized: "no direction")
        case 1: return points[0]
        case 2: return String(localized: "\(points[0]) and \(points[1])")
        default:
            let head = points.dropLast().joined(separator: ", ")
            return String(localized: "\(head) and \(points[points.count - 1])")
        }
    }

    /// Compass-ordered (N → NW) list of the sectors a window covers.
    static func orderedPoints(_ points: some Collection<String>) -> [String] {
        WeatherService.compassPoints.filter { points.contains($0) }
    }
}
