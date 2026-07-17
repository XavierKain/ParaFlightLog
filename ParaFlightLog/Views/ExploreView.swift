//
//  ExploreView.swift
//  ParaFlightLog
//
//  "Explore" screen (roadmap Step D v1): community spots on a map or list,
//  decorated with recent activity (shared flights within a selectable time
//  window — today / 30 days / 1 year / all time / custom) and live presence,
//  plus a detail sheet with community stats, current conditions and the
//  spot's recent shared flights.
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

    /// The pilot's own spots — their effective types back-fill community
    /// spots that carry no type yet (see `filtered`).
    @Query private var localSpots: [Spot]

    /// nil until the first successful load; kept (stale) on refresh failures.
    @State private var spots: [CommunitySpotSummary]?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var backendUnavailable = false

    @State private var selectedSpot: CommunitySpotSummary?

    /// nil = "All types". Filters both Map and List by CommunitySpotSummary
    /// type. Untyped spots show only under "All", hidden under a specific type.
    @State private var typeFilter: FlightType?

    /// Activity window for the shared-flight counts/colouring (presence is
    /// always live). Defaults to all time.
    @State private var period: ExplorePeriod = .allTime
    /// Presented by the "Custom…" menu entry; two DatePickers seed a
    /// `.custom` period on Apply.
    @State private var showingCustomSheet = false
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    /// The camera is fitted to the spots once, on first load — not on every
    /// refresh, which would yank the map away from where the pilot panned.
    @State private var didFitCamera = false

    /// Learned flyability of the CURRENT forecast per spot key, computed
    /// lazily in the background for the busiest spots (bounded budget +
    /// concurrency, 15-minute weather/window caches). Absent or `.unknown`
    /// entries keep the activity colouring — the map never blocks on it.
    @State private var flyability: [String: Flyability] = [:]
    @State private var isColoring = false

    /// Stay gentle on Open-Meteo (non-commercial): colour at most this many
    /// spots per pass, a few requests at a time.
    private static let flyabilityBudget = 24
    private static let flyabilityConcurrency = 4

    var body: some View {
        content
            .navigationTitle("Explore")
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let spots, !spots.isEmpty {
                        typeFilterMenu
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let spots, !spots.isEmpty {
                        periodMenu
                    }
                }
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
            // Switching windows re-reads (cache is keyed per period, so an
            // already-loaded window returns instantly). Reuses the same
            // reentrancy-guarded loader as .task/refresh/retry.
            .onChange(of: period) { _, _ in
                Task { await load(force: false) }
            }
            .sheet(item: $selectedSpot) { spot in
                CommunitySpotSheet(summary: spot)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingCustomSheet) {
                customRangeSheet
            }
    }

    /// Toolbar type filter: "All types" + every FlightType. Shows a filled
    /// funnel while a specific type is active.
    private var typeFilterMenu: some View {
        Menu {
            Picker("Spot type", selection: $typeFilter) {
                Label("All types", systemImage: "square.grid.2x2")
                    .tag(FlightType?.none)
                ForEach(FlightType.allCases) { type in
                    Label(type.rawValue, systemImage: type.symbolName)
                        .tag(FlightType?.some(type))
                }
            }
        } label: {
            Label(
                typeFilter?.rawValue ?? "All types",
                systemImage: typeFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .accessibilityLabel("Filter by spot type")
    }

    /// Toolbar activity-window selector. The current window's short label is
    /// the menu title (also the "selected period" chip). "Custom…" opens a
    /// two-DatePicker sheet.
    private var periodMenu: some View {
        Menu {
            Picker("Activity period", selection: $period) {
                Text("Today").tag(ExplorePeriod.day)
                Text("30 days").tag(ExplorePeriod.month)
                Text("1 year").tag(ExplorePeriod.year)
                Text("All time").tag(ExplorePeriod.allTime)
            }
            Divider()
            Button {
                // Seed the pickers from the active custom range, if any.
                if case .custom(let start, let end) = period {
                    customStart = start
                    customEnd = end
                }
                showingCustomSheet = true
            } label: {
                Label("Custom…", systemImage: "calendar")
            }
        } label: {
            Label(period.menuLabel, systemImage: "clock.arrow.circlepath")
        }
        .accessibilityLabel("Activity period: \(period.menuLabel)")
    }

    /// Two-date range picker for a `.custom` window. End is normalised to the
    /// end of its day on Apply so the whole day is included.
    private var customRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCustomSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let calendar = Calendar.current
                        let start = calendar.startOfDay(for: customStart)
                        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: customEnd) ?? customEnd
                        period = .custom(start: start, end: end)
                        showingCustomSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Keeps only the spots matching the active type filter. "All types"
    /// (nil) shows everything. A community spot without a type falls back to
    /// the matching LOCAL spot's effective type (many community rows predate
    /// the spotType column), so known spots don't vanish under a type filter.
    private func filtered(_ spots: [CommunitySpotSummary]) -> [CommunitySpotSummary] {
        guard let typeFilter else { return spots }
        let localTypes = localTypeByKey
        return spots.filter { spot in
            let type = spot.spotType.flatMap(FlightType.init(rawValue:))
                ?? localTypes[spot.spotKey]
            return type == typeFilter
        }
    }

    /// Effective type of the pilot's own spots, keyed by community spot key.
    private var localTypeByKey: [String: FlightType] {
        var result: [String: FlightType] = [:]
        for spot in localSpots {
            guard let type = spot.effectiveFlightType,
                  let key = spot.communitySpotKey
                      ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude) else { continue }
            result[key] = type
        }
        return result
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

            legend

            let shown = filtered(spots)
            if shown.isEmpty {
                filteredEmptyState
            } else {
                switch mode {
                case .map:
                    mapView(shown)
                case .list:
                    listView(shown)
                }
            }
        }
    }

    /// Shown when the active type filter leaves no spots.
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("No spots of this type", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No community spots match \(typeFilter?.rawValue ?? "this type"). Try “All types”.")
        } actions: {
            Button("Show all types") { typeFilter = nil }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Tiny colour key: flyability dots (from the current forecast) plus the
    /// activity fallback used when no forecast/window is available.
    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.green, "Flyable")
            legendItem(.orange, "Marginal")
            legendItem(.red, "Too strong")
            legendItem(.blue, "Activity")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: green flyable, orange marginal, red too strong, blue activity.")
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
        }
    }

    /// Flyability colour for a spot when the current forecast rates it,
    /// otherwise its activity colour (busyness of the last 30 days).
    private func color(for spot: CommunitySpotSummary) -> Color {
        if let rating = flyability[spot.spotKey], rating != .unknown {
            return rating.displayColor
        }
        return spot.activityColor
    }

    // MARK: Map

    private func mapView(_ spots: [CommunitySpotSummary]) -> some View {
        Map(position: $cameraPosition) {
            ForEach(spots) { spot in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)) {
                    CommunitySpotBadge(spot: spot, tint: color(for: spot), periodPhrase: period.activityPhrase)
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

    /// Live spots first, then the busiest within the selected window, then A→Z.
    private static func listOrder(_ spots: [CommunitySpotSummary]) -> [CommunitySpotSummary] {
        spots.sorted {
            if $0.pilotsFlyingNow != $1.pilotsFlyingNow {
                return $0.pilotsFlyingNow > $1.pilotsFlyingNow
            }
            if $0.flightsInPeriod != $1.flightsInPeriod {
                return $0.flightsInPeriod > $1.flightsInPeriod
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func spotRow(_ spot: CommunitySpotSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(color(for: spot))

            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name)
                    .font(.headline)
                    .lineLimit(1)
                activityText(spot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Tiny type symbol when this community spot carries a type.
            if let type = spot.spotType.flatMap(FlightType.init(rawValue:)) {
                Image(systemName: type.symbolName)
                    .font(.caption)
                    .foregroundStyle(.indigo)
                    .accessibilityLabel(type.rawValue)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func activityText(_ spot: CommunitySpotSummary) -> Text {
        let base = Text("^[\(spot.flightsInPeriod) flight](inflect: true) \(period.activityPhrase)")
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
            let result = try await CommunityService.shared.exploreSpots(period: period, forceRefresh: force)
            spots = result
            backendUnavailable = false
            if !didFitCamera, let region = Self.fitRegion(result) {
                cameraPosition = .region(region)
                didFitCamera = true
            }
            // Colour the spots by the current forecast, in the background — a
            // forced refresh recomputes, an initial load fills what it can.
            if force { flyability = [:] }
            Task { await computeFlyability(for: result) }
        } catch CommunityError.backendNotConfigured {
            backendUnavailable = true
        } catch {
            logWarning("Explore load failed: \(error.localizedDescription)", category: .community)
            // Keep showing the (stale) spots on a refresh failure.
            loadFailed = spots == nil
        }
        isLoading = false
    }

    // MARK: Flyability colouring

    /// Rates the busiest spots against the current forecast, a few requests at
    /// a time, and stores the non-`.unknown` results. Reentrancy-guarded so
    /// overlapping loads don't double the network traffic.
    private func computeFlyability(for spots: [CommunitySpotSummary]) async {
        guard !isColoring else { return }
        isColoring = true
        defer { isColoring = false }

        let targets = Array(
            spots.sorted {
                if $0.pilotsFlyingNow != $1.pilotsFlyingNow {
                    return $0.pilotsFlyingNow > $1.pilotsFlyingNow
                }
                return $0.flightsInPeriod > $1.flightsInPeriod
            }
            .prefix(Self.flyabilityBudget)
        )
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: (String, Flyability)?.self) { group in
            var iterator = targets.makeIterator()
            // Prime the pump with a bounded number of concurrent requests…
            for _ in 0..<Self.flyabilityConcurrency {
                guard let spot = iterator.next() else { break }
                let key = spot.spotKey, lat = spot.latitude, lon = spot.longitude
                group.addTask { await Self.computeOne(spotKey: key, latitude: lat, longitude: lon) }
            }
            // …then feed one more each time a request completes.
            while let result = await group.next() {
                if let (key, rating) = result, rating != .unknown {
                    flyability[key] = rating
                }
                guard let spot = iterator.next() else { continue }
                let key = spot.spotKey, lat = spot.latitude, lon = spot.longitude
                group.addTask { await Self.computeOne(spotKey: key, latitude: lat, longitude: lon) }
            }
        }
    }

    /// One spot: current forecast × learned window → flyability. `.unknown`
    /// when there's no learned window (community-only; no PGE fetch here);
    /// nil when the weather request fails (keeps the activity colour).
    private static func computeOne(spotKey: String, latitude: Double, longitude: Double) async -> (String, Flyability)? {
        do {
            let weather = try await WeatherService.shared.weather(latitude: latitude, longitude: longitude)
            let window = await SpotIntelligenceService.shared.learnedWindow(
                spotKey: spotKey, latitude: latitude, longitude: longitude
            )
            guard !window.isEmpty else { return (spotKey, .unknown) }
            let rating = SpotIntelligenceService.shared.flyabilityV2(
                windDirectionDeg: weather.windDirectionDeg,
                windSpeed: weather.windSpeed,
                windGusts: weather.windGusts,
                window: window
            )
            return (spotKey, rating)
        } catch {
            return nil
        }
    }
}

// MARK: - CommunitySpotBadge (map annotation)

/// Capsule with the spot name and its activity in the selected window, tinted
/// by how busy the spot is (gray: none, blue: 1–9 flights, orange: 10+). A
/// pulsing green "🪂 N" badge sits on top while pilots are flying there now.
private struct CommunitySpotBadge: View {
    let spot: CommunitySpotSummary
    /// Resolved colour: current-forecast flyability when known, else activity.
    let tint: Color
    /// Activity-window phrase for the accessibility label (e.g. "in the last 30 days").
    let periodPhrase: String

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
                if spot.flightsInPeriod > 0 {
                    Text("\(spot.flightsInPeriod)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint, in: Capsule())
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 1.5)
            )
            .frame(maxWidth: 160)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "\(spot.name), \(spot.flightsInPeriod) flights \(periodPhrase)"
        if spot.pilotsFlyingNow > 0 {
            text += ", \(spot.pilotsFlyingNow) flying now"
        }
        return text
    }
}

private extension CommunitySpotSummary {
    /// Visual hierarchy of the selected window: gray (quiet), blue, orange (busy).
    var activityColor: Color {
        switch flightsInPeriod {
        case 0: return .gray
        case 1...9: return .blue
        default: return .orange
        }
    }
}

private extension ExplorePeriod {
    /// Short label for the toolbar menu title / selected-period chip.
    var menuLabel: String {
        switch self {
        case .day:     return "Today"
        case .month:   return "30 days"
        case .year:    return "1 year"
        case .allTime: return "All time"
        case .custom:  return "Custom"
        }
    }

    /// Trailing phrase for activity counts, e.g. "12 flights <phrase>".
    var activityPhrase: String {
        switch self {
        case .day:     return "in the last 24 hours"
        case .month:   return "in the last 30 days"
        case .year:    return "in the last year"
        case .allTime: return "all time"
        case .custom(let start, let end):
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return "\(start.formatted(style))–\(end.formatted(style))"
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

    /// Launch directions LEARNED from the community's shared flights at this
    /// spot (a community spot carries no configured directions). They drive
    /// the hourly-strip flyability tint and the climatology's flyable share —
    /// same information as the pilot's own spot page.
    @State private var learnedDirections: [String] = []

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

                // Live condition reports + "Report conditions" — the SAME
                // section as the local spot page (works without a local Spot).
                SpotReportsSection(spot: mySpot, spotKey: summary.spotKey, spotName: summary.name)

                conditionsSection

                // "Best months to fly" — same ERA5 climatology as the local
                // spot page; the flyable share uses the LEARNED directions.
                SpotClimatologySection(
                    latitude: summary.latitude,
                    longitude: summary.longitude,
                    directions: learnedDirections
                )

                communitySection
                // Spot leaderboard (Phase 4). Fail-soft: hides itself when the
                // social backend isn't configured.
                SpotLeaderboardSection(spotKey: summary.spotKey, spotName: summary.name)
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
            // Independent tasks so stats, weather, the flight feed and the
            // learned window load in parallel and fail independently.
            .task { await loadStats() }
            .task { await loadWeather() }
            .task { await loadFlights() }
            .task { await loadLearnedDirections() }
        }
        // Presented from the NavigationStack's ROOT, not from inside it. A sheet
        // attached within the stack is presented by the stack's hosting
        // controller, which is transiently "detached" while this whole view is
        // itself a detent sheet — iOS logs "Presenting … from detached
        // NavigationStackHostingController … will become a hard exception" and
        // may fail to present. Hoisting the modifier outside the stack presents
        // it from the stable sheet root instead.
        .sheet(item: $selectedFlight) { flight in
            SharedFlightDetailView(flight: flight, spotName: summary.name)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Current conditions

    private var conditionsSection: some View {
        Section {
            if let weather {
                currentConditionsRow(weather)

                // Next 48 h — same strip as the local spot page. The
                // flyability tint uses the directions LEARNED from shared
                // flights here (gray cells until the spot has learned data).
                if !weather.hourly.isEmpty {
                    HourlyForecastStrip(hours: weather.hourly, directions: learnedDirections)
                }

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
                    // Spot record: the longest shared flight here.
                    if let record = flights.max(by: { $0.durationSeconds < $1.durationSeconds }) {
                        HStack(spacing: 8) {
                            Text("🏆")
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Spot record — \(recordDurationText(record.durationSeconds))")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(record.pilotName) · \(record.date, format: .dateTime.day().month().year())")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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

    /// "1h05" / "45 min" for the spot-record row.
    private func recordDurationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(hours)h"
        }
        return "\(minutes) min"
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
            flights = try await CommunityService.shared.recentFlights(forSpotKey: summary.spotKey, limit: 100)
        } catch {
            flightsFailed = flights == nil
        }
    }

    /// Learned flying window → compass directions (busiest sectors), used by
    /// the hourly strip and the climatology. Fail-soft: stays empty.
    private func loadLearnedDirections() async {
        let window = await SpotIntelligenceService.shared.learnedWindow(
            spotKey: summary.spotKey, latitude: summary.latitude, longitude: summary.longitude
        )
        guard !window.isEmpty else { return }
        learnedDirections = WeatherService.compassPoints.filter { window.sectors[$0] != nil }
    }
}

// MARK: - SharedFlightRow

/// One shared flight: pilot name, relative date + duration, flight-type badge.
/// Internal — also used by the local spot page's Community section.
struct SharedFlightRow: View {
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
