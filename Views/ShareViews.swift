//
//  ShareViews.swift
//  ParaFlightLog
//
//  Vues de partage social pour vols et badges
//  Génération d'images et partage via ShareSheet
//  Target: iOS only
//

import SwiftUI

// MARK: - FlightShareView

/// Vue de prévisualisation et partage d'un vol
struct FlightShareView: View {
    let flight: PublicFlight
    @Environment(\.dismiss) private var dismiss

    @State private var shareImage: UIImage?
    @State private var isGenerating = false
    @State private var selectedFormat: ShareFormat = .instagram
    @State private var showingShareSheet = false

    enum ShareFormat: String, CaseIterable {
        case instagram = "Instagram Story"
        case square = "Carré"
        case standard = "Standard"

        var config: ShareImageConfig {
            switch self {
            case .instagram: return .instagram
            case .square: return .square
            case .standard: return .standard
            }
        }

        var icon: String {
            switch self {
            case .instagram: return "rectangle.portrait"
            case .square: return "square"
            case .standard: return "rectangle"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Format selector
                Picker("Format", selection: $selectedFormat) {
                    ForEach(ShareFormat.allCases, id: \.self) { format in
                        Label(format.rawValue, systemImage: format.icon)
                            .tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Preview
                ScrollView {
                    VStack(spacing: 16) {
                        if let image = shareImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 500)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(radius: 10)
                        } else if isGenerating {
                            ProgressView("Génération de l'image...".localized)
                                .frame(height: 400)
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemGray5))
                                .frame(height: 400)
                                .overlay {
                                    VStack(spacing: 12) {
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                            .foregroundStyle(.secondary)
                                        Text("Prévisualisation".localized)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                        }

                        // Flight info summary
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Informations du vol".localized)
                                .font(.headline)

                            HStack {
                                Label(flight.formattedDuration, systemImage: "clock.fill")
                                Spacer()
                                if let spotName = flight.spotName {
                                    Label(spotName, systemImage: "location.fill")
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                            HStack {
                                if let altitude = flight.maxAltitude {
                                    Text("Alt: \(Int(altitude))m")
                                }
                                Spacer()
                                if let distance = flight.formattedDistance {
                                    Text("Dist: \(distance)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding()
                }

                // Share button
                Button {
                    showingShareSheet = true
                } label: {
                    Label("Partager".localized, systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(shareImage != nil ? Color.blue : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(shareImage == nil)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Partager le vol".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }
            }
            .onChange(of: selectedFormat) { _, _ in
                generateImage()
            }
            .task {
                generateImage()
            }
            .sheet(isPresented: $showingShareSheet) {
                if let image = shareImage {
                    ShareSheet(
                        items: [
                            image,
                            ShareService.shared.generateFlightShareText(flight: flight)
                        ],
                        onComplete: { _ in }
                    )
                }
            }
        }
    }

    private func generateImage() {
        isGenerating = true
        Task { @MainActor in
            shareImage = ShareService.shared.generateFlightShareImage(
                flight: flight,
                config: selectedFormat.config
            )
            isGenerating = false
        }
    }
}

// MARK: - BadgeShareView

/// Vue de prévisualisation et partage d'un badge obtenu
struct BadgeShareView: View {
    let badge: Badge
    let earnedAt: Date
    @Environment(\.dismiss) private var dismiss

    @State private var shareImage: UIImage?
    @State private var isGenerating = false
    @State private var showingShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ScrollView {
                    VStack(spacing: 16) {
                        // Preview
                        if let image = shareImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 500)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(radius: 10)
                        } else if isGenerating {
                            ProgressView("Génération de l'image...".localized)
                                .frame(height: 400)
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemGray5))
                                .frame(height: 400)
                                .overlay {
                                    VStack(spacing: 12) {
                                        Image(systemName: badge.icon)
                                            .font(.largeTitle)
                                            .foregroundStyle(tierColor)
                                        Text("Prévisualisation".localized)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                        }

                        // Badge info summary
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(tierColor.opacity(0.2))
                                        .frame(width: 50, height: 50)

                                    Image(systemName: badge.icon)
                                        .font(.title2)
                                        .foregroundStyle(tierColor)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(badge.localizedName)
                                        .font(.headline)

                                    HStack(spacing: 6) {
                                        Text(badge.tier.displayName)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundStyle(tierColor)

                                        Text("•")
                                            .foregroundStyle(.secondary)

                                        Text(badge.category.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                        Text("+\(badge.xpReward) XP")
                                            .fontWeight(.semibold)
                                    }
                                    .font(.subheadline)
                                }
                            }

                            Text(badge.localizedDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Divider()

                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(.secondary)
                                Text("Obtenu le \(earnedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding()
                }

                // Share button
                Button {
                    showingShareSheet = true
                } label: {
                    Label("Partager".localized, systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(shareImage != nil ? tierColor : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(shareImage == nil)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Partager le badge".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }
            }
            .task {
                generateImage()
            }
            .sheet(isPresented: $showingShareSheet) {
                if let image = shareImage {
                    ShareSheet(
                        items: [
                            image,
                            ShareService.shared.generateBadgeShareText(badge: badge)
                        ],
                        onComplete: { _ in }
                    )
                }
            }
        }
    }

    private var tierColor: Color {
        switch badge.tier {
        case .bronze: return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .silver: return Color(red: 0.75, green: 0.75, blue: 0.75)
        case .gold: return Color(red: 1.0, green: 0.84, blue: 0.0)
        case .platinum: return Color(red: 0.9, green: 0.89, blue: 0.88)
        }
    }

    private func generateImage() {
        isGenerating = true
        Task { @MainActor in
            shareImage = ShareService.shared.generateBadgeShareImage(
                badge: badge,
                earnedAt: earnedAt,
                config: .square
            )
            isGenerating = false
        }
    }
}

// MARK: - ShareButton (Reusable component)
// Note: ShareSheet est défini dans SettingsViews.swift

/// Bouton de partage réutilisable pour les vols
struct FlightShareButton: View {
    let flight: PublicFlight
    @State private var showingShareView = false

    var body: some View {
        Button {
            showingShareView = true
        } label: {
            Label("Partager".localized, systemImage: "square.and.arrow.up")
        }
        .sheet(isPresented: $showingShareView) {
            FlightShareView(flight: flight)
        }
    }
}

/// Bouton de partage réutilisable pour les badges
struct BadgeShareButton: View {
    let badge: Badge
    let earnedAt: Date
    @State private var showingShareView = false

    var body: some View {
        Button {
            showingShareView = true
        } label: {
            Label("Partager".localized, systemImage: "square.and.arrow.up")
        }
        .sheet(isPresented: $showingShareView) {
            BadgeShareView(badge: badge, earnedAt: earnedAt)
        }
    }
}

// MARK: - Quick Share Button (Icon only)

/// Bouton de partage compact (icône uniquement)
struct QuickFlightShareButton: View {
    let flight: PublicFlight
    @State private var showingShareView = false

    var body: some View {
        Button {
            showingShareView = true
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.title3)
        }
        .sheet(isPresented: $showingShareView) {
            FlightShareView(flight: flight)
        }
    }
}

struct QuickBadgeShareButton: View {
    let badge: Badge
    let earnedAt: Date
    @State private var showingShareView = false

    var body: some View {
        Button {
            showingShareView = true
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.title3)
        }
        .sheet(isPresented: $showingShareView) {
            BadgeShareView(badge: badge, earnedAt: earnedAt)
        }
    }
}

// MARK: - Previews

#Preview("Flight Share") {
    FlightShareView(flight: PublicFlight(
        id: "test",
        pilotId: "pilot1",
        pilotName: "Jean Dupont",
        pilotUsername: "jeandupont",
        pilotPhotoFileId: nil,
        pilotLevel: 3,
        startDate: Date(),
        durationSeconds: 5400,
        spotId: "spot1",
        spotName: "Puy de Dôme",
        latitude: 45.77,
        longitude: 2.96,
        wingBrand: "Ozone",
        wingModel: "Rush 6",
        wingSize: "M",
        wingPhotoFileId: nil,
        maxAltitude: 1465,
        totalDistance: 12500,
        maxSpeed: 45,
        hasGpsTrack: true,
        likeCount: 5,
        commentCount: 2,
        hasPhotos: false,
        photoCount: 0,
        photoFileIds: [],
        createdAt: Date()
    ))
}

#Preview("Badge Share") {
    BadgeShareView(
        badge: Badge(
            id: "first_flight",
            name: "Premier Vol",
            nameEn: "First Flight",
            description: "Complétez votre premier vol",
            descriptionEn: "Complete your first flight",
            icon: "airplane.departure",
            category: .flights,
            tier: .bronze,
            requirementType: .totalFlights,
            requirementValue: 1,
            xpReward: 50
        ),
        earnedAt: Date()
    )
}
