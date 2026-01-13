//
//  ZoneProposalView.swift
//  ParaFlightLog
//
//  Vue pour proposer un nouveau nom de spot ou voter sur une proposition existante
//  Target: iOS only
//

import SwiftUI
import MapKit

// MARK: - Zone Proposal Card

struct ZoneProposalCard: View {
    let zone: SpotZone
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(zone.name)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if let parentSpotId = zone.parentSpotId {
                            Text("Renommage de spot")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Nouvelle zone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    ZoneStatusBadge(status: zone.status)
                }

                // Vote progress
                if zone.status == .pending {
                    VoteProgressView(
                        approvalWeight: zone.approvalWeight,
                        rejectionWeight: zone.rejectionWeight,
                        voterCount: zone.voterCount
                    )
                }

                // Footer
                HStack {
                    if let username = zone.createdByUsername {
                        Label("@\(username)", systemImage: "person.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let remaining = zone.formattedVotingTimeRemaining {
                        Label(remaining, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Zone Status Badge

struct ZoneStatusBadge: View {
    let status: ZoneStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(hex: status.color))
            .clipShape(Capsule())
    }
}

// MARK: - Vote Progress View

struct VoteProgressView: View {
    let approvalWeight: Double
    let rejectionWeight: Double
    let voterCount: Int

    private var totalWeight: Double {
        approvalWeight + rejectionWeight
    }

    private var approvalPercentage: Double {
        guard totalWeight > 0 else { return 0 }
        return (approvalWeight / totalWeight) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red.opacity(0.3))

                    // Approval
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.green)
                        .frame(width: geometry.size.width * (approvalPercentage / 100))
                }
            }
            .frame(height: 8)

