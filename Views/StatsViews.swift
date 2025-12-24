//
//  StatsViews.swift
//  ParaFlightLog
//
//  Vues liées aux statistiques : vue principale, graphiques par voile/spot
//  Target: iOS only
//

import SwiftUI
import SwiftData
import Charts

// MARK: - StatsView (Statistiques améliorées)

struct StatsView: View {
    @Environment(DataController.self) private var dataController
    @Query private var flights: [Flight]
    @Query(filter: #Predicate<Wing> { !$0.isArchived }) private var wings: [Wing]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Carte totale
                    TotalStatsCard(flights: flights)

                    // Tableau et graphique par voile
                    StatsByWingSection(flights: flights, wings: wings)

                    // Tableau et graphique par spot
                    StatsBySpotSection(flights: flights)
                }
                .padding()
            }
            .navigationTitle("Statistiques")
            .background(Color(.systemGroupedBackground))
        }
    }
}

// MARK: - TotalStatsCard

struct TotalStatsCard: View {
    let flights: [Flight]

    var body: some View {
        VStack(spacing: 16) {
            Text("Total")
                .font(.title2)
                .fontWeight(.bold)

            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60

            HStack(spacing: 40) {
                VStack(spacing: 4) {
                    Text("\(flights.count)")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.blue)
                    Text("session\(flights.count > 1 ? "s" : "")")
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
                    Text("temps de vol")
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
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    let wings: [Wing]
    @State private var selectedWing: Wing?

    var wingStats: [(wing: Wing, sessions: Int, hours: Int, minutes: Int)] {
        wings.compactMap { wing in
            let wingFlights = flights.filter { $0.wing?.id == wing.id }
            guard !wingFlights.isEmpty else { return nil }

            let totalSeconds = wingFlights.reduce(0) { $0 + $1.durationSeconds }
            return (
                wing: wing,
                sessions: wingFlights.count,
                hours: totalSeconds / 3600,
                minutes: (totalSeconds % 3600) / 60
            )
        }
        .sorted { $0.hours * 60 + $0.minutes > $1.hours * 60 + $1.minutes }
    }

    /// Abrège un nom de voile en supprimant les mots de marques
    private func abbreviateWingName(_ name: String) -> String {
        // Supprimer les marques connues (pas de remplacement, juste suppression)
        var abbreviated = name
        abbreviated = abbreviated.replacingOccurrences(of: "Moustache ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Skyman ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Advance ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Ozone ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Nova ", with: "", options: .caseInsensitive)

        return abbreviated.trimmingCharacters(in: .whitespaces)
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "bleu": return .blue
        case "rouge": return .red
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        case "gris": return .gray
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Par voile")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if wingStats.isEmpty {
                Text("Aucune donnée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                // Tableau
                VStack(spacing: 0) {
                    // En-tête
                    HStack {
                        Text("Voile")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Sessions")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("Temps")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    // Lignes
                    ForEach(wingStats, id: \.wing.id) { stat in
                        Button {
                            selectedWing = stat.wing
                        } label: {
                            HStack(spacing: 8) {
                                // Photo de la voile avec cache (24x24)
                                CachedImage(
                                    data: stat.wing.photoData,
                                    key: stat.wing.id.uuidString,
                                    size: CGSize(width: 24, height: 24)
                                ) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(colorFromString(stat.wing.color ?? "Gris").opacity(0.3))
                                        .overlay {
                                            Image(systemName: "wind")
                                                .font(.system(size: 10))
                                                .foregroundStyle(colorFromString(stat.wing.color ?? "Gris"))
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

                // Graphique
                if #available(iOS 16.0, *) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Répartition des heures")
                            .font(.headline)
                            .padding(.horizontal)

                        Chart {
                            ForEach(wingStats, id: \.wing.id) { stat in
                                let hours = Double(stat.hours * 60 + stat.minutes) / 60.0
                                let maxMinutes = (wingStats.first?.hours ?? 1) * 60 + (wingStats.first?.minutes ?? 0)
                                let maxHours = Double(maxMinutes) / 60.0
                                let scaledHours = (hours / maxHours) * 0.85 * maxHours

                                let wingLabel = stat.wing.size != nil
                                    ? "\(abbreviateWingName(stat.wing.name)) (\(stat.wing.size!) m²)"
                                    : abbreviateWingName(stat.wing.name)

                                BarMark(
                                    x: .value("Heures", scaledHours),
                                    y: .value("Voile", wingLabel)
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
        }
        .sheet(item: $selectedWing) { wing in
            WingFlightsDetailView(wing: wing, flights: flights)
        }
    }
}

// MARK: - StatsBySpotSection

struct StatsBySpotSection: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    @State private var selectedSpot: String?

    var spotStats: [(spot: String, sessions: Int, hours: Int, minutes: Int)] {
        let grouped = Dictionary(grouping: flights, by: { $0.spotName ?? "Spot inconnu" })

        return grouped.map { spot, spotFlights in
            let totalSeconds = spotFlights.reduce(0) { $0 + $1.durationSeconds }
            return (
                spot: spot,
                sessions: spotFlights.count,
                hours: totalSeconds / 3600,
                minutes: (totalSeconds % 3600) / 60
            )
        }
        .sorted { $0.hours * 60 + $0.minutes > $1.hours * 60 + $1.minutes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Par spot")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if spotStats.isEmpty {
                Text("Aucune donnée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                // Tableau
                VStack(spacing: 0) {
                    // En-tête
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

                        Text("Temps")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    // Lignes
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

                // Graphique
                if #available(iOS 16.0, *) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Répartition des heures")
                            .font(.headline)
                            .padding(.horizontal)

                        Chart {
                            ForEach(spotStats, id: \.spot) { stat in
                                BarMark(
                                    x: .value("Heures", Double(stat.hours * 60 + stat.minutes) / 60.0),
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

// MARK: - WingFlightsDetailView (Détail des vols par voile)

struct WingFlightsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let wing: Wing
    let flights: [Flight]

    // Calculer les vols filtrés immédiatement lors de l'init
    private let wingFlights: [Flight]

    init(wing: Wing, flights: [Flight]) {
        self.wing = wing
        self.flights = flights
        // Pré-calculer les vols de cette voile
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
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - SpotFlightsDetailView (Détail des vols par spot)

struct SpotFlightsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let spotName: String
    let flights: [Flight]

    // Calculer les vols filtrés immédiatement lors de l'init
    private let spotFlights: [Flight]

    init(spotName: String, flights: [Flight]) {
        self.spotName = spotName
        self.flights = flights
        // Pré-calculer les vols de ce spot
        self.spotFlights = flights
            .filter { $0.spotName == spotName }
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
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
        }
    }
}
