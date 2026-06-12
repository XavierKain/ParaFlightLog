//
//  BadgesView.swift
//  ParaFlightLog
//
//  Vues pour l'affichage des badges et de la progression
//  Calcul 100 % local à partir des vols SwiftData
//  Target: iOS only
//

import SwiftUI
import SwiftData

// MARK: - BadgesView

/// Vue principale affichant tous les badges organisés par catégorie
struct BadgesView: View {
    @State private var selectedCategory: BadgeCategory?
    @State private var selectedBadge: Badge?

    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]
    @Query private var wings: [Wing]

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
            .task {
                refreshBadges()
            }
            .refreshable {
                refreshBadges()
            }
        }
    }

    private var filteredBadges: [Badge] {
        if let category = selectedCategory {
            return badgeService.allBadges.filter { $0.category == category }
        }
        return badgeService.allBadges
    }

    /// Vérifie et débloque les badges à partir des vols locaux
    private func refreshBadges() {
        badgeService.checkBadges(flights: flights, wings: wings)
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

            // XP total (calculé localement à partir des badges débloqués)
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("\(badgeService.totalXP) XP")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text("Niveau \(badgeService.level)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        case .bronze: return Color("#CD7F32")
        case .silver: return Color(.systemGray)
        case .gold: return Color("#FFD700")
        case .platinum: return Color("#E5E4E2")
        }
    }
}

// MARK: - BadgeDetailView

struct BadgeDetailView: View {
    let badge: Badge
    @Environment(\.dismiss) private var dismiss

    @Query private var flights: [Flight]

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

                    // Progression (calculée localement à partir des vols)
                    progressSection

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

                    // Bouton de partage (seulement si badge obtenu)
                    if isEarned, let earnedDate = earnedDate {
                        BadgeShareButton(badge: badge, earnedAt: earnedDate)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
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

    private var progressSection: some View {
        let progress = badgeService.getProgress(for: badge, flights: flights)

        return VStack(alignment: .leading, spacing: 12) {
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

    private var isEarned: Bool {
        badgeService.hasBadge(badge.id)
    }

    private var earnedDate: Date? {
        badgeService.earnedDate(for: badge.id)
    }

    private var tierColor: Color {
        switch badge.tier {
        case .bronze: return Color("#CD7F32")
        case .silver: return Color(.systemGray)
        case .gold: return Color("#FFD700")
        case .platinum: return Color("#E5E4E2")
        }
    }
}

// MARK: - LevelProgressView

/// Vue compacte de la progression de niveau (pour le profil)
/// XP et niveau calculés localement à partir des badges débloqués
struct LevelProgressView: View {
    let level: Int
    let xpTotal: Int

    private var xpForCurrentLevel: Int {
        let thresholds = BadgeService.levelThresholds
        guard level > 0 && level <= thresholds.count else { return 0 }
        return thresholds[level - 1]
    }

    private var xpForNextLevel: Int {
        let thresholds = BadgeService.levelThresholds
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
        case .bronze: return Color("#CD7F32")
        case .silver: return Color(.systemGray)
        case .gold: return Color("#FFD700")
        case .platinum: return Color("#E5E4E2")
        }
    }
}

// MARK: - Color Extension
// Note: Color(hex:) is now provided natively by SwiftUI in iOS 26+
// Our custom implementation has been removed to avoid conflicts
