//
//  BadgesView.swift
//  ParaFlightLog
//
//  Vues pour l'affichage des badges et de la progression
//  Target: iOS only
//

import SwiftUI

// MARK: - BadgesView

/// Vue principale affichant tous les badges organisés par catégorie
struct BadgesView: View {
    @State private var selectedCategory: BadgeCategory?
    @State private var selectedBadge: Badge?

    private let badgeService = BadgeService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Filtre par catégorie
                    CategoryFilterBar(selectedCategory: $selectedCategory)

                    // Résumé de progression
                    ProgressSummaryCard()

                    // Grille de badges
                    BadgesGrid(
                        badges: filteredBadges,
                        selectedBadge: $selectedBadge
                    )
                }
                .padding()
            }
            .navigationTitle("Badges".localized)
            .sheet(item: $selectedBadge) { badge in
                BadgeDetailView(badge: badge)
            }
            .refreshable {
                await refreshBadges()
            }
        }
    }

    private var filteredBadges: [Badge] {
        if let category = selectedCategory {
            return badgeService.allBadges.filter { $0.category == category }
        }
        return badgeService.allBadges
    }

    private func refreshBadges() async {
        await badgeService.loadAllBadges()
        if let userId = UserService.shared.currentUserProfile?.id {
            await badgeService.loadUserBadges(userId: userId)
        }
    }
}

// MARK: - CategoryFilterBar

struct CategoryFilterBar: View {
    @Binding var selectedCategory: BadgeCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Bouton "Tous"
                FilterChipButton(
                    title: "Tous".localized,
                    icon: "square.grid.2x2",
                    isSelected: selectedCategory == nil
                ) {
                    selectedCategory = nil
                }

                // Boutons par catégorie
                ForEach(BadgeCategory.allCases, id: \.self) { category in
                    FilterChipButton(
                        title: category.displayName,
                        icon: category.icon,
                        isSelected: selectedCategory == category
                    ) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct FilterChipButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ProgressSummaryCard

struct ProgressSummaryCard: View {
    private let badgeService = BadgeService.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Progression".localized)
                        .font(.headline)

                    Text("\(earnedCount)/\(totalCount) badges obtenus")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Cercle de progression
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray5), lineWidth: 6)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .frame(width: 50, height: 50)
            }

            // XP total
            if let profile = UserService.shared.currentUserProfile {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text("\(profile.xpTotal) XP")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Text("Niveau \(profile.level)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var earnedCount: Int {
        badgeService.userBadges.count
    }

    private var totalCount: Int {
        badgeService.allBadges.count
    }

    private var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(earnedCount) / Double(totalCount)
    }
}

// MARK: - BadgesGrid

struct BadgesGrid: View {
    let badges: [Badge]
    @Binding var selectedBadge: Badge?

    private let badgeService = BadgeService.shared
    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(badges) { badge in
                BadgeCard(
                    badge: badge,
                    isEarned: badgeService.hasBadge(badge.id)
                )
                .onTapGesture {
                    selectedBadge = badge
                }
            }
        }
    }
}

// MARK: - BadgeCard

struct BadgeCard: View {
    let badge: Badge
    let isEarned: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Icône du badge
            ZStack {
                Circle()
                    .fill(isEarned ? tierColor.opacity(0.2) : Color(.systemGray5))
                    .frame(width: 60, height: 60)

                Image(systemName: badge.icon)
                    .font(.title2)
                    .foregroundStyle(isEarned ? tierColor : Color(.systemGray3))
            }

            // Nom du badge
            Text(badge.localizedName)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(isEarned ? .primary : .secondary)

            // Tier
            Text(badge.tier.displayName)
                .font(.caption2)
                .foregroundStyle(isEarned ? tierColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(isEarned ? 1 : 0.6)
    }

    private var tierColor: Color {
        switch badge.tier {
        case .bronze: return Color(hex: "#CD7F32") ?? .brown
        case .silver: return Color(.systemGray)
        case .gold: return Color(hex: "#FFD700") ?? .yellow
        case .platinum: return Color(hex: "#E5E4E2") ?? .gray
        }
    }
}

// MARK: - BadgeDetailView

struct BadgeDetailView: View {
    let badge: Badge
    @Environment(\.dismiss) private var dismiss

    private let badgeService = BadgeService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header avec icône
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(isEarned ? tierColor.opacity(0.2) : Color(.systemGray5))
                                .frame(width: 100, height: 100)

                            Image(systemName: badge.icon)
                                .font(.system(size: 44))
                                .foregroundStyle(isEarned ? tierColor : Color(.systemGray3))

