//
//  StatsViews.swift
//  ParaFlightLog
//
//  Statistics tab: Overview (totals, by wing, by spot), Charts (timeline,
//  flight types, spots heatmap) and Map (spots bubble map).
//  Target: iOS only
//

import SwiftUI
import SwiftData
import Charts

// MARK: - StatsView (Merged Stats + Charts tab)

struct StatsView: View {
    @Environment(DataController.self) private var dataController
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    enum StatsSection: String, CaseIterable {
        case overview
        case charts
        case map

        var displayName: String {
            switch self {
            case .overview: return "Overview"
            case .charts: return "Charts"
            case .map: return "Map"
            }
        }
    }

    @State private var selectedSection: StatsSection = .overview

    // Charts/Map filter state lives here so it survives switching sections
    @State private var selectedPeriod: StatsTimePeriod = .all
    @State private var selectedWings: Set<UUID> = []
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate: Date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedSection) {
                    ForEach(StatsSection.allCases, id: \.self) { section in
                        Text(section.displayName).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                switch selectedSection {
                case .overview:
                    StatsOverviewContent(flights: flights, wings: wings)
                case .charts:
                    ChartsContentView(
                        flights: flights,
                        wings: wings,
                        showMap: false,
                        selectedPeriod: $selectedPeriod,
                        selectedWings: $selectedWings,
                        customStartDate: $customStartDate,
                        customEndDate: $customEndDate
                    )
                case .map:
                    ChartsContentView(
                        flights: flights,
                        wings: wings,
                        showMap: true,
                        selectedPeriod: $selectedPeriod,
                        selectedWings: $selectedWings,
                        customStartDate: $customStartDate,
                        customEndDate: $customEndDate
                    )
                }
            }
            .navigationTitle("Stats")
            .background(Color(.systemGroupedBackground))
        }
    }
}

// MARK: - StatsOverviewContent (Total + by wing + by spot)

struct StatsOverviewContent: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    let wings: [Wing]

    @State private var stats: FlightStats?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let stats {
                    TotalStatsCard(stats: stats)
                    StatsByTypeSection(flights: flights)
                    StatsByWingSection(stats: stats, flights: flights, wings: wings)
                    StatsBySpotSection(stats: stats, flights: flights)
                } else {
                    ProgressView()
                        .padding(.top, 60)
                }
            }
            .padding()
        }
        // Compute after the view is on screen (keeps the tab switch snappy) and
        // recompute whenever the set of flights changes. Uses the already-loaded
        // @Query flights (no redundant fetch).
        .task(id: flights.count) {
            stats = dataController.computeStats(from: flights)
        }
    }
}

// MARK: - Hours formatting helper

/// Splits a decimal hour count into whole hours and minutes (e.g. 1.5 -> (1, 30))
func splitHours(_ hours: Double) -> (hours: Int, minutes: Int) {
    let totalMinutes = Int((hours * 60).rounded())
    return (totalMinutes / 60, totalMinutes % 60)
}

// MARK: - TotalStatsCard

struct TotalStatsCard: View {
    let stats: FlightStats

