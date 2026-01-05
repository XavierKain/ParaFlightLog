//
//  LeaderboardsView.swift
//  ParaFlightLog
//
//  Vues pour l'affichage des classements globaux et nationaux
//  Target: iOS only
//

import SwiftUI

// MARK: - LeaderboardsView

/// Vue principale des classements avec onglets par type
struct LeaderboardsView: View {
    @State private var selectedType: LeaderboardType = .flightHours
    @State private var selectedScope: LeaderboardScope = .global
    @State private var entries: [LeaderboardEntry] = []
    @State private var userRank: UserRank?
    @State private var isLoading = false
    @State private var error: String?

    private let leaderboardService = LeaderboardService.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Sélecteur de type
                LeaderboardTypePicker(selectedType: $selectedType)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Sélecteur de portée
                Picker("Portée", selection: $selectedScope) {
                    ForEach(LeaderboardScope.allCases) { scope in
                        Label(scope.displayName, systemImage: scope.icon)
                            .tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                // Contenu
                if isLoading && entries.isEmpty {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let error = error {
                    Spacer()
                    ErrorStateView(message: error) {
                        Task { await loadLeaderboard() }
                    }
                    Spacer()
                } else {
                    // Rang de l'utilisateur
                    if let userRank = userRank {
                        UserRankCard(rank: userRank, type: selectedType)
                            .padding(.horizontal)
                    }

                    // Liste des entrées
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                LeaderboardRow(entry: entry, type: selectedType)
                            }
                        }
                        .padding(.vertical)
                    }
                    .refreshable {
                        leaderboardService.invalidateCache()
                        await loadLeaderboard()
                    }
                }
            }
            .navigationTitle("Classements".localized)
            .task {
                await loadLeaderboard()
            }
            .onChange(of: selectedType) { _, _ in
                Task { await loadLeaderboard() }
            }
            .onChange(of: selectedScope) { _, _ in
                Task { await loadLeaderboard() }
            }
        }
    }

    private func loadLeaderboard() async {
        isLoading = true
        error = nil

        do {
            // Charger le classement
            if selectedScope == .global {
                entries = try await leaderboardService.getGlobalLeaderboard(type: selectedType)
            } else {
                // Pour le national, utiliser le pays de l'utilisateur
                let country = UserService.shared.currentUserProfile?.homeLocationName ?? "France"
                entries = try await leaderboardService.getNationalLeaderboard(type: selectedType, country: country)
            }

            // Charger le rang de l'utilisateur
            userRank = try? await leaderboardService.getUserRank(type: selectedType)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - LeaderboardTypePicker

struct LeaderboardTypePicker: View {
    @Binding var selectedType: LeaderboardType

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(LeaderboardType.allCases) { type in
                    Button {
                        selectedType = type
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: type.icon)
                                .font(.title3)
                            Text(type.displayName)
                                .font(.caption)
                        }
                        .frame(width: 80)
                        .padding(.vertical, 12)
                        .background(selectedType == type ? Color.accentColor : Color(.secondarySystemBackground))
                        .foregroundStyle(selectedType == type ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - UserRankCard

struct UserRankCard: View {
    let rank: UserRank
    let type: LeaderboardType

    var body: some View {
        HStack {
            // Rang
            VStack(spacing: 2) {
                Text("#\(rank.rank)")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("sur \(rank.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: 40)
                .padding(.horizontal, 12)

            // Valeur
            VStack(alignment: .leading, spacing: 2) {
                Text("Votre score".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formattedValue)
                    .font(.headline)
            }

            Spacer()

            // Percentile
            Text(rank.percentileText)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(percentileColor)
                .clipShape(Capsule())
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var formattedValue: String {
        switch type {
        case .flightHours:
            let hours = rank.value / 3600
            let minutes = (rank.value % 3600) / 60
            return "\(hours)h\(String(format: "%02d", minutes))"
        case .totalFlights:
            return "\(rank.value) vols"
        case .level:
            return "Niv. \(UserService.shared.currentUserProfile?.level ?? 1)"
        case .longestStreak:
            return "\(rank.value) jours"
        }
    }

    private var percentileColor: Color {
        if rank.percentile <= 1 {
            return .purple
        } else if rank.percentile <= 5 {
            return Color(hex: "#FFD700") ?? .yellow
        } else if rank.percentile <= 10 {
            return .orange
        } else if rank.percentile <= 25 {
            return .blue
        } else {
            return .gray
        }
    }
}

// MARK: - LeaderboardRow

struct LeaderboardRow: View {
    let entry: LeaderboardEntry
    let type: LeaderboardType

    private var isCurrentUser: Bool {
        entry.oderId == UserService.shared.currentUserProfile?.id
    }

    var body: some View {
        HStack(spacing: 12) {
            // Rang
            RankBadge(rank: entry.rank)

            // Avatar
            ProfilePhotoView(
                fileId: entry.profilePhotoFileId,
                displayName: entry.displayName,
                size: 44
            )

            // Info pilote
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isCurrentUser ? Color.accentColor : Color.primary)

                Text("@\(entry.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Valeur
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.formattedValue(for: type))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("Niv. \(entry.level)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(isCurrentUser ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}

// MARK: - RankBadge

struct RankBadge: View {
    let rank: Int

    var body: some View {
        ZStack {
            if rank <= 3 {
                Image(systemName: "medal.fill")
                    .font(.title2)
                    .foregroundStyle(medalColor)
            } else {
                Text("\(rank)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32)
    }

    private var medalColor: Color {
        switch rank {
        case 1: return Color(hex: "#FFD700") ?? .yellow
        case 2: return Color(.systemGray)
        case 3: return Color(hex: "#CD7F32") ?? .brown
        default: return .clear
        }
    }
}

// MARK: - ErrorStateView

struct ErrorStateView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Réessayer".localized, action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

// MARK: - LeaderboardPreviewCard

/// Carte compacte de classement pour le profil
struct LeaderboardPreviewCard: View {
    let type: LeaderboardType
    @State private var userRank: UserRank?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: type.icon)
                    .foregroundStyle(Color.accentColor)
                Text(type.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if let rank = userRank {
                HStack {
                    Text("#\(rank.rank)")
                        .font(.title3)
                        .fontWeight(.bold)

                    Spacer()

                    Text(rank.percentileText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !isLoading {
                Text("--")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await loadRank()
        }
    }

    private func loadRank() async {
        isLoading = true
        userRank = try? await LeaderboardService.shared.getUserRank(type: type)
        isLoading = false
    }
}
