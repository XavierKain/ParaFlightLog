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
import Appwrite
import NIOCore
import NIOFoundationCompat

// MARK: - DiscoverView (Onglet principal)

struct DiscoverView: View {
    @Environment(AuthService.self) private var authService
    @Environment(LocalizationManager.self) private var localizationManager

    @State private var selectedSegment: DiscoverSegment = .global
    @State private var showingSearch = false

    enum DiscoverSegment: String, CaseIterable {
        case global = "Tous"
        case friends = "Amis"
        case live = "Live"
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
                case .live:
                    LiveFlightsMapView()
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

// MARK: - FeedFilters

/// Options de filtre pour les feeds
struct FeedFilters: Equatable {
    enum DateFilter: String, CaseIterable {
        case all = "Toutes"
        case today = "Aujourd'hui"
        case week = "Cette semaine"
        case month = "Ce mois"
        case year = "Cette année"

        var localized: String {
            rawValue.localized
        }

        var dateRange: (from: Date, to: Date)? {
            let calendar = Calendar.current
            let now = Date()

            switch self {
            case .all:
                return nil
            case .today:
                let start = calendar.startOfDay(for: now)
                return (start, now)
            case .week:
                guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
                return (start, now)
            case .month:
                guard let start = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
                return (start, now)
            case .year:
                guard let start = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
                return (start, now)
            }
        }
    }

    var dateFilter: DateFilter = .all
    var country: String? = nil  // Code pays ISO (FR, ES, CH, etc.)

    var hasActiveFilters: Bool {
        dateFilter != .all || country != nil
    }
}

// MARK: - FeedFilterBar

struct FeedFilterBar: View {
    @Binding var filters: FeedFilters
    let availableCountries: [String]  // Pays extraits des vols chargés (noms de spots)
    @State private var showingCountryPicker = false

    // Tous les pays supportés avec leur drapeau
    static let allCountries: [(code: String, name: String, flag: String)] = [
        ("FR", "France", "🇫🇷"),
        ("ES", "Espagne", "🇪🇸"),
        ("CH", "Suisse", "🇨🇭"),
        ("IT", "Italie", "🇮🇹"),
        ("AT", "Autriche", "🇦🇹"),
        ("DE", "Allemagne", "🇩🇪"),
        ("PT", "Portugal", "🇵🇹"),
        ("SI", "Slovénie", "🇸🇮"),
        ("HR", "Croatie", "🇭🇷"),
        ("GR", "Grèce", "🇬🇷"),
        ("TR", "Turquie", "🇹🇷"),
        ("MA", "Maroc", "🇲🇦"),
        ("CO", "Colombie", "🇨🇴"),
        ("NP", "Népal", "🇳🇵"),
        ("BE", "Belgique", "🇧🇪"),
        ("UK", "Royaume-Uni", "🇬🇧"),
        ("US", "États-Unis", "🇺🇸"),
        ("BR", "Brésil", "🇧🇷"),
        ("AR", "Argentine", "🇦🇷"),
        ("AU", "Australie", "🇦🇺"),
        ("NZ", "Nouvelle-Zélande", "🇳🇿"),
        ("ZA", "Afrique du Sud", "🇿🇦")
    ]

