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

                        // Weather Widget
                        SpotWeatherWidget(
                            latitude: spot.latitude,
                            longitude: spot.longitude,
                            spotId: spot.id
                        )

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

// MARK: - PilotProfileView

struct PilotProfileView: View {
    let pilotId: String

    @State private var profile: CloudUserProfile?
    @State private var flights: [PublicFlight] = []
    @State private var badges: [EarnedBadge] = []
    @State private var isLoading = true
    @State private var isFollowing = false
    @State private var isTogglingFollow = false
    @State private var errorMessage: String?
    @State private var selectedSegment = 0
    @State private var isAnimatingStreak = false

    private let segments = ["Vols", "Badges", "Stats"]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "person.slash")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    // Header avec photo et stats
                    profileHeader

                    // Segmented picker
                    Picker("Section", selection: $selectedSegment) {
                        ForEach(0..<segments.count, id: \.self) { index in
                            Text(segments[index].localized).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    // Contenu selon le segment
                    switch selectedSegment {
                    case 0:
                        flightsSection
                    case 1:
                        badgesSection
                    case 2:
                        statsSection
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .navigationTitle(profile?.displayName ?? "Profil".localized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadData()
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(spacing: 0) {
            // Cover image / Hero section (same as ProfileHeaderView)
            ZStack(alignment: .bottom) {
                // Gradient cover
                LinearGradient(
                    colors: [.blue.opacity(0.6), .cyan.opacity(0.4), .teal.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 120)
                .overlay {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.white.opacity(0.1))
                        .offset(x: -50, y: -10)
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.white.opacity(0.08))
                        .offset(x: 80, y: 15)
                }

                // Profile photo overlapping cover
                VStack(spacing: 0) {
                    Spacer()
                    if let photoId = profile?.profilePhotoFileId {
                        ProfilePhotoView(fileId: photoId, displayName: profile?.displayName ?? "", size: 100)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color(.systemBackground), lineWidth: 4)
                            )
                            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                    } else {
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 100, height: 100)
                            .overlay {
                                Text(profile?.displayName.prefix(1).uppercased() ?? "?")
                                    .font(.system(size: 40, weight: .bold))
                                    .foregroundStyle(.blue)
                            }
                            .overlay(
                                Circle()
                                    .strokeBorder(Color(.systemBackground), lineWidth: 4)
                            )
                            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                    }
                }
                .offset(y: 50)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            // Profile info section (with padding for overlapping photo)
            VStack(spacing: 12) {
                Spacer()
                    .frame(height: 60)

                // Name and username
                VStack(spacing: 4) {
                    Text(profile?.displayName ?? "Pilote")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("@\(profile?.username ?? "pilot")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Level badge with prominent display
                if let level = profile?.level {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.subheadline)
                            .foregroundStyle(levelColor(level))
                        Text("Niveau \(level)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(levelColor(level).opacity(0.15))
                    .clipShape(Capsule())
                }

                // XP Progress bar
                if let xp = profile?.xpTotal, let level = profile?.level {
                    VStack(spacing: 6) {
                        HStack {
                            Text("\(xp) XP")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            Text("Prochain niveau: \(xpForLevel(level + 1)) XP")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.systemGray5))

                                RoundedRectangle(cornerRadius: 8)
                                    .fill(LinearGradient(
                                        colors: [levelColor(level), levelColor(level).opacity(0.7)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: geometry.size.width * levelProgress(for: level, xp: xp))
                            }
                        }
                        .frame(height: 10)
                    }
                    .padding(.horizontal)
                }

                // Streak with animation
                if let streak = profile?.currentStreak, streak > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
                            .scaleEffect(isAnimatingStreak ? 1.2 : 1.0)
                            .animation(
                                .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true),
                                value: isAnimatingStreak
                            )
                        Text("\(streak) jour\(streak > 1 ? "s" : "") de série")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear {
                        isAnimatingStreak = true
                    }
                }

                // Bio
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Additional info
                HStack(spacing: 20) {
                    if let weight = profile?.pilotWeight {
                        Label("\(Int(weight)) kg", systemImage: "scalemass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let location = profile?.homeLocationName, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Bouton suivre (sauf si c'est notre propre profil)
                if profile?.authUserId != AuthService.shared.currentUserId {
                    Button {
                        Task { await toggleFollow() }
                    } label: {
                        HStack(spacing: 6) {
                            if isTogglingFollow {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: isFollowing ? "person.badge.minus" : "person.badge.plus")
                            }
                            Text(isFollowing ? "Ne plus suivre".localized : "Suivre".localized)
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(isFollowing ? Color.secondary.opacity(0.2) : Color.blue)
                        .foregroundColor(isFollowing ? .primary : .white)
                        .clipShape(Capsule())
                    }
                    .disabled(isTogglingFollow)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }

    private func levelProgress(for level: Int, xp: Int) -> Double {
        let currentLevelStartXP = xpForLevel(level)
        let xpNeeded = level * 100 // XP needed for next level
        let xpInCurrentLevel = xp - currentLevelStartXP

        guard xpNeeded > 0 else { return 1.0 }
        let progress = Double(xpInCurrentLevel) / Double(xpNeeded)
        return min(max(progress, 0), 1)
    }

    // MARK: - Flights Section

    private var flightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if flights.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "airplane.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Aucun vol public".localized)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            } else {
                ForEach(flights) { flight in
                    NavigationLink {
                        PublicFlightDetailView(flightId: flight.id)
                    } label: {
                        PilotFlightRow(flight: flight)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
    }

    // MARK: - Badges Section

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if badges.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "medal")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Aucun badge obtenu".localized)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    ForEach(badges) { earnedBadge in
                        PilotBadgeItem(earnedBadge: earnedBadge)
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(spacing: 16) {
            // Niveau et XP
            VStack(spacing: 8) {
                HStack {
                    Text("Niveau".localized)
                        .font(.headline)
                    Spacer()
                    Text("\(profile?.level ?? 1)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(levelColor(profile?.level ?? 1))
                }

                // Barre de progression XP
                if let xp = profile?.xpTotal, let level = profile?.level {
                    let currentLevelXP = xpForLevel(level)
                    let nextLevelXP = xpForLevel(level + 1)
                    let progress = Double(xp - currentLevelXP) / Double(nextLevelXP - currentLevelXP)

                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(height: 8)

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(levelColor(level))
                                    .frame(width: geo.size.width * min(max(progress, 0), 1), height: 8)
                            }
                        }
                        .frame(height: 8)

                        HStack {
                            Text("\(xp) XP")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Niveau \(level + 1): \(nextLevelXP) XP")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Statistiques détaillées
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                PilotDetailStatCard(
                    icon: "airplane",
                    value: "\(profile?.totalFlights ?? 0)",
                    label: "Vols totaux".localized
                )

                PilotDetailStatCard(
                    icon: "clock.fill",
                    value: formatFlightHours(profile?.totalFlightSeconds ?? 0),
                    label: "Heures de vol".localized
                )

                PilotDetailStatCard(
                    icon: "flame.fill",
                    value: "\(profile?.currentStreak ?? 0) jours",
                    label: "Série actuelle".localized
                )

                PilotDetailStatCard(
                    icon: "trophy.fill",
                    value: "\(profile?.longestStreak ?? 0) jours",
                    label: "Meilleure série".localized
                )
            }

            // Date d'inscription
            if let createdAt = profile?.createdAt {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text("Membre depuis".localized)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(createdAt, format: .dateTime.month(.wide).year())
                        .fontWeight(.medium)
                }
                .font(.subheadline)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            // Charger le profil
            profile = try await UserService.shared.getPublicProfile(userId: pilotId)

            // Charger les vols
            flights = try await DiscoveryService.shared.getPilotFlights(userId: pilotId)

            // Charger les badges
            badges = try await BadgeService.shared.getUserBadges(userId: pilotId)

            // Vérifier si on suit ce pilote
            isFollowing = try await UserService.shared.isFollowing(userId: pilotId)
        } catch {
            logError("Failed to load pilot profile: \(error)", category: .sync)
            // Fallback si on a des vols mais pas de profil
            if !flights.isEmpty {
                profile = nil
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func toggleFollow() async {
        isTogglingFollow = true
        do {
            isFollowing = try await UserService.shared.toggleFollow(userId: pilotId)
        } catch {
            logError("Failed to toggle follow: \(error)", category: .sync)
        }
        isTogglingFollow = false
    }

    private func formatFlightHours(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        }
        return "\(minutes)m"
    }

    private func levelColor(_ level: Int) -> Color {
        switch level {
        case 1...10: return .blue
        case 11...20: return .green
        case 21...30: return .orange
        case 31...40: return .purple
        case 41...50: return .red
        default: return .yellow
        }
    }

    private func xpForLevel(_ level: Int) -> Int {
        // Seuils XP simplifiés
        let thresholds = [
            0, 100, 200, 300, 400, 500, 600, 800, 1000, 1200, 1400,
            1600, 1800, 2000, 2200, 2500, 2800, 3100, 3500, 3900, 4300
        ]
        if level <= thresholds.count {
            return thresholds[level - 1]
        }
        return thresholds.last! + (level - thresholds.count) * 500
    }
}

// MARK: - PilotStatItem

private struct PilotStatItem: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PilotFlightRow

private struct PilotFlightRow: View {
    let flight: PublicFlight

    var body: some View {
        HStack(spacing: 12) {
            // Date
            VStack(spacing: 2) {
                Text(flight.startDate, format: .dateTime.day())
                    .font(.title2)
                    .fontWeight(.bold)
                Text(flight.startDate, format: .dateTime.month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 50)

            // Détails
            VStack(alignment: .leading, spacing: 4) {
                Text(flight.spotName ?? "Vol".localized)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(flight.formattedDuration, systemImage: "clock")
                    if let alt = flight.formattedMaxAltitude {
                        Label(alt, systemImage: "arrow.up")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Badges
            HStack(spacing: 4) {
                if flight.hasPhotos {
                    Image(systemName: "photo.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if flight.hasGpsTrack {
                    Image(systemName: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - PilotBadgeItem

private struct PilotBadgeItem: View {
    let earnedBadge: EarnedBadge

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: earnedBadge.badge.icon)
                .font(.system(size: 30))
                .foregroundStyle(tierColor(earnedBadge.badge.tier))

            Text(earnedBadge.badge.localizedName)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(tierColor(earnedBadge.badge.tier).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tierColor(_ tier: BadgeTier) -> Color {
        switch tier {
        case .bronze: return .brown
        case .silver: return .gray
        case .gold: return .yellow
        case .platinum: return .purple
        }
    }
}

// MARK: - PilotDetailStatCard

private struct PilotDetailStatCard: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)

            Text(value)
                .font(.headline)
                .fontWeight(.bold)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
