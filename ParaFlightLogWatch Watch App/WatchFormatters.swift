//
//  WatchFormatters.swift
//  ParaFlightLogWatch Watch App
//
//  Single home for the value formatters used across the Watch UI.
//  Compact formats so long values fit on 40-45mm screens.
//  Target: Watch only
//

import Foundation

enum WatchFormatters {
    /// Human duration: "1h05" or "12min"
    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }

    /// Timer style: "1:05:33" or "05:33"
    static func elapsedTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    /// Altitude with unit, whole meters: "1234m" or "--"
    static func altitude(_ altitude: Double?) -> String {
        guard let alt = altitude else { return "--" }
        return "\(Int(alt.rounded()))m"
    }

    /// Altitude without unit, whole meters: "1234" or "--"
    static func altitudeValue(_ altitude: Double?) -> String {
        guard let alt = altitude else { return "--" }
        return "\(Int(alt.rounded()))"
    }

    /// Distance, auto km with one decimal: "12.3km" or "850m"
    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1fkm", meters / 1000)
        } else {
            return "\(Int(meters.rounded()))m"
        }
    }

    /// Speed in km/h, whole number without unit: "45"
    static func speedKmh(_ metersPerSecond: Double) -> String {
        return "\(Int((metersPerSecond * 3.6).rounded()))"
    }

    /// G-force with one decimal: "2.1"
    static func gForce(_ g: Double) -> String {
        return String(format: "%.1f", g)
    }

    /// Signed vertical speed: "+1.2 m/s" / "-0.8 m/s"
    static func verticalSpeed(_ metersPerSecond: Double) -> String {
        return String(format: "%+.1f m/s", metersPerSecond)
    }
}
