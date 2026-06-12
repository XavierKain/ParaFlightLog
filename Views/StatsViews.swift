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

                    // Personal Records section
                    PersonalRecordsCard(flights: flights)

                    // Expérience pilote (toutes voiles, possédées et empruntées)
                    ExperienceSection(flights: flights)

                    // Matériel possédé (compteurs et alertes de révision)
                    GearSection(wings: wings)

                    // Tableau et graphique par voile
                    StatsByWingSection(flights: flights, wings: wings)

                    // Heures et vols par type de vol
                    FlightTypeStatsSection(flights: flights)

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

// MARK: - PersonalRecordsCard

struct PersonalRecordsCard: View {
    let flights: [Flight]

    private var longestFlight: Flight? {
        flights.max(by: { $0.durationSeconds < $1.durationSeconds })
    }

    private var highestAltitude: Flight? {
        flights.compactMap { flight in
            flight.maxAltitude != nil ? flight : nil
        }.max(by: { ($0.maxAltitude ?? 0) < ($1.maxAltitude ?? 0) })
    }

    private var longestDistance: Flight? {
        flights.compactMap { flight in
            flight.totalDistance != nil ? flight : nil
        }.max(by: { ($0.totalDistance ?? 0) < ($1.totalDistance ?? 0) })
    }

    private var fastestSpeed: Flight? {
        flights.compactMap { flight in
            flight.maxSpeed != nil ? flight : nil
        }.max(by: { ($0.maxSpeed ?? 0) < ($1.maxSpeed ?? 0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(.orange)
                Text("Records Personnels")
                    .font(.title3)
                    .fontWeight(.bold)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                // Longest flight
                if let flight = longestFlight {
                    RecordItem(
                        icon: "clock.fill",
                        color: .blue,
                        title: "Vol le plus long",
                        value: formatDuration(flight.durationSeconds),
                        subtitle: flight.spotName ?? "N/A"
                    )
                }

                // Highest altitude
                if let flight = highestAltitude, let altitude = flight.maxAltitude {
                    RecordItem(
                        icon: "arrow.up.circle.fill",
                        color: .orange,
                        title: "Altitude max",
                        value: "\(Int(altitude)) m",
                        subtitle: flight.spotName ?? "N/A"
                    )
                }

                // Longest distance
                if let flight = longestDistance, let distance = flight.totalDistance {
                    RecordItem(
                        icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
                        color: .cyan,
                        title: "Distance max",
                        value: distance >= 1000 ? String(format: "%.1f km", distance / 1000) : "\(Int(distance)) m",
                        subtitle: flight.spotName ?? "N/A"
                    )
                }

                // Fastest speed
                if let flight = fastestSpeed, let speed = flight.maxSpeed {
                    RecordItem(
                        icon: "speedometer",
                        color: .purple,
                        title: "Vitesse max",
                        value: "\(Int(speed * 3.6)) km/h",
                        subtitle: flight.spotName ?? "N/A"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)min"
        } else {
            return "\(minutes) min"
        }
    }
}

struct RecordItem: View {
    let icon: String
    let color: Color
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)

                Spacer()
            }

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)

            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - ExperienceSection (Mon expérience)

/// Expérience pilote : heures et vols agrégés par type d'aile et par taille,
/// toutes voiles confondues (possédées ET empruntées — c'est l'expérience qui compte)
struct ExperienceSection: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]

    // Stats pré-calculées à l'init (pattern du fichier)
    private let typeStats: [(label: String, sessions: Int, hours: Double)]
    private let sizeStats: [(label: String, sessions: Int, hours: Double)]

    init(flights: [Flight]) {
        self.flights = flights

        func aggregate(by key: (Flight) -> String) -> [(label: String, sessions: Int, hours: Double)] {
            Dictionary(grouping: flights, by: key)
                .map { label, group in
                    let totalSeconds = group.reduce(0) { $0 + $1.durationSeconds }
                    return (label: label, sessions: group.count, hours: Double(totalSeconds) / 3600.0)
                }
                .sorted { $0.hours > $1.hours }
        }

        self.typeStats = aggregate { $0.wing?.type ?? "Non défini" }
        self.sizeStats = aggregate { flight in
            if let size = flight.wing?.size {
                return "\(size) m²"
            }
            return "Non définie"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mon expérience")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if flights.isEmpty {
                Text("Aucune donnée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    // Par type d'aile
                    ExperienceSubList(title: "Par type d'aile", icon: "wind", stats: typeStats)

                    Divider()

                    // Par taille
                    ExperienceSubList(title: "Par taille", icon: "ruler", stats: sizeStats)
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
        }
    }
}

