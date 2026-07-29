//
//  ThermalOutlookView.swift
//  ParaFlightLog
//
//  One compact row for the day's thermal picture: how high thermals go, where
//  cumulus marks them (or that nothing will), and whether the day can
//  overdevelop.
//
//  Deliberately small and deliberately shy. SoarX is soaring-first — coastal
//  ridge and sea breeze — where CAPE and mixed-layer depth are close to
//  irrelevant. So this row lives on the spot page only, never on the dashboard,
//  and renders nothing at all on days that aren't thermal days.
//  Target: iOS only
//

import SwiftUI

struct ThermalOutlookRow: View {
    let outlook: ThermalOutlook

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: outlook.isBlue ? "sun.max" : "cloud.sun")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.primary)

                if outlook.hasOverdevelopmentRisk {
                    Label("Unstable — the day can overdevelop.", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// "Thermals to 1800 m · cloudbase 1200 m" / "Thermals to 900 m · blue".
    /// Heights are above ground, rounded to 50 m — a forecast mixed-layer depth
    /// is not accurate to the metre and should not pretend to be.
    private var summary: String {
        let top = Self.rounded(outlook.thermalTopMeters)
        if let base = outlook.cloudBaseMeters {
            return String(localized: "Thermals to \(top) m · cloudbase \(Self.rounded(base)) m")
        }
        return String(localized: "Thermals to \(top) m · blue, no cumulus")
    }

    private static func rounded(_ meters: Double) -> Int {
        Int((meters / 50).rounded()) * 50
    }
}

// MARK: - Preview

#Preview {
    Form {
        ThermalOutlookRow(outlook: ThermalOutlook(
            time: .now, thermalTopMeters: 1830, cloudBaseMeters: 1225, cape: 120
        ))
        ThermalOutlookRow(outlook: ThermalOutlook(
            time: .now, thermalTopMeters: 940, cloudBaseMeters: nil, cape: 40
        ))
        ThermalOutlookRow(outlook: ThermalOutlook(
            time: .now, thermalTopMeters: 2600, cloudBaseMeters: 1600, cape: 1400
        ))
    }
}
