//
//  SpotIntelligenceViews.swift
//  ParaFlightLog
//
//  Phase 2 UI — the "This spot flies when…" block on the spot detail page.
//  A compact 8-point wind rose (sectors tinted by how many flights support
//  them), the learned speed range, and a provenance caption. Reads its
//  window from SpotIntelligenceService; fails soft to a short hint.
//
//  `SpotLearnedWindowSection(spot:)` is the integration point embedded by
//  the spot detail List (see the coordination contract in the Phase 2 plan).
//  Target: iOS only
//

import SwiftUI

// MARK: - SpotLearnedWindowSection

/// A `Section` for the spot detail `List`: the spot's learned flying window.
///
/// NOTE: declared with module-internal access (not `public`) because its
/// `init(spot:)` takes the internal `Spot` model — a `public` initializer
/// cannot expose an internal type, and the embedding view lives in the same
/// app target, so internal access is both sufficient and required. The
/// coordination contract `SpotLearnedWindowSection(spot: spot)` is honoured.
struct SpotLearnedWindowSection: View {
    @Environment(DataController.self) private var dataController

    private let spot: Spot

    @State private var window: SpotIntelligenceService.LearnedWindow?
    @State private var isLoading = true

    init(spot: Spot) {
        self.spot = spot
    }

    var body: some View {
        Section {
            if let window {
                if window.isEmpty {
                    emptyRow
                } else {
                    windowRow(window)
                }
            } else if isLoading {
                loadingRow
            } else {
                emptyRow
            }
        } header: {
            Text("This spot flies when…")
                // On the header (a plain view), NOT the Section — matches the
                // SpotWeatherSection pattern so section rendering stays intact.
                .task { await load() }
        } footer: {
            if let window, !window.isEmpty {
                Text(provenanceText(window))
            }
        }
    }

    // MARK: Rows

    private func windowRow(_ window: SpotIntelligenceService.LearnedWindow) -> some View {
        HStack(alignment: .center, spacing: 16) {
            WindRose(sectors: window.sectors)
                .frame(width: 108, height: 108)
                .accessibilityLabel(roseAccessibilityText(window))

            VStack(alignment: .leading, spacing: 6) {
                Label(sectorsText(window), systemImage: "location.north.line")
                    .font(.subheadline.weight(.medium))
                    .labelStyle(.titleAndIcon)

                if let range = window.speedRange {
                    Label(speedText(range), systemImage: "wind")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Learning this spot…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyRow: some View {
        Text("No flights or launch directions yet — record a flight here, or set the launch directions above, to learn when it flies.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Text

    /// "Wind from SW, W, NW" — the learned sectors, busiest first.
    private func sectorsText(_ window: SpotIntelligenceService.LearnedWindow) -> String {
        let ordered = WeatherService.compassPoints
            .filter { window.sectors[$0] != nil }
            .sorted { (window.sectors[$0] ?? 0) > (window.sectors[$1] ?? 0) }
        guard !ordered.isEmpty else { return "Any direction" }
        return "Wind from " + ordered.joined(separator: ", ")
    }

    /// "12–25 km/h".
    private func speedText(_ range: ClosedRange<Double>) -> String {
        "\(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) km/h"
    }

    /// Provenance caption for the footer. `LocalizedStringKey` (not `String`)
    /// so the `^[…](inflect:)` grammar agreement is actually applied.
    private func provenanceText(_ window: SpotIntelligenceService.LearnedWindow) -> LocalizedStringKey {
        switch window.source {
        case .learned:
            return "Learned from ^[\(window.totalFlights) flight](inflect: true) at this spot."
        case .seeded:
            return "Seeded from ParaglidingEarth — refine it by flying here."
        case .configured:
            return "From the configured launch directions above."
        }
    }

    private func roseAccessibilityText(_ window: SpotIntelligenceService.LearnedWindow) -> String {
        "Wind rose. " + sectorsText(window) + (window.speedRange.map { ". " + speedText($0) } ?? "")
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        window = await SpotIntelligenceService.shared.learnedWindow(for: spot, dataController: dataController)
        isLoading = false
    }
}

// MARK: - WindRose

/// Compact 8-point wind rose: each 45° wedge is tinted by its sector's
/// relative support (flight count / PGE rating). North is up.
private struct WindRose: View {
    let sectors: [String: Int]

    private var maxCount: Int {
        max(sectors.values.max() ?? 1, 1)
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 1

            for (index, point) in WeatherService.compassPoints.enumerated() {
                let count = sectors[point] ?? 0
                // Screen angle: bearing (clockwise from North/up) → SwiftUI
                // angle (clockwise from +x/right) is bearing − 90°.
                let bearing = Double(index) * 45
                let start = Angle(degrees: bearing - 22.5 - 90)
                let end = Angle(degrees: bearing + 22.5 - 90)

                var wedge = Path()
                wedge.move(to: center)
                wedge.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                wedge.closeSubpath()

                let color: Color
                if count > 0 {
                    let intensity = Double(count) / Double(maxCount)
                    color = Color.accentColor.opacity(0.28 + 0.62 * intensity)
                } else {
                    color = Color.gray.opacity(0.12)
                }
                context.fill(wedge, with: .color(color))
            }

            // Thin separators + a hub for legibility.
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.gray.opacity(0.25)),
                lineWidth: 0.5
            )

            // Cardinal letters.
            let letters: [(String, CGVector)] = [
                ("N", CGVector(dx: 0, dy: -1)),
                ("E", CGVector(dx: 1, dy: 0)),
                ("S", CGVector(dx: 0, dy: 1)),
                ("W", CGVector(dx: -1, dy: 0))
            ]
            for (letter, dir) in letters {
                // resolve takes a Text; colour comes from the Canvas default
                // foreground (styling a Text yields a View, not a Text).
                let resolved = context.resolve(
                    Text(letter).font(.system(size: 9, weight: .semibold))
                )
                let point = CGPoint(
                    x: center.x + dir.dx * (radius - 7),
                    y: center.y + dir.dy * (radius - 7)
                )
                context.draw(resolved, at: point)
            }
        }
        .accessibilityHidden(true)
    }
}
