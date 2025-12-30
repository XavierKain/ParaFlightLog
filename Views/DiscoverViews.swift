//
//  DiscoverViews.swift
//  ParaFlightLog
//
//  Vues de découverte des vols publics
//  Feed global, feed amis, carte et recherche
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit

// MARK: - DiscoverView (Onglet principal)

struct DiscoverView: View {
    @Environment(AuthService.self) private var authService
    @Environment(LocalizationManager.self) private var localizationManager

    @State private var selectedSegment: DiscoverSegment = .global
    @State private var showingSearch = false

    enum DiscoverSegment: String, CaseIterable {
        case global = "Tous"
        case friends = "Amis"
        case map = "Carte"

        var localized: String {
            rawValue.localized
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segment picker
                Picker("Feed", selection: $selectedSegment) {
                    ForEach(DiscoverSegment.allCases, id: \.self) { segment in
                        Text(segment.localized).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Content based on selection
                switch selectedSegment {
                case .global:
                    GlobalFeedView()
                case .friends:
                    if authService.isAuthenticated {
                        FriendsFeedView()
                    } else {
                        NotAuthenticatedView(message: "Connectez-vous pour voir les vols de vos amis".localized)
                    }
                case .map:
                    MapDiscoveryView()
                }
            }
            .navigationTitle("Découvrir".localized)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showingSearch) {
                SearchView()
            }
        }
    }
}

// MARK: - GlobalFeedView

struct GlobalFeedView: View {
    @State private var flights: [PublicFlight] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentPage = 0
    @State private var hasMorePages = true

