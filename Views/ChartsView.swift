//
//  ChartsView.swift
//  ParaFlightLog
//
//  Charts content embedded in the Stats tab: timeline, flight types,
//  spots heatmap and spots map, with period + wing filters.
//  Target: iOS only
//

import SwiftUI
import SwiftData
import Charts
import MapKit

// MARK: - StatsTimePeriod (Filter period)

enum StatsTimePeriod: String, CaseIterable {
    case all
    case week
    case month
    case threeMonths
    case sixMonths
    case year
    case custom

    var displayName: String {
        switch self {
        case .week: return "7d"
        case .month: return "30d"
        case .threeMonths: return "3m"
        case .sixMonths: return "6m"
        case .year: return "1y"
        case .custom: return "Custom"
        case .all: return "All"
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .year: return 365
        case .custom, .all: return nil
        }
    }
}

// MARK: - ChartsContentView (Embedded in StatsView)

/// Filtered charts content rendered inside the Stats tab.
/// `showMap == false` shows the timeline + flight types + spots heatmap;
/// `showMap == true` shows the spots bubble map. Both share the same filters.
struct ChartsContentView: View {
    let flights: [Flight]
    let wings: [Wing]
    let showMap: Bool

    @Binding var selectedPeriod: StatsTimePeriod
    @Binding var selectedWings: Set<UUID>
    @Binding var customStartDate: Date
    @Binding var customEndDate: Date

    @State private var showingCustomDatePicker = false

    /// Flights matching the current period + wing filters
    private var filteredFlights: [Flight] {
        var result = flights

        // Period filter
        if selectedPeriod == .custom {
            result = result.filter { $0.startDate >= customStartDate && $0.startDate <= customEndDate }
        } else if let days = selectedPeriod.days {
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            result = result.filter { $0.startDate >= cutoffDate }
        }

        // Wing filter (active when at least one wing is selected)
        if !selectedWings.isEmpty {
            result = result.filter { flight in
                if let wingId = flight.wing?.id {
                    return selectedWings.contains(wingId)
                }
                return false
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Period selector (scrollable to fit all options)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StatsTimePeriod.allCases, id: \.self) { period in
                        Button {
                            selectedPeriod = period
                            if period == .custom {
                                showingCustomDatePicker = true
                            }
                        } label: {
                            Text(period.displayName)
                                .font(.caption)
                                .fontWeight(selectedPeriod == period ? .semibold : .regular)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedPeriod == period ? Color.blue : Color(.systemGray6))
                                .foregroundStyle(selectedPeriod == period ? .white : .primary)
                                .cornerRadius(16)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)

            // Wing selector (multi-selection)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // "All wings" button
                    Button {
                        selectedWings.removeAll()
                    } label: {
                        Text("All")
                            .font(.caption)
                            .fontWeight(selectedWings.isEmpty ? .semibold : .regular)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedWings.isEmpty ? Color.green : Color(.systemGray6))
                            .foregroundStyle(selectedWings.isEmpty ? .white : .primary)
                            .cornerRadius(16)
                    }

                    // One button per wing
                    ForEach(wings) { wing in
                        Button {
                            if selectedWings.contains(wing.id) {
                                selectedWings.remove(wing.id)
                            } else {
                                selectedWings.insert(wing.id)
                            }
                        } label: {
                            Text(wing.name)
                                .font(.caption)
                                .fontWeight(selectedWings.contains(wing.id) ? .semibold : .regular)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedWings.contains(wing.id) ? Color.blue : Color(.systemGray6))
                                .foregroundStyle(selectedWings.contains(wing.id) ? .white : .primary)
                                .cornerRadius(16)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 12)

            // Chart content
            ScrollView {
                VStack(spacing: 20) {
                    if showMap {
                        FlightsSpotsMapView(flights: filteredFlights)
                    } else {
                        TimelineChartCard(flights: filteredFlights, period: selectedPeriod)
                        FlightTypeBreakdownCard(flights: filteredFlights)
                        HeatmapChartCard(flights: filteredFlights)
                    }
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingCustomDatePicker) {
            CustomDateRangePicker(startDate: $customStartDate, endDate: $customEndDate)
        }
    }
}

// MARK: - TimelineChartCard (Activity timeline)

struct TimelineChartCard: View {
    let flights: [Flight]
    let period: StatsTimePeriod

