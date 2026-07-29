//
//  FlyabilityVerdictView.swift
//  ParaFlightLog
//
//  The explained verdict, on screen. A coloured dot answers "can I fly?" and
//  then leaves the pilot to guess; these views answer "why?" and "says who?" —
//  which is the only part that makes a red worth believing.
//
//  Two levels:
//    - `FlyabilityVerdictBadge`  — the capsule that already existed, unchanged
//    - `FlyabilityVerdictRow`    — badge + the single limiting factor + the
//                                  provenance caption
//  plus `SpotVerdictRow`, which loads the LEARNED verdict for a spot (async,
//  because the window merges community observations).
//  Target: iOS only
//

import SwiftUI

// MARK: - Badge

/// The short coloured capsule ("Flyable" / "Marginal" / "Not flyable").
struct FlyabilityVerdictBadge: View {
    let rating: Flyability

    var body: some View {
        Text(rating.displayLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(rating.displayColor)
            .background(rating.displayColor.opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - Row

/// Badge + the one limiting factor + where the limits come from.
///
/// The provenance caption is deliberately not optional-looking: a verdict built
/// on 14 recorded flights and a verdict built on two compass points the pilot
/// tapped once are worth very different amounts of trust, and hiding which one
/// you are looking at is the failure mode this whole feature exists to fix.
struct FlyabilityVerdictRow: View {
    let verdict: FlyabilityVerdict
    /// Hide the capsule when the caller already shows one nearby.
    var showsBadge: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if showsBadge {
                    FlyabilityVerdictBadge(rating: verdict.rating)
                } else {
                    Circle()
                        .fill(verdict.rating.displayColor)
                        .frame(width: 8, height: 8)
                }
                Text(verdict.headline)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = verdict.basisNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        [verdict.rating.displayLabel, verdict.headline, verdict.basisNote]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

// MARK: - Spot-loading wrapper

/// Loads the LEARNED verdict for a spot and shows it. Renders nothing until the
/// verdict arrives (the window may need a community fetch) and nothing at all
/// when the spot is `.unknown` with no basis — an empty caption beats a caption
/// that says "we don't know" on every screen.
struct SpotVerdictRow: View {
    let spot: Spot
    let windDirectionDeg: Double?
    let windSpeed: Double?
    let windGusts: Double?
    var showsBadge: Bool = true

    @Environment(DataController.self) private var dataController
    @State private var verdict: FlyabilityVerdict?

    var body: some View {
        Group {
            if let verdict, verdict.rating != .unknown || verdict.basisNote != nil {
                FlyabilityVerdictRow(verdict: verdict, showsBadge: showsBadge)
            }
        }
        .task(id: reloadKey) {
            verdict = await WeatherService.shared.verdictV2(
                for: spot,
                windDirectionDeg: windDirectionDeg,
                windSpeed: windSpeed,
                windGusts: windGusts,
                dataController: dataController
            )
        }
    }

    /// Recompute when the spot OR the rated conditions change — a refreshed
    /// forecast must not keep showing the previous hour's reason.
    private var reloadKey: String {
        let direction = windDirectionDeg.map { String(Int($0.rounded())) } ?? "-"
        let speed = windSpeed.map { String(Int($0.rounded())) } ?? "-"
        let gusts = windGusts.map { String(Int($0.rounded())) } ?? "-"
        return "\(spot.id)|\(direction)|\(speed)|\(gusts)"
    }
}

// MARK: - Preview

#Preview("Learned red") {
    Form {
        FlyabilityVerdictRow(verdict: FlyabilityVerdict(
            rating: .bad,
            limitingFactor: .direction(from: "S", worksWith: ["W", "NW"]),
            basis: .learned(flights: 14),
            windFrom: "S",
            windSpeed: 22
        ))
        FlyabilityVerdictRow(verdict: FlyabilityVerdict(
            rating: .marginal,
            limitingFactor: .gusts(kmh: 46, limit: 40, isLearned: false),
            basis: .configured,
            windFrom: "W",
            windSpeed: 24
        ))
        FlyabilityVerdictRow(verdict: FlyabilityVerdict(
            rating: .bad,
            limitingFactor: .windTooLight(kmh: 4, band: 12...24),
            basis: .learned(flights: 31),
            windFrom: "W",
            windSpeed: 4
        ))
        FlyabilityVerdictRow(verdict: FlyabilityVerdict(
            rating: .good,
            limitingFactor: nil,
            basis: .seeded,
            windFrom: "NW",
            windSpeed: 18
        ))
    }
}
