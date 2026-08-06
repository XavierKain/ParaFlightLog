//
//  SharedModels.swift
//  ParaFlightLog
//
//  DTOs (Data Transfer Objects) shared between iOS and Watch
//  Target: iOS + Watch
//

import Foundation

// MARK: - FlightType
/// Category of a flight session. Shared between iOS and Watch.
nonisolated enum FlightType: String, Codable, CaseIterable, Identifiable {
    case soaring = "Soaring"
    case thermal = "Thermal"
    case airSurfing = "Air Surfing"
    case speedflying = "Speedflying"
    case groundHandling = "Ground Handling"
    case other = "Other"

    var id: String { rawValue }

    /// SF Symbol used to represent this flight type.
    var symbolName: String {
        switch self {
        case .soaring: return "wind"
        case .thermal: return "sun.max"
        case .airSurfing: return "figure.surfing"
        case .speedflying: return "hare.fill"
        case .groundHandling: return "figure.walk"
        case .other: return "questionmark.circle"
        }
    }

    /// Short description shown next to the icon in the flight-type picker.
    var subtitle: String {
        switch self {
        case .soaring: return "Ridge / dynamic lift"
        case .thermal: return "Climbing in thermals"
        case .airSurfing: return "Speed riding / acro"
        case .speedflying: return "Small wing, fast descents"
        case .groundHandling: return "Kiting on the ground"
        case .other: return "Anything else"
        }
    }
}

// MARK: - ReportStatus
/// What a pilot reports about a spot right now. Raw values are the exact
/// strings stored in `spot_reports.status`.
///
/// Lives HERE (and not in ConditionReportService.swift) because the Apple
/// Watch posts condition reports too, and this root-level file is the only
/// source file compiled into BOTH the iOS app and the Watch app targets.
/// The SwiftUI `color` used by the iPhone chips stays iOS-only, as an
/// extension in ConditionReportService.swift — this file must not import
/// SwiftUI.
nonisolated enum ReportStatus: String, CaseIterable, Identifiable, Sendable {
    case flying
    case goingToFly
    case flyable
    case notFlyable
    case tooStrong

    var id: String { rawValue }

    /// Emoji shown on the status chip.
    var emoji: String {
        switch self {
        case .flying: return "🪂"
        case .goingToFly: return "🚗"
        case .flyable: return "✅"
        case .notFlyable: return "🚫"
        case .tooStrong: return "💨"
        }
    }

    /// Short chip label.
    var label: String {
        switch self {
        case .flying: return "Flying now"
        case .goingToFly: return "Going to fly"
        case .flyable: return "Flyable"
        case .notFlyable: return "Not flyable"
        case .tooStrong: return "Too strong"
        }
    }
}

// MARK: - WindForce
/// Rough wind strength reported alongside the status. Raw values are the
/// exact strings stored in `spot_reports.windForce` (unchanged — only the
/// labels/hints are recalibrated for free flight, in KNOTS).
///
/// Free-flight scale (paraglider / parakite), knots reference:
///   calm       < 5 kt   — hard to soar
///   light      5–11 kt
///   moderate   11–18 kt — sweet spot
///   strong     18–25 kt — flyable for parakite / experienced
///   veryStrong 25–30 kt
///   tooMuch    > 30 kt
///
/// Shared with the Watch (see ReportStatus). The unit-aware
/// `rangeHint(in:)` needs `WindUnit`, an iPhone-only preference, so it
/// stays in ConditionReportService.swift; the Watch uses `knotsHint`.
nonisolated enum WindForce: String, CaseIterable, Identifiable, Sendable {
    case calm
    case light
    case moderate
    case strong
    case veryStrong
    case tooMuch

    var id: String { rawValue }

    /// Short chip label.
    var label: String {
        switch self {
        case .calm: return "Calm"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .strong: return "Strong"
        case .veryStrong: return "Very strong"
        case .tooMuch: return "Too much"
        }
    }

    /// The band's knots range as (lower, upper); nil bounds are open-ended.
    var knotsRange: (lower: Int?, upper: Int?) {
        switch self {
        case .calm: return (nil, 5)
        case .light: return (5, 11)
        case .moderate: return (11, 18)
        case .strong: return (18, 25)
        case .veryStrong: return (25, 30)
        case .tooMuch: return (30, nil)
        }
    }

    /// Unit-free range hint in knots, e.g. "11–18 kt". Used where the
    /// iPhone's km/h-or-knots preference is not available (the Watch).
    var knotsHint: String {
        switch knotsRange {
        case let (nil, upper?): return "< \(upper) kt"
        case let (lower?, nil): return "> \(lower) kt"
        case let (lower?, upper?): return "\(lower)–\(upper) kt"
        case (nil, nil): return ""
        }
    }
}