    struct DayData: Identifiable {
        let id = UUID()
        let date: Date
        let count: Int
        let hours: Double
    }

    var chartData: [DayData] {
        let calendar = Calendar.current
        let grouped: [Date: [Flight]]

        // Group by day, week or month depending on the period
        switch period {
        case .week, .month:
            // Group by day
            grouped = Dictionary(grouping: flights) { flight in
                calendar.startOfDay(for: flight.startDate)
            }
        case .threeMonths, .sixMonths, .year:
            // Group by week
            grouped = Dictionary(grouping: flights) { flight in
                let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: flight.startDate)
                return calendar.date(from: components) ?? flight.startDate
            }
        case .custom, .all:
            // Group by month
            grouped = Dictionary(grouping: flights) { flight in
                let components = calendar.dateComponents([.year, .month], from: flight.startDate)
                return calendar.date(from: components) ?? flight.startDate
            }
        }

        return grouped.map { date, flights in
            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            return DayData(
                date: date,
                count: flights.count,
                hours: Double(totalSeconds) / 3600.0
            )
        }
        .sorted { $0.date < $1.date }
    }

    var totalFlights: Int {
        flights.count
    }

    var totalHours: Double {
        Double(flights.reduce(0) { $0 + $1.durationSeconds }) / 3600.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity")
                    .font(.title2)
                    .fontWeight(.bold)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(totalFlights)")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                        Text(totalFlights == 1 ? "flight" : "flights")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f", totalHours))
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                        Text("hours")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal)

            Divider()

            // Chart
            if chartData.isEmpty {
                ContentUnavailableView(
                    "No Flights",
                    systemImage: "chart.bar",
                    description: Text("No flights during this period")
                )
                .frame(height: 200)
            } else {
                Chart(chartData) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: chartUnit),
                        y: .value("Flights", item.count)
                    )
                    .foregroundStyle(.blue.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5))
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 250)
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    var chartUnit: Calendar.Component {
        switch period {
        case .week, .month: return .day
        case .threeMonths, .sixMonths, .year: return .weekOfYear
        case .custom, .all: return .month
        }
    }
}

// MARK: - FlightTypeBreakdownCard (Hours per flight type)

struct FlightTypeBreakdownCard: View {
    let flights: [Flight]

    struct TypeData: Identifiable {
        let type: FlightType
        let count: Int
        let hours: Double

        var id: String { type.rawValue }
    }

    var typeData: [TypeData] {
        // Flights without a type are counted under "Other"
        let grouped = Dictionary(grouping: flights) { $0.flightTypeEnum ?? .other }

        return grouped.map { type, flights in
            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            return TypeData(
                type: type,
                count: flights.count,
                hours: Double(totalSeconds) / 3600.0
            )
        }
        .sorted { $0.hours > $1.hours }
    }