    // Filtrer pour ne garder que les pays avec des vols
    private var countries: [(code: String, name: String, flag: String)] {
        if availableCountries.isEmpty {
            return []  // Pas de filtre pays si aucun vol n'a de spot
        }

        return Self.allCountries.filter { country in
            availableCountries.contains { spotName in
                spotName.localizedCaseInsensitiveContains(country.name)
            }
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Filtre par date
                Menu {
                    ForEach(FeedFilters.DateFilter.allCases, id: \.self) { option in
                        Button {
                            filters.dateFilter = option
                        } label: {
                            HStack {
                                Text(option.localized)
                                if filters.dateFilter == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    FilterChip(
                        icon: "calendar",
                        text: filters.dateFilter.localized,
                        isActive: filters.dateFilter != .all
                    )
                }

                // Filtre par pays (seulement si des pays sont disponibles)
                if !countries.isEmpty {
                    Menu {
                        Button {
                            filters.country = nil
                        } label: {
                            HStack {
                                Text("Tous les pays".localized)
                                if filters.country == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Divider()

                        ForEach(countries, id: \.code) { country in
                            Button {
                                filters.country = country.code
                            } label: {
                                HStack {
                                    Text("\(country.flag) \(country.name)")
                                    if filters.country == country.code {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        FilterChip(
                            icon: "globe",
                            text: countryDisplayName,
                            isActive: filters.country != nil
                        )
                    }
                }

                // Bouton reset si filtres actifs
                if filters.hasActiveFilters {
                    Button {
                        withAnimation {
                            filters = FeedFilters()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    private var countryDisplayName: String {
        if let code = filters.country,
           let country = Self.allCountries.first(where: { $0.code == code }) {
            return "\(country.flag) \(country.name)"
        }
        return "Pays".localized
    }
}

// MARK: - FilterChip

struct FilterChip: View {
    let icon: String
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.subheadline)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color.blue.opacity(0.15) : Color(.secondarySystemBackground))
        .foregroundStyle(isActive ? .blue : .primary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(isActive ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - GlobalFeedView

struct GlobalFeedView: View {
    @State private var flights: [PublicFlight] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var currentPage = 0
    @State private var hasMorePages = true
    @State private var filters = FeedFilters()

    /// Pays disponibles extraits des noms de spots des vols chargés
    private var availableCountries: [String] {
        flights.compactMap { $0.spotName }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Barre de filtres (avec pays disponibles)
            FeedFilterBar(filters: $filters, availableCountries: availableCountries)

            // Contenu
            Group {
                if isLoading && flights.isEmpty {
                    ProgressView("Chargement...".localized)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = error, flights.isEmpty {
                    ErrorView(message: error) {
                        Task { await loadFlights(refresh: true) }
                    }
                } else if flights.isEmpty {
                    EmptyFeedView(message: filters.hasActiveFilters
                        ? "Aucun vol ne correspond aux filtres".localized
                        : "Aucun vol public pour le moment".localized)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            // Premier vol avec carte (style featured)
                            if let firstFlight = filteredFlights.first {
                                NavigationLink {
                                    PublicFlightDetailView(flightId: firstFlight.id)
                                } label: {
                                    PublicFlightCardView(flight: firstFlight, showMap: true)
                                }
                                .buttonStyle(.plain)
                            }

                            // Autres vols sans carte (plus léger)
                            ForEach(Array(filteredFlights.dropFirst())) { flight in
                                NavigationLink {
                                    PublicFlightDetailView(flightId: flight.id)
                                } label: {
                                    PublicFlightCardView(flight: flight, showMap: false)
                                }
                                .buttonStyle(.plain)
                            }

                            if hasMorePages && !filters.hasActiveFilters {
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
        }
        .task {
            if flights.isEmpty {
                await loadFlights(refresh: true)
            }
        }
        .onChange(of: filters) { _, _ in
            // Reload quand les filtres changent
            Task { await loadFlights(refresh: true) }
        }
    }

    /// Applique les filtres localement sur les vols chargés
    private var filteredFlights: [PublicFlight] {
        var result = flights

        // Filtre par date
        if let dateRange = filters.dateFilter.dateRange {
            result = result.filter { flight in
                flight.startDate >= dateRange.from && flight.startDate <= dateRange.to
            }
        }

        // Filtre par pays (basé sur le nom du spot qui peut contenir le pays)
        if let countryCode = filters.country,
           let country = FeedFilterBar.allCountries.first(where: { $0.code == countryCode }) {
            result = result.filter { flight in
                // Vérifier si le spotName ou country field contient le pays
                if let spotName = flight.spotName {
                    return spotName.localizedCaseInsensitiveContains(country.name)
                }
                return false
            }
        }

        return result
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
        } catch is CancellationError {
            // Navigation normale - ignorer silencieusement
            return
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
        } catch is CancellationError {
            // Navigation normale - ignorer silencieusement
            return
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
    @State private var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.0, longitude: 2.0),  // France
        span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
    ))
    @State private var flights: [PublicFlight] = []
    @State private var clusters: [FlightCluster] = []
    @State private var isLoading = false
    @State private var selectedCluster: FlightCluster?

    var body: some View {
        ZStack {
            Map(position: $cameraPosition) {
                ForEach(clusters) { cluster in
                    Annotation("", coordinate: cluster.coordinate) {
                        ClusterAnnotationView(cluster: cluster) {
                            selectedCluster = cluster
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .onMapCameraChange { context in
                Task { await loadFlightsInRegion(context.region) }
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
            let initialRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 46.0, longitude: 2.0),
                span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
            )
            await loadFlightsInRegion(initialRegion)
        }
    }

    private func loadFlightsInRegion(_ region: MKCoordinateRegion) async {
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
        } catch is CancellationError {
            // Navigation normale - ignorer silencieusement
            return
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

// MARK: - WingPhotoView

/// Vue qui affiche la photo d'une voile depuis Appwrite Storage
struct WingPhotoView: View {
    let fileId: String?
    let size: CGFloat

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: size, height: size)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "wind")
                                .font(size > 40 ? .title3 : .caption)
                                .foregroundStyle(.cyan.opacity(0.6))
                        }
                    }
            }
        }
        .task(id: fileId) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let fileId = fileId, !fileId.isEmpty else {
            loadedImage = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await AppwriteService.shared.storage.getFileView(
                bucketId: AppwriteConfig.wingImagesBucketId,
                fileId: fileId
            )

            if let image = UIImage(data: Data(buffer: data)) {
                await MainActor.run {
                    loadedImage = image
                }
            }
        } catch {
            logError("Failed to load wing photo: \(error.localizedDescription)", category: .sync)
            await MainActor.run {
                loadedImage = nil
            }
        }
    }
}

// MARK: - PublicFlightCardView

struct PublicFlightCardView: View {
    let flight: PublicFlight
    var showMap: Bool = true  // Par défaut true pour compatibilité

    var body: some View {
        VStack(spacing: 0) {
            // Header avec carte seulement si showMap est true
            if showMap {
                ZStack(alignment: .bottomLeading) {
                    if let lat = flight.latitude, let lon = flight.longitude {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                        ))) {
                            Marker(flight.spotName ?? "Vol", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                                .tint(.blue)
                        }
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .allowsHitTesting(false)
                    } else {
                        // Placeholder sans coordonnées
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.blue.opacity(0.2), .cyan.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(height: 140)
                            .overlay {
                                if let spotName = flight.spotName {
                                    VStack {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.title)
                                            .foregroundStyle(.blue.opacity(0.5))
                                        Text(spotName)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.primary.opacity(0.7))
                                    }
                                } else {
                                    Image(systemName: "map")
                                        .font(.largeTitle)
                                        .foregroundStyle(.blue.opacity(0.4))
                                }
                            }
                    }

                    // Badge trace GPS
                    if flight.hasGpsTrack {
                        HStack(spacing: 4) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            Text("Trace GPS")
                        }
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue)
                        .clipShape(Capsule())
                        .padding(10)
                    }
                }
            }

            // Contenu principal
            VStack(spacing: 12) {
                // Pilote + Date + Voile
                HStack(spacing: 12) {
                    // Photo du pilote
                    ProfilePhotoView(
                        fileId: flight.pilotPhotoFileId,
                        displayName: flight.pilotName,
                        size: 44
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(flight.pilotName)
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("@\(flight.pilotUsername)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Photo de la voile (si disponible)
                    if flight.wingPhotoFileId != nil || flight.wingDescription != nil {
                        WingPhotoView(fileId: flight.wingPhotoFileId, size: 40)
                    }

                    // Durée en vedette
                    Text(flight.formattedDuration)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                }

                // Date et Spot
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flight.startDate, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(.subheadline)
                        Text(flight.startDate, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let spotName = flight.spotName {
                        Label(spotName, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Statistiques (style grille comme LatestFlightCard)
                if flight.maxAltitude != nil || flight.totalDistance != nil || flight.maxSpeed != nil {
                    Divider()

                    HStack(spacing: 16) {
                        if let altitude = flight.maxAltitude {
                            PublicStatCard(
                                value: "\(Int(altitude))",
                                unit: "m",
                                label: "Alt. max",
                                icon: "arrow.up",
                                color: .orange
                            )
                        }
                        if let distance = flight.totalDistance {
                            PublicStatCard(
                                value: formatDistanceValue(distance),
                                unit: formatDistanceUnit(distance),
                                label: "Distance",
                                icon: "point.topleft.down.to.point.bottomright.curvepath",
                                color: .cyan
                            )
                        }
                        if let speed = flight.maxSpeed {
                            PublicStatCard(
                                value: "\(Int(speed * 3.6))",
                                unit: "km/h",
                                label: "Vitesse",
                                icon: "speedometer",
                                color: .purple
                            )
                        }
                    }
                }

                // Nom de la voile (l'image est déjà dans le header)
                if let wing = flight.wingDescription {
                    HStack(spacing: 6) {
                        Image(systemName: "wind")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(wing)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                // Ligne de séparation et infos supplémentaires
                Divider()

                HStack {
                    // Badge GPS si pas de carte
                    if !showMap && flight.hasGpsTrack {
                        HStack(spacing: 4) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            Text("GPS")
                        }
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.blue)
                    }

                    Spacer()

                    Text(flight.startDate, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }

    private func formatDistanceValue(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1f", distance / 1000)
        } else {
            return "\(Int(distance))"
        }
    }

    private func formatDistanceUnit(_ distance: Double) -> String {
        return distance >= 1000 ? "km" : "m"
    }
}

// MARK: - PublicStatCard

struct PublicStatCard: View {
    let value: String
    let unit: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
    @State private var showingFullScreenMap = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Chargement...".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                ErrorView(message: error) {
                    Task { await loadDetails() }
                }
            } else if let details = details {
                ScrollView {
                    VStack(spacing: 20) {
                        // Map avec trace GPS ou marker
                        FlightMapSection(
                            flight: details.flight,
                            gpsTrack: details.gpsTrack,
                            showingFullScreenMap: $showingFullScreenMap
                        )

                        // Durée en grand (style FlightDetailView)
                        VStack(spacing: 4) {
                            Text("Durée du vol".localized)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(details.flight.formattedDuration)
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(.blue)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)

                        // Statistiques de vol
                        if details.flight.maxAltitude != nil || details.flight.totalDistance != nil || details.flight.maxSpeed != nil {
                            PublicFlightStatsSection(flight: details.flight)
                                .padding(.horizontal)
                        }

                        // Date et heure
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Date".localized, systemImage: "calendar")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(details.flight.startDate, format: .dateTime.weekday(.abbreviated).day().month().year())
                                    .font(.subheadline)
                                Text(details.flight.startDate, format: .dateTime.hour().minute())
                                    .font(.headline)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                        // Pilote
                        NavigationLink {
                            PilotProfileView(pilotId: details.flight.pilotId)
                        } label: {
                            HStack(spacing: 12) {
                                // Photo du pilote
                                ProfilePhotoView(
                                    fileId: details.flight.pilotPhotoFileId,
                                    displayName: details.flight.pilotName,
                                    size: 50
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Pilote".localized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(details.flight.pilotName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("@\(details.flight.pilotUsername)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal)

                        // Voile avec image
                        if let wing = details.flight.wingDescription {
                            HStack(spacing: 12) {
                                WingPhotoView(fileId: details.flight.wingPhotoFileId, size: 50)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Voile".localized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(wing)
                                        .font(.headline)
                                }
                                Spacer()
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }

                        // Spot
                        if let spotName = details.flight.spotName {
                            HStack(spacing: 12) {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.blue)
                                    .font(.title2)
                                    .frame(width: 50, height: 50)
                                    .background(Color.blue.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Spot".localized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(spotName)
                                        .font(.headline)
                                }
                                Spacer()

                                if details.flight.spotId != nil {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                        }

                        // Note: Likes et commentaires désactivés pour le moment
                        // Seront implémentés dans une version future

                        Spacer(minLength: 40)
                    }
                }
            }
        }
        .navigationTitle("Détail du vol".localized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDetails()
        }
        .fullScreenCover(isPresented: $showingFullScreenMap) {
            if let details = details {
                FullScreenPublicMapView(
                    flight: details.flight,
                    gpsTrack: details.gpsTrack
                )
            }
        }
    }

    private func loadDetails() async {
        isLoading = true
        error = nil

        do {
            details = try await DiscoveryService.shared.getFlightDetails(flightId: flightId)
        } catch is CancellationError {
            return
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

// MARK: - FlightMapSection

struct FlightMapSection: View {
    let flight: PublicFlight
    let gpsTrack: [GPSTrackPoint]?
    @Binding var showingFullScreenMap: Bool

    private var mapRegion: MKCoordinateRegion {
        if let track = gpsTrack, !track.isEmpty {
            let lats = track.map { $0.latitude }
            let lons = track.map { $0.longitude }
            let minLat = lats.min() ?? 0
            let maxLat = lats.max() ?? 0
            let minLon = lons.min() ?? 0
            let maxLon = lons.max() ?? 0

            let centerLat = (minLat + maxLat) / 2
            let centerLon = (minLon + maxLon) / 2
            let spanLat = max(0.01, (maxLat - minLat) * 1.3)
            let spanLon = max(0.01, (maxLon - minLon) * 1.3)

            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            )
        } else if let lat = flight.latitude, let lon = flight.longitude {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
            span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            if gpsTrack != nil || (flight.latitude != nil && flight.longitude != nil) {
                Map(initialPosition: .region(mapRegion)) {
                    // Afficher la trace GPS si disponible
                    if let track = gpsTrack, track.count >= 2 {
                        MapPolyline(coordinates: track.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(.blue, lineWidth: 3)

                        // Marker de départ (vert)
                        if let first = track.first {
                            Marker("Départ".localized, systemImage: "flag.fill", coordinate:
                                CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                                .tint(.green)
                        }

                        // Marker d'arrivée (rouge)
                        if let last = track.last {
                            Marker("Arrivée".localized, systemImage: "flag.checkered", coordinate:
                                CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                                .tint(.red)
                        }
                    } else if let lat = flight.latitude, let lon = flight.longitude {
                        Marker(flight.spotName ?? "Vol".localized, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                            .tint(.blue)
                    }
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .padding(8)
                }
                .onTapGesture {
                    showingFullScreenMap = true
                }
                .padding(.horizontal)

                // Info sur la trace GPS
                if let track = gpsTrack, !track.isEmpty {
                    HStack {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            .foregroundStyle(.blue)
                        Text("\(track.count) points GPS enregistrés".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Toucher pour agrandir".localized)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

// MARK: - PublicFlightStatsSection

struct PublicFlightStatsSection: View {
    let flight: PublicFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistiques de vol".localized)
                .font(.headline)

            HStack(spacing: 8) {
                if let alt = flight.maxAltitude {
                    PublicDetailStatCard(
                        title: "Alt. max".localized,
                        value: "\(Int(alt)) m",
                        color: .orange,
                        icon: "arrow.up"
                    )
                }
                if let distance = flight.totalDistance {
                    PublicDetailStatCard(
                        title: "Distance".localized,
                        value: flight.formattedDistance ?? "\(Int(distance)) m",
                        color: .cyan,
                        icon: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                }
                if let speed = flight.maxSpeed {
                    PublicDetailStatCard(
                        title: "Vitesse max".localized,
                        value: "\(Int(speed * 3.6)) km/h",
                        color: .purple,
                        icon: "speedometer"
                    )
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - PublicDetailStatCard

struct PublicDetailStatCard: View {
    let title: String
    let value: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - FullScreenPublicMapView

struct FullScreenPublicMapView: View {
    @Environment(\.dismiss) private var dismiss
    let flight: PublicFlight
    let gpsTrack: [GPSTrackPoint]?

    private var mapRegion: MKCoordinateRegion {
        if let track = gpsTrack, !track.isEmpty {
            let lats = track.map { $0.latitude }
            let lons = track.map { $0.longitude }
            let minLat = lats.min() ?? 0
            let maxLat = lats.max() ?? 0
            let minLon = lons.min() ?? 0
            let maxLon = lons.max() ?? 0

            let centerLat = (minLat + maxLat) / 2
            let centerLon = (minLon + maxLon) / 2
            let spanLat = max(0.01, (maxLat - minLat) * 1.3)
            let spanLon = max(0.01, (maxLon - minLon) * 1.3)

            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            )
        } else if let lat = flight.latitude, let lon = flight.longitude {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
            span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
        )
    }

    var body: some View {
        NavigationStack {
            Map(initialPosition: .region(mapRegion)) {
                if let track = gpsTrack, track.count >= 2 {
                    MapPolyline(coordinates: track.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    })
                    .stroke(.blue, lineWidth: 4)

                    if let first = track.first {
                        Marker("Départ".localized, systemImage: "flag.fill", coordinate:
                            CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                            .tint(.green)
                    }

                    if let last = track.last {
                        Marker("Arrivée".localized, systemImage: "flag.checkered", coordinate:
                            CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                            .tint(.red)
                    }
                } else if let lat = flight.latitude, let lon = flight.longitude {
                    Marker(flight.spotName ?? "Vol".localized, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                        .tint(.blue)
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .ignoresSafeArea()
            .navigationTitle(flight.spotName ?? "Trace GPS".localized)
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