            // Stats
            HStack {
                Text("\(Int(approvalPercentage))% pour")
                    .font(.caption)
                    .foregroundStyle(.green)

                Spacer()

                Text("\(voterCount) vote\(voterCount > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Zone Detail View

struct ZoneDetailView: View {
    let zone: SpotZone
    @State private var userVote: ZoneVote?
    @State private var isVoting = false
    @State private var showVoteSheet = false
    @State private var allVotes: [ZoneVote] = []
    @State private var canVote = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Map preview
                    ZoneMapPreview(zone: zone)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Zone info
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(zone.name)
                                .font(.title2.bold())

                            Spacer()

                            ZoneStatusBadge(status: zone.status)
                        }

                        if let reason = zone.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }

                        // Stats
                        HStack(spacing: 20) {
                            StatItem(value: String(format: "%.1f km²", zone.areaKm2), label: "Surface")
                            StatItem(value: "\(zone.flightCount)", label: "Vols")
                            StatItem(value: "\(zone.uniquePilotCount)", label: "Pilotes")
                        }
                    }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Vote section (if pending)
                    if zone.status == .pending {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Vote en cours")
                                .font(.headline)

                            VoteProgressView(
                                approvalWeight: zone.approvalWeight,
                                rejectionWeight: zone.rejectionWeight,
                                voterCount: zone.voterCount
                            )

                            if let remaining = zone.formattedVotingTimeRemaining {
                                Label("Se termine dans \(remaining)", systemImage: "clock")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                            }

                            // Vote buttons
                            if canVote {
                                HStack(spacing: 12) {
                                    Button {
                                        vote(type: .approve)
                                    } label: {
                                        Label(userVote?.vote == .approve ? "Approuvé" : "Approuver", systemImage: "checkmark.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                    .disabled(isVoting || userVote?.vote == .approve)

                                    Button {
                                        vote(type: .reject)
                                    } label: {
                                        Label(userVote?.vote == .reject ? "Rejeté" : "Rejeter", systemImage: "xmark.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.red)
                                    .disabled(isVoting || userVote?.vote == .reject)
                                }
                            } else {
                                Text("Vous devez avoir volé près de ce spot pour voter")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Proposer info
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proposé par")
                            .font(.headline)

                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading) {
                                Text("@\(zone.createdByUsername ?? "inconnu")")
                                    .font(.subheadline.weight(.medium))

                                Text(zone.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Votes list
                    if !allVotes.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Votes (\(allVotes.count))")
                                .font(.headline)

                            ForEach(allVotes) { voteItem in
                                VoteRow(vote: voteItem)
                            }
                        }
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("Proposition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadData()
            }
        }
    }

    private func loadData() async {
        // Charger le vote de l'utilisateur
        userVote = try? await ZoneVotingService.shared.getUserVote(for: zone.id)

        // Charger tous les votes
        allVotes = (try? await ZoneVotingService.shared.getVotes(for: zone.id)) ?? []

        // Vérifier si l'utilisateur peut voter
        canVote = await TrustService.shared.canProposeName()
    }

    private func vote(type: ZoneVoteType) {
        isVoting = true
        Task {
            do {
                userVote = try await ZoneVotingService.shared.vote(on: zone.id, voteType: type)
                await loadData()
            } catch {
                // Handle error
            }
            isVoting = false
        }
    }
}

// MARK: - Vote Row

struct VoteRow: View {
    let vote: ZoneVote

    var body: some View {
        HStack {
            Image(systemName: vote.isApproval ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(vote.isApproval ? .green : .red)

            VStack(alignment: .leading) {
                Text("@\(vote.username ?? "inconnu")")
                    .font(.subheadline)

                if let reason = vote.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text("×\(String(format: "%.1f", vote.weight))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Zone Map Preview

struct ZoneMapPreview: View {
    let zone: SpotZone

    var body: some View {
        Map {
            // Zone polygon
            if case .polygon(let coordinates) = zone.geometry {
                MapPolygon(coordinates: coordinates)
                    .foregroundStyle(.blue.opacity(0.2))
                    .stroke(.blue, lineWidth: 2)
            }

            // Zone circle
            if case .circle(let center, let radius) = zone.geometry {
                MapCircle(center: center, radius: radius)
                    .foregroundStyle(.blue.opacity(0.2))
                    .stroke(.blue, lineWidth: 2)
            }

            // Center marker
            Annotation(zone.name, coordinate: zone.coordinate) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
    }
}

// MARK: - Proposals List View

struct ZoneProposalsListView: View {
    @State private var pendingZones: [SpotZone] = []
    @State private var myZones: [SpotZone] = []
    @State private var isLoading = true
    @State private var selectedZone: SpotZone?
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("", selection: $selectedTab) {
                    Text("Près de moi").tag(0)
                    Text("Mes propositions").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if selectedTab == 0 {
                                if pendingZones.isEmpty {
                                    ContentUnavailableView(
                                        "Aucune proposition",
                                        systemImage: "map",
                                        description: Text("Il n'y a pas de propositions de zones en cours près de chez vous")
                                    )
                                } else {
                                    ForEach(pendingZones) { zone in
                                        ZoneProposalCard(zone: zone) {
                                            selectedZone = zone
                                        }
                                    }
                                }
                            } else {
                                if myZones.isEmpty {
                                    ContentUnavailableView(
                                        "Aucune proposition",
                                        systemImage: "plus.circle",
                                        description: Text("Vous n'avez pas encore proposé de zone")
                                    )
                                } else {
                                    ForEach(myZones) { zone in
                                        ZoneProposalCard(zone: zone) {
                                            selectedZone = zone
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Propositions de zones")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedZone) { zone in
                ZoneDetailView(zone: zone)
            }
            .task {
                await loadData()
            }
            .refreshable {
                await loadData()
            }
        }
    }

    private func loadData() async {
        isLoading = true

        // Récupérer la position actuelle (simplifiée)
        let coordinate = UserService.shared.currentUserProfile.flatMap { profile in
            if let lat = profile.homeLocationLat, let lon = profile.homeLocationLon {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            return nil
        }

        async let pendingTask = SpotZoneService.shared.findPendingZones(near: coordinate)
        async let myTask = SpotZoneService.shared.getMyZones()

        pendingZones = (try? await pendingTask) ?? []
        myZones = (try? await myTask) ?? []

        isLoading = false
    }
}

// MARK: - Create Zone Proposal Sheet

struct CreateZoneProposalSheet: View {
    let coordinate: CLLocationCoordinate2D
    let onComplete: (SpotZone?) -> Void

    @State private var name = ""
    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du spot", text: $name)
                        .autocorrectionDisabled()

                    TextField("Pourquoi ce nom ?", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Proposition")
                } footer: {
                    Text("Minimum 20 caractères pour la raison")
                }

                Section {
                    Map {
                        Annotation(name.isEmpty ? "Nouveau spot" : name, coordinate: coordinate) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title)
                                .foregroundStyle(.blue)
                        }
                    }
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } header: {
                    Text("Position")
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Proposer un nom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                        onComplete(nil)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Soumettre") {
                        submit()
                    }
                    .disabled(name.count < 3 || reason.count < 20 || isSubmitting)
                }
            }
        }
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                let geometry = SpotZoneGeometry.circle(center: coordinate, radiusMeters: 300)
                let request = CreateZoneRequest(
                    name: name,
                    geometry: geometry,
                    reason: reason,
                    parentSpotId: nil,
                    photoFileIds: []
                )

                let zone = try await SpotZoneService.shared.createZone(request: request)
                dismiss()
                onComplete(zone)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

// MARK: - Rename Spot Sheet

/// Vue pour proposer un renommage de spot depuis les détails d'un vol
struct RenameSpotSheet: View {
    let coordinate: CLLocationCoordinate2D
    let currentName: String

    @State private var newName = ""
    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var trustInfo: TrustInfo?
    @State private var isLoading = true
    @State private var showDrawZone = false

    @Environment(\.dismiss) private var dismiss

    private var canPropose: Bool {
        trustInfo?.level.canProposeName ?? false
    }

    private var canDrawZone: Bool {
        trustInfo?.level.canDrawZone ?? false
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Chargement...")
                } else if !canPropose {
                    // Pas assez de trust level
                    VStack(spacing: 20) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)

                        Text("Niveau insuffisant")
                            .font(.title2.bold())

                        Text("Vous devez avoir au moins 3 vols enregistrés pour proposer un renommage de spot.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        if let info = trustInfo {
                            TrustLevelBadge(level: info.level)
                        }
                    }
                    .padding()
                } else {
                    Form {
                        Section {
                            HStack {
                                Text("Nom actuel")
                                Spacer()
                                Text(currentName)
                                    .foregroundStyle(.secondary)
                            }

                            TextField("Nouveau nom", text: $newName)
                                .autocorrectionDisabled()
                        } header: {
                            Text("Renommer le spot")
                        } footer: {
                            Text("Le nouveau nom sera soumis au vote de la communauté")
                        }

                        Section {
                            TextField("Pourquoi ce nom ?", text: $reason, axis: .vertical)
                                .lineLimit(3...6)
                        } header: {
                            Text("Justification")
                        } footer: {
                            Text("Minimum 20 caractères pour expliquer votre choix")
                        }

                        Section {
                            HStack {
                                Text("Votre niveau")
                                Spacer()
                                if let info = trustInfo {
                                    TrustLevelBadge(level: info.level)
                                }
                            }

                            HStack {
                                Text("Poids de vote")
                                Spacer()
                                Text(String(format: "%.1fx", trustInfo?.level.voteWeight ?? 1.0))
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Votre profil")
                        }

                        if canDrawZone {
                            Section {
                                Button {
                                    showDrawZone = true
                                } label: {
                                    Label("Dessiner une zone précise", systemImage: "pencil.and.outline")
                                }
                            } footer: {
                                Text("En tant qu'expert, vous pouvez définir une zone polygonale au lieu d'un cercle de 300m")
                            }
                        }

                        if let error = errorMessage {
                            Section {
                                Text(error)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Renommer le spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                if canPropose && !isLoading {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Soumettre") {
                            submit()
                        }
                        .disabled(newName.count < 3 || reason.count < 20 || isSubmitting)
                    }
                }
            }
            .task {
                await loadTrustInfo()
            }
            .fullScreenCover(isPresented: $showDrawZone) {
                ZoneDrawingView(initialCenter: coordinate) { zone in
                    if zone != nil {
                        dismiss()
                    }
                }
            }
        }
    }

    private func loadTrustInfo() async {
        isLoading = true
        trustInfo = try? await TrustService.shared.getCurrentUserTrustInfo()
        isLoading = false
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil

        Task {
            do {
                // Créer une zone circulaire de 300m autour du point
                let geometry = SpotZoneGeometry.circle(center: coordinate, radiusMeters: 300)
                let request = CreateZoneRequest(
                    name: newName,
                    geometry: geometry,
                    reason: reason,
                    parentSpotId: nil,  // TODO: lier au spot existant si on a l'ID
                    photoFileIds: []
                )

                _ = try await SpotZoneService.shared.createZone(request: request)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
