//
//  SpotViews.swift
//  ParaFlightLog
//
//  Vues pour les spots de vol
//  Détail spot, classements, abonnements
//  Target: iOS only
//

import SwiftUI
import MapKit

// MARK: - SpotDetailView

struct SpotDetailView: View {
    let spotId: String

    @State private var spot: Spot?
    @State private var flights: [PublicFlight] = []
    @State private var isLoading = true
    @State private var isSubscribed = false
    @State private var error: String?
    @State private var selectedTab: SpotTab = .flights

    enum SpotTab: String, CaseIterable {
        case flights = "Vols"
        case stats = "Stats"
        case leaderboard = "Classement"

        var localized: String { rawValue.localized }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Chargement...".localized)
            } else if let error = error {
                ErrorView(message: error) {
                    Task { await loadSpot() }
                }
            } else if let spot = spot {
                ScrollView {
                    VStack(spacing: 16) {
                        // Header
                        SpotHeaderView(spot: spot, isSubscribed: isSubscribed) {
                            await toggleSubscription()
                        }

                        // Map
                        SpotMapView(spot: spot)
                            .frame(height: 180)
                            .cornerRadius(12)

                        // Tabs
                        Picker("Tab", selection: $selectedTab) {
                            ForEach(SpotTab.allCases, id: \.self) { tab in
                                Text(tab.localized).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)

                        // Content
                        switch selectedTab {
                        case .flights:
                            SpotFlightsSection(spotId: spotId, flights: flights)
                        case .stats:
                            SpotStatsSection(spot: spot)
                        case .leaderboard:
                            SpotLeaderboardSection(spotId: spotId)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(spot?.name ?? "Spot".localized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSpot()
        }
    }

    private func loadSpot() async {
        isLoading = true
        error = nil

        do {
            spot = try await SpotService.shared.getSpot(spotId: spotId)
            flights = try await SpotService.shared.getFlightsAtSpot(spotId: spotId, limit: 20)
            isSubscribed = try await SpotService.shared.isSubscribed(spotId: spotId)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func toggleSubscription() async {
        do {
            if isSubscribed {
                try await SpotService.shared.unsubscribeFromSpot(spotId: spotId)
            } else {
                try await SpotService.shared.subscribeToSpot(spotId: spotId)
            }
            isSubscribed.toggle()
        } catch {
            logError("Failed to toggle subscription: \(error)", category: .sync)
        }
    }
}

// MARK: - SpotHeaderView

struct SpotHeaderView: View {
    let spot: Spot
    let isSubscribed: Bool
    let onToggleSubscription: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(spot.name)
                            .font(.title2)
                            .fontWeight(.bold)

                        if spot.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.blue)
                        }
                    }

                    if let region = spot.region, let country = spot.country {
                        Text("\(region), \(country)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    Task { await onToggleSubscription() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isSubscribed ? "bell.fill" : "bell")
                        Text(isSubscribed ? "Abonné".localized : "S'abonner".localized)
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isSubscribed ? Color.blue : Color.blue.opacity(0.15))
                    .foregroundStyle(isSubscribed ? .white : .blue)
                    .cornerRadius(20)
                }
            }

            // Quick stats
            HStack(spacing: 24) {
                SpotQuickStat(value: "\(spot.totalFlights)", label: "Vols".localized)
                SpotQuickStat(value: spot.formattedTotalFlightTime, label: "Temps total".localized)
                SpotQuickStat(value: "\(spot.subscriberCount)", label: "Abonnés".localized)
            }

            // Description
            if let description = spot.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Wind directions
            if !spot.windDirections.isEmpty {
                HStack {
                    Image(systemName: "wind")
                        .foregroundStyle(.secondary)
                    Text(spot.windDirections.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - SpotQuickStat

struct SpotQuickStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - SpotMapView

struct SpotMapView: View {
    let spot: Spot

    @State private var cameraPosition: MapCameraPosition

    init(spot: Spot) {
        self.spot = spot
        _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
            center: spot.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )))
    }

    var body: some View {
        Map(position: $cameraPosition) {
            Annotation("", coordinate: spot.coordinate) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - SpotFlightsSection

struct SpotFlightsSection: View {
    let spotId: String
    let flights: [PublicFlight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if flights.isEmpty {
                Text("Aucun vol sur ce spot".localized)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(flights) { flight in
                    NavigationLink {
                        PublicFlightDetailView(flightId: flight.id)
                    } label: {
                        SpotFlightRow(flight: flight)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - SpotFlightRow

struct SpotFlightRow: View {
    let flight: PublicFlight

    var body: some View {
        HStack {
            // Avatar
            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(flight.pilotName.prefix(1).uppercased())
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(flight.pilotName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Text(flight.formattedDuration)
                    if let wing = flight.wingDescription {
                        Text("•")
                        Text(wing)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(flight.startDate, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Image(systemName: "heart")
                        Text("\(flight.likeCount)")
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "bubble.left")
                        Text("\(flight.commentCount)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - SpotStatsSection

struct SpotStatsSection: View {
    let spot: Spot

    var body: some View {
        VStack(spacing: 16) {
            // Main stats
            HStack(spacing: 16) {
                SpotStatCard(icon: "airplane", value: "\(spot.totalFlights)", label: "Total vols".localized, color: .blue)
                SpotStatCard(icon: "clock", value: spot.formattedTotalFlightTime, label: "Temps total".localized, color: .orange)
            }

            HStack(spacing: 16) {
                SpotStatCard(icon: "timer", value: spot.formattedAvgFlightTime, label: "Durée moyenne".localized, color: .green)
                SpotStatCard(icon: "trophy", value: spot.formattedLongestFlight, label: "Record durée".localized, color: .purple)
            }

            if let maxAlt = spot.maxAltitudeGain {
                HStack(spacing: 16) {
                    SpotStatCard(icon: "arrow.up", value: "\(Int(maxAlt)) m", label: "Alt max".localized, color: .red)
                    SpotStatCard(icon: "person.2", value: "\(spot.subscriberCount)", label: "Abonnés".localized, color: .cyan)
                }
            }

            // Last activity
            if let lastFlight = spot.lastFlightAt {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    Text("Dernier vol: \(lastFlight.formatted(date: .abbreviated, time: .omitted))".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - SpotStatCard

struct SpotStatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(value)
                .font(.headline)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - SpotLeaderboardSection

struct SpotLeaderboardSection: View {
    let spotId: String

    @State private var leaderboards: SpotLeaderboards?
    @State private var isLoading = true
    @State private var selectedCategory: LeaderboardCategory = .longestFlight

    enum LeaderboardCategory: String, CaseIterable {
        case longestFlight = "Plus long vol"
        case mostFlights = "Plus de vols"
        case totalTime = "Temps total"
        case highestAltitude = "Plus haute altitude"

        var localized: String { rawValue.localized }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Category picker
            Picker("Catégorie", selection: $selectedCategory) {
                ForEach(LeaderboardCategory.allCases, id: \.self) { category in
                    Text(category.localized).tag(category)
                }
            }
            .pickerStyle(.menu)

            if isLoading {
                ProgressView()
                    .padding()
            } else if let leaderboards = leaderboards {
                let entries: [SpotLeaderEntry] = {
                    switch selectedCategory {
                    case .longestFlight: return leaderboards.longestFlight
                    case .mostFlights: return leaderboards.mostFlights
                    case .totalTime: return leaderboards.totalTime
                    case .highestAltitude: return leaderboards.highestAltitude
                    }
                }()

                if entries.isEmpty {
                    Text("Aucune donnée disponible".localized)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(entries) { entry in
                        LeaderboardEntryRow(entry: entry)
                    }
                }
            }
        }
        .task {
            await loadLeaderboards()
        }
    }

    private func loadLeaderboards() async {
        isLoading = true
        do {
            leaderboards = try await SpotService.shared.getSpotLeaderboards(spotId: spotId)
        } catch {
            logError("Failed to load leaderboards: \(error)", category: .sync)
        }
        isLoading = false
    }
}

// MARK: - LeaderboardEntryRow

struct LeaderboardEntryRow: View {
    let entry: SpotLeaderEntry

    var body: some View {
        HStack(spacing: 12) {
            // Rank
            ZStack {
                Circle()
                    .fill(rankColor)
                    .frame(width: 32, height: 32)

                Text("\(entry.rank)")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }

            // Pilot
            NavigationLink {
                PilotProfileView(pilotId: entry.pilotId)
            } label: {
                HStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Text(entry.pilotName.prefix(1).uppercased())
                                .font(.caption)
                                .fontWeight(.semibold)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.pilotName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Text("@\(entry.pilotUsername)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Value
            Text(entry.formattedValue)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.blue)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var rankColor: Color {
        switch entry.rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .blue.opacity(0.7)
        }
    }
}

// MARK: - PilotProfileView (placeholder)

struct PilotProfileView: View {
    let pilotId: String

    @State private var pilot: PilotSummary?
    @State private var flights: [PublicFlight] = []
    @State private var isLoading = true
    @State private var isFollowing = false

    var body: some View {
        content
            .navigationTitle(pilot?.displayName ?? "Profil")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadData()
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    // Profile header
                    VStack(spacing: 12) {
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 80, height: 80)
                            .overlay {
                                Text(pilot?.displayName.prefix(1).uppercased() ?? "?")
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.blue)
                            }

                        Text(pilot?.displayName ?? "Pilote")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("@\(pilot?.username ?? "pilot")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button {
                            isFollowing.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isFollowing ? "person.badge.minus" : "person.badge.plus")
                                Text(isFollowing ? "Ne plus suivre".localized : "Suivre".localized)
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(isFollowing ? Color.secondary.opacity(0.2) : Color.blue)
                            .foregroundColor(isFollowing ? .primary : .white)
                            .cornerRadius(20)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Flights
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Vols publics".localized)
                            .font(.headline)

                        if flights.isEmpty {
                            Text("Aucun vol public".localized)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            ForEach(flights) { flight in
                                NavigationLink {
                                    PublicFlightDetailView(flightId: flight.id)
                                } label: {
                                    PublicFlightCardView(flight: flight)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    private func loadData() async {
        isLoading = true
        do {
            flights = try await DiscoveryService.shared.getPilotFlights(userId: pilotId)
            if let firstFlight = flights.first {
                pilot = PilotSummary(
                    id: pilotId,
                    displayName: firstFlight.pilotName,
                    username: firstFlight.pilotUsername,
                    profilePhotoFileId: firstFlight.pilotPhotoFileId
                )
            }
        } catch {
            logError("Failed to load pilot: \(error)", category: .sync)
        }
        isLoading = false
    }
}

// MARK: - SubscribedSpotsView

struct SubscribedSpotsView: View {
    @State private var spots: [Spot] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if spots.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)

                    Text("Vous n'êtes abonné à aucun spot".localized)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text("Abonnez-vous à des spots pour recevoir des notifications".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List(spots) { spot in
                    NavigationLink {
                        SpotDetailView(spotId: spot.id)
                    } label: {
                        SpotListRow(spot: spot)
                    }
                }
            }
        }
        .navigationTitle("Mes spots".localized)
        .task {
            await loadSpots()
        }
        .refreshable {
            await loadSpots()
        }
    }

    private func loadSpots() async {
        isLoading = true
        do {
            spots = try await SpotService.shared.getSubscribedSpots()
        } catch {
            logError("Failed to load subscribed spots: \(error)", category: .sync)
        }
        isLoading = false
    }
}

// MARK: - SpotListRow

struct SpotListRow: View {
    let spot: Spot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(spot.name)
                        .font(.headline)

                    if spot.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }

                if let region = spot.region {
                    Text(region)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "airplane")
                        Text("\(spot.totalFlights)")
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                        Text("\(spot.subscriberCount)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