// MARK: - ConditionVocabulary

/// How a wind band is PHRASED, given the kind of flying that was done.
///
/// The stored values never change — a report always travels as a `WindForce`
/// raw value, so the backend, the iPhone chips and any other client keep
/// working untouched. Only the words on screen move: telling a thermal pilot
/// their day was "moderate wind" describes the wrong thing entirely, when what
/// they actually know is whether it was working.
///
/// Shared, because the Watch asks the question and the iPhone renders the
/// answer.
nonisolated enum ConditionVocabulary {

    /// Bands offered right after a flight. Four is what fits a wrist without
    /// scrolling, and they span the range a pilot who just landed can actually
    /// distinguish — the finer bands only make sense when you are standing at
    /// the launch watching the windsock.
    static let postFlightForces: [WindForce] = [.light, .moderate, .strong, .tooMuch]

    /// The question, phrased for what the pilot was doing.
    static func postFlightQuestion(for flightType: FlightType?) -> String {
        switch flightType {
        case .thermal: return String(localized: "How were the thermals?")
        case .groundHandling: return String(localized: "How was the wind?")
        default: return String(localized: "How were the conditions?")
        }
    }

    /// Label for one band. Thermal flying gets its own words; everything else
    /// keeps the wind wording, which is what `WindForce.label` already says.
    static func label(_ force: WindForce, for flightType: FlightType?) -> String {
        guard flightType == .thermal else { return force.label }
        switch force {
        case .calm: return String(localized: "Nothing working")
        case .light: return String(localized: "Light thermals")
        case .moderate: return String(localized: "Working well")
        case .strong: return String(localized: "Strong and punchy")
        case .veryStrong: return String(localized: "Very punchy")
        case .tooMuch: return String(localized: "Too rough")
        }
    }

    /// Status implied by the band the pilot picked. They flew it, so it was
    /// flyable — unless they say it was over the top, which is the one answer
    /// worth flagging to everyone else.
    static func impliedStatus(for force: WindForce) -> ReportStatus {
        force == .tooMuch ? .tooStrong : .flyable
    }
}

// MARK: - ConditionReportOutcome
/// Verdict of a condition report posted FROM THE WATCH. The Watch has no
/// auth, no spot list, no cooldown state and no network, so only the iPhone
/// can decide what happened — it answers the Watch's sendMessage with the
/// raw value of one of these.
///
/// The last three are produced by the Watch itself and never travel over the
/// wire (`noLocation` is also sent by the iPhone when a payload arrives with
/// no coordinates).
nonisolated enum ConditionReportOutcome: String, Sendable {
    /// The report row was created. The reply also carries the resolved spot name.
    case posted
    /// No Appwrite session on the iPhone.
    case notSignedIn
    /// The 10-minute per-spot submit cooldown is still running. The reply also
    /// carries the remaining seconds.
    case cooldown
    /// No known spot within 1.5 km of the Watch's coordinates.
    case noSpotNearby
    /// The community backend has no `spot_reports` table yet.
    case backendUnavailable
    /// Anything else (network, unreadable payload, unexpected Appwrite error).
    case failed
    /// Watch-side: WCSession is not activated or the iPhone is not reachable,
    /// so NOTHING was sent.
    case phoneUnreachable
    /// Watch-side: sendMessage itself failed, so the outcome is UNKNOWN.
    case sendFailed
    /// No usable GPS fix (Watch-side), or a payload with no coordinates (iPhone-side).
    case noLocation
}