/// Sous-liste compacte pour ExperienceSection (type d'aile ou taille)
struct ExperienceSubList: View {
    @Environment(DataController.self) private var dataController
    let title: String
    let icon: String
    let stats: [(label: String, sessions: Int, hours: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(stats, id: \.label) { stat in
                HStack {
                    Text(stat.label)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(stat.sessions) vol\(stat.sessions > 1 ? "s" : "")")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(width: 70, alignment: .trailing)

                    Text(dataController.formatHours(stat.hours))
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - GearSection (Mon matériel)

/// Compteurs matériel : voiles possédées non vendues, avec alerte de révision
struct GearSection: View {
    @Environment(DataController.self) private var dataController
    let wings: [Wing]

    /// Voiles possédées et non vendues uniquement (le matériel actuel)
    private var ownedWings: [Wing] {
        wings.filter { $0.isOwned && $0.soldDate == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mon matériel")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if ownedWings.isEmpty {
                Text("Aucune voile possédée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(ownedWings) { wing in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(wing.name)
                                    .font(.body)
                                    .lineLimit(1)

                                if wing.isMaintenanceDue {
                                    Label("Révision à prévoir", systemImage: "wrench.and.screwdriver.fill")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Compteur total de la voile (heures à l'achat incluses)
                            Text(dataController.formatHours(wing.totalAirframeHours))
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundStyle(.blue)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)

                        if wing.id != ownedWings.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
        }
    }
}

// MARK: - FlightTypeStatsSection (Par type de vol)

/// Heures et nombre de vols par type de vol (Flight.flightType)
struct FlightTypeStatsSection: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]

    // Stats pré-calculées à l'init (pattern du fichier)
    private let typeStats: [(type: String?, label: String, sessions: Int, hours: Double)]

    init(flights: [Flight]) {
        self.flights = flights
        self.typeStats = Dictionary(grouping: flights, by: { $0.flightType })
            .map { type, group in
                let totalSeconds = group.reduce(0) { $0 + $1.durationSeconds }
                return (
                    type: type,
                    label: type ?? "Non défini",
                    sessions: group.count,
                    hours: Double(totalSeconds) / 3600.0
                )
            }
            .sorted { $0.hours > $1.hours }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Par type de vol")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if typeStats.isEmpty {
                Text("Aucune donnée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(typeStats, id: \.label) { stat in
                        HStack(spacing: 8) {
                            Image(systemName: FlightTypes.icon(for: stat.type))
                                .font(.body)
                                .foregroundStyle(.blue)
                                .frame(width: 28)

                            Text(stat.label)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("\(stat.sessions) vol\(stat.sessions > 1 ? "s" : "")")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .frame(width: 70, alignment: .trailing)

                            Text(dataController.formatHours(stat.hours))
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundStyle(.green)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)

                        if stat.label != typeStats.last?.label {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
            }
        }
    }
}

// MARK: - StatsByWingSection

struct StatsByWingSection: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    let wings: [Wing]
    @State private var selectedWing: Wing?

    // Cache des stats par voile - calculé une fois à l'init
    private let wingStats: [(wing: Wing, sessions: Int, hours: Int, minutes: Int)]

    init(flights: [Flight], wings: [Wing]) {
        self.flights = flights
        self.wings = wings
        // Pré-calculer les stats dès l'init
        self.wingStats = wings.compactMap { wing in
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

    /// Crée le label pour une voile dans le graphique
    private func wingChartLabel(for wing: Wing) -> String {
        if let size = wing.size {
            return "\(abbreviateWingName(wing.name)) (\(size) m²)"
        } else {
            return abbreviateWingName(wing.name)
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
                                        .fill((stat.wing.color ?? "Gris").toColor().opacity(0.3))
                                        .overlay {
                                            Image(systemName: "wind")
                                                .font(.system(size: 10))
                                                .foregroundStyle((stat.wing.color ?? "Gris").toColor())
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
                                let wingLabel = wingChartLabel(for: stat.wing)

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

    // Cache des stats par spot - calculé une fois à l'init
    private let spotStats: [(spot: String, sessions: Int, hours: Int, minutes: Int)]

    init(flights: [Flight]) {
        self.flights = flights
        // Pré-calculer les stats dès l'init
        let grouped = Dictionary(grouping: flights, by: { $0.spotName ?? "Spot inconnu" })
        self.spotStats = grouped.map { spot, spotFlights in
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
