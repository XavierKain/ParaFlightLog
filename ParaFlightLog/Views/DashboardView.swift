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
    @Query(sort: \Spot.name) private var spots: [Spot]

    /// Switches the TabView to another tab (provided by ContentView).
    let onOpenTab: (Int) -> Void

    @State private var stats = FlightStats()
    @State private var showingFlightDetail: Flight?
    @State private var showingConditionReport = false
    @State private var showingNearbySpots = false
    @State private var showingNotificationCenter = false

    /// Observed singleton — the bell badge tracks the unread count live.
    private var inbox: NotificationInboxService { NotificationInboxService.shared }

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

    // Spot whose current conditions the dashboard shows: the most-flown
    // located Spot (by hours), resolved through the flights' actual spot
    // relationship — a first-name-match lookup could pick the wrong Spot
    // when two spots share a name.
    private var conditionsSpot: Spot? {
        var hoursBySpotID: [UUID: Double] = [:]
        var spotByID: [UUID: Spot] = [:]
        for flight in flights {
            guard let spot = flight.spot, spot.latitude != nil, spot.longitude != nil else { continue }
            spotByID[spot.id] = spot
            hoursBySpotID[spot.id, default: 0] += Double(flight.durationSeconds) / 3600.0
        }
        guard let best = hoursBySpotID.max(by: { $0.value < $1.value }) else { return nil }
        return spotByID[best.key]
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
                            // Report conditions: the fastest way to the "how does
                            // it fly right now?" flow — spots near me, or drop a
                            // new one. Kept at the very top so it's never buried
                            // in the conditions card lower down.
                            Button {
                                showingNearbySpots = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "wind")
                                        .font(.system(size: 26))
                                        .foregroundStyle(.white)
                                        .frame(width: 46, height: 46)
                                        .background(.teal, in: RoundedRectangle(cornerRadius: 11))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Report conditions")
                                            .font(.headline)
                                            .foregroundStyle(Color.primary)
                                        Text("Spots near you — see how it flies, or add a new one")
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

                            // Global stats — tappable: in phone-tracker mode the
                            // Stats tab gives up its slot to the Timer, so this
                            // is how the full stats stay one tap away.
                            Button {
                                onOpenTab(2)
                            } label: {
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
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("See all stats")

                            // Explore the community (Step D): spots map/list
                            // with live activity, pushed onto this stack.
                            NavigationLink {
                                ExploreView()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 30))
                                        .foregroundStyle(.blue)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Explore")
                                            .font(.headline)
                                            .foregroundStyle(Color.primary)
                                        Text("Community spots, live activity & conditions")
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

                            // Community Feed (Step E): latest flights from the
                            // pilots you follow, pushed onto this stack.
                            NavigationLink {
                                CommunityFeedView()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.2")
                                        .font(.system(size: 30))
                                        .foregroundStyle(.purple)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Community Feed")
                                            .font(.headline)
                                            .foregroundStyle(Color.primary)
                                        Text("Latest flights from pilots you follow")
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

                            // My Spots: reach the local spots list (each spot's
                            // weather, forecast & flyability) without going
                            // through Settings or Explore.
                            NavigationLink {
                                SpotsManagementView()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .font(.system(size: 30))
                                        .foregroundStyle(.red)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("My Spots")
                                            .font(.headline)
                                            .foregroundStyle(Color.primary)
                                        Text("Your spots' weather, forecast & flyability")
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

                            // Current conditions at the pilot's main spot —
                            // pushes the full spot page (forecast, flyability,
                            // your stats).
                            if let spot = conditionsSpot {
                                HStack {
                                    Text("Conditions")
                                        .font(.headline)
                                    Spacer()
                                    // Quick 2-tap condition report for the
                                    // pilot's main located spot.
                                    Button {
                                        showingConditionReport = true
                                    } label: {
                                        Label("Report", systemImage: "megaphone.fill")
                                            .font(.subheadline)
                                            .labelStyle(.titleAndIcon)
                                    }
                                }
                                NavigationLink {
                                    SpotDetailView(spot: spot)
                                } label: {
                                    DashboardConditionsCard(spot: spot)
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
            .toolbar {
                // Notification center: unread count badges the bell.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingNotificationCenter = true
                    } label: {
                        Image(systemName: "bell")
                            .overlay(alignment: .topTrailing) {
                                if inbox.unreadCount > 0 {
                                    Text(inbox.unreadCount > 99 ? "99+" : "\(inbox.unreadCount)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.red, in: Capsule())
                                        .offset(x: 10, y: -8)
                                        .fixedSize()
                                }
                            }
                    }
                    .accessibilityLabel(
                        inbox.unreadCount > 0
                            ? "Notifications, \(inbox.unreadCount) unread"
                            : "Notifications"
                    )
                }
                // Same destination as the Explore card — also reachable from
                // the empty-logbook welcome state.
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ExploreView()
                    } label: {
                        Image(systemName: "globe")
                    }
                    .accessibilityLabel("Explore community spots")
                }
            }
            // Token (not just count) so in-place flight edits refresh the totals
            .task(id: flights.statsChangeToken) {
                stats = dataController.computeStats(from: flights)
            }
            // Recover reports whose push was never delivered/tapped (best-effort).
            .task {
                await inbox.syncMissed(dataController: dataController)
            }
            .sheet(item: $showingFlightDetail) { flight in
                FlightDetailView(flight: flight)
            }
            .sheet(isPresented: $showingNearbySpots) {
                NearbySpotsView()
            }
            .sheet(isPresented: $showingNotificationCenter) {
                NotificationCenterView()
                    .environment(dataController)
            }
            .sheet(isPresented: $showingConditionReport) {
                if let spot = conditionsSpot,
                   let lat = spot.latitude, let lon = spot.longitude,
                   let key = spot.communitySpotKey
                       ?? CommunitySpotKey.make(name: spot.name, latitude: lat, longitude: lon) {
                    ConditionReportSheet(spot: spot, spotKey: key, spotName: spot.name)
                }
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

// MARK: - DashboardConditionsCard

/// Current wind conditions at the pilot's main spot, with a flyability badge
/// rated against the spot's configured launch directions. Presented inside a
/// NavigationLink that pushes the spot detail (weather section + forecast).
private struct DashboardConditionsCard: View {
    let spot: Spot

    @State private var weather: SpotWeather?
    @State private var loadFailed = false

    var body: some View {
        HStack(spacing: 12) {
                Image(systemName: "wind")
                    .font(.system(size: 30))
                    .foregroundStyle(.teal)

                VStack(alignment: .leading, spacing: 3) {
                    Text(spot.name)
                        .font(.headline)
                        .foregroundStyle(Color.primary)

                    if let weather {
                        HStack(spacing: 6) {
                            if let speed = weather.windSpeed {
                                Text("\(Int(speed.rounded())) km/h")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                            }
                            if let gusts = weather.windGusts {
                                Text("gusts \(Int(gusts.rounded()))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let direction = weather.windDirectionDeg {
                                HStack(spacing: 2) {
                                    // Wind comes FROM `direction`; arrow shows the flow.
                                    Image(systemName: "location.north.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.teal)
                                        .rotationEffect(.degrees(direction + 180))
                                    Text(WeatherService.degreesToCompass(direction))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text(loadFailed ? "Conditions unavailable" : "Loading conditions…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let weather {
                    let flyability = WeatherService.flyability(
                        windDirectionDeg: weather.windDirectionDeg,
                        windSpeed: weather.windSpeed,
                        windGusts: weather.windGusts,
                        spotDirections: spot.windDirections
                    )
                    if flyability != .unknown {
                        Text(flyability.displayLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(flyability.displayColor)
                            .background(flyability.displayColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: spot.id) {
            await load()
        }
    }

    private func load() async {
        loadFailed = false
        do {
            weather = try await WeatherService.shared.weather(
                latitude: spot.latitude ?? 0, longitude: spot.longitude ?? 0
            )
        } catch {
            logWarning("Dashboard conditions failed: \(error.localizedDescription)", category: .weather)
            loadFailed = weather == nil
        }
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
