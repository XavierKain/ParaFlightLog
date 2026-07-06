//
//  DashboardView.swift
//  ParaFlightLog
//
//  Home tab: the essentials of every other tab at a glance —
//  global stats, latest flight, most-used wing and top spot.
//  Target: iOS only
//

import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(DataController.self) private var dataController
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    /// Switches the TabView to another tab (provided by ContentView).
    let onOpenTab: (Int) -> Void

    @State private var stats = FlightStats()
    @State private var showingFlightDetail: Flight?

    // Most recently flown wing (flights are sorted newest first), with its
    // aggregate hours. "Most-used" would surface long-retired wings after a
    // full history import.
    private var topWing: (wing: Wing, hours: Double)? {
        guard let wing = flights.first(where: { $0.wing != nil })?.wing else { return nil }
        return (wing, stats.hoursByWing[wing.id] ?? 0)
    }

    // Top spot by hours
    private var topSpot: (name: String, hours: Double, count: Int)? {
        guard let best = stats.hoursBySpot.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value, stats.countBySpot[best.key] ?? 0)
    }

    // Hours flown this calendar year
    private var hoursThisYear: Double {
        let calendar = Calendar.current
        return flights
            .filter { calendar.isDate($0.startDate, equalTo: Date(), toGranularity: .year) }
            .reduce(0.0) { $0 + Double($1.durationSeconds) / 3600.0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if flights.isEmpty {
                    ContentUnavailableView(
                        "Welcome to SoarX",
                        systemImage: "wind",
                        description: Text("Your dashboard fills up as you log flights. Start with your Watch, or add a flight manually from the Flights tab.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Global stats
                            HStack(spacing: 12) {
                                DashboardStatCard(
                                    value: formatHoursValue(stats.totalHours),
                                    label: "Total hours",
                                    symbol: "clock.fill",
                                    color: .blue
                                )
                                DashboardStatCard(
                                    value: "\(stats.totalCount)",
                                    label: "Flights",
                                    symbol: "airplane",
                                    color: .green
                                )
                                DashboardStatCard(
                                    value: formatHoursValue(hoursThisYear),
                                    label: "This year",
                                    symbol: "calendar",
                                    color: .orange
                                )
                            }

                            // Latest flight (reuses the featured card)
                            if let latest = flights.first {
                                sectionHeader("Latest flight", tab: 0)
                                LatestFlightCard(flight: latest)
                                    .onTapGesture {
                                        showingFlightDetail = latest
                                    }
                            }

                            // Most-used wing
                            if let top = topWing {
                                sectionHeader("Current wing", tab: 1)
                                Button {
                                    onOpenTab(1)
                                } label: {
                                    HStack(spacing: 12) {
                                        CachedImage(
                                            data: top.wing.photoData,
                                            key: top.wing.id.uuidString,
                                            size: CGSize(width: 54, height: 54)
                                        ) {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill((top.wing.color ?? "Gray").toColor().opacity(0.3))
                                                .overlay {
                                                    Image(systemName: "wind")
                                                        .foregroundStyle((top.wing.color ?? "Gray").toColor())
                                                }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(top.wing.name)
                                                .font(.headline)
                                                .foregroundStyle(Color.primary)
                                            Text("\(formatHoursValue(top.hours)) flown • \(stats.countByWing[top.wing.id] ?? 0) flights")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(12)
                                    .background(Color(.secondarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                            }

                            // Top spot
                            if let spot = topSpot {
                                sectionHeader("Top spot", tab: 2)
                                Button {
                                    onOpenTab(2)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.system(size: 34))
                                            .foregroundStyle(.red)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(spot.name)
                                                .font(.headline)
                                                .foregroundStyle(Color.primary)
                                            Text("\(formatHoursValue(spot.hours)) • \(spot.count) flights")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(12)
                                    .background(Color(.secondarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Home")
            .background(Color(.systemGroupedBackground))
            // Token (not just count) so in-place flight edits refresh the totals
            .task(id: flights.statsChangeToken) {
                stats = dataController.computeStats(from: flights)
            }
            .sheet(item: $showingFlightDetail) { flight in
                FlightDetailView(flight: flight)
            }
        }
    }

    // MARK: - Helpers

    /// Section title with a "see all" affordance jumping to the related tab.
    private func sectionHeader(_ title: String, tab: Int) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button("See all") {
                onOpenTab(tab)
            }
            .font(.subheadline)
        }
    }

    /// "12h30" style from decimal hours.
    private func formatHoursValue(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        return m > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(h)h"
    }
}

// MARK: - DashboardStatCard

private struct DashboardStatCard: View {
    let value: String
    let label: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
