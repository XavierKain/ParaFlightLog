//
//  FlightsViews.swift
//  ParaFlightLog
//
//  Vues liées aux vols : liste, détail, édition
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit
import Charts

// MARK: - FlightTypeFilter (Filtre par type de vol)

/// Filtre de la liste des vols par type de vol
enum FlightTypeFilter: Hashable {
    /// Tous les vols
    case all
    /// Vols d'un type précis (valeur de FlightTypes ou valeur libre)
    case type(String)
    /// Vols sans type défini
    case undefined
}

// MARK: - FlightsView (Liste des vols avec dernier vol en vedette)

struct FlightsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LocalizationManager.self) private var localizationManager
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]
    @State private var selectedFlight: Flight?
    @State private var showingFlightDetail: Flight?
    @State private var flightToDelete: Flight?
    @State private var showingDeleteConfirmation = false

    // Filtre par type de vol
    @State private var typeFilter: FlightTypeFilter = .all

    // Pagination: nombre de vols affichés
    @State private var displayedFlightsCount: Int = 20
    private let pageSize: Int = 15

    // Vols filtrés par type de vol
    private var filteredFlights: [Flight] {
        switch typeFilter {
        case .all:
            return flights
        case .type(let type):
            return flights.filter { $0.flightType == type }
        case .undefined:
            return flights.filter { ($0.flightType ?? "").isEmpty }
        }
    }

    // Dernier vol (le plus récent)
    private var latestFlight: Flight? {
        filteredFlights.first
    }

    // Autres vols paginés (tous sauf le dernier, limités au nombre affiché)
    private var olderFlights: [Flight] {
        let allOlder = Array(filteredFlights.dropFirst())
        return Array(allOlder.prefix(displayedFlightsCount - 1))
    }

    // Vérifie s'il reste des vols à charger
    private var hasMoreFlights: Bool {
        filteredFlights.count > displayedFlightsCount
    }

    // Nombre de vols restants à charger
    private var remainingFlightsCount: Int {
        max(0, filteredFlights.count - displayedFlightsCount)
    }

    var body: some View {
        NavigationStack {
            Group {
                if flights.isEmpty {
                    ContentUnavailableView(
                        String(localized: "Aucun vol"),
                        systemImage: "airplane.circle",
                        description: Text(String(localized: "Commencez un vol depuis la Watch ou l'onglet Chrono"))
                    )
                    .padding(.top, 100)
                } else if filteredFlights.isEmpty {
                    // Aucun vol ne correspond au filtre par type
                    ContentUnavailableView(
                        String(localized: "Aucun vol de ce type"),
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(String(localized: "Modifiez le filtre pour voir d'autres vols"))
                    )
                    .padding(.top, 100)
                } else {
                List {
                    // Dernier vol en grand (featured)
                    if let latest = latestFlight {
                        LatestFlightCard(flight: latest)
                            .onTapGesture {
                                showingFlightDetail = latest
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteFlight(latest)
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                    }

                    // Section vols précédents
                    if !olderFlights.isEmpty {
                        Section {
                            ForEach(olderFlights) { flight in
                                FlightRow(flight: flight)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        showingFlightDetail = flight
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            deleteFlight(flight)
                                        } label: {
                                            Label("Supprimer", systemImage: "trash")
                                        }
                                    }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                            // Infinite scroll : charger plus automatiquement
                            if hasMoreFlights {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .onAppear {
                                        loadMoreFlights()
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text(String(localized: "Vols précédents"))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(String(localized: "Mes vols"))
            .toolbar {
                // Filtre par type de vol
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(String(localized: "Type de vol"), selection: $typeFilter) {
                            Label(String(localized: "Tous"), systemImage: "circle.grid.2x2")
                                .tag(FlightTypeFilter.all)
                            ForEach(FlightTypes.all, id: \.self) { type in
                                Label(type, systemImage: FlightTypes.icon(for: type))
                                    .tag(FlightTypeFilter.type(type))
                            }
                            Label(String(localized: "Non défini"), systemImage: "questionmark.circle")
                                .tag(FlightTypeFilter.undefined)
                        }
                    } label: {
                        Image(systemName: typeFilter == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .onChange(of: typeFilter) { _, _ in
                // Réinitialiser la pagination quand le filtre change
                displayedFlightsCount = 20
            }
        }
        .id(localizationManager.currentLanguage) // Force re-render quand la langue change
        .sheet(item: $showingFlightDetail) { flight in
            FlightDetailView(flight: flight)
        }
        .confirmationDialog(String(localized: "Supprimer ce vol ?"), isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button(String(localized: "Supprimer"), role: .destructive) {
                if let flight = flightToDelete {
                    deleteFlight(flight)
                }
            }
            Button(String(localized: "Annuler"), role: .cancel) {}
        }
    }

    /// Charge plus de vols (pagination)
    private func loadMoreFlights() {
        withAnimation(.easeInOut(duration: 0.3)) {
            displayedFlightsCount += pageSize
        }
    }

    private func deleteFlight(_ flight: Flight) {
        modelContext.delete(flight)
        do {
            try modelContext.save()
            logInfo("Flight deleted and saved to database", category: .flight)
        } catch {
            logError("Error saving deletion: \(error)", category: .flight)
        }
    }
}

// MARK: - LatestFlightCard (Carte du dernier vol en grand)

struct LatestFlightCard: View {
    let flight: Flight

    var body: some View {
        VStack(spacing: 0) {
            // Carte avec le spot sur la map
            ZStack(alignment: .bottomLeading) {
                // Map ou placeholder
                if let lat = flight.latitude, let lon = flight.longitude {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))) {
                        Marker(flight.spotName ?? "Vol", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                            .tint(.blue)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)
                } else {
                    // Placeholder sans coordonnées
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.blue.opacity(0.3), .cyan.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(height: 180)
                        .overlay {
                            VStack {
                                Image(systemName: "map")
                                    .font(.largeTitle)
                                    .foregroundStyle(.blue.opacity(0.5))
                                Text("Pas de coordonnées")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }

                // Badge "Dernier vol"
                HStack {
                    Image(systemName: "clock.fill")
                    Text("Dernier vol")
                }
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.blue)
                .clipShape(Capsule())
                .padding(12)
            }

            // Infos du vol
            VStack(spacing: 12) {
                // Date et durée
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flight.startDate, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.headline)
                        Text(flight.startDate, format: .dateTime.hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(flight.durationFormatted)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                }

                // Voile et spot
                HStack {
                    if let wing = flight.wing {
                        HStack(spacing: 8) {
                            if wing.photoData != nil {
                                CachedImage(
                                    data: wing.photoData,
                                    key: wing.id.uuidString,
                                    size: CGSize(width: 32, height: 32)
                                ) {
                                    EmptyView()
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(wing.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let size = wing.size {
                                    Text("\(size) m²")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Spacer()
                    if let spotName = flight.spotName {
                        Label(spotName, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Statistiques en grand
                if flight.maxAltitude != nil || flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
                    Divider()

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        if let maxAlt = flight.maxAltitude {
                            StatCard(
                                value: "\(Int(maxAlt))",
                                unit: "m",
                                label: String(localized: "Alt. max"),
                                icon: "arrow.up",
                                color: .orange
                            )
                        }
                        if let distance = flight.totalDistance {
                            StatCard(
                                value: formatDistanceValue(distance),
                                unit: formatDistanceUnit(distance),
                                label: String(localized: "Distance"),
                                icon: "point.topleft.down.to.point.bottomright.curvepath",
                                color: .cyan
                            )
                        }
                        if let speed = flight.maxSpeed {
                            StatCard(
                                value: "\(Int(speed * 3.6))",
                                unit: "km/h",
                                label: String(localized: "Vitesse"),
                                icon: "speedometer",
                                color: .purple
                            )
                        }
                        if let gForce = flight.maxGForce {
                            StatCard(
                                value: String(format: "%.1f", gForce),
                                unit: "G",
                                label: String(localized: "G-Force"),
                                icon: "waveform.path.ecg",
                                color: .green
                            )
                        }
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
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

// MARK: - StatCard (Petite carte de statistique)

struct StatCard: View {
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
                    .font(.system(size: 18, weight: .bold, design: .rounded))
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

// MARK: - TraceDisplayMode (Mode d'affichage de la trace dans le détail)

/// Mode d'affichage de la trace GPS dans la vue détail d'un vol
private enum TraceDisplayMode: String, CaseIterable, Identifiable {
    case standard       // Trace bleue classique
    case speed          // Trace colorée par vitesse horizontale
    case verticalSpeed  // Trace colorée par vitesse verticale (vario)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return String(localized: "Standard")
        case .speed: return String(localized: "Vitesse")
        case .verticalSpeed: return String(localized: "Montée")
        }
    }
}

// MARK: - FlightProfilePoint (Point du profil de vol pour Swift Charts)

/// Point échantillonné de la trace pour les graphes altitude/Vz
private struct FlightProfilePoint: Identifiable {
    let index: Int
    let minutes: Double   // Minutes depuis le décollage
    let altitude: Double? // Altitude (m)
    let vz: Double?       // Vitesse verticale lissée (m/s)

    var id: Int { index }
}

// MARK: - FlightDetailView (Vue détaillée d'un vol)

struct FlightDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let flight: Flight
    @State private var showingEditSheet = false
    @State private var showingFullScreenMap = false
    @State private var showingShareSheet = false
    @State private var traceMode: TraceDisplayMode = .speed  // Mode de coloration de la trace
    @State private var showingRenameSpotSheet = false
    @State private var renameSpotNewName = ""

    // Stats verticales et profil calculés une seule fois à l'apparition
    @State private var verticalStats: VerticalStats?
    @State private var profileData: [FlightProfilePoint] = []

    // Calculer les segments colorés par vitesse si trace GPS disponible
    private var coloredSegments: [SpeedSegment] {
        guard let track = flight.gpsTrack, track.count >= 2 else { return [] }
        return GPSTraceColorMapper.generateColoredSegments(points: track)
    }

    // Segments colorés par vitesse verticale (mode vario)
    private var varioSegments: [SpeedSegment] {
        guard let track = flight.gpsTrack, track.count >= 2 else { return [] }
        return GPSTraceColorMapper.generateVerticalSpeedSegments(points: track)
    }

    // Segments à afficher selon le mode sélectionné
    private var displayedSegments: [SpeedSegment] {
        switch traceMode {
        case .standard: return []
        case .speed: return coloredSegments
        case .verticalSpeed: return varioSegments
        }
    }

    // Le profil contient-il des altitudes exploitables ?
    private var hasAltitudeProfile: Bool {
        profileData.contains { $0.altitude != nil }
    }

    // Le profil contient-il des Vz exploitables ?
    private var hasVzProfile: Bool {
        profileData.contains { $0.vz != nil }
    }

    // Calcul de la région pour afficher toute la trace GPS
    private var mapRegion: MKCoordinateRegion {
        if let track = flight.gpsTrack, !track.isEmpty {
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Map avec trace GPS ou simple marker (cliquable pour plein écran)
                    if flight.gpsTrack != nil || (flight.latitude != nil && flight.longitude != nil) {
                        // Sélecteur de mode de trace : Standard | Vitesse | Montée
                        if !coloredSegments.isEmpty {
                            Picker(String(localized: "Mode de trace"), selection: $traceMode) {
                                ForEach(TraceDisplayMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                        }

                        ZStack(alignment: .topTrailing) {
                            // Afficher trace GPS colorée ou carte standard
                            if !displayedSegments.isEmpty {
                                ColoredGPSTraceMapView(
                                    segments: displayedSegments,
                                    showLegend: false,
                                    colorMode: traceMode == .verticalSpeed ? .verticalSpeed : .speed
                                )
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            } else {
                                Map(initialPosition: .region(mapRegion)) {
                                    // Afficher la trace GPS si disponible
                                    if let track = flight.gpsTrack, track.count >= 2 {
                                        MapPolyline(coordinates: track.map {
                                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                        })
                                        .stroke(.blue, lineWidth: 3)

                                        // Marker de départ (vert)
                                        if let first = track.first {
                                            Marker("Départ", systemImage: "flag.fill", coordinate:
                                                CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                                                .tint(.green)
                                        }

                                        // Marker d'arrivée (rouge)
                                        if let last = track.last {
                                            Marker("Arrivée", systemImage: "flag.checkered", coordinate:
                                                CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                                                .tint(.red)
                                        }
                                    } else if let lat = flight.latitude, let lon = flight.longitude {
                                        Marker(flight.spotName ?? "Vol", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                                            .tint(.blue)
                                    }
                                }
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }

                            // Overlay controls
                            VStack(spacing: 8) {
                                // Full screen icon
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption)
                                    .padding(6)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .padding(8)
                        }
                        .onTapGesture {
                            showingFullScreenMap = true
                        }
                        .padding(.horizontal)

                        // Légende adaptée au mode de coloration actif
                        if traceMode == .speed && !coloredSegments.isEmpty {
                            SpeedLegendView()
                                .padding(.horizontal)
                        } else if traceMode == .verticalSpeed && !varioSegments.isEmpty {
                            VarioLegendView()
                                .padding(.horizontal)
                        }

                        // Info sur la trace GPS
                        if let track = flight.gpsTrack, !track.isEmpty {
                            HStack {
                                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                    .foregroundStyle(.blue)
                                Text("\(track.count) points GPS enregistrés")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(localized: "Toucher pour agrandir"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Infos principales
                    VStack(spacing: 16) {
                        // Durée en grand
                        VStack(spacing: 4) {
                            Text(String(localized: "Durée du vol"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(flight.durationFormatted)
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(.blue)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        // Statistiques de vol (juste après la durée)
                        if flight.startAltitude != nil || flight.maxAltitude != nil || flight.endAltitude != nil ||
                           flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil ||
                           verticalStats != nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(localized: "Statistiques de vol"))
                                    .font(.headline)

                                VStack(spacing: 8) {
                                    // Altitudes
                                    if flight.startAltitude != nil || flight.maxAltitude != nil || flight.endAltitude != nil {
                                        HStack(spacing: 8) {
                                            if let alt = flight.startAltitude {
                                                DetailStatCard(title: String(localized: "Alt. départ"), value: "\(Int(alt)) m", color: .orange, icon: "arrow.up.circle")
                                            }
                                            if let alt = flight.maxAltitude {
                                                DetailStatCard(title: String(localized: "Alt. max"), value: "\(Int(alt)) m", color: .red, icon: "arrow.up")
                                            }
                                            if let alt = flight.endAltitude {
                                                DetailStatCard(title: String(localized: "Alt. arrivée"), value: "\(Int(alt)) m", color: .orange, icon: "arrow.down.circle")
                                            }
                                        }
                                    }

                                    // Distance et vitesse
                                    HStack(spacing: 8) {
                                        if let distance = flight.totalDistance {
                                            DetailStatCard(
                                                title: String(localized: "Distance"),
                                                value: formatDistance(distance),
                                                color: .cyan,
                                                icon: "point.topleft.down.to.point.bottomright.curvepath"
                                            )
                                        }
                                        if let speed = flight.maxSpeed {
                                            DetailStatCard(
                                                title: String(localized: "Vitesse max"),
                                                value: "\(Int(speed * 3.6)) km/h",
                                                color: .purple,
                                                icon: "speedometer"
                                            )
                                        }
                                        if let gForce = flight.maxGForce {
                                            DetailStatCard(
                                                title: String(localized: "G-Force max"),
                                                value: String(format: "%.1f G", gForce),
                                                color: .green,
                                                icon: "waveform.path.ecg"
                                            )
                                        }
                                    }

                                    // Stats verticales calculées depuis la trace GPS
                                    if let vStats = verticalStats {
                                        HStack(spacing: 8) {
                                            DetailStatCard(
                                                title: String(localized: "Gain cumulé"),
                                                value: "\(Int(vStats.totalGain)) m",
                                                color: .mint,
                                                icon: "arrow.up.right"
                                            )
                                            DetailStatCard(
                                                title: String(localized: "Meilleure ascendance"),
                                                value: String(format: "+%.1f m/s", vStats.maxClimbRate),
                                                color: .orange,
                                                icon: "arrow.up.to.line"
                                            )
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // Date et heure
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(String(localized: "Début"), systemImage: "play.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(flight.startDate, format: .dateTime.weekday(.abbreviated).day().month().year())
                                    .font(.subheadline)
                                Text(flight.startDate, format: .dateTime.hour().minute())
                                    .font(.headline)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Label(String(localized: "Fin"), systemImage: "stop.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(flight.endDate, format: .dateTime.weekday(.abbreviated).day().month().year())
                                    .font(.subheadline)
                                Text(flight.endDate, format: .dateTime.hour().minute())
                                    .font(.headline)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    // Profil du vol (graphes altitude et Vz si trace avec altitudes)
                    if hasAltitudeProfile {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(String(localized: "Profil du vol"))
                                .font(.headline)

                            // Graphe altitude / temps
                            VStack(alignment: .leading, spacing: 6) {
                                Text(String(localized: "Altitude (m)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Chart(profileData.filter { $0.altitude != nil }) { point in
                                    AreaMark(
                                        x: .value("Temps (min)", point.minutes),
                                        y: .value("Altitude", point.altitude ?? 0)
                                    )
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue.opacity(0.45), .blue.opacity(0.05)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )

                                    LineMark(
                                        x: .value("Temps (min)", point.minutes),
                                        y: .value("Altitude", point.altitude ?? 0)
                                    )
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(.blue)
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                                }
                                .chartYScale(domain: .automatic(includesZero: false))
                                .chartXAxisLabel(String(localized: "min"), alignment: .trailing)
                                .frame(height: 150)
                            }

                            // Graphe vitesse verticale / temps
                            if hasVzProfile {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(String(localized: "Vitesse verticale (m/s)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Chart {
                                        // Ligne zéro
                                        RuleMark(y: .value("Zéro", 0))
                                            .foregroundStyle(.gray.opacity(0.6))
                                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                                        // Montées en orange (Vz clampée à ≥ 0)
                                        ForEach(profileData.filter { $0.vz != nil }) { point in
                                            LineMark(
                                                x: .value("Temps (min)", point.minutes),
                                                y: .value("Vz", max(0, point.vz ?? 0)),
                                                series: .value("Phase", "Montée")
                                            )
                                            .foregroundStyle(.orange)
                                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                                        }

                                        // Descentes en bleu (Vz clampée à ≤ 0)
                                        ForEach(profileData.filter { $0.vz != nil }) { point in
                                            LineMark(
                                                x: .value("Temps (min)", point.minutes),
                                                y: .value("Vz", min(0, point.vz ?? 0)),
                                                series: .value("Phase", "Descente")
                                            )
                                            .foregroundStyle(.blue)
                                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                                        }
                                    }
                                    .chartXAxisLabel(String(localized: "min"), alignment: .trailing)
                                    .frame(height: 130)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }

                    // Voile et spot
                    VStack(spacing: 12) {
                        if let wing = flight.wing {
                            HStack(spacing: 12) {
                                CachedImage(
                                    data: wing.photoData,
                                    key: wing.id.uuidString,
                                    size: CGSize(width: 50, height: 50)
                                ) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.blue.opacity(0.2))
                                        .overlay {
                                            Image(systemName: "wind")
                                                .foregroundStyle(.blue)
                                        }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Voile")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(wing.name)
                                        .font(.headline)
                                    if let size = wing.size {
                                        Text("\(size) m²")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        if let spotName = flight.spotName {
                            HStack {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.blue)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Spot")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(spotName)
                                        .font(.headline)
                                }
                                Spacer()

                                // Bouton pour proposer un renommage
                                if flight.latitude != nil && flight.longitude != nil {
                                    Button {
                                        showingRenameSpotSheet = true
                                    } label: {
                                        Image(systemName: "pencil.circle")
                                            .font(.title2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal)

                    // Notes
                    if let notes = flight.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes")
                                .font(.headline)
                            Text(notes)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 40)
                }
            }
            .navigationTitle("Détail du vol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showingShareSheet = true
                    } label: {
                        Label("Partager", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showingEditSheet = true
                    } label: {
                        Label("Modifier", systemImage: "pencil")
                    }
                }
            }
            .onAppear {
                computeVerticalAnalysis()
            }
            .sheet(isPresented: $showingEditSheet) {
                EditFlightView(flight: flight)
            }
            .sheet(isPresented: $showingShareSheet) {
                LocalFlightShareView(flight: flight)
            }
            .fullScreenCover(isPresented: $showingFullScreenMap) {
                FullScreenMapView(flight: flight, initialRegion: mapRegion)
            }
            .sheet(isPresented: $showingRenameSpotSheet) {
                SpotRenameSheet(
                    originalName: flight.spotName ?? "Spot inconnu",
                    newName: $renameSpotNewName,
                    onRename: { oldName, newName in
                        // Renommer le spot dans tous les vols (local)
                        let descriptor = FetchDescriptor<Flight>()
                        if let allFlights = try? modelContext.fetch(descriptor) {
                            for f in allFlights where f.spotName == oldName {
                                f.spotName = newName
                            }
                            try? modelContext.save()
                        }
                    }
                )
            }
        }
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1f km", distance / 1000)
        } else {
            return "\(Int(distance)) m"
        }
    }

    /// Calcule les stats verticales et le profil de vol (une seule fois à l'apparition)
    private func computeVerticalAnalysis() {
        guard let track = flight.gpsTrack, track.count >= 2 else {
            verticalStats = nil
            profileData = []
            return
        }

        verticalStats = GPSTraceColorMapper.verticalStats(points: track)

        // Échantillonner la trace pour les graphes (max ~240 points)
        let verticalSpeeds = GPSTraceColorMapper.smoothedVerticalSpeeds(points: track)
        guard let start = track.first?.timestamp else { return }

        let maxPoints = 240
        let step = max(1, track.count / maxPoints)
        var data: [FlightProfilePoint] = []

        for i in stride(from: 0, to: track.count, by: step) {
            data.append(FlightProfilePoint(
                index: i,
                minutes: track[i].timestamp.timeIntervalSince(start) / 60,
                altitude: track[i].altitude,
                vz: verticalSpeeds[i]
            ))
        }

        profileData = data
    }
}

// MARK: - DetailStatCard (Carte de stat pour la vue détail)

struct DetailStatCard: View {
    let title: String
    let value: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - FlightRow

struct FlightRow: View {
    let flight: Flight

    private let thumbnailSize = CGSize(width: 40, height: 40)

    var body: some View {
        HStack(spacing: 12) {
            // Photo de la voile avec cache (40x40)
            if let wing = flight.wing {
                CachedImage(
                    data: wing.photoData,
                    key: wing.id.uuidString,
                    size: thumbnailSize
                ) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill((wing.color ?? "Gris").toColor().opacity(0.3))
                        .overlay {
                            Image(systemName: "wind")
                                .font(.caption)
                                .foregroundStyle((wing.color ?? "Gris").toColor())
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // Pas de voile associée
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "questionmark")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(flight.dateFormatted)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Icône du type de vol si défini
                    if let type = flight.flightType, !type.isEmpty {
                        Image(systemName: FlightTypes.icon(for: type))
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .padding(4)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Circle())
                            .accessibilityLabel(type)
                    }

                    Spacer()

                    Text(flight.durationFormatted)
                        .font(.headline)
                        .foregroundStyle(.blue)
                }

                if let wing = flight.wing {
                    HStack(spacing: 4) {
                        Text(wing.name)
                            .font(.body)
                            .fontWeight(.medium)
                        if let size = wing.size {
                            Text("(\(size) m²)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let spotName = flight.spotName {
                    Label(spotName, systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Statistiques de vol (altitude, distance, vitesse, G-force)
                if flight.maxAltitude != nil || flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
                    HStack(spacing: 8) {
                        if let maxAlt = flight.maxAltitude {
                            Label("\(Int(maxAlt))m", systemImage: "arrow.up")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if let distance = flight.totalDistance {
                            Label(formatDistance(distance), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.caption2)
                                .foregroundStyle(.cyan)
                        }
                        if let speed = flight.maxSpeed {
                            Label("\(Int(speed * 3.6))km/h", systemImage: "speedometer")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                        }
                        if let gForce = flight.maxGForce {
                            Label(String(format: "%.1fG", gForce), systemImage: "waveform.path.ecg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1fkm", distance / 1000)
        } else {
            return "\(Int(distance))m"
        }
    }
}

// MARK: - EditFlightView (Éditer un vol)

struct EditFlightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    let flight: Flight

    @State private var selectedWing: Wing?
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var spotName: String
    @State private var notes: String

    // Type de vol : tag sélectionné dans le Picker + texte libre pour « Autre… »
    @State private var flightTypeSelection: String
    @State private var customFlightType: String

    /// Tag du Picker pour « Aucun » type de vol
    private static let noneTypeTag = "__none__"
    /// Tag du Picker pour « Autre… » (valeur libre)
    private static let otherTypeTag = "__other__"
    @State private var isGeocodingSpot = false
    @State private var geocodingMessage: String?
    @State private var showingMapPicker = false
    @State private var selectedCoordinate: CLLocationCoordinate2D?

    // Spot suggestions
    @State private var nearbySpots: [DataController.LocalSpot] = []
    @State private var showingSpotRenameSheet = false
    @State private var newSpotName: String = ""
    @State private var originalSpotName: String = ""

    // Statistiques de vol (lecture seule)
    @State private var startAltitude: String
    @State private var maxAltitude: String
    @State private var endAltitude: String
    @State private var totalDistance: String
    @State private var maxSpeed: String
    @State private var maxGForce: String

    // Suppression
    @State private var showingDeleteConfirmation = false
    @State private var showSaveError = false

    init(flight: Flight) {
        self.flight = flight
        _startDate = State(initialValue: flight.startDate)
        _endDate = State(initialValue: flight.endDate)
        _spotName = State(initialValue: flight.spotName ?? "")
        _notes = State(initialValue: flight.notes ?? "")
        if let lat = flight.latitude, let lon = flight.longitude {
            _selectedCoordinate = State(initialValue: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }

        // Initialiser le type de vol en préservant les valeurs libres existantes
        let currentType = flight.flightType ?? ""
        if currentType.isEmpty {
            _flightTypeSelection = State(initialValue: Self.noneTypeTag)
            _customFlightType = State(initialValue: "")
        } else if FlightTypes.all.contains(currentType) {
            _flightTypeSelection = State(initialValue: currentType)
            _customFlightType = State(initialValue: "")
        } else {
            // Valeur libre existante → « Autre… » avec le texte préservé
            _flightTypeSelection = State(initialValue: Self.otherTypeTag)
            _customFlightType = State(initialValue: currentType)
        }

        // Initialiser les statistiques (avec if let pour éviter les force unwraps)
        if let alt = flight.startAltitude {
            _startAltitude = State(initialValue: String(format: "%.0f", alt))
        } else {
            _startAltitude = State(initialValue: "")
        }
        if let alt = flight.maxAltitude {
            _maxAltitude = State(initialValue: String(format: "%.0f", alt))
        } else {
            _maxAltitude = State(initialValue: "")
        }
        if let alt = flight.endAltitude {
            _endAltitude = State(initialValue: String(format: "%.0f", alt))
        } else {
            _endAltitude = State(initialValue: "")
        }
        if let dist = flight.totalDistance {
            _totalDistance = State(initialValue: String(format: "%.0f", dist))
        } else {
            _totalDistance = State(initialValue: "")
        }
        if let speed = flight.maxSpeed {
            _maxSpeed = State(initialValue: String(format: "%.1f", speed * 3.6))
        } else {
            _maxSpeed = State(initialValue: "")
        }
        if let gforce = flight.maxGForce {
            _maxGForce = State(initialValue: String(format: "%.1f", gforce))
        } else {
            _maxGForce = State(initialValue: "")
        }
    }

    var calculatedDuration: Int {
        Int(endDate.timeIntervalSince(startDate))
    }

    var durationFormatted: String {
        let duration = max(0, calculatedDuration)
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date et heure") {
                    DatePicker("Début du vol", selection: $startDate)
                    DatePicker("Fin du vol", selection: $endDate)

                    HStack {
                        Text("Durée calculée")
                        Spacer()
                        Text(durationFormatted)
                            .foregroundStyle(calculatedDuration < 0 ? .red : .secondary)
                    }

                    if calculatedDuration < 0 {
                        Text("⚠️ La fin doit être après le début")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Voile utilisée") {
                    Picker("Voile", selection: $selectedWing) {
                        Text("Aucune").tag(nil as Wing?)
                        ForEach(wings) { wing in
                            Text(wing.name).tag(wing as Wing?)
                        }
                    }
                }

                Section(String(localized: "Type de vol")) {
                    Picker(String(localized: "Type"), selection: $flightTypeSelection) {
                        Text(String(localized: "Aucun")).tag(Self.noneTypeTag)
                        ForEach(FlightTypes.all, id: \.self) { type in
                            Label(type, systemImage: FlightTypes.icon(for: type)).tag(type)
                        }
                        Text(String(localized: "Autre…")).tag(Self.otherTypeTag)
                    }

                    // Champ libre révélé quand « Autre… » est sélectionné
                    if flightTypeSelection == Self.otherTypeTag {
                        TextField(String(localized: "Type personnalisé"), text: $customFlightType)
                            .autocorrectionDisabled()
                    }
                }

                Section("Spot") {
                    TextField("Nom du spot", text: $spotName)
                        .onChange(of: spotName) { _, _ in
                            updateNearbySpots()
                        }

                    // Suggestions de spots proches
                    if !nearbySpots.isEmpty && spotName.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Spots à proximité (~1km)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            ForEach(nearbySpots.prefix(3)) { spot in
                                Button {
                                    spotName = spot.name
                                } label: {
                                    HStack {
                                        Image(systemName: "mappin.circle.fill")
                                            .foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(spot.name)
                                                .foregroundStyle(.primary)
                                            Text("\(spot.flightCount) vol\(spot.flightCount > 1 ? "s" : "") • \(spot.formattedTotalTime)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.right.circle")
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Bouton pour renommer ce spot dans tous les vols
                    if let currentSpotName = flight.spotName, !currentSpotName.isEmpty {
                        Button {
                            originalSpotName = currentSpotName
                            newSpotName = currentSpotName
                            showingSpotRenameSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "pencil.circle")
                                Text("Renommer ce spot partout")
                                Spacer()
                                Text("(\(getFlightCountForSpot(currentSpotName)) vols)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Afficher les coordonnées si elles existent
                    if let coord = selectedCoordinate {
                        HStack {
                            Text("Coordonnées")
                            Spacer()
                            Text("\(coord.latitude, specifier: "%.4f"), \(coord.longitude, specifier: "%.4f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Bouton pour modifier les coordonnées sur la carte
                        Button {
                            showingMapPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "map")
                                Text("Modifier sur la carte")
                            }
                        }

                        // Bouton pour supprimer les coordonnées
                        Button(role: .destructive) {
                            selectedCoordinate = nil
                            flight.latitude = nil
                            flight.longitude = nil
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Supprimer les coordonnées")
                            }
                        }
                    } else {
                        // Bouton pour ajouter des coordonnées via geocoding
                        if !spotName.isEmpty {
                            Button {
                                geocodeSpot()
                            } label: {
                                HStack {
                                    if isGeocodingSpot {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "location.fill")
                                    }
                                    Text("Rechercher le lieu")
                                }
                            }
                            .disabled(isGeocodingSpot)
                        }

                        // Bouton pour choisir sur la carte
                        Button {
                            showingMapPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "map")
                                Text("Choisir sur la carte")
                            }
                        }

                        if let message = geocodingMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(message.hasPrefix("✅") ? .green : .red)
                        }
                    }
                }

                // Section statistiques en lecture seule
                if hasAnyStats {
                    Section(String(localized: "Statistiques de vol")) {
                        if !startAltitude.isEmpty {
                            HStack {
                                Label(String(localized: "Altitude départ"), systemImage: "arrow.up.circle")
                                Spacer()
                                Text("\(startAltitude) m")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !maxAltitude.isEmpty {
                            HStack {
                                Label(String(localized: "Altitude max"), systemImage: "arrow.up")
                                Spacer()
                                Text("\(maxAltitude) m")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !endAltitude.isEmpty {
                            HStack {
                                Label(String(localized: "Altitude atterrissage"), systemImage: "arrow.down.circle")
                                Spacer()
                                Text("\(endAltitude) m")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !totalDistance.isEmpty {
                            HStack {
                                Label(String(localized: "Distance"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                Spacer()
                                Text(formatDisplayDistance(totalDistance))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !maxSpeed.isEmpty {
                            HStack {
                                Label(String(localized: "Vitesse max"), systemImage: "speedometer")
                                Spacer()
                                Text("\(maxSpeed) km/h")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !maxGForce.isEmpty {
                            HStack {
                                Label(String(localized: "G-Force max"), systemImage: "waveform.path.ecg")
                                Spacer()
                                Text("\(maxGForce) G")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                }

                // Section suppression
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Supprimer ce vol")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Modifier le vol"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saveFlight()
                    }
                    .disabled(calculatedDuration < 0)
                }
            }
            .onAppear {
                selectedWing = flight.wing
                updateNearbySpots()
            }
            .sheet(isPresented: $showingMapPicker) {
                MapCoordinatePicker(
                    selectedCoordinate: $selectedCoordinate,
                    spotName: spotName
                )
            }
            .sheet(isPresented: $showingSpotRenameSheet) {
                SpotRenameSheet(
                    originalName: originalSpotName,
                    newName: $newSpotName,
                    onRename: { oldName, newName in
                        // Renommer le spot dans tous les vols
                        let descriptor = FetchDescriptor<Flight>()
                        if let allFlights = try? modelContext.fetch(descriptor) {
                            var renamedCount = 0
                            for f in allFlights {
                                if f.spotName == oldName {
                                    f.spotName = newName
                                    renamedCount += 1
                                }
                            }
                            if renamedCount > 0 {
                                try? modelContext.save()
                                spotName = newName
                                logInfo("Renamed spot '\(oldName)' to '\(newName)' in \(renamedCount) flights", category: .dataController)
                            }
                        }
                    }
                )
            }
            .confirmationDialog("Supprimer ce vol ?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    deleteFlight()
                }
                Button("Annuler", role: .cancel) {}
            }
            .alert("Erreur de sauvegarde", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Impossible de sauvegarder les modifications. Veuillez réessayer.")
            }
        }
    }

    private func deleteFlight() {
        modelContext.delete(flight)
        do {
            try modelContext.save()
        } catch {
            logError("Error deleting flight: \(error)", category: .flight)
        }
        dismiss()
    }

    private var hasAnyStats: Bool {
        !startAltitude.isEmpty || !maxAltitude.isEmpty || !endAltitude.isEmpty ||
        !totalDistance.isEmpty || !maxSpeed.isEmpty || !maxGForce.isEmpty
    }

    private func formatDisplayDistance(_ distance: String) -> String {
        guard let d = Double(distance) else { return "\(distance) m" }
        if d >= 1000 {
            return String(format: "%.1f km", d / 1000)
        } else {
            return "\(Int(d)) m"
        }
    }

    private func saveFlight() {
        flight.wing = selectedWing
        flight.startDate = startDate
        flight.endDate = endDate
        flight.durationSeconds = calculatedDuration
        flight.spotName = spotName.isEmpty ? nil : spotName
        flight.notes = notes.isEmpty ? nil : notes
        flight.latitude = selectedCoordinate?.latitude
        flight.longitude = selectedCoordinate?.longitude

        // Type de vol : valeur du Picker ou texte libre (« Autre… »)
        switch flightTypeSelection {
        case Self.noneTypeTag:
            flight.flightType = nil
        case Self.otherTypeTag:
            let trimmed = customFlightType.trimmingCharacters(in: .whitespacesAndNewlines)
            flight.flightType = trimmed.isEmpty ? nil : trimmed
        default:
            flight.flightType = flightTypeSelection
        }

        // Les statistiques ne sont plus modifiables, elles sont préservées

        Task { @MainActor in
            do {
                try modelContext.save()
                dismiss()
            } catch {
                logError("Failed to save flight: \(error.localizedDescription)", category: .dataController)
                showSaveError = true
            }
        }
    }

    private func geocodeSpot() {
        guard !spotName.isEmpty else { return }

        isGeocodingSpot = true
        geocodingMessage = nil

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = spotName
        let search = MKLocalSearch(request: request)

        search.start { response, error in
            DispatchQueue.main.async {
                isGeocodingSpot = false

                if let error = error {
                    geocodingMessage = "❌ Impossible de trouver ce lieu"
                    logError("Geocoding error: \(error.localizedDescription)", category: .location)
                    return
                }

                guard let mapItem = response?.mapItems.first else {
                    geocodingMessage = "❌ Aucun résultat trouvé"
                    return
                }
                let location = mapItem.location

                selectedCoordinate = location.coordinate
                flight.latitude = location.coordinate.latitude
                flight.longitude = location.coordinate.longitude
                geocodingMessage = "✅ Coordonnées ajoutées"

                Task { @MainActor in
                    do {
                        try modelContext.save()
                    } catch {
                        logError("Failed to save geocoded coordinates: \(error.localizedDescription)", category: .dataController)
                        // Note: On ne montre pas d'alerte ici car les coordonnées sont déjà visuellement affichées
                        // et seront sauvegardées au prochain enregistrement du vol
                    }
                }
            }
        }
    }

    private func updateNearbySpots() {
        // Si on a des coordonnées, chercher les spots proches
        guard let coord = selectedCoordinate else {
            nearbySpots = []
            return
        }

        let descriptor = FetchDescriptor<Flight>()
        guard let allFlights = try? modelContext.fetch(descriptor) else {
            nearbySpots = []
            return
        }

        // Grouper les vols par nom de spot
        var spotGroups: [String: (flights: [Flight], avgLat: Double, avgLon: Double)] = [:]

        for f in allFlights {
            guard let spotName = f.spotName,
                  let lat = f.latitude,
                  let lon = f.longitude else { continue }

            if var group = spotGroups[spotName] {
                group.flights.append(f)
                let count = Double(group.flights.count)
                let prevCount = count - 1
                group.avgLat = (group.avgLat * prevCount + lat) / count
                group.avgLon = (group.avgLon * prevCount + lon) / count
                spotGroups[spotName] = group
            } else {
                spotGroups[spotName] = (flights: [f], avgLat: lat, avgLon: lon)
            }
        }

        // Filtrer par distance (1km) et créer les LocalSpot
        var result: [(spot: DataController.LocalSpot, distance: Double)] = []
        let radiusMeters = 1000.0

        for (name, group) in spotGroups {
            let distance = haversineDistance(
                lat1: coord.latitude, lon1: coord.longitude,
                lat2: group.avgLat, lon2: group.avgLon
            )

            if distance <= radiusMeters {
                let totalSeconds = group.flights.reduce(0) { $0 + $1.durationSeconds }
                let spot = DataController.LocalSpot(
                    name: name,
                    latitude: group.avgLat,
                    longitude: group.avgLon,
                    flightCount: group.flights.count,
                    totalFlightSeconds: totalSeconds
                )
                result.append((spot: spot, distance: distance))
            }
        }

        nearbySpots = result.sorted { $0.distance < $1.distance }.map { $0.spot }
    }

    private func getFlightCountForSpot(_ spotName: String) -> Int {
        let descriptor = FetchDescriptor<Flight>()
        guard let allFlights = try? modelContext.fetch(descriptor) else { return 0 }
        return allFlights.filter { $0.spotName == spotName }.count
    }

    private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 6371000.0 // mètres
        let lat1Rad = lat1 * .pi / 180
        let lat2Rad = lat2 * .pi / 180
        let deltaLat = (lat2 - lat1) * .pi / 180
        let deltaLon = (lon2 - lon1) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2) +
                cos(lat1Rad) * cos(lat2Rad) *
                sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadius * c
    }
}

// MARK: - SpotRenameSheet

struct SpotRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let originalName: String
    @Binding var newName: String
    let onRename: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Nom actuel")
                        Spacer()
                        Text(originalName)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Nouveau nom", text: $newName)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Ce changement sera appliqué à tous les vols de ce spot.")
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

                ToolbarItem(placement: .confirmationAction) {
                    Button("Renommer") {
                        if !newName.isEmpty && newName != originalName {
                            onRename(originalName, newName)
                        }
                        dismiss()
                    }
                    .disabled(newName.isEmpty || newName == originalName)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - MapCoordinatePicker (Sélecteur de coordonnées sur carte)

struct MapCoordinatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCoordinate: CLLocationCoordinate2D?
    let spotName: String

    @State private var cameraPosition: MapCameraPosition
    @State private var markerCoordinate: CLLocationCoordinate2D?
    @State private var searchText: String = ""
    @State private var isSearching = false

    init(selectedCoordinate: Binding<CLLocationCoordinate2D?>, spotName: String) {
        self._selectedCoordinate = selectedCoordinate
        self.spotName = spotName

        // Position initiale : coordonnées existantes ou France par défaut
        if let coord = selectedCoordinate.wrappedValue {
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )))
            _markerCoordinate = State(initialValue: coord)
        } else {
            // France par défaut
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
                span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
            )))
        }
        _searchText = State(initialValue: spotName)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Carte
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        if let coord = markerCoordinate {
                            Marker(spotName.isEmpty ? "Position" : spotName, coordinate: coord)
                                .tint(.red)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .onTapGesture { position in
                        if let coordinate = proxy.convert(position, from: .local) {
                            withAnimation {
                                markerCoordinate = coordinate
                            }
                        }
                    }
                }

                // Instructions en bas
                VStack {
                    Spacer()

                    VStack(spacing: 8) {
                        // Barre de recherche
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Rechercher un lieu...", text: $searchText)
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    searchLocation()
                                }
                            if isSearching {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else if !searchText.isEmpty {
                                Button {
                                    searchLocation()
                                } label: {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text("Tapez sur la carte pour placer le marqueur")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())

                        if let coord = markerCoordinate {
                            Text("\(coord.latitude, specifier: "%.5f"), \(coord.longitude, specifier: "%.5f")")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Choisir la position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Valider") {
                        selectedCoordinate = markerCoordinate
                        dismiss()
                    }
                    .disabled(markerCoordinate == nil)
                }
            }
            .onAppear {
                // Si on a un nom de spot mais pas de coordonnées, rechercher automatiquement
                if !spotName.isEmpty && markerCoordinate == nil {
                    searchLocation()
                }
            }
        }
    }

    private func searchLocation() {
        let query = searchText.isEmpty ? spotName : searchText
        guard !query.isEmpty else { return }

        isSearching = true

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let search = MKLocalSearch(request: request)

        search.start { response, error in
            DispatchQueue.main.async {
                isSearching = false

                guard let mapItem = response?.mapItems.first else { return }
                let location = mapItem.location

                withAnimation {
                    markerCoordinate = location.coordinate
                    cameraPosition = .region(MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
            }
        }
    }
}

// MARK: - FullScreenMapView (Carte plein écran pour analyser la trace GPS)

struct FullScreenMapView: View {
    @Environment(\.dismiss) private var dismiss
    let flight: Flight
    let initialRegion: MKCoordinateRegion

    @State private var selectedMapStyle: Int = 0  // 0 = standard, 1 = satellite, 2 = hybrid
    @State private var showColoredTrace = true

    // Calculer les segments colorés si trace GPS disponible
    private var coloredSegments: [SpeedSegment] {
        guard let track = flight.gpsTrack, track.count >= 2 else { return [] }
        return GPSTraceColorMapper.generateColoredSegments(points: track)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Carte avec trace colorée (UIViewRepresentable)
                FullScreenColoredMapView(
                    flight: flight,
                    segments: showColoredTrace ? coloredSegments : [],
                    initialRegion: initialRegion,
                    mapType: selectedMapStyle
                )
                .ignoresSafeArea(edges: .bottom)

                // Contrôles overlay
                VStack {
                    // Toggle trace colorée en haut à droite
                    HStack {
                        Spacer()
                        if !coloredSegments.isEmpty {
                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    showColoredTrace.toggle()
                                }
                            } label: {
                                Image(systemName: showColoredTrace ? "paintpalette.fill" : "paintpalette")
                                    .font(.title3)
                                    .padding(10)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .padding(.trailing, 16)
                            .padding(.top, 8)
                        }
                    }

                    Spacer()

                    // Légende des couleurs si trace colorée active
                    if showColoredTrace && !coloredSegments.isEmpty {
                        SpeedLegendView()
                            .padding(.bottom, 8)
                    }

                    // Infos du vol
                    HStack(spacing: 16) {
                        if let track = flight.gpsTrack, !track.isEmpty {
                            Label("\(track.count) pts", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                .font(.caption)
                        }
                        if let distance = flight.totalDistance {
                            Label(formatDistance(distance), systemImage: "arrow.triangle.swap")
                                .font(.caption)
                        }
                        if let maxAlt = flight.maxAltitude {
                            Label("\(Int(maxAlt))m max", systemImage: "arrow.up")
                                .font(.caption)
                        }
                        Text(flight.durationFormatted)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.bottom, 8)

                    // Sélecteur de style de carte
                    Picker("Style", selection: $selectedMapStyle) {
                        Text("Standard").tag(0)
                        Text("Satellite").tag(1)
                        Text("Hybride").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle(flight.spotName ?? String(localized: "Trace GPS"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1f km", distance / 1000)
        } else {
            return "\(Int(distance)) m"
        }
    }
}

// MARK: - FullScreenColoredMapView (UIViewRepresentable pour carte avec trace colorée)

struct FullScreenColoredMapView: UIViewRepresentable {
    let flight: Flight
    let segments: [SpeedSegment]
    let initialRegion: MKCoordinateRegion
    let mapType: Int  // 0 = standard, 1 = satellite, 2 = hybrid

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.setRegion(initialRegion, animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Mettre à jour le type de carte
        switch mapType {
        case 1:
            mapView.mapType = .satellite
        case 2:
            mapView.mapType = .hybrid
        default:
            mapView.mapType = .standard
        }

        // Supprimer les overlays et annotations existants
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        // Si on a des segments colorés, les afficher
        if !segments.isEmpty {
            for segment in segments {
                let coordinates = [
                    CLLocationCoordinate2D(
                        latitude: segment.startPoint.latitude,
                        longitude: segment.startPoint.longitude
                    ),
                    CLLocationCoordinate2D(
                        latitude: segment.endPoint.latitude,
                        longitude: segment.endPoint.longitude
                    )
                ]
                let polyline = ColoredPolyline(coordinates: coordinates, count: 2)
                polyline.color = UIColor(segment.color)
                mapView.addOverlay(polyline)
            }
        } else if let track = flight.gpsTrack, track.count >= 2 {
            // Trace bleue standard si pas de segments colorés
            let coordinates = track.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polyline)
        }

        // Ajouter les annotations de départ et arrivée
        if let track = flight.gpsTrack, track.count >= 2 {
            if let first = track.first {
                let startAnnotation = FlightPointAnnotation(
                    coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                    title: "Départ",
                    altitude: first.altitude,
                    isStart: true
                )
                mapView.addAnnotation(startAnnotation)
            }

            if let last = track.last {
                let endAnnotation = FlightPointAnnotation(
                    coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
                    title: "Arrivée",
                    altitude: last.altitude,
                    isStart: false
                )
                mapView.addAnnotation(endAnnotation)
            }
        } else if let lat = flight.latitude, let lon = flight.longitude {
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            annotation.title = flight.spotName ?? "Vol"
            mapView.addAnnotation(annotation)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let coloredPolyline = overlay as? ColoredPolyline {
                let renderer = MKPolylineRenderer(polyline: coloredPolyline)
                renderer.strokeColor = coloredPolyline.color
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            } else if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let flightAnnotation = annotation as? FlightPointAnnotation else {
                return nil
            }

            let identifier = flightAnnotation.isStart ? "StartAnnotation" : "EndAnnotation"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)

            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = true
            } else {
                annotationView?.annotation = annotation
            }

            // Créer la vue personnalisée pour l'annotation
            let containerView = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 60))

            let circleView = UIView(frame: CGRect(x: 9, y: 0, width: 32, height: 32))
            circleView.backgroundColor = flightAnnotation.isStart ? .systemGreen : .systemRed
            circleView.layer.cornerRadius = 16

            let imageView = UIImageView(frame: CGRect(x: 6, y: 6, width: 20, height: 20))
            let imageName = flightAnnotation.isStart ? "flag.fill" : "flag.checkered"
            imageView.image = UIImage(systemName: imageName)
            imageView.tintColor = .white
            imageView.contentMode = .scaleAspectFit
            circleView.addSubview(imageView)
            containerView.addSubview(circleView)

            // Badge altitude si disponible
            if let altitude = flightAnnotation.altitude {
                let altLabel = UILabel(frame: CGRect(x: 0, y: 34, width: 50, height: 18))
                altLabel.text = "\(Int(altitude))m"
                altLabel.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
                altLabel.textColor = .white
                altLabel.textAlignment = .center
                altLabel.backgroundColor = flightAnnotation.isStart ? .systemGreen : .systemRed
                altLabel.layer.cornerRadius = 9
                altLabel.layer.masksToBounds = true
                containerView.addSubview(altLabel)
            }

            // Convertir la vue en image
            let renderer = UIGraphicsImageRenderer(bounds: containerView.bounds)
            let image = renderer.image { context in
                containerView.layer.render(in: context.cgContext)
            }
            annotationView?.image = image
            annotationView?.centerOffset = CGPoint(x: 0, y: -25)

            return annotationView
        }
    }
}

// MARK: - FlightPointAnnotation (Annotation personnalisée pour départ/arrivée)

class FlightPointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let altitude: Double?
    let isStart: Bool

    init(coordinate: CLLocationCoordinate2D, title: String?, altitude: Double?, isStart: Bool) {
        self.coordinate = coordinate
        self.title = title
        self.altitude = altitude
        self.isStart = isStart
        super.init()
    }
}

