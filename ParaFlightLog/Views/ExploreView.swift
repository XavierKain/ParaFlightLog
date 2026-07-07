//
//  ExploreView.swift
//  ParaFlightLog
//
//  "Explore" screen (roadmap Step D v1): community spots on a map or list,
//  decorated with recent activity (shared flights, last 30 days) and live
//  presence, plus a detail sheet with community stats, current conditions
//  and the spot's recent shared flights.
//
//  Pushed from the Home dashboard (card + toolbar globe) — it assumes it
//  lives inside a NavigationStack and is NOT a tab (tab promotion is a
//  deferred roadmap decision). Everything community-backed fails soft:
//  an unconfigured backend shows a friendly full-screen placeholder.
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit

// MARK: - ExploreView

struct ExploreView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case map = "Map"
        case list = "List"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .map

    /// nil until the first successful load; kept (stale) on refresh failures.
    @State private var spots: [CommunitySpotSummary]?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var backendUnavailable = false

    @State private var selectedSpot: CommunitySpotSummary?

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    /// The camera is fitted to the spots once, on first load — not on every
    /// refresh, which would yank the map away from where the pilot panned.
    @State private var didFitCamera = false

    var body: some View {
        content
            .navigationTitle("Explore")
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading || backendUnavailable)
                    .accessibilityLabel("Refresh community spots")
                }
            }
            .task {
                await load(force: false)
            }
            .sheet(item: $selectedSpot) { spot in
                CommunitySpotSheet(summary: spot)
                    .presentationDetents([.medium, .large])
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if backendUnavailable {
            ContentUnavailableView(
                "Community",
                systemImage: "globe",
                description: Text("Community features are not available yet. Please check back later.")
            )
        } else if let spots {
            if spots.isEmpty {
                emptyState
            } else {
                loadedContent(spots)
            }
        } else if loadFailed {
            ContentUnavailableView {
                Label("Could not load community spots", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Retry") {
                    Task { await load(force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ProgressView("Loading community spots…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No community spots yet", systemImage: "globe")
        } description: {
            Text("Be the first to share your flights! Turn on sharing in Settings › Community and your spots will appear here for every pilot.")
        }
    }

    private func loadedContent(_ spots: [CommunitySpotSummary]) -> some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .map:
                mapView(spots)
            case .list:
                listView(spots)
            }
        }
    }

    // MARK: Map

    private func mapView(_ spots: [CommunitySpotSummary]) -> some View {
        Map(position: $cameraPosition) {
            ForEach(spots) { spot in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)) {
                    CommunitySpotBadge(spot: spot)
                        .onTapGesture {
                            selectedSpot = spot
                        }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
    }

    /// Region containing every spot, with padding. nil when there are none
    /// (the camera then stays on the user-location/automatic fallback).
    private static func fitRegion(_ spots: [CommunitySpotSummary]) -> MKCoordinateRegion? {
        guard let first = spots.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for spot in spots.dropFirst() {
            minLat = min(minLat, spot.latitude)
            maxLat = max(maxLat, spot.latitude)
            minLon = min(minLon, spot.longitude)
            maxLon = max(maxLon, spot.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: min(max((maxLat - minLat) * 1.4, 0.08), 120),
                longitudeDelta: min(max((maxLon - minLon) * 1.4, 0.08), 300)
            )
        )
    }

    // MARK: List

    private func listView(_ spots: [CommunitySpotSummary]) -> some View {
        List {
            Section {
                ForEach(Self.listOrder(spots)) { spot in
                    Button {
                        selectedSpot = spot
                    } label: {
                        spotRow(spot)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Activity from pilots who share their flights in Settings › Community.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await load(force: true)
        }
    }

    /// Live spots first, then the busiest of the last 30 days, then A→Z.
    private static func listOrder(_ spots: [CommunitySpotSummary]) -> [CommunitySpotSummary] {
        spots.sorted {
            if $0.pilotsFlyingNow != $1.pilotsFlyingNow {
                return $0.pilotsFlyingNow > $1.pilotsFlyingNow
            }
            if $0.flightsLast30Days != $1.flightsLast30Days {
                return $0.flightsLast30Days > $1.flightsLast30Days
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func spotRow(_ spot: CommunitySpotSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(spot.activityColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name)
                    .font(.headline)
                    .lineLimit(1)
                activityText(spot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func activityText(_ spot: CommunitySpotSummary) -> Text {
        let base = Text("^[\(spot.flightsLast30Days) flight](inflect: true) in the last 30 days")
        guard spot.pilotsFlyingNow > 0 else { return base }
        // Interpolating styled Text runs (iOS 26 replaces the deprecated Text `+`).
        let live = Text(" · 🪂 \(spot.pilotsFlyingNow) flying now")
            .foregroundStyle(.green)
            .bold()
        return Text("\(base)\(live)")
    }

    // MARK: Loading

    private func load(force: Bool) async {
        // Reentrancy guard: .task, .refreshable, Retry and the toolbar
        // button can overlap — a load fired while one is already in flight
        // would just duplicate the request and race the state updates.
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        do {
            let result = try await CommunityService.shared.exploreSpots(forceRefresh: force)
            spots = result
            backendUnavailable = false
            if !didFitCamera, let region = Self.fitRegion(result) {
                cameraPosition = .region(region)
                didFitCamera = true
            }
        } catch CommunityError.backendNotConfigured {
            backendUnavailable = true
        } catch {
            logWarning("Explore load failed: \(error.localizedDescription)", category: .community)
            // Keep showing the (stale) spots on a refresh failure.
            loadFailed = spots == nil
        }
        isLoading = false
    }
}

// MARK: - CommunitySpotBadge (map annotation)

/// Capsule with the spot name and its 30-day activity, tinted by how busy
/// the spot is (gray: none, blue: 1–9 flights, orange: 10+). A pulsing
/// green "🪂 N" badge sits on top while pilots are flying there right now.
private struct CommunitySpotBadge: View {
    let spot: CommunitySpotSummary

    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 3) {
            if spot.pilotsFlyingNow > 0 {
                Text("🪂 \(spot.pilotsFlyingNow)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
                    .scaleEffect(pulsing ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }

            HStack(spacing: 5) {
                Text(spot.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if spot.flightsLast30Days > 0 {
                    Text("\(spot.flightsLast30Days)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(spot.activityColor, in: Capsule())
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(spot.activityColor.opacity(0.7), lineWidth: 1.5)
            )
            .frame(maxWidth: 160)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "\(spot.name), \(spot.flightsLast30Days) flights in the last 30 days"
        if spot.pilotsFlyingNow > 0 {
            text += ", \(spot.pilotsFlyingNow) flying now"
        }
        return text
    }
}

private extension CommunitySpotSummary {
    /// Visual hierarchy of the last 30 days: gray (quiet), blue, orange (busy).
    var activityColor: Color {
        switch flightsLast30Days {
        case 0: return .gray
        case 1...9: return .blue
        default: return .orange
        }
    }
}

// MARK: - CommunitySpotSheet (spot detail)

/// Medium/large detail sheet for one community spot: live presence,
/// community stats, CURRENT weather only (community spots carry no launch
/// orientations, so no forecast rows and no flyability rating), the spot's
/// recent shared flights, and — when the pilot has a matching local spot —
/// a link to their own SpotDetailView.
private struct CommunitySpotSheet: View {
    let summary: CommunitySpotSummary

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Spot.name) private var localSpots: [Spot]

    @State private var stats: SpotCommunityStats?
    @State private var statsFailed = false
    @State private var weather: SpotWeather?
    @State private var weatherFailed = false
    @State private var flights: [SharedFlightSummary]?
    @State private var flightsFailed = false
    @State private var selectedFlight: SharedFlightSummary?

    /// Live presence: prefer the fresh per-spot stats over the (possibly
    /// 15-minute-old) Explore summary once they arrive.
    private var pilotsFlyingNow: Int {
        stats?.pilotsFlyingNow ?? summary.pilotsFlyingNow
    }

    /// The pilot's own spot matching this community spot, either through the
    /// key recorded when a flight was shared or derived from name+location.
    private var mySpot: Spot? {
        localSpots.first { spot in
            spot.communitySpotKey == summary.spotKey
                || CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude) == summary.spotKey
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if pilotsFlyingNow > 0 {
                    Section {
                        Text("🪂 \(pilotsFlyingNow) flying now")
                            .font(.headline)
                            .foregroundStyle(.green)
                    }
                }

                conditionsSection
                communitySection
                recentFlightsSection

                if let mySpot {
                    Section {
                        NavigationLink {
                            SpotDetailView(spot: mySpot)
                        } label: {
                            Label("View my spot", systemImage: "mappin.circle")
                        }
                    } footer: {
                        Text("You fly here too — open your own spot page (forecast, flyability, your flights).")
                    }
                }
            }
            .navigationTitle(summary.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            // Three independent tasks so stats, weather and the flight feed
            // load in parallel and fail independently.
            .task { await loadStats() }
            .task { await loadWeather() }
            .task { await loadFlights() }
            .sheet(item: $selectedFlight) { flight in
                SharedFlightDetailView(flight: flight, spotName: summary.name)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: Current conditions

    private var conditionsSection: some View {
        Section {
            if let weather {
                currentConditionsRow(weather)
                // Coming days. No flyability rating: community spots carry no
                // launch orientations, so these are raw forecast rows only.
                ForEach(weather.daily) { day in
                    forecastRow(day)
                }
            } else if weatherFailed {
                Text("Conditions unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                loadingRow("Loading conditions…")
            }
        } header: {
            Text("Weather")
        } footer: {
            if weather != nil {
                Text("Weather by Open-Meteo.")
            }
        }
    }

    /// One forecast day: weekday, wind direction arrow, max wind / gusts,
    /// precip probability and max temperature. Mirrors the local spot detail's
    /// daily row but WITHOUT the flyability dot (no launch orientations here).
    private func forecastRow(_ day: DayForecast) -> some View {
        HStack(spacing: 10) {
            Text(day.date, format: .dateTime.weekday(.abbreviated))
                .font(.subheadline.weight(.medium))
                .frame(width: 40, alignment: .leading)

            if let direction = day.windDirectionDominantDeg {
                // Wind comes FROM `direction`; the arrow shows where it blows TO.
                Image(systemName: "location.north.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(direction + 180))
            }

            Text(windText(day))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let precip = day.precipProbabilityMax {
                HStack(spacing: 2) {
                    Image(systemName: "drop.fill")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                    Text("\(Int(precip.rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let temp = day.tempMax {
                Text("\(Int(temp.rounded()))°")
                    .font(.caption.weight(.medium))
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    /// "18 / 32 km/h" (max wind / max gusts).
    private func windText(_ day: DayForecast) -> String {
        let speed = day.windSpeedMax.map { "\(Int($0.rounded()))" } ?? "—"
        if let gusts = day.windGustsMax {
            return "\(speed) / \(Int(gusts.rounded())) km/h"
        }
        return "\(speed) km/h"
    }

    /// Big current wind speed + gusts, direction arrow + compass, temperature
    /// (same layout as the spot detail's current row — no forecast here).
    private func currentConditionsRow(_ weather: SpotWeather) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(weather.windSpeed.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                    Text("km/h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let gusts = weather.windGusts {
                    Text("Gusts \(Int(gusts.rounded())) km/h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let direction = weather.windDirectionDeg {
                VStack(spacing: 2) {
                    // Wind comes FROM `direction`; the arrow shows where it blows TO.
                    Image(systemName: "location.north.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .rotationEffect(.degrees(direction + 180))
                    Text(WeatherService.degreesToCompass(direction))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let temperature = weather.temperature {
                Text("\(Int(temperature.rounded()))°C")
                    .font(.title2.weight(.medium))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Community stats

    private var communitySection: some View {
        Section("Community") {
            if let stats {
                if stats.flightsThisMonth == 0 && stats.hoursThisYear == 0 {
                    Text("No shared flights at this spot yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("^[\(stats.flightsThisMonth) flight](inflect: true) by ^[\(stats.pilotsThisMonth) pilot](inflect: true) this month")
                        .font(.subheadline)
                    Text("\(hoursText(stats.hoursThisYear)) this year")
                        .font(.subheadline)
                    ForEach(Array(stats.topPilots.enumerated()), id: \.offset) { index, pilot in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            Text(pilot.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Text(hoursText(pilot.hours))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if statsFailed {
                Text("Community stats unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                loadingRow("Loading community activity…")
            }
        }
    }

    // MARK: Recent shared flights

    private var recentFlightsSection: some View {
        Section {
            if let flights {
                if flights.isEmpty {
                    Text("No shared flights yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(flights) { flight in
                        Button {
                            selectedFlight = flight
                        } label: {
                            SharedFlightRow(flight: flight)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if flightsFailed {
                Text("Recent flights unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                loadingRow("Loading recent flights…")
            }
        } header: {
            Text("Recent flights here")
        } footer: {
            Text("From pilots who share their flights in Settings › Community.")
        }
    }

    // MARK: Helpers

    private func loadingRow(_ label: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "12 h" above 10 hours, "3.5 h" below (same as the spot community section).
    private func hoursText(_ hours: Double) -> String {
        hours >= 10 ? "\(Int(hours.rounded())) h" : String(format: "%.1f h", hours)
    }

    // MARK: Loading

    private func loadStats() async {
        do {
            stats = try await CommunityService.shared.communityStats(forSpotKey: summary.spotKey)
        } catch {
            statsFailed = stats == nil
        }
    }

    private func loadWeather() async {
        do {
            weather = try await WeatherService.shared.weather(
                latitude: summary.latitude, longitude: summary.longitude
            )
        } catch {
            logWarning("Community spot conditions failed: \(error.localizedDescription)", category: .weather)
            weatherFailed = weather == nil
        }
    }

    private func loadFlights() async {
        do {
            flights = try await CommunityService.shared.recentFlights(forSpotKey: summary.spotKey)
        } catch {
            flightsFailed = flights == nil
        }
    }
}

// MARK: - SharedFlightRow

/// One shared flight: pilot name, relative date + duration, flight-type badge.
private struct SharedFlightRow: View {
    let flight: SharedFlightSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(flight.pilotName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(flight.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("• \(durationText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let type = flight.flightType.flatMap(FlightType.init(rawValue:)) {
                Label(type.rawValue, systemImage: type.symbolName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.indigo.opacity(0.12), in: Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// "1h05" / "45 min" from the shared duration.
    private var durationText: String {
        let hours = flight.durationSeconds / 3600
        let minutes = (flight.durationSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(hours)h"
        }
        return "\(minutes) min"
    }
}