// MARK: - WatchSyncKeys
/// Keys and message types used by the Watch <-> iPhone WatchConnectivity protocol.
/// Kept in one place so both sides always agree.
nonisolated enum WatchSyncKeys {
    /// Message/userInfo payload key holding an encoded FlightDTO.
    static let flightData = "flightData"
    /// applicationContext key holding encoded [WingDTO].
    static let wingsData = "wingsData"
    /// applicationContext key holding watch settings.
    static let settingsData = "settingsData"
    /// Reply key: Bool, true when the iPhone persisted the flight.
    static let flightSaved = "flightSaved"
    /// Payload key: unique flight id (UUID string) used for deduplication and acks.
    static let flightId = "flightId"
    /// Marker (Bool) set on a Watch->iPhone payload carrying settings changed on the Watch.
    static let watchSettingsUpdate = "watchSettingsUpdate"
    /// Version stamp (Double, seconds since 1970) of the settings in a payload,
    /// carried in BOTH directions. Whoever changed a setting last wins: a side
    /// applies an incoming payload only when this is strictly newer than its own
    /// stamp. Without it the two devices had no ordering, so the iPhone's
    /// push-on-activation silently overwrote a change made on the Watch.
    static let settingsUpdatedAt = "settingsUpdatedAt"
    /// Marker (Bool) on a best-effort Watch->iPhone sendMessage when a flight
    /// STARTS, alongside "latitude"/"longitude" (Double). Drives the live
    /// presence heartbeat (Step C2). Ephemeral by design: sent via
    /// sendMessage only, never through the persistent outbox.
    static let flightStarted = "flightStarted"

    // MARK: Condition report (Watch -> iPhone, always answered)

    /// Marker (Bool) on a Watch->iPhone sendMessage carrying a community
    /// CONDITION REPORT, alongside `conditionReportStatus`,
    /// `conditionReportWindForce` (String raw values) and "latitude" /
    /// "longitude" (Double) — the same raw-coordinates shape as
    /// `flightStarted`, so the Watch never needs the spot list or GeoHash.
    ///
    /// ALWAYS sent with a replyHandler: the Watch cannot know whether the
    /// pilot is signed in, whether a spot is in range or whether the submit
    /// cooldown is running, so a fake "sent!" would be a lie. Never queued
    /// through transferUserInfo — a condition report expires after 3 h and a
    /// stale one is worse than none.
    static let conditionReport = "conditionReport"
    /// Payload key: ReportStatus raw value (String).
    static let conditionReportStatus = "conditionReportStatus"
    /// Payload key: WindForce raw value (String).
    static let conditionReportWindForce = "conditionReportWindForce"
    /// Reply key: ConditionReportOutcome raw value (String).
    static let conditionReportOutcome = "conditionReportOutcome"
    /// Reply key: remaining submit cooldown in SECONDS (Double). Only present
    /// on a `.cooldown` outcome.
    static let conditionReportCooldown = "conditionReportCooldown"
    /// Reply key: name of the spot the report was filed under (String). Only
    /// present on a `.posted` outcome.
    static let conditionReportSpotName = "conditionReportSpotName"
    /// Marker (Bool) on a report sent from the post-flight summary rather than
    /// from the launch. It carries the TAKEOFF coordinates, and it supersedes
    /// the pre-flight report instead of being refused by the anti-spam
    /// cooldown: a pilot who reported before launching and again after landing
    /// is not spamming, they are saying how it actually turned out.
    static let conditionReportPostFlight = "conditionReportPostFlight"
}

// MARK: - SettingsSyncPolicy

/// The one rule both devices use to merge Watch-synced settings: the most
/// recent edit wins, wherever it was made. Kept as a pure function so the
/// policy is identical on iPhone and Watch and can be unit-tested — the bug it
/// replaces was that neither side had any notion of ordering, so the iPhone's
/// push-on-activation silently reverted a setting just changed on the Watch.
nonisolated enum SettingsSyncPolicy {
    /// - Parameters:
    ///   - incomingStamp: version stamp carried by the payload, nil when it
    ///     comes from a build that predates stamping.
    ///   - localStamp: stamp of the settings this device currently holds.
    /// - Returns: true when the payload should overwrite the local values.
    static func shouldApply(incomingStamp: Double?, localStamp: Double) -> Bool {
        // No stamp: an older app version on the other side. Accept it, so a
        // mixed-version pair keeps syncing the way it always did.
        guard let incomingStamp else { return true }
        // Strictly newer only: on a tie the local value stands, which stops two
        // devices bouncing the same payload back and forth.
        return incomingStamp > localStamp
    }
}

// MARK: - GPSTrackPoint
/// GPS point of a flight track
nonisolated struct GPSTrackPoint: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let speed: Double?       // Ground speed in m/s

    init(id: UUID = UUID(), timestamp: Date = Date(), latitude: Double, longitude: Double, altitude: Double? = nil, speed: Double? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
    }
}