    var body: some View {
        VStack(spacing: 16) {
            Text("Total")
                .font(.title2)
                .fontWeight(.bold)

            let (hours, minutes) = splitHours(stats.totalHours)

            HStack(spacing: 40) {
                VStack(spacing: 4) {
                    Text("\(stats.totalCount)")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.blue)
                    Text(stats.totalCount == 1 ? "session" : "sessions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(hours)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.green)
                        Text("h")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("\(minutes)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.green)
                        Text("min")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("flight time")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

// MARK: - StatsByWingSection

struct StatsByWingSection: View {
    let flights: [Flight]
    let wings: [Wing]
    @State private var selectedWing: Wing?

    // Per-wing stats derived once at init from the shared aggregate
    private let wingStats: [(wing: Wing, sessions: Int, hours: Int, minutes: Int, totalHours: Double)]

    init(stats: FlightStats, flights: [Flight], wings: [Wing]) {
        self.flights = flights
        self.wings = wings
        self.wingStats = wings.compactMap { wing in
            guard let hours = stats.hoursByWing[wing.id],
                  let sessions = stats.countByWing[wing.id],
                  sessions > 0 else { return nil }

            let (h, m) = splitHours(hours)
            return (wing: wing, sessions: sessions, hours: h, minutes: m, totalHours: hours)
        }
        .sorted { $0.totalHours > $1.totalHours }
    }

    /// Abbreviates a wing name by stripping well-known brand prefixes
    private func abbreviateWingName(_ name: String) -> String {
        var abbreviated = name
        abbreviated = abbreviated.replacingOccurrences(of: "Moustache ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Skyman ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Advance ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Ozone ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Nova ", with: "", options: .caseInsensitive)

        return abbreviated.trimmingCharacters(in: .whitespaces)
    }

    /// Chart label for a wing
    private func wingChartLabel(for wing: Wing) -> String {
        if let size = wing.size {
            return "\(abbreviateWingName(wing.name)) (\(size) m²)"
        } else {
            return abbreviateWingName(wing.name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By Wing")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if wingStats.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                // Table
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("Wing")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Sessions")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("Time")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    // Rows
                    ForEach(wingStats, id: \.wing.id) { stat in
                        Button {
                            selectedWing = stat.wing
                        } label: {
                            HStack(spacing: 8) {
                                // Wing photo with cache (24x24)
                                CachedImage(
                                    data: stat.wing.photoData,
                                    key: stat.wing.id.uuidString,
                                    size: CGSize(width: 24, height: 24)
                                ) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill((stat.wing.color ?? "Gray").toColor().opacity(0.3))
                                        .overlay {
                                            Image(systemName: "wind")
                                                .font(.system(size: 10))
                                                .foregroundStyle((stat.wing.color ?? "Gray").toColor())
                                        }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(abbreviateWingName(stat.wing.name))
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let size = stat.wing.size {
                                        Text("\(size) m²")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(stat.sessions)")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                                    .frame(width: 70, alignment: .trailing)

                                Text("\(stat.hours)h \(String(format: "%02d", stat.minutes))m")
                                    .font(.body)
                                    .foregroundStyle(.green)
                                    .frame(width: 80, alignment: .trailing)

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }

                        if stat.wing.id != wingStats.last?.wing.id {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)

                // Chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hours Breakdown")
                        .font(.headline)
                        .padding(.horizontal)

                    Chart {
                        ForEach(wingStats, id: \.wing.id) { stat in
                            BarMark(
                                x: .value("Hours", stat.totalHours),
                                y: .value("Wing", wingChartLabel(for: stat.wing))
                            )
                            .foregroundStyle(.blue.gradient)
                            .annotation(position: .trailing, alignment: .leading) {
                                let timeText = stat.hours > 0 ? "\(stat.hours)h\(String(format: "%02d", stat.minutes))" : "\(stat.minutes)min"
                                Text(timeText)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(height: CGFloat(max(150, wingStats.count * 40)))
                    .chartXAxis {
                        AxisMarks(position: .bottom)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                }
            }
        }
        .sheet(item: $selectedWing) { wing in
            WingFlightsDetailView(wing: wing, flights: flights)
        }
    }
}

// MARK: - StatsBySpotSection

// MARK: - StatsByTypeSection (hours & sessions per flight type)

struct StatsByTypeSection: View {
    /// Per-type stats derived once at init (uncategorized flights get their own row)
    private let typeStats: [(type: FlightType?, sessions: Int, hours: Int, minutes: Int, totalHours: Double)]

    init(flights: [Flight]) {
        let grouped = Dictionary(grouping: flights) { $0.flightTypeEnum }
        self.typeStats = grouped.map { type, typeFlights in
            let totalHours = typeFlights.reduce(0.0) { $0 + Double($1.durationSeconds) / 3600.0 }
            let (h, m) = splitHours(totalHours)
            return (type: type, sessions: typeFlights.count, hours: h, minutes: m, totalHours: totalHours)
        }
        // Typed rows by hours desc; "uncategorized" always last
        .sorted {
            switch ($0.type, $1.type) {
            case (nil, _): return false
            case (_, nil): return true
            default: return $0.totalHours > $1.totalHours
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By Flight Type")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if typeStats.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("Type")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Sessions")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("Time")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(Array(typeStats.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: entry.type?.symbolName ?? "questionmark.circle.dashed")
                                    .font(.caption)
                                    .foregroundStyle(entry.type != nil ? Color.indigo : Color.orange)
                                    .frame(width: 20)
                                Text(entry.type?.rawValue ?? "Uncategorized")
                                    .font(.subheadline)
                                    .foregroundStyle(entry.type != nil ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text("\(entry.sessions)")
                                .font(.subheadline.monospacedDigit())
                                .frame(width: 70, alignment: .trailing)

                            Text(entry.minutes > 0 ? "\(entry.hours)h\(String(format: "%02d", entry.minutes))" : "\(entry.hours)h")
                                .font(.subheadline.monospacedDigit())
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        if index < typeStats.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
            }
        }
    }
}

struct StatsBySpotSection: View {
    let flights: [Flight]
    @State private var selectedSpot: String?

    // Per-spot stats derived once at init from the shared aggregate
    private let spotStats: [(spot: String, sessions: Int, hours: Int, minutes: Int, totalHours: Double)]

    init(stats: FlightStats, flights: [Flight]) {
        self.flights = flights
        self.spotStats = stats.hoursBySpot.map { spot, hours in
            let (h, m) = splitHours(hours)
            return (
                spot: spot,
                sessions: stats.countBySpot[spot] ?? 0,
                hours: h,
                minutes: m,
                totalHours: hours
            )
        }
        .sorted { $0.totalHours > $1.totalHours }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By Spot")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if spotStats.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                // Table
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("Spot")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Sessions")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("Time")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    // Rows
                    ForEach(spotStats, id: \.spot) { stat in
                        Button {
                            selectedSpot = stat.spot
                        } label: {
                            HStack {
                                Text(stat.spot)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(stat.sessions)")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                                    .frame(width: 70, alignment: .trailing)

                                Text("\(stat.hours)h \(String(format: "%02d", stat.minutes))m")
                                    .font(.body)
                                    .foregroundStyle(.green)
                                    .frame(width: 80, alignment: .trailing)

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }

                        if stat.spot != spotStats.last?.spot {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)

                // Chart
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hours Breakdown")
                        .font(.headline)
                        .padding(.horizontal)

                    Chart {
                        ForEach(spotStats, id: \.spot) { stat in
                            BarMark(
                                x: .value("Hours", stat.totalHours),
                                y: .value("Spot", stat.spot)
                            )
                            .foregroundStyle(.green.gradient)
                            .annotation(position: .trailing, alignment: .leading) {
                                Text(stat.hours > 0 ? "\(stat.hours)h\(String(format: "%02d", stat.minutes))" : "\(stat.minutes)min")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(height: CGFloat(max(200, spotStats.count * 50)))
                    .chartXAxis {
                        AxisMarks(position: .bottom)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedSpot != nil },
            set: { if !$0 { selectedSpot = nil } }
        )) {
            if let spot = selectedSpot {
                SpotFlightsDetailView(spotName: spot, flights: flights)
            }
        }
    }
}

// MARK: - WingFlightsDetailView (Flights of a wing)

struct WingFlightsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let wing: Wing
    let flights: [Flight]

    // Filtered flights computed once at init
    private let wingFlights: [Flight]

    init(wing: Wing, flights: [Flight]) {
        self.wing = wing
        self.flights = flights
        self.wingFlights = flights
            .filter { $0.wing?.id == wing.id }
            .sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(wingFlights) { flight in
                        FlightRow(flight: flight)
                    }
                }
            }
            .navigationTitle(wing.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - SpotFlightsDetailView (Flights of a spot)

struct SpotFlightsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let spotName: String
    let flights: [Flight]

    // Filtered flights computed once at init
    private let spotFlights: [Flight]

    init(spotName: String, flights: [Flight]) {
        self.spotName = spotName
        self.flights = flights
        // Flights without a spot are aggregated under "Unknown" in the stats
        self.spotFlights = flights
            .filter { ($0.spotName ?? "Unknown") == spotName }
            .sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(spotFlights) { flight in
                        FlightRow(flight: flight)
                    }
                }
            }
            .navigationTitle(spotName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
