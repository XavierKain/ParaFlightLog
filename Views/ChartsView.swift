//
//  ChartsView.swift
//  ParaFlightLog
//
//  Graphiques avancés : Timeline et Heatmap des vols
//  Target: iOS only
//

import SwiftUI
import SwiftData
import Charts
import MapKit

// MARK: - ChartsView (Vue principale des graphiques)

struct ChartsView: View {
    @Environment(DataController.self) private var dataController
    @Query private var flights: [Flight]
    @Query(filter: #Predicate<Wing> { !$0.isArchived }) private var wings: [Wing]

    @State private var selectedPeriod: TimePeriod = .month
    @State private var selectedChartType: ChartType = .timeline
    @State private var showingCustomDatePicker = false
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate: Date = Date()

    enum ChartType: String, CaseIterable {
        case timeline
        case heatmap
        case map

        var displayName: String {
            switch self {
            case .timeline: return String(localized: "Timeline")
            case .heatmap: return String(localized: "Spots")
            case .map: return String(localized: "Carte")
            }
        }
    }

    enum TimePeriod: String, CaseIterable {
        case week
        case month
        case threeMonths
        case sixMonths
        case year
        case custom
        case all

        var displayName: String {
            switch self {
            case .week: return "7j"
            case .month: return "30j"
            case .threeMonths: return "3mois"
            case .sixMonths: return "6mois"
            case .year: return "1an"
            case .custom: return "Custom"
            case .all: return "Tout"
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

    var filteredFlights: [Flight] {
        if selectedPeriod == .custom {
            return flights.filter { $0.startDate >= customStartDate && $0.startDate <= customEndDate }
        }

        guard let days = selectedPeriod.days else { return flights }
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return flights.filter { $0.startDate >= cutoffDate }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Sélecteur de type de graphique
                Picker("Type", selection: $selectedChartType) {
                    ForEach(ChartType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Sélecteur de période (scrollable pour accommoder plus d'options)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TimePeriod.allCases, id: \.self) { period in
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
                .padding(.bottom, 12)

                // Contenu du graphique
                ScrollView {
                    VStack(spacing: 20) {
                        if selectedChartType == .timeline {
                            TimelineChartCard(flights: filteredFlights, period: selectedPeriod)
                        } else if selectedChartType == .heatmap {
                            HeatmapChartCard(flights: filteredFlights)
                        } else {
                            FlightsSpotsMapView(flights: filteredFlights)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Graphiques")
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showingCustomDatePicker) {
                CustomDateRangePicker(startDate: $customStartDate, endDate: $customEndDate)
            }
        }
    }
}

// MARK: - TimelineChartCard (Graphique Timeline)

struct TimelineChartCard: View {
    let flights: [Flight]
    let period: ChartsView.TimePeriod

    struct DayData: Identifiable {
        let id = UUID()
        let date: Date
        let count: Int
        let hours: Double
    }

    var chartData: [DayData] {
        let calendar = Calendar.current
        let grouped: [Date: [Flight]]

        // Grouper par jour, semaine ou mois selon la période
        switch period {
        case .week, .month:
            // Grouper par jour
            grouped = Dictionary(grouping: flights) { flight in
                calendar.startOfDay(for: flight.startDate)
            }
        case .threeMonths, .sixMonths, .year:
            // Grouper par semaine
            grouped = Dictionary(grouping: flights) { flight in
                let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: flight.startDate)
                return calendar.date(from: components) ?? flight.startDate
            }
        case .custom, .all:
            // Grouper par mois
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
            // En-tête
            VStack(alignment: .leading, spacing: 4) {
                Text("Activité")
                    .font(.title2)
                    .fontWeight(.bold)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(totalFlights)")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                        Text(totalFlights > 1 ? "vols" : "vol")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f", totalHours))
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                        Text("heures")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal)

            Divider()

            // Graphique
            if chartData.isEmpty {
                ContentUnavailableView(
                    "Aucun vol",
                    systemImage: "chart.bar",
                    description: Text("Aucun vol durant cette période")
                )
                .frame(height: 200)
            } else {
                Chart(chartData) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: chartUnit),
                        y: .value("Vols", item.count)
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

// MARK: - HeatmapChartCard (Graphique Heatmap des spots)

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
        let grouped = Dictionary(grouping: flights) { $0.spotName ?? "Inconnu" }
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
            // En-tête
            VStack(alignment: .leading, spacing: 4) {
                Text("Spots de vol")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("\(spotData.count) \(spotData.count > 1 ? "spots" : "spot") \(spotData.count > 1 ? "différents" : "différent")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Divider()

            // Liste des spots avec barres
            if spotData.isEmpty {
                ContentUnavailableView(
                    "Aucun spot",
                    systemImage: "map",
                    description: Text("Aucun vol durant cette période")
                )
                .frame(height: 200)
            } else {
                VStack(spacing: 12) {
                    ForEach(spotData.prefix(10)) { spot in
                        SpotRow(spot: spot, maxCount: maxCount)
                    }

                    if spotData.count > 10 {
                        let remaining = spotData.count - 10
                        Text("+ \(remaining) \(remaining > 1 ? "autres" : "autre") \(remaining > 1 ? "spots" : "spot")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
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

// MARK: - SpotRow (Ligne d'un spot dans la heatmap)

struct SpotRow: View {
    let spot: HeatmapChartCard.SpotData
    let maxCount: Int

    var barWidth: CGFloat {
        CGFloat(spot.count) / CGFloat(maxCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Nom et stats
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
                        Text(spot.count > 1 ? "vols" : "vol")
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

            // Barre de progression
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Fond
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    // Barre colorée
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .green],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * barWidth)

                    // Pourcentage
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
            flight.spotName ?? "Spot inconnu"
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Carte des spots")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if spotData.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Aucun spot avec coordonnées GPS")
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
                                Circle()
                                    .fill(Color.blue.gradient)
                                    .frame(width: max(20, min(60, spot.hours * 10)))
                                    .overlay {
                                        Text("\(Int(spot.hours))h")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.white)
                                    }
                                Text(spot.name)
                                    .font(.caption2)
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.9))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
                .frame(height: 400)
                .cornerRadius(12)
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
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
                Section("Période personnalisée") {
                    DatePicker("Date de début", selection: $startDate, displayedComponents: .date)
                    DatePicker("Date de fin", selection: $endDate, displayedComponents: .date)
                }
            }
            .navigationTitle("Choisir la période")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valider") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ChartsView()
        .environment(DataController())
}