// MARK: - WingDTO
/// DTO used to transfer wings from the iPhone to the Watch
nonisolated struct WingDTO: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let size: String?
    let type: String?
    let color: String?
    let photoData: Data?
    let displayOrder: Int

    init(id: UUID, name: String, size: String? = nil, type: String? = nil, color: String? = nil, photoData: Data? = nil, displayOrder: Int = 0) {
        self.id = id
        self.name = name
        self.size = size
        self.type = type
        self.color = color
        self.photoData = photoData
        self.displayOrder = displayOrder
    }

    /// Short display name for the Apple Watch.
    /// Strips a leading brand word when the name is long, e.g. "Moustache M1 2025 18m" -> "M1 2025 18m".
    var shortName: String {
        if name.hasPrefix("Moustache ") {
            return String(name.dropFirst("Moustache ".count))
        }
        return name
    }
}

// MARK: - FlightDTO
/// DTO used to transfer flights from the Watch to the iPhone
nonisolated struct FlightDTO: Codable, Identifiable {
    let id: UUID
    let wingId: UUID
    let startDate: Date
    let endDate: Date
    let durationSeconds: Int
    let createdAt: Date

    /// Flight category chosen by the pilot (raw value of FlightType)
    let flightType: String?

    // Tracking data
    let startAltitude: Double?      // Takeoff altitude (m)
    let maxAltitude: Double?        // Maximum altitude (m)
    let endAltitude: Double?        // Landing altitude (m)
    let totalDistance: Double?      // Total distance flown (m)
    let maxSpeed: Double?           // Maximum ground speed (m/s)
    let maxGForce: Double?          // Maximum G-force (G)

    // GPS track of the flight
    let gpsTrack: [GPSTrackPoint]?

    init(id: UUID = UUID(),
         wingId: UUID,
         startDate: Date,
         endDate: Date,
         durationSeconds: Int,
         createdAt: Date = Date(),
         flightType: String? = nil,
         startAltitude: Double? = nil,
         maxAltitude: Double? = nil,
         endAltitude: Double? = nil,
         totalDistance: Double? = nil,
         maxSpeed: Double? = nil,
         maxGForce: Double? = nil,
         gpsTrack: [GPSTrackPoint]? = nil) {
        self.id = id
        self.wingId = wingId
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.flightType = flightType
        self.startAltitude = startAltitude
        self.maxAltitude = maxAltitude
        self.endAltitude = endAltitude
        self.totalDistance = totalDistance
        self.maxSpeed = maxSpeed
        self.maxGForce = maxGForce
        self.gpsTrack = gpsTrack
    }
}

// MARK: - FlightActivityAttributes
//
// Lives HERE (and not in ParaFlightLog/ or ParaFlightLogWidgetExtension/)
// on purpose: this root-level file is the only source file explicitly
// compiled into BOTH the iOS app target and the widget extension target
// (pbxproj Sources phases: app 25C97992, widget extension 25145C44, watch
// app 25C97990), so both sides share ONE definition — ActivityKit matches
// activities by attributes type name + coding, so app and widget must agree.
//
// The whole block is compile-guarded: ActivityKit does not exist on watchOS
// (the current widget extension and the watch app build with SDKROOT =
// watchos), so the type simply vanishes from those targets.
#if canImport(ActivityKit)
import ActivityKit

/// Attributes of the Live Activity shown while a phone-tracked flight runs.
/// Static data (wing, flight type) is fixed at start; everything that can
/// change in-flight lives in `ContentState`.
nonisolated struct FlightActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        /// Elapsed flight time at the moment of the push (the visible timer
        /// ticks by itself via Text(timerInterval:), anchored to startDate).
        var elapsedSeconds: Int
        /// Current altitude in meters (GPS or simulator), nil when unknown.
        var altitude: Double?
        /// Current vertical speed in m/s (vario), nil when the vario is off.
        var verticalSpeed: Double?
        /// Takeoff spot name; carries a "(Simulation)" suffix for simulated flights.
        var spotName: String
        /// Flight start — the anchor for the self-ticking timer.
        var startDate: Date
    }

    /// Name of the wing being flown (fixed for the whole activity).
    var wingName: String
    /// Raw value of the FlightType chosen by the pilot.
    var flightType: String
}
#endif