    private func formatHours(_ hours: Double) -> String {
        let (h, m) = splitHours(hours)
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("Flight Types")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            Divider()

            if typeData.isEmpty {
                ContentUnavailableView(
                    "No Flights",
                    systemImage: "chart.bar",
                    description: Text("No flights during this period")
                )
                .frame(height: 150)
            } else {
                Chart {
                    ForEach(typeData) { item in
                        BarMark(
                            x: .value("Hours", item.hours),
                            y: .value("Type", item.type.rawValue)
                        )
                        .foregroundStyle(.blue.gradient)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(formatHours(item.hours))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let rawValue = value.as(String.self),
                               let type = FlightType(rawValue: rawValue) {
                                HStack(spacing: 4) {
                                    Image(systemName: type.symbolName)
                                    Text(type.rawValue)
                                }
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom)
                }
                .frame(height: CGFloat(max(120, typeData.count * 44)))
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

// MARK: - HeatmapChartCard (Spots heatmap)

struct HeatmapChartCard: View {
    let flights: [Flight]

    struct SpotData: Identifiable {
        let id = UUID()
        let name: String
        let count: Int
        let hours: Double
        let percentage: Double
    }

    var spotData: [SpotData] {
        let grouped = Dictionary(grouping: flights) { $0.spotName ?? "Unknown" }
        let total = flights.count

        return grouped.map { name, flights in
            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            return SpotData(
                name: name,
                count: flights.count,
                hours: Double(totalSeconds) / 3600.0,
                percentage: total > 0 ? Double(flights.count) / Double(total) * 100.0 : 0
            )
        }
        .sorted { $0.count > $1.count }
    }

    var maxCount: Int {
        spotData.map(\.count).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Flying Spots")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("\(spotData.count) different \(spotData.count == 1 ? "spot" : "spots")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Divider()

            // Spot list with bars
            if spotData.isEmpty {
                ContentUnavailableView(
                    "No Spots",
                    systemImage: "map",
                    description: Text("No flights during this period")
                )
                .frame(height: 200)
            } else {
                VStack(spacing: 12) {
                    ForEach(spotData) { spot in
                        SpotRow(spot: spot, maxCount: maxCount)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

// MARK: - SpotRow (Row in the spots heatmap)

struct SpotRow: View {
    let spot: HeatmapChartCard.SpotData
    let maxCount: Int

    var barWidth: CGFloat {
        CGFloat(spot.count) / CGFloat(maxCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name and stats
            HStack {
                Text(spot.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("\(spot.count)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                        Text(spot.count == 1 ? "flight" : "flights")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Text(String(format: "%.1f", spot.hours))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                        Text("h")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    // Colored bar
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .green],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * barWidth)

                    // Percentage
                    if spot.percentage >= 10 {
                        Text(String(format: "%.0f%%", spot.percentage))
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.leading, 8)
                    }
                }
            }
            .frame(height: 24)
        }
    }
}

// MARK: - FlightsSpotsMapView

struct FlightsSpotsMapView: View {
    let flights: [Flight]

    var spotData: [SpotMapData] {
        let grouped = Dictionary(grouping: flights.filter { $0.latitude != nil && $0.longitude != nil }) { flight in
            flight.spotName ?? "Unknown"
        }

        return grouped.compactMap { spotName, flights in
            guard let firstFlight = flights.first,
                  let lat = firstFlight.latitude,
                  let lon = firstFlight.longitude else {
                return nil
            }

            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            let hours = Double(totalSeconds) / 3600.0

            return SpotMapData(
                name: spotName,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                hours: hours,
                flightCount: flights.count
            )
        }
        .sorted { $0.hours < $1.hours } // Ascending so the biggest spots are drawn last (on top)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spot Map")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if spotData.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No spots with GPS coordinates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            } else {
                Map {
                    ForEach(spotData) { spot in
                        Annotation(spot.name, coordinate: spot.coordinate) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue.gradient)
                                        .frame(width: calculateBubbleSize(hours: spot.hours))

                                    Text(formatSpotTime(spot.hours))
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.white)
                                        .zIndex(1) // Text always on top
                                }
                                Text(spot.name)
                                    .font(.caption2)
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.9))
                                    .cornerRadius(4)
                                    .shadow(color: .black.opacity(0.2), radius: 2)
                            }
                        }
                        .annotationTitles(.hidden) // Hide default titles to avoid duplicates
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .frame(height: 400)
                .cornerRadius(12)
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }

    /// Formats flight time for display on the map
    /// - Shows hours when >= 1h
    /// - Shows minutes when < 1h (short "m" format so it fits in the bubbles)
    private func formatSpotTime(_ hours: Double) -> String {
        if hours >= 1.0 {
            return "\(Int(hours))h"
        } else {
            let minutes = Int(hours * 60)
            return "\(minutes)m"
        }
    }

    /// Computes the bubble size from the flight time
    /// - For < 1h: sized so the minutes fit (min 35px)
    /// - For >= 1h: proportional to hours (max 60px)
    private func calculateBubbleSize(hours: Double) -> CGFloat {
        if hours < 1.0 {
            // For < 1h, guarantee a 35px minimum so "45m" fits,
            // growing slightly with duration
            return max(35, 35 + CGFloat(hours) * 15)
        } else {
            // For >= 1h, use the classic formula
            return max(40, min(60, CGFloat(hours) * 10))
        }
    }
}

struct SpotMapData: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let hours: Double
    let flightCount: Int
}

// MARK: - CustomDateRangePicker

struct CustomDateRangePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var startDate: Date
    @Binding var endDate: Date

    var body: some View {
        NavigationStack {
            Form {
                Section("Custom Period") {
                    DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                    DatePicker("End Date", selection: $endDate, displayedComponents: .date)
                }
            }
            .navigationTitle("Select Period")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
