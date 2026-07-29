//
//  LiveWindBeaconRow.swift
//  ParaFlightLog
//
//  The forecast, checked against a real anemometer.
//
//  Shown next to the flyability verdict, never folded into it: this row is
//  allowed to say the forecast is wrong, which is only meaningful if the two
//  are visibly separate numbers.
//
//  When there is no beacon it says so — plainly, and without apologising. Our
//  spots are largely off the official-site map, which is exactly where the
//  beacon network thins out; a pilot who understands that understands why the
//  community reports exist.
//  Target: iOS only
//

import SwiftUI

struct LiveWindBeaconRow: View {
    let latitude: Double
    let longitude: Double
    /// Forecast sustained wind to compare against, km/h.
    let forecastSpeed: Double?

    @State private var check: LiveWindCheck?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let check {
                beaconRow(check)
            } else if didLoad {
                noBeaconRow
            }
        }
        .task(id: reloadKey) {
            check = await WindBeaconService.shared.liveCheck(
                latitude: latitude, longitude: longitude, forecastSpeed: forecastSpeed
            )
            didLoad = true
        }
    }

    // MARK: Rows

    private func beaconRow(_ check: LiveWindCheck) -> some View {
        let beacon = check.beacon
        return HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(tint(check.agreement))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(beacon.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text(Self.distance(beacon.distanceMeters))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(reading(beacon, agreement: check.agreement))
                    .font(.caption)
                    .foregroundStyle(tint(check.agreement))

                Text(Self.age(since: beacon.measuredAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var noBeaconRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("No live wind beacon nearby — pilot reports are the only ground truth here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    // MARK: Wording

    /// "34 km/h W — windier than the forecast".
    private func reading(_ beacon: WindBeacon, agreement: LiveWindCheck.Agreement) -> String {
        let speed = Int(beacon.windAverage.rounded())
        let measured = beacon.compass.map { String(localized: "\(speed) km/h \($0)") }
            ?? String(localized: "\(speed) km/h")

        switch agreement {
        case .windierThanForecast:
            return String(localized: "\(measured) — windier than the forecast")
        case .lighterThanForecast:
            return String(localized: "\(measured) — lighter than the forecast")
        case .agrees:
            // With no forecast to compare against, the reading stands alone
            // rather than claiming an agreement that was never tested.
            return forecastSpeed == nil ? measured : String(localized: "\(measured) — matches the forecast")
        }
    }

    private func tint(_ agreement: LiveWindCheck.Agreement) -> Color {
        agreement == .agrees ? .secondary : .orange
    }

    private var reloadKey: String {
        let speed = forecastSpeed.map { String(Int($0.rounded())) } ?? "-"
        return String(format: "%.3f,%.3f|%@", latitude, longitude, speed)
    }

    // MARK: Formatting

    /// "600 m" / "6.2 km" / "18 km".
    static func distance(_ meters: Double) -> String {
        if meters < 1000 {
            return String(localized: "\(Int(meters.rounded())) m away")
        }
        let km = meters / 1000
        if km < 10 {
            return String(localized: "\(String(format: "%.1f", km)) km away")
        }
        return String(localized: "\(Int(km.rounded())) km away")
    }

    /// "just now" / "6 min ago". Never a bare timestamp: what matters about a
    /// beacon reading is its age, and a clock time makes the reader do the
    /// subtraction.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return String(localized: "just now") }
        return String(localized: "\(Int((seconds / 60).rounded())) min ago")
    }
}

// MARK: - Preview

#Preview {
    Form {
        LiveWindBeaconRow(latitude: 44.5, longitude: -1.2, forecastSpeed: 20)
    }
}