                            if isEarned {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.green)
                                    .background(Circle().fill(.white))
                                    .offset(x: 35, y: 35)
                            }
                        }

                        Text(badge.localizedName)
                            .font(.title2)
                            .fontWeight(.bold)

                        HStack(spacing: 8) {
                            Text(badge.tier.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(tierColor)

                            Text("•")
                                .foregroundStyle(.secondary)

                            Text(badge.category.displayName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description".localized)
                            .font(.headline)

                        Text(badge.localizedDescription)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Progression
                    if let profile = UserService.shared.currentUserProfile {
                        let progress = badgeService.getProgress(for: badge, profile: profile)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Progression".localized)
                                .font(.headline)

                            HStack {
                                ProgressView(value: progress.progress)
                                    .tint(tierColor)

                                Text(progress.progressText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if isEarned, let earnedDate = earnedDate {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Obtenu le \(earnedDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Récompense XP
                    HStack {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text("\(badge.xpReward) XP")
                            .font(.headline)
                        Spacer()
                        if !isEarned {
                            Text("À débloquer".localized)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Détail du badge".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer".localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var isEarned: Bool {
        badgeService.hasBadge(badge.id)
    }

    private var earnedDate: Date? {
        badgeService.userBadges.first { $0.badgeId == badge.id }?.earnedAt
    }

    private var tierColor: Color {
        switch badge.tier {
        case .bronze: return Color(hex: "#CD7F32") ?? .brown
        case .silver: return Color(.systemGray)
        case .gold: return Color(hex: "#FFD700") ?? .yellow
        case .platinum: return Color(hex: "#E5E4E2") ?? .gray
        }
    }
}

// MARK: - LevelProgressView

/// Vue compacte de la progression de niveau (pour le profil)
struct LevelProgressView: View {
    let level: Int
    let xpTotal: Int

    private var xpForCurrentLevel: Int {
        let thresholds = [
            0, 100, 200, 300, 400, 500,
            600, 800, 1000, 1200, 1400,
            1600, 1800, 2000, 2200, 2500,
            2800, 3100, 3500, 3900, 4300,
            4700, 5100, 5600, 6100, 6700,
            7300, 8000, 8700, 9500, 10500
        ]
        guard level > 0 && level <= thresholds.count else { return 0 }
        return thresholds[level - 1]
    }

    private var xpForNextLevel: Int {
        let thresholds = [
            0, 100, 200, 300, 400, 500,
            600, 800, 1000, 1200, 1400,
            1600, 1800, 2000, 2200, 2500,
            2800, 3100, 3500, 3900, 4300,
            4700, 5100, 5600, 6100, 6700,
            7300, 8000, 8700, 9500, 10500
        ]
        guard level < thresholds.count else { return thresholds.last ?? 10500 }
        return thresholds[level]
    }

    private var progress: Double {
        let xpInCurrentLevel = xpTotal - xpForCurrentLevel
        let xpNeeded = xpForNextLevel - xpForCurrentLevel
        guard xpNeeded > 0 else { return 1.0 }
        return min(Double(xpInCurrentLevel) / Double(xpNeeded), 1.0)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Niveau \(level)")
                    .font(.headline)
                Spacer()
                Text("\(xpTotal) XP")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(.accentColor)

            HStack {
                Text("\(xpForCurrentLevel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(xpForNextLevel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - BadgeEarnedAlert

/// Vue d'alerte quand un badge est obtenu
struct BadgeEarnedAlert: View {
    let badge: Badge
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Animation de confettis ou étoiles pourrait être ajoutée ici

            Text("Badge obtenu !".localized)
                .font(.title2)
                .fontWeight(.bold)

            ZStack {
                Circle()
                    .fill(tierColor.opacity(0.2))
                    .frame(width: 100, height: 100)

                Image(systemName: badge.icon)
                    .font(.system(size: 44))
                    .foregroundStyle(tierColor)
            }

            Text(badge.localizedName)
                .font(.title3)
                .fontWeight(.semibold)

            Text(badge.localizedDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("+\(badge.xpReward) XP")
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())

            Button(action: onDismiss) {
                Text("Super !".localized)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(24)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 20)
        .padding(40)
    }

    private var tierColor: Color {
        switch badge.tier {
        case .bronze: return Color(hex: "#CD7F32") ?? .brown
        case .silver: return Color(.systemGray)
        case .gold: return Color(hex: "#FFD700") ?? .yellow
        case .platinum: return Color(hex: "#E5E4E2") ?? .gray
        }
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