    var body: some View {
        Group {
            if isLoading && flights.isEmpty {
                ProgressView("Chargement...".localized)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error, flights.isEmpty {
                ErrorView(message: error) {
                    Task { await loadFlights(refresh: true) }
                }
            } else if flights.isEmpty {
                EmptyFeedView(message: "Aucun vol public pour le moment".localized)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(flights) { flight in
                            NavigationLink {
                                PublicFlightDetailView(flightId: flight.id)
                            } label: {
                                PublicFlightCardView(flight: flight)
                            }
                            .buttonStyle(.plain)
                        }

                        if hasMorePages {
                            ProgressView()
                                .onAppear {
                                    Task { await loadMoreFlights() }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadFlights(refresh: true)
                }
            }
        }
        .task {
            if flights.isEmpty {
                await loadFlights(refresh: true)
            }
        }
    }

    private func loadFlights(refresh: Bool) async {
        if refresh {
            currentPage = 0
            hasMorePages = true
        }

        isLoading = true
        error = nil

        do {
            let newFlights = try await DiscoveryService.shared.getGlobalFeed(page: currentPage)
            if refresh {
                flights = newFlights
            } else {
                flights.append(contentsOf: newFlights)
            }
            hasMorePages = newFlights.count == 20
        } catch let discoveryError as DiscoveryError {
            // Message plus clair pour les collections manquantes
            if case .collectionNotFound = discoveryError {
                self.error = "Les fonctionnalités sociales arrivent bientôt ! 🚀\n\nLes vols publics de la communauté seront disponibles prochainement.".localized
            } else {
                self.error = discoveryError.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func loadMoreFlights() async {
        guard !isLoading && hasMorePages else { return }
        currentPage += 1
        await loadFlights(refresh: false)
    }
}

// MARK: - FriendsFeedView

struct FriendsFeedView: View {
    @State private var flights: [PublicFlight] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentPage = 0
    @State private var hasMorePages = true

    var body: some View {
        Group {
            if isLoading && flights.isEmpty {
                ProgressView("Chargement...".localized)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error, flights.isEmpty {
                ErrorView(message: error) {
                    Task { await loadFlights(refresh: true) }
                }
            } else if flights.isEmpty {
                EmptyFeedView(message: "Suivez des pilotes pour voir leurs vols ici".localized)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(flights) { flight in
                            NavigationLink {
                                PublicFlightDetailView(flightId: flight.id)
                            } label: {
                                PublicFlightCardView(flight: flight)
                            }
                            .buttonStyle(.plain)
                        }

                        if hasMorePages {
                            ProgressView()
                                .onAppear {
                                    Task { await loadMoreFlights() }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadFlights(refresh: true)
                }
            }
        }
        .task {
            if flights.isEmpty {
                await loadFlights(refresh: true)
            }
        }
    }

    private func loadFlights(refresh: Bool) async {
        if refresh {
            currentPage = 0
            hasMorePages = true
        }

        isLoading = true
        error = nil

        do {
            let newFlights = try await DiscoveryService.shared.getFriendsFeed(page: currentPage)
            if refresh {
                flights = newFlights
            } else {
                flights.append(contentsOf: newFlights)
            }
            hasMorePages = newFlights.count == 20
        } catch let discoveryError as DiscoveryError {
            // Message plus clair pour les collections manquantes
            if case .collectionNotFound = discoveryError {
                self.error = "Les fonctionnalités sociales arrivent bientôt ! 🚀\n\nVous pourrez suivre d'autres pilotes et voir leurs vols ici.".localized
            } else {
                self.error = discoveryError.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func loadMoreFlights() async {
        guard !isLoading && hasMorePages else { return }
        currentPage += 1
        await loadFlights(refresh: false)
    }
}

// MARK: - MapDiscoveryView

struct MapDiscoveryView: View {
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.0, longitude: 2.0),  // France
        span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
    )
    @State private var flights: [PublicFlight] = []
    @State private var clusters: [FlightCluster] = []
    @State private var isLoading = false
    @State private var selectedCluster: FlightCluster?

    var body: some View {
        ZStack {
            Map(coordinateRegion: $region, annotationItems: clusters) { cluster in
                MapAnnotation(coordinate: cluster.coordinate) {
                    ClusterAnnotationView(cluster: cluster) {
                        selectedCluster = cluster
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .onChange(of: region.center.latitude) { _, _ in
                Task { await loadFlightsInRegion() }
            }

            if isLoading {
                VStack {
                    ProgressView()
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .sheet(item: $selectedCluster) { cluster in
            ClusterDetailSheet(cluster: cluster)
        }
        .task {
            await loadFlightsInRegion()
        }
    }

    private func loadFlightsInRegion() async {
        isLoading = true

        let bounds = MapBounds(
            northEast: CLLocationCoordinate2D(
                latitude: region.center.latitude + region.span.latitudeDelta / 2,
                longitude: region.center.longitude + region.span.longitudeDelta / 2
            ),
            southWest: CLLocationCoordinate2D(
                latitude: region.center.latitude - region.span.latitudeDelta / 2,
                longitude: region.center.longitude - region.span.longitudeDelta / 2
            )
        )

        do {
            flights = try await DiscoveryService.shared.getFlightsInArea(bounds: bounds, limit: 100)

            // Déterminer le niveau de zoom approximatif
            let zoomLevel = Int(log2(360 / region.span.longitudeDelta))
            clusters = DiscoveryService.shared.clusterFlights(flights, zoomLevel: zoomLevel)
        } catch {
            logError("Failed to load flights in region: \(error)", category: .sync)
        }

        isLoading = false
    }
}

// MARK: - ClusterAnnotationView

struct ClusterAnnotationView: View {
    let cluster: FlightCluster
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            if cluster.isCluster {
                // Cluster avec plusieurs vols
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 40, height: 40)

                    Text("\(cluster.flightCount)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
            } else {
                // Vol unique
                Image(systemName: "airplane.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
            }
        }
    }
}

// MARK: - ClusterDetailSheet

struct ClusterDetailSheet: View {
    let cluster: FlightCluster
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if cluster.isCluster {
                    Section {
                        Text("\(cluster.flightCount) vols dans cette zone".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Vols récents".localized) {
                    ForEach(cluster.flights) { flight in
                        NavigationLink {
                            PublicFlightDetailView(flightId: flight.id)
                        } label: {
                            FlightRowCompact(flight: flight)
                        }
                    }
                }
            }
            .navigationTitle(cluster.flights.first?.spotName ?? "Vols".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer".localized) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - PublicFlightCardView

struct PublicFlightCardView: View {
    let flight: PublicFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header - Pilote
            HStack(spacing: 12) {
                // Avatar
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(flight.pilotName.prefix(1).uppercased())
                            .font(.headline)
                            .foregroundStyle(.blue)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(flight.pilotName)
                        .font(.headline)

                    Text("@\(flight.pilotUsername)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(flight.startDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Spot
            if let spotName = flight.spotName {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.red)
                    Text(spotName)
                        .font(.subheadline)
                }
            }

            // Stats
            HStack(spacing: 24) {
                StatBadge(icon: "clock", value: flight.formattedDuration, label: "Durée".localized)

                if let altitude = flight.formattedMaxAltitude {
                    StatBadge(icon: "arrow.up", value: altitude, label: "Alt max".localized)
                }

                if let distance = flight.formattedDistance {
                    StatBadge(icon: "point.bottomleft.forward.to.point.topright.scurvepath", value: distance, label: "Distance".localized)
                }
            }

            // Wing
            if let wing = flight.wingDescription {
                HStack {
                    Image(systemName: "wind")
                        .foregroundStyle(.secondary)
                    Text(wing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Social
            Divider()

            HStack(spacing: 24) {
                HStack(spacing: 4) {
                    Image(systemName: "heart")
                    Text("\(flight.likeCount)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                    Text("\(flight.commentCount)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Spacer()

                if flight.hasGpsTrack {
                    Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath.fill")
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

// MARK: - StatBadge

struct StatBadge: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - FlightRowCompact

struct FlightRowCompact: View {
    let flight: PublicFlight

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(flight.pilotName)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(flight.formattedDuration)
                    if let wing = flight.wingDescription {
                        Text("•")
                        Text(wing)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(flight.startDate, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PublicFlightDetailView

struct PublicFlightDetailView: View {
    let flightId: String

    @State private var details: FlightDetails?
    @State private var isLoading = true
    @State private var error: String?
    @State private var isLiked = false
    @State private var newComment = ""
    @State private var isSendingComment = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Chargement...".localized)
            } else if let error = error {
                ErrorView(message: error) {
                    Task { await loadDetails() }
                }
            } else if let details = details {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        FlightDetailHeader(flight: details.flight)

                        // Map if GPS track
                        if let track = details.gpsTrack, !track.isEmpty {
                            FlightTrackMapView(track: track)
                                .frame(height: 200)
                                .cornerRadius(12)
                        }

                        // Stats
                        FlightDetailStats(flight: details.flight)

                        // Social actions
                        FlightSocialBar(
                            flight: details.flight,
                            isLiked: isLiked,
                            onLike: { await toggleLike() },
                            onComment: { }
                        )

                        // Comments
                        if !details.comments.isEmpty {
                            CommentsSection(comments: details.comments)
                        }

                        // Add comment
                        AddCommentView(
                            text: $newComment,
                            isSending: isSendingComment,
                            onSend: { await sendComment() }
                        )
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Vol".localized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDetails()
        }
    }

    private func loadDetails() async {
        isLoading = true
        error = nil

        do {
            details = try await DiscoveryService.shared.getFlightDetails(flightId: flightId)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func toggleLike() async {
        // TODO: Implement like/unlike
        isLiked.toggle()
    }

    private func sendComment() async {
        guard !newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSendingComment = true
        // TODO: Implement send comment via SocialService
        try? await Task.sleep(for: .seconds(1))
        newComment = ""
        isSendingComment = false
        await loadDetails()
    }
}

// MARK: - FlightDetailHeader

struct FlightDetailHeader: View {
    let flight: PublicFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pilote
            NavigationLink {
                PilotProfileView(pilotId: flight.pilotId)
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 50, height: 50)
                        .overlay {
                            Text(flight.pilotName.prefix(1).uppercased())
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundStyle(.blue)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(flight.pilotName)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)

                        Text("@\(flight.pilotUsername)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }

            // Spot
            if let spotName = flight.spotName, let spotId = flight.spotId {
                NavigationLink {
                    SpotDetailView(spotId: spotId)
                } label: {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.red)
                        Text(spotName)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }

            // Date
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text(flight.startDate.formatted(date: .long, time: .shortened))
                    .font(.subheadline)
            }

            // Wing
            if let wing = flight.wingDescription {
                HStack {
                    Image(systemName: "wind")
                        .foregroundStyle(.secondary)
                    Text(wing)
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - FlightDetailStats

struct FlightDetailStats: View {
    let flight: PublicFlight

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                DetailStatItem(icon: "clock.fill", value: flight.formattedDuration, label: "Durée".localized, color: .blue)
                Spacer()
                if let alt = flight.formattedMaxAltitude {
                    DetailStatItem(icon: "arrow.up.circle.fill", value: alt, label: "Alt max".localized, color: .orange)
                }
                Spacer()
                if let dist = flight.formattedDistance {
                    DetailStatItem(icon: "point.bottomleft.forward.to.point.topright.scurvepath.fill", value: dist, label: "Distance".localized, color: .green)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - DetailStatItem

struct DetailStatItem: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
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
    }
}

// MARK: - FlightTrackMapView

struct FlightTrackMapView: View {
    let track: [GPSTrackPoint]

    var body: some View {
        // Simplified map view - would need full implementation
        ZStack {
            Color(.systemGray5)
            Image(systemName: "map")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Trace GPS".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .offset(y: 30)
        }
    }
}

// MARK: - FlightSocialBar

struct FlightSocialBar: View {
    let flight: PublicFlight
    let isLiked: Bool
    let onLike: () async -> Void
    let onComment: () -> Void

    var body: some View {
        HStack(spacing: 32) {
            Button {
                Task { await onLike() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(isLiked ? .red : .secondary)
                    Text("\(flight.likeCount)")
                }
            }
            .buttonStyle(.plain)

            Button(action: onComment) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                    Text("\(flight.commentCount)")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            ShareLink(item: "Vol de \(flight.pilotName) - \(flight.formattedDuration)") {
                Image(systemName: "square.and.arrow.up")
            }
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - CommentsSection

struct CommentsSection: View {
    let comments: [FlightComment]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commentaires".localized)
                .font(.headline)

            ForEach(comments) { comment in
                CommentRow(comment: comment)
            }
        }
    }
}

// MARK: - CommentRow

struct CommentRow: View {
    let comment: FlightComment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(comment.userName.prefix(1).uppercased())
                        .font(.caption)
                        .fontWeight(.semibold)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(comment.userName)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text(comment.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(comment.content)
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - AddCommentView

struct AddCommentView: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Ajouter un commentaire...".localized, text: $text)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await onSend() }
            } label: {
                if isSending {
                    ProgressView()
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
    }
}

// MARK: - Helper Views

struct NotAuthenticatedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct EmptyFeedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "airplane.circle")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Réessayer".localized, action: onRetry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
