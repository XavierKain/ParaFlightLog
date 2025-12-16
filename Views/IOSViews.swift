//
//  IOSViews.swift
//  ParaFlightLog
//
//  Toutes les vues SwiftUI pour l'app iOS
//  Target: iOS only
//

import SwiftUI
import SwiftData
import Charts
import PhotosUI
import MapKit

// MARK: - ContentView (TabView principale)

struct ContentView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocalizationManager.self) private var localizationManager

    // Conserver l'onglet sélectionné lors du changement de langue
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            WingsView()
                .tabItem {
                    Label("Voiles", systemImage: "wind")
                }
                .tag(0)

            FlightsView()
                .tabItem {
                    Label("Vols", systemImage: "airplane")
                }
                .tag(1)

            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar")
                }
                .tag(2)

            ChartsView()
                .tabItem {
                    Label("Graphiques", systemImage: "chart.xyaxis.line")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Réglages", systemImage: "gearshape")
                }
                .tag(4)
        }
    }
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

    // Dernier vol (le plus récent)
    private var latestFlight: Flight? {
        flights.first
    }

    // Autres vols (tous sauf le dernier)
    private var olderFlights: [Flight] {
        Array(flights.dropFirst())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if flights.isEmpty {
                    ContentUnavailableView(
                        "Aucun vol",
                        systemImage: "airplane.circle",
                        description: Text("Commencez un vol depuis la Watch ou l'onglet Chrono")
                    )
                    .padding(.top, 100)
                } else {
                    VStack(spacing: 20) {
                        // Dernier vol en grand
                        if let latest = latestFlight {
                            LatestFlightCard(flight: latest)
                                .onTapGesture {
                                    showingFlightDetail = latest
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        flightToDelete = latest
                                        showingDeleteConfirmation = true
                                    } label: {
                                        Label("Supprimer", systemImage: "trash")
                                    }
                                }
                        }

                        // Vols précédents
                        if !olderFlights.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Vols précédents")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)

                                // Utiliser un List pour permettre swipe-to-delete
                                List {
                                    ForEach(olderFlights) { flight in
                                        FlightRow(flight: flight)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                showingFlightDetail = flight
                                            }
                                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                            .listRowSeparator(.hidden)
                                            .listRowBackground(Color.clear)
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button(role: .destructive) {
                                                    deleteFlight(flight)
                                                } label: {
                                                    Label("Supprimer", systemImage: "trash")
                                                }
                                            }
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    deleteFlight(flight)
                                                } label: {
                                                    Label("Supprimer", systemImage: "trash")
                                                }
                                            }
                                    }
                                }
                                .listStyle(.plain)
                                .frame(height: CGFloat(olderFlights.count) * 110) // Hauteur approximative par row
                                .scrollDisabled(true) // Le scroll est géré par le ScrollView parent
                            }
                        }
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle(String(localized: "Mes vols"))
            .id(localizationManager.currentLanguage) // Force re-render quand la langue change
            .sheet(item: $showingFlightDetail) { flight in
                FlightDetailView(flight: flight)
            }
            .confirmationDialog("Supprimer ce vol ?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    if let flight = flightToDelete {
                        deleteFlight(flight)
                    }
                }
                Button("Annuler", role: .cancel) {}
            }
        }
    }

    private func deleteFlight(_ flight: Flight) {
        modelContext.delete(flight)
        do {
            try modelContext.save()
            print("✅ Flight deleted and saved to database")
        } catch {
            print("❌ Error saving deletion: \(error)")
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
                            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 32, height: 32)
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
        .padding(.horizontal)
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

// MARK: - FlightDetailView (Vue détaillée d'un vol)

struct FlightDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let flight: Flight
    @State private var showingEditSheet = false
    @State private var showingExportSheet = false
    @State private var exportURL: URL?

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
                    // Map avec trace GPS ou simple marker
                    if flight.gpsTrack != nil || (flight.latitude != nil && flight.longitude != nil) {
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
                        .padding(.horizontal)

                        // Info sur la trace GPS
                        if let track = flight.gpsTrack, !track.isEmpty {
                            HStack {
                                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                    .foregroundStyle(.blue)
                                Text("\(track.count) points GPS enregistrés")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                           flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
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
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // Estimation du vent
                        if flight.windSpeed != nil || flight.gpsTrack?.count ?? 0 >= 12 {
                            WindEstimationCard(flight: flight)
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

                    // Voile et spot
                    VStack(spacing: 12) {
                        if let wing = flight.wing {
                            HStack(spacing: 12) {
                                if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 50, height: 50)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.blue.opacity(0.2))
                                        .frame(width: 50, height: 50)
                                        .overlay {
                                            Image(systemName: "wind")
                                                .foregroundStyle(.blue)
                                        }
                                }
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingEditSheet = true
                        } label: {
                            Label("Modifier", systemImage: "pencil")
                        }

                        if flight.gpsTrack != nil && !flight.gpsTrack!.isEmpty {
                            Button {
                                exportFlightGPX()
                            } label: {
                                Label("Exporter GPX", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                exportFlightJSON()
                            } label: {
                                Label("Exporter JSON", systemImage: "doc.text")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                EditFlightView(flight: flight)
            }
            .sheet(isPresented: $showingExportSheet) {
                if let url = exportURL {
                    ShareSheet(items: [url]) { _ in
                        showingExportSheet = false
                    }
                }
            }
        }
    }

    private func exportFlightGPX() {
        guard let track = flight.gpsTrack, !track.isEmpty else { return }

        let gpx = FlightExporter.exportToGPX(flight: flight, track: track)
        let fileName = "ParaFlightLog_\(formatDateForFilename(flight.startDate)).gpx"

        if let url = saveToTempFile(content: gpx, fileName: fileName) {
            exportURL = url
            showingExportSheet = true
        }
    }

    private func exportFlightJSON() {
        guard let track = flight.gpsTrack else { return }

        let json = FlightExporter.exportToJSON(flight: flight, track: track)
        let fileName = "ParaFlightLog_\(formatDateForFilename(flight.startDate)).json"

        if let url = saveToTempFile(content: json, fileName: fileName) {
            exportURL = url
            showingExportSheet = true
        }
    }

    private func saveToTempFile(content: String, fileName: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("❌ Erreur sauvegarde fichier: \(error)")
            return nil
        }
    }

    private func formatDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1f km", distance / 1000)
        } else {
            return "\(Int(distance)) m"
        }
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

// MARK: - WindEstimationCard

struct WindEstimationCard: View {
    let flight: Flight
    @State private var isCalculating = false
    @Environment(\.modelContext) private var modelContext

    private var windUnit: String {
        UserDefaults.standard.string(forKey: "windUnit") ?? "knots"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Estimation du vent", systemImage: "wind")
                    .font(.headline)
                Spacer()
                if let confidence = flight.windConfidence {
                    ConfidenceBadge(confidence: confidence)
                }
            }

            if let windSpeed = flight.windSpeed, windSpeed > 0 {
                // Affichage du vent calculé
                HStack(spacing: 20) {
                    // Boussole du vent
                    if let direction = flight.windDirection {
                        WindCompassView(direction: direction)
                            .frame(width: 70, height: 70)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        // Vitesse moyenne
                        HStack(spacing: 4) {
                            Text(formatWindSpeed(windSpeed))
                                .font(.title)
                                .fontWeight(.bold)
                            Text(windUnit == "knots" ? "kn" : "km/h")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Direction
                        if let direction = flight.windDirection {
                            let cardinal = directionToCardinal(direction)
                            Text("Vent de \(cardinal) (\(Int(direction))°)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Fourchette
                        if let min = flight.windSpeedMin, let max = flight.windSpeedMax {
                            Text("Fourchette: \(formatWindRange(min: min, max: max))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if isCalculating {
                HStack {
                    ProgressView()
                    Text("Calcul en cours...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Pas encore calculé
                VStack(spacing: 8) {
                    Text("Estimation non calculée")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        calculateWind()
                    } label: {
                        Label("Calculer l'estimation", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func calculateWind() {
        isCalculating = true
        Task {
            flight.calculateWindEstimation()
            try? modelContext.save()
            await MainActor.run {
                isCalculating = false
            }
        }
    }

    private func formatWindSpeed(_ speed: Double) -> String {
        let value = windUnit == "knots" ? speed * 1.94384 : speed * 3.6
        return String(Int(value.rounded()))
    }

    private func formatWindRange(min: Double, max: Double) -> String {
        let (minVal, maxVal) = windUnit == "knots"
            ? (Int((min * 1.94384).rounded()), Int((max * 1.94384).rounded()))
            : (Int((min * 3.6).rounded()), Int((max * 3.6).rounded()))
        let unit = windUnit == "knots" ? "kn" : "km/h"
        return "\(minVal)-\(maxVal) \(unit)"
    }

    private func directionToCardinal(_ degrees: Double) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let index = Int((degrees + 22.5) / 45.0) % 8
        return directions[index]
    }
}

// MARK: - WindCompassView

struct WindCompassView: View {
    let direction: Double  // Direction d'où vient le vent (degrés)

    var body: some View {
        ZStack {
            // Cercle de fond
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 2)

            // Points cardinaux
            ForEach(["N", "E", "S", "O"], id: \.self) { dir in
                Text(dir)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .position(positionForDirection(dir, in: 70))
            }

            // Flèche du vent (pointe vers où va le vent)
            Image(systemName: "arrow.down")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.teal)
                .rotationEffect(.degrees(direction))
        }
    }

    private func positionForDirection(_ dir: String, in size: CGFloat) -> CGPoint {
        let center = size / 2
        let radius = size / 2 - 10
        let angle: Double
        switch dir {
        case "N": angle = -90
        case "E": angle = 0
        case "S": angle = 90
        case "O": angle = 180
        default: angle = 0
        }
        let radians = angle * .pi / 180
        return CGPoint(
            x: center + cos(radians) * radius,
            y: center + sin(radians) * radius
        )
    }
}

// MARK: - ConfidenceBadge

struct ConfidenceBadge: View {
    let confidence: Double

    var color: Color {
        switch confidence {
        case 0.7...: return .green
        case 0.4..<0.7: return .orange
        default: return .red
        }
    }

    var text: String {
        switch confidence {
        case 0.7...: return "Fiable"
        case 0.4..<0.7: return "Approximatif"
        default: return "Incertain"
        }
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - FlightExporter

struct FlightExporter {
    /// Exporte un vol au format GPX
    static func exportToGPX(flight: Flight, track: [GPSTrackPoint]) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="ParaFlightLog"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escapeXML(flight.spotName ?? "Vol ParaFlightLog"))</name>
            <time>\(dateFormatter.string(from: flight.startDate))</time>
          </metadata>
          <trk>
            <name>\(escapeXML(flight.wing?.name ?? "Vol")) - \(flight.durationFormatted)</name>
            <trkseg>

        """

        for point in track {
            var trkpt = "      <trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
            if let altitude = point.altitude {
                trkpt += "\n        <ele>\(altitude)</ele>"
            }
            trkpt += "\n        <time>\(dateFormatter.string(from: point.timestamp))</time>"
            if let speed = point.speed {
                trkpt += "\n        <extensions><speed>\(speed)</speed></extensions>"
            }
            trkpt += "\n      </trkpt>\n"
            gpx += trkpt
        }

        gpx += """
            </trkseg>
          </trk>
        </gpx>
        """

        return gpx
    }

    /// Exporte un vol au format JSON complet
    static func exportToJSON(flight: Flight, track: [GPSTrackPoint]) -> String {
        let dateFormatter = ISO8601DateFormatter()

        var json: [String: Any] = [
            "id": flight.id.uuidString,
            "startDate": dateFormatter.string(from: flight.startDate),
            "endDate": dateFormatter.string(from: flight.endDate),
            "durationSeconds": flight.durationSeconds
        ]

        if let spotName = flight.spotName { json["spotName"] = spotName }
        if let lat = flight.latitude { json["latitude"] = lat }
        if let lon = flight.longitude { json["longitude"] = lon }
        if let notes = flight.notes { json["notes"] = notes }

        // Wing info
        if let wing = flight.wing {
            json["wing"] = [
                "id": wing.id.uuidString,
                "name": wing.name,
                "size": wing.size as Any,
                "type": wing.type as Any
            ]
        }

        // Tracking data
        if let alt = flight.startAltitude { json["startAltitude"] = alt }
        if let alt = flight.maxAltitude { json["maxAltitude"] = alt }
        if let alt = flight.endAltitude { json["endAltitude"] = alt }
        if let dist = flight.totalDistance { json["totalDistance"] = dist }
        if let speed = flight.maxSpeed { json["maxSpeed"] = speed }
        if let gForce = flight.maxGForce { json["maxGForce"] = gForce }

        // Wind estimation
        if let wind = flight.windSpeed {
            json["windEstimation"] = [
                "speed": wind,
                "speedMin": flight.windSpeedMin as Any,
                "speedMax": flight.windSpeedMax as Any,
                "direction": flight.windDirection as Any,
                "confidence": flight.windConfidence as Any
            ]
        }

        // GPS Track
        let trackData = track.map { point -> [String: Any] in
            var p: [String: Any] = [
                "timestamp": dateFormatter.string(from: point.timestamp),
                "latitude": point.latitude,
                "longitude": point.longitude
            ]
            if let alt = point.altitude { p["altitude"] = alt }
            if let speed = point.speed { p["speed"] = speed }
            return p
        }
        json["gpsTrack"] = trackData

        // Convert to JSON string
        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "{}"
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct FlightRow: View {
    let flight: Flight

    var body: some View {
        HStack(spacing: 12) {
            // Photo de la voile (40x40)
            if let wing = flight.wing {
                if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "wind")
                                .font(.caption)
                                .foregroundStyle(colorFromString(wing.color ?? "Gris"))
                        }
                }
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

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "bleu": return .blue
        case "rouge": return .red
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        case "gris": return .gray
        default: return .gray
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
    @State private var isGeocodingSpot = false
    @State private var geocodingMessage: String?
    @State private var showingMapPicker = false
    @State private var selectedCoordinate: CLLocationCoordinate2D?

    // Statistiques de vol (lecture seule)
    @State private var startAltitude: String
    @State private var maxAltitude: String
    @State private var endAltitude: String
    @State private var totalDistance: String
    @State private var maxSpeed: String
    @State private var maxGForce: String

    // Suppression
    @State private var showingDeleteConfirmation = false

    init(flight: Flight) {
        self.flight = flight
        _startDate = State(initialValue: flight.startDate)
        _endDate = State(initialValue: flight.endDate)
        _spotName = State(initialValue: flight.spotName ?? "")
        _notes = State(initialValue: flight.notes ?? "")
        if let lat = flight.latitude, let lon = flight.longitude {
            _selectedCoordinate = State(initialValue: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }

        // Initialiser les statistiques
        _startAltitude = State(initialValue: flight.startAltitude != nil ? String(format: "%.0f", flight.startAltitude!) : "")
        _maxAltitude = State(initialValue: flight.maxAltitude != nil ? String(format: "%.0f", flight.maxAltitude!) : "")
        _endAltitude = State(initialValue: flight.endAltitude != nil ? String(format: "%.0f", flight.endAltitude!) : "")
        _totalDistance = State(initialValue: flight.totalDistance != nil ? String(format: "%.0f", flight.totalDistance!) : "")
        _maxSpeed = State(initialValue: flight.maxSpeed != nil ? String(format: "%.1f", flight.maxSpeed! * 3.6) : "")
        _maxGForce = State(initialValue: flight.maxGForce != nil ? String(format: "%.1f", flight.maxGForce!) : "")
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

                Section("Spot") {
                    TextField("Nom du spot", text: $spotName)

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
            }
            .sheet(isPresented: $showingMapPicker) {
                MapCoordinatePicker(
                    selectedCoordinate: $selectedCoordinate,
                    spotName: spotName
                )
            }
            .confirmationDialog("Supprimer ce vol ?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    deleteFlight()
                }
                Button("Annuler", role: .cancel) {}
            }
        }
    }

    private func deleteFlight() {
        modelContext.delete(flight)
        do {
            try modelContext.save()
        } catch {
            print("❌ Error deleting flight: \(error)")
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

        // Les statistiques ne sont plus modifiables, elles sont préservées

        Task { @MainActor in
            try? modelContext.save()
        }

        dismiss()
    }

    private func geocodeSpot() {
        guard !spotName.isEmpty else { return }

        isGeocodingSpot = true
        geocodingMessage = nil

        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(spotName) { placemarks, error in
            DispatchQueue.main.async {
                isGeocodingSpot = false

                if let error = error {
                    geocodingMessage = "❌ Impossible de trouver ce lieu"
                    print("Geocoding error: \(error.localizedDescription)")
                    return
                }

                guard let location = placemarks?.first?.location else {
                    geocodingMessage = "❌ Aucun résultat trouvé"
                    return
                }

                selectedCoordinate = location.coordinate
                flight.latitude = location.coordinate.latitude
                flight.longitude = location.coordinate.longitude
                geocodingMessage = "✅ Coordonnées ajoutées"

                Task { @MainActor in
                    try? modelContext.save()
                }
            }
        }
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
        
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(query) { placemarks, error in
            DispatchQueue.main.async {
                isSearching = false
                
                guard let location = placemarks?.first?.location else { return }
                
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

// MARK: - WingsView (Liste + ajout de voiles)

struct WingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]
    @State private var showingAddWing = false
    @State private var wingToAction: Wing?
    @State private var showingActionSheet = false

    var body: some View {
        NavigationStack {
            List {
                if wings.isEmpty {
                    ContentUnavailableView(
                        "Aucune voile",
                        systemImage: "wind",
                        description: Text("Ajoutez votre première voile")
                    )
                } else {
                    ForEach(wings) { wing in
                        NavigationLink {
                            WingDetailView(wing: wing)
                        } label: {
                            WingRow(wing: wing)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                wingToAction = wing
                                showingActionSheet = true
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveWing)
                }
            }
            .navigationTitle(String(localized: "Mes voiles"))
            .id(localizationManager.currentLanguage) // Force re-render quand la langue change
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddWing = true
                    } label: {
                        Label("Ajouter", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddWing) {
                AddWingView()
            }
            .confirmationDialog("Que voulez-vous faire ?", isPresented: $showingActionSheet, presenting: wingToAction) { wing in
                Button("Archiver") {
                    dataController.archiveWing(wing)
                }
                Button("Supprimer définitivement", role: .destructive) {
                    let flightCount = wing.flights?.count ?? 0
                    if flightCount > 0 {
                        // Si la voile a des vols, forcer l'archivage
                        dataController.archiveWing(wing)
                    } else {
                        // Si pas de vols, suppression directe
                        dataController.deleteWing(wing)
                    }
                }
                Button("Annuler", role: .cancel) { }
            } message: { wing in
                let flightCount = wing.flights?.count ?? 0
                if flightCount > 0 {
                    Text("Cette voile a \(flightCount) vol\(flightCount > 1 ? "s" : "") enregistré\(flightCount > 1 ? "s" : ""). L'archivage conservera les données, la suppression les effacera.")
                } else {
                    Text("Cette voile n'a aucun vol enregistré.")
                }
            }
        }
    }

    private func moveWing(from source: IndexSet, to destination: Int) {
        var updatedWings = wings.map { $0 }
        updatedWings.move(fromOffsets: source, toOffset: destination)

        // Mettre à jour displayOrder pour toutes les voiles affectées
        for (index, wing) in updatedWings.enumerated() {
            wing.displayOrder = index
        }

        // Sauvegarder le contexte
        do {
            try modelContext.save()
            print("✅ Wings reordered successfully")

            // Synchroniser avec Apple Watch
            watchManager.syncWingsToWatch(wings: Array(updatedWings))
        } catch {
            print("❌ Error saving wing order: \(error)")
        }
    }
}

struct WingRow: View {
    let wing: Wing
    @Environment(DataController.self) private var dataController

    var body: some View {
        HStack(spacing: 12) {
            // Photo de la voile ou icône par défaut
            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "wind")
                            .font(.title2)
                            .foregroundStyle(colorFromString(wing.color ?? "Gris"))
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(wing.name)
                    .font(.headline)

                HStack(spacing: 12) {
                    if let size = wing.size {
                        Text("\(size) m²")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let type = wing.type {
                        Text(type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Stats de cette voile
                let stats = dataController.totalHoursByWing()
                if let hours = stats[wing.id] {
                    Text("\(dataController.formatHours(hours)) de vol")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge": return .red
        case "bleu": return .blue
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        default: return .gray
        }
    }
}

// MARK: - AddWingView (Formulaire d'ajout avec photo)

struct AddWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    @State private var name: String = ""
    @State private var size: String = ""
    @State private var type: String = "Soaring"
    @State private var color: String = "Bleu"
    @State private var customColor: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showingLibraryPicker = false
    @State private var isLoadingImage = false

    let types = ["Soaring", "Cross", "Thermique", "Speedflying", "Acro"]
    let colors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir", "Pétrole", "Autre..."]

    var body: some View {
        NavigationStack {
            Form {
                // Section bibliothèque
                Section {
                    Button {
                        showingLibraryPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "books.vertical")
                                .foregroundStyle(.blue)
                            Text("Choisir depuis la bibliothèque")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Bibliothèque")
                } footer: {
                    Text("Sélectionnez une voile préenregistrée pour remplir automatiquement les informations.")
                }

                Section("Photo") {
                    HStack {
                        Spacer()
                        if isLoadingImage {
                            ProgressView()
                                .frame(width: 120, height: 120)
                        } else if let photoData = photoData, let uiImage = UIImage(data: photoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 120, height: 120)
                                .overlay {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.gray)
                                }
                        }
                        Spacer()
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Choisir une photo", systemImage: "photo.on.rectangle.angled")
                    }
                }

                Section("Informations") {
                    TextField("Nom", text: $name)
                    HStack {
                        TextField("Taille", text: $size)
                            .keyboardType(.decimalPad)
                            .onChange(of: size) { _, newValue in
                                // Filtrer pour ne garder que les chiffres et le point/virgule
                                let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                                if filtered != newValue {
                                    size = filtered
                                }
                            }
                        Text("m²")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Caractéristiques") {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }

                    Picker("Couleur", selection: $color) {
                        ForEach(colors, id: \.self) { color in
                            Text(color).tag(color)
                        }
                    }

                    if color == "Autre..." {
                        TextField("Couleur personnalisée", text: $customColor)
                    }
                }
            }
            .navigationTitle("Nouvelle voile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        addWing()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onChange(of: selectedPhoto) { _, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        photoData = data
                    }
                }
            }
            .sheet(isPresented: $showingLibraryPicker) {
                WingLibraryPickerView { selectedWing, selectedSize in
                    applyLibraryWing(selectedWing, size: selectedSize)
                    showingLibraryPicker = false
                }
            }
        }
    }

    private func applyLibraryWing(_ libraryWing: WingLibraryItem, size selectedSize: String?) {
        // Remplir les champs avec les données de la bibliothèque
        name = libraryWing.fullName
        if let selectedSize = selectedSize {
            size = selectedSize
        }
        type = libraryWing.type
        if let wingColor = libraryWing.color {
            if colors.contains(wingColor) {
                color = wingColor
            } else {
                color = "Autre..."
                customColor = wingColor
            }
        }

        // Télécharger l'image si disponible
        if libraryWing.imageURL != nil {
            isLoadingImage = true
            Task {
                if let imageData = await WingLibraryManager.shared.downloadImage(for: libraryWing) {
                    await MainActor.run {
                        photoData = imageData
                        isLoadingImage = false
                    }
                } else {
                    await MainActor.run {
                        isLoadingImage = false
                    }
                }
            }
        }
    }

    private func addWing() {
        // Récupérer le displayOrder max actuel pour ajouter la nouvelle voile à la fin
        let descriptor = FetchDescriptor<Wing>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\Wing.displayOrder, order: .reverse)]
        )
        let maxDisplayOrder = (try? modelContext.fetch(descriptor).first?.displayOrder) ?? -1

        // Utiliser la couleur personnalisée si "Autre..." est sélectionné
        let finalColor = color == "Autre..." ? customColor : color

        let wing = Wing(
            name: name,
            size: size.isEmpty ? nil : size,
            type: type,
            color: finalColor.isEmpty ? nil : finalColor,
            photoData: photoData,
            displayOrder: maxDisplayOrder + 1
        )

        modelContext.insert(wing)

        Task { @MainActor in
            try? modelContext.save()
            watchManager.sendWingsToWatch()
        }

        dismiss()
    }
}

// MARK: - EditWingView (Modifier une voile)

struct EditWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    let wing: Wing

    @State private var name: String
    @State private var size: String
    @State private var type: String
    @State private var color: String
    @State private var customColor: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?

    let types = ["Soaring", "Cross", "Thermique", "Speedflying", "Acro"]
    let colors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir", "Pétrole", "Autre..."]

    init(wing: Wing) {
        self.wing = wing
        _name = State(initialValue: wing.name)
        _size = State(initialValue: wing.size ?? "")
        _type = State(initialValue: wing.type ?? "Soaring")
        // Si la couleur actuelle n'est pas dans la liste, utiliser "Autre..."
        let existingColor = wing.color ?? "Bleu"
        let standardColors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir", "Pétrole"]
        if standardColors.contains(existingColor) {
            _color = State(initialValue: existingColor)
            _customColor = State(initialValue: "")
        } else {
            _color = State(initialValue: "Autre...")
            _customColor = State(initialValue: existingColor)
        }
        _photoData = State(initialValue: wing.photoData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    HStack {
                        Spacer()
                        if let photoData = photoData, let uiImage = UIImage(data: photoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 120, height: 120)
                                .overlay {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.gray)
                                }
                        }
                        Spacer()
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Changer la photo", systemImage: "photo.on.rectangle.angled")
                    }

                    if photoData != nil {
                        Button(role: .destructive) {
                            photoData = nil
                        } label: {
                            Label("Supprimer la photo", systemImage: "trash")
                        }
                    }
                }

                Section("Informations") {
                    TextField("Nom", text: $name)
                    HStack {
                        TextField("Taille", text: $size)
                            .keyboardType(.decimalPad)
                            .onChange(of: size) { _, newValue in
                                // Filtrer pour ne garder que les chiffres et le point/virgule
                                let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                                if filtered != newValue {
                                    size = filtered
                                }
                            }
                        Text("m²")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Caractéristiques") {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }

                    Picker("Couleur", selection: $color) {
                        ForEach(colors, id: \.self) { color in
                            Text(color).tag(color)
                        }
                    }

                    if color == "Autre..." {
                        TextField("Couleur personnalisée", text: $customColor)
                    }
                }
            }
            .navigationTitle("Modifier la voile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saveWing()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onChange(of: selectedPhoto) { _, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        photoData = data
                    }
                }
            }
        }
    }

    private func saveWing() {
        // Utiliser la couleur personnalisée si "Autre..." est sélectionné
        let finalColor = color == "Autre..." ? customColor : color

        wing.name = name
        wing.size = size.isEmpty ? nil : size
        wing.type = type
        wing.color = finalColor.isEmpty ? nil : finalColor
        wing.photoData = photoData

        Task { @MainActor in
            try? modelContext.save()
            watchManager.sendWingsToWatch()
        }

        dismiss()
    }
}

// MARK: - WingDetailView (Détail d'une voile)

struct WingDetailView: View {
    let wing: Wing
    @Environment(\.dismiss) private var dismiss
    @Environment(DataController.self) private var dataController
    @Query private var allFlights: [Flight]
    @State private var showingEditWing = false
    @State private var selectedFlight: Flight?
    @State private var showingFullScreenPhoto = false

    var flights: [Flight] {
        allFlights.filter { $0.wing?.id == wing.id }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    // Photo de la voile (tappable pour afficher en plein écran)
                    if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture {
                                showingFullScreenPhoto = true
                            }
                    } else {
                        // Placeholder quand pas de photo
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 150)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.gray.opacity(0.5))
                            }
                    }

                    VStack(spacing: 8) {
                        Text(wing.name)
                            .font(.title)
                            .fontWeight(.bold)

                        HStack(spacing: 20) {
                            if let size = wing.size {
                                Label("\(size) m²", systemImage: "ruler")
                                    .font(.subheadline)
                            }

                            if let type = wing.type {
                                Label(type, systemImage: "tag")
                                    .font(.subheadline)
                            }

                            if let color = wing.color {
                                Label(color, systemImage: "paintpalette")
                                    .font(.subheadline)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 16)
            }

            Section("Statistiques") {
                let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
                let totalHours = Double(totalSeconds) / 3600.0
                HStack {
                    Text("Heures de vol")
                    Spacer()
                    Text(dataController.formatHours(totalHours))
                        .foregroundStyle(.blue)
                }

                HStack {
                    Text("Nombre de vols")
                    Spacer()
                    Text("\(flights.count)")
                        .foregroundStyle(.blue)
                }
            }

            if !flights.isEmpty {
                Section("Historique des vols") {
                    ForEach(flights.sorted { $0.startDate > $1.startDate }) { flight in
                        FlightRow(flight: flight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedFlight = flight
                            }
                    }
                }
            }
        }
        .navigationTitle("Détails")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingEditWing = true
                } label: {
                    Label("Modifier", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showingEditWing) {
            EditWingView(wing: wing)
        }
        .sheet(item: $selectedFlight) { flight in
            EditFlightView(flight: flight)
                .onAppear {
                    // Vérifier immédiatement si le vol a été supprimé
                    if flight.isDeleted {
                        selectedFlight = nil
                    }
                }
        }
        .onChange(of: allFlights.count) { oldValue, newValue in
            // Si un vol est supprimé, fermer immédiatement la sheet
            if let selected = selectedFlight {
                if selected.isDeleted || !allFlights.contains(where: { $0.id == selected.id }) {
                    selectedFlight = nil
                }
            }
        }
        .fullScreenCover(isPresented: $showingFullScreenPhoto) {
            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                FullScreenPhotoView(image: uiImage, wingName: wing.name)
            }
        }
    }
}

// MARK: - FullScreenPhotoView

struct FullScreenPhotoView: View {
    let image: UIImage
    let wingName: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = lastScale * value
                        }
                        .onEnded { _ in
                            lastScale = scale
                            // Limiter le zoom entre 1x et 4x
                            if scale < 1.0 {
                                withAnimation {
                                    scale = 1.0
                                    lastScale = 1.0
                                }
                            } else if scale > 4.0 {
                                withAnimation {
                                    scale = 4.0
                                    lastScale = 4.0
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    // Double-tap pour réinitialiser le zoom
                    withAnimation {
                        scale = 1.0
                        lastScale = 1.0
                    }
                }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .background(Circle().fill(Color.black.opacity(0.5)).padding(-8))
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}

// MARK: - StatsView (Statistiques améliorées)

struct StatsView: View {
    @Environment(DataController.self) private var dataController
    @Query private var flights: [Flight]
    @Query(filter: #Predicate<Wing> { !$0.isArchived }) private var wings: [Wing]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Carte totale
                    TotalStatsCard(flights: flights)

                    // Tableau et graphique par voile
                    StatsByWingSection(flights: flights, wings: wings)

                    // Tableau et graphique par spot
                    StatsBySpotSection(flights: flights)
                }
                .padding()
            }
            .navigationTitle("Statistiques")
            .background(Color(.systemGroupedBackground))
        }
    }
}

// MARK: - TotalStatsCard

struct TotalStatsCard: View {
    let flights: [Flight]

    var body: some View {
        VStack(spacing: 16) {
            Text("Total")
                .font(.title2)
                .fontWeight(.bold)

            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60

            HStack(spacing: 40) {
                VStack(spacing: 4) {
                    Text("\(flights.count)")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.blue)
                    Text("session\(flights.count > 1 ? "s" : "")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(hours)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.green)
                        Text("h")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("\(minutes)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.green)
                        Text("min")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("temps de vol")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

// MARK: - StatsByWingSection

struct StatsByWingSection: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    let wings: [Wing]
    @State private var selectedWing: Wing?

    var wingStats: [(wing: Wing, sessions: Int, hours: Int, minutes: Int)] {
        wings.compactMap { wing in
            let wingFlights = flights.filter { $0.wing?.id == wing.id }
            guard !wingFlights.isEmpty else { return nil }

            let totalSeconds = wingFlights.reduce(0) { $0 + $1.durationSeconds }
            return (
                wing: wing,
                sessions: wingFlights.count,
                hours: totalSeconds / 3600,
                minutes: (totalSeconds % 3600) / 60
            )
        }
        .sorted { $0.hours * 60 + $0.minutes > $1.hours * 60 + $1.minutes }
    }

    /// Abrège un nom de voile en supprimant les mots de marques
    private func abbreviateWingName(_ name: String) -> String {
        // Supprimer les marques connues (pas de remplacement, juste suppression)
        var abbreviated = name
        abbreviated = abbreviated.replacingOccurrences(of: "Moustache ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Skyman ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Advance ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Ozone ", with: "", options: .caseInsensitive)
        abbreviated = abbreviated.replacingOccurrences(of: "Nova ", with: "", options: .caseInsensitive)

        return abbreviated.trimmingCharacters(in: .whitespaces)
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "bleu": return .blue
        case "rouge": return .red
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        case "gris": return .gray
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Par voile")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if wingStats.isEmpty {
                Text("Aucune donnée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                // Tableau
                VStack(spacing: 0) {
                    // En-tête
                    HStack {
                        Text("Voile")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Sessions")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("Temps")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    // Lignes
                    ForEach(wingStats, id: \.wing.id) { stat in
                        Button {
                            selectedWing = stat.wing
                        } label: {
                            HStack(spacing: 8) {
                                // Photo de la voile (24x24)
                                if let photoData = stat.wing.photoData, let uiImage = UIImage(data: photoData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 24, height: 24)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                } else {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(colorFromString(stat.wing.color ?? "Gris").opacity(0.3))
                                        .frame(width: 24, height: 24)
                                        .overlay {
                                            Image(systemName: "wind")
                                                .font(.system(size: 10))
                                                .foregroundStyle(colorFromString(stat.wing.color ?? "Gris"))
                                        }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(abbreviateWingName(stat.wing.name))
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let size = stat.wing.size {
                                        Text("\(size) m²")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(stat.sessions)")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                                    .frame(width: 70, alignment: .trailing)

                                Text("\(stat.hours)h \(String(format: "%02d", stat.minutes))m")
                                    .font(.body)
                                    .foregroundStyle(.green)
                                    .frame(width: 80, alignment: .trailing)

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }

                        if stat.wing.id != wingStats.last?.wing.id {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)

                // Graphique
                if #available(iOS 16.0, *) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Répartition des heures")
                            .font(.headline)
                            .padding(.horizontal)

                        Chart {
                            ForEach(wingStats, id: \.wing.id) { stat in
                                let hours = Double(stat.hours * 60 + stat.minutes) / 60.0
                                let maxMinutes = (wingStats.first?.hours ?? 1) * 60 + (wingStats.first?.minutes ?? 0)
                                let maxHours = Double(maxMinutes) / 60.0
                                let scaledHours = (hours / maxHours) * 0.85 * maxHours

                                let wingLabel = stat.wing.size != nil
                                    ? "\(abbreviateWingName(stat.wing.name)) (\(stat.wing.size!) m²)"
                                    : abbreviateWingName(stat.wing.name)

                                BarMark(
                                    x: .value("Heures", scaledHours),
                                    y: .value("Voile", wingLabel)
                                )
                                .foregroundStyle(.blue.gradient)
                                .annotation(position: .trailing, alignment: .leading) {
                                    let timeText = stat.hours > 0 ? "\(stat.hours)h\(String(format: "%02d", stat.minutes))" : "\(stat.minutes)min"
                                    Text(timeText)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(height: CGFloat(max(150, wingStats.count * 40)))
                        .chartXAxis {
                            AxisMarks(position: .bottom)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                    }
                }
            }
        }
        .sheet(item: $selectedWing) { wing in
            WingFlightsDetailView(wing: wing, flights: flights)
        }
    }
}

// MARK: - StatsBySpotSection

struct StatsBySpotSection: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    @State private var selectedSpot: String?

    var spotStats: [(spot: String, sessions: Int, hours: Int, minutes: Int)] {
        let grouped = Dictionary(grouping: flights, by: { $0.spotName ?? "Spot inconnu" })

        return grouped.map { spot, spotFlights in
            let totalSeconds = spotFlights.reduce(0) { $0 + $1.durationSeconds }
            return (
                spot: spot,
                sessions: spotFlights.count,
                hours: totalSeconds / 3600,
                minutes: (totalSeconds % 3600) / 60
            )
        }
        .sorted { $0.hours * 60 + $0.minutes > $1.hours * 60 + $1.minutes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Par spot")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if spotStats.isEmpty {
                Text("Aucune donnée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                // Tableau
                VStack(spacing: 0) {
                    // En-tête
                    HStack {
                        Text("Spot")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Sessions")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("Temps")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    // Lignes
                    ForEach(spotStats, id: \.spot) { stat in
                        Button {
                            selectedSpot = stat.spot
                        } label: {
                            HStack {
                                Text(stat.spot)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(stat.sessions)")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                                    .frame(width: 70, alignment: .trailing)

                                Text("\(stat.hours)h \(String(format: "%02d", stat.minutes))m")
                                    .font(.body)
                                    .foregroundStyle(.green)
                                    .frame(width: 80, alignment: .trailing)

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }

                        if stat.spot != spotStats.last?.spot {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)

                // Graphique
                if #available(iOS 16.0, *) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Répartition des heures")
                            .font(.headline)
                            .padding(.horizontal)

                        Chart {
                            ForEach(spotStats, id: \.spot) { stat in
                                BarMark(
                                    x: .value("Heures", Double(stat.hours * 60 + stat.minutes) / 60.0),
                                    y: .value("Spot", stat.spot)
                                )
                                .foregroundStyle(.green.gradient)
                                .annotation(position: .trailing, alignment: .leading) {
                                    Text(stat.hours > 0 ? "\(stat.hours)h\(String(format: "%02d", stat.minutes))" : "\(stat.minutes)min")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(height: CGFloat(max(200, spotStats.count * 50)))
                        .chartXAxis {
                            AxisMarks(position: .bottom)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedSpot != nil },
            set: { if !$0 { selectedSpot = nil } }
        )) {
            if let spot = selectedSpot {
                SpotFlightsDetailView(spotName: spot, flights: flights)
            }
        }
    }
}

// MARK: - WingFlightsDetailView (Détail des vols par voile)

struct WingFlightsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let wing: Wing
    let flights: [Flight]

    // Calculer les vols filtrés immédiatement lors de l'init
    private let wingFlights: [Flight]

    init(wing: Wing, flights: [Flight]) {
        self.wing = wing
        self.flights = flights
        // Pré-calculer les vols de cette voile
        self.wingFlights = flights
            .filter { $0.wing?.id == wing.id }
            .sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(wingFlights) { flight in
                        FlightRow(flight: flight)
                    }
                }
            }
            .navigationTitle(wing.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - SpotFlightsDetailView (Détail des vols par spot)

struct SpotFlightsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let spotName: String
    let flights: [Flight]

    // Calculer les vols filtrés immédiatement lors de l'init
    private let spotFlights: [Flight]

    init(spotName: String, flights: [Flight]) {
        self.spotName = spotName
        self.flights = flights
        // Pré-calculer les vols de ce spot
        self.spotFlights = flights
            .filter { $0.spotName == spotName }
            .sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(spotFlights) { flight in
                        FlightRow(flight: flight)
                    }
                }
            }
            .navigationTitle(spotName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - TimerView (Chrono redesigné)

struct TimerView: View {
    @Environment(DataController.self) private var dataController
    @Environment(LocationService.self) private var locationService
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    @State private var selectedWing: Wing?
    @State private var isFlying = false
    @State private var startDate: Date?
    @State private var elapsedSeconds: Int = 0
    @State private var backgroundTask: Timer?
    @State private var currentSpot: String = "Recherche..."
    @State private var manualSpotOverride: String? = nil
    @State private var showingManualSpot = false
    @State private var showingWingPicker = false
    @State private var showingFlightSummary = false
    @State private var completedFlight: Flight?

    var body: some View {
        NavigationStack {
            ZStack {
                // Fond dégradé
                LinearGradient(
                    colors: isFlying ? [.green.opacity(0.2), .blue.opacity(0.2)] : [.gray.opacity(0.1), .gray.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 24) {
                    // Sélection de la voile (design compact)
                    if !isFlying {
                        VStack(spacing: 12) {
                            Text("Voile")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(1)

                            if wings.isEmpty {
                                Text("Ajoutez d'abord une voile dans l'onglet Voiles")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding()
                            } else {
                                Button {
                                    showingWingPicker = true
                                } label: {
                                    HStack(spacing: 12) {
                                        if let wing = selectedWing {
                                            // Photo miniature
                                            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                                Image(uiImage: uiImage)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 50, height: 50)
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                            } else {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                                                    .frame(width: 50, height: 50)
                                                    .overlay {
                                                        Image(systemName: "wind")
                                                            .foregroundStyle(colorFromString(wing.color ?? "Gris"))
                                                    }
                                            }

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(wing.name)
                                                    .font(.headline)
                                                    .foregroundStyle(.primary)
                                                if let size = wing.size {
                                                    Text("\(size) m²")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }

                                            Spacer()

                                            Image(systemName: "chevron.down")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        } else {
                                            Image(systemName: "wind")
                                                .font(.title2)
                                                .foregroundStyle(.blue)

                                            Text("Sélectionner une voile")
                                                .font(.body)
                                                .foregroundStyle(.blue)

                                            Spacer()

                                            Image(systemName: "chevron.down")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding()
                                    .background(
                                        LinearGradient(
                                            colors: selectedWing == nil ? [.blue.opacity(0.1), .blue.opacity(0.05)] : [Color(.systemBackground)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedWing == nil ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 2)
                                    )
                                    .cornerRadius(12)
                                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                                }
                                .padding(.horizontal)
                            }
                        }
                    } else {
                        // Afficher la voile sélectionnée pendant le vol
                        if let wing = selectedWing {
                            VStack(spacing: 8) {
                                if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(.blue.opacity(0.2))
                                        .frame(width: 80, height: 80)
                                        .overlay {
                                            Image(systemName: "wind")
                                                .font(.largeTitle)
                                                .foregroundStyle(.blue)
                                        }
                                }

                                Text(wing.name)
                                    .font(.title2)
                                    .fontWeight(.bold)

                                if let size = wing.size {
                                    Text("\(size) m²")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Spot actuel
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "location.fill")
                                .foregroundStyle(manualSpotOverride != nil ? .blue : .green)
                            Text(manualSpotOverride ?? currentSpot)
                                .font(.headline)
                        }

                        Button {
                            showingManualSpot = true
                        } label: {
                            Text(manualSpotOverride != nil ? "Changer le spot" : "Définir le spot manuellement")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding(.horizontal)

                    Spacer()

                    // Chrono
                    VStack(spacing: 8) {
                        Text("TEMPS DE VOL")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .tracking(2)

                        Text(formatElapsedTime(elapsedSeconds))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isFlying ? .green : .primary)
                    }

                    Spacer()

                    // Bouton Start/Stop (redesigné)
                    Button {
                        if isFlying {
                            stopFlight()
                        } else {
                            startFlight()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isFlying ? "stop.fill" : "play.fill")
                                .font(.title2)
                            Text(isFlying ? "ARRÊTER LE VOL" : "DÉMARRER LE VOL")
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(isFlying ? Color.red : Color.green)
                        .foregroundStyle(.white)
                        .cornerRadius(16)
                        .shadow(color: (isFlying ? Color.red : Color.green).opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    .disabled(!isFlying && selectedWing == nil)
                    .opacity((!isFlying && selectedWing == nil) ? 0.5 : 1.0)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Chrono")
            .sheet(isPresented: $showingManualSpot) {
                ManualSpotEditView(manualSpot: $manualSpotOverride)
            }
            .sheet(isPresented: $showingWingPicker) {
                WingPickerSheet(wings: wings, selectedWing: $selectedWing)
            }
            .sheet(isPresented: $showingFlightSummary) {
                if let flight = completedFlight {
                    FlightSummaryView(flight: flight)
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Gérer le timer en arrière-plan
            if isFlying {
                if newPhase == .background || newPhase == .inactive {
                    // Continuer le timer en background
                } else if newPhase == .active, let start = startDate {
                    // Recalculer le temps écoulé quand on revient au premier plan
                    elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        }
        .onAppear {
            if !isFlying && manualSpotOverride == nil {
                updateCurrentSpot()
            }
            // Démarrer le timer de mise à jour si un vol est en cours
            if isFlying, let start = startDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
                startBackgroundTimer()
            }
        }
    }

    private func startBackgroundTimer() {
        backgroundTask?.invalidate()
        backgroundTask = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = startDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func startFlight() {
        guard selectedWing != nil else { return }

        // Démarrer le timer IMMÉDIATEMENT pour une réponse instantanée
        startDate = Date()
        elapsedSeconds = 0
        isFlying = true
        startBackgroundTimer()

        // Démarrer la localisation en arrière-plan pour ne pas bloquer l'UI
        Task {
            locationService.startUpdatingLocation()

            // Ne mettre à jour le spot que si aucun spot manuel n'est défini
            if manualSpotOverride == nil {
                updateCurrentSpot()
            }
        }
    }

    private func stopFlight() {
        guard let wing = selectedWing, let start = startDate else { return }

        let end = Date()
        let duration = Int(end.timeIntervalSince(start))

        backgroundTask?.invalidate()
        backgroundTask = nil

        locationService.stopUpdatingLocation()

        // Utiliser le spot manuel en priorité, sinon le spot automatique
        let finalSpot: String?
        if let manual = manualSpotOverride {
            finalSpot = manual
        } else if currentSpot != "Recherche..." && currentSpot != "Position indisponible" {
            finalSpot = currentSpot
        } else {
            finalSpot = nil
        }

        locationService.requestLocation { [self] location in
            DispatchQueue.main.async {
                let flight = Flight(
                    wing: wing,
                    startDate: start,
                    endDate: end,
                    durationSeconds: duration,
                    spotName: finalSpot,
                    latitude: location?.coordinate.latitude,
                    longitude: location?.coordinate.longitude
                )

                dataController.modelContext.insert(flight)
                try? dataController.modelContext.save()

                // Afficher le récapitulatif
                completedFlight = flight
                showingFlightSummary = true
            }
        }

        isFlying = false
        elapsedSeconds = 0
        startDate = nil
        selectedWing = nil
        currentSpot = "Recherche..."
        manualSpotOverride = nil
    }

    private func updateCurrentSpot() {
        locationService.requestLocation { location in
            guard let location = location else {
                DispatchQueue.main.async {
                    currentSpot = "Position indisponible"
                }
                return
            }

            locationService.reverseGeocode(location: location) { spot in
                DispatchQueue.main.async {
                    currentSpot = spot ?? "Spot inconnu"
                }
            }
        }
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge": return .red
        case "bleu": return .blue
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        default: return .gray
        }
    }

    private func formatElapsedTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}

// MARK: - WingPickerSheet (Sélection de voile en sheet)

struct WingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let wings: [Wing]
    @Binding var selectedWing: Wing?

    var body: some View {
        NavigationStack {
            List {
                ForEach(wings) { wing in
                    Button {
                        selectedWing = wing
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            // Photo de la voile
                            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                                    .frame(width: 50, height: 50)
                                    .overlay {
                                        Image(systemName: "wind")
                                            .foregroundStyle(colorFromString(wing.color ?? "Gris"))
                                    }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(wing.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 8) {
                                    if let size = wing.size {
                                        Text("\(size) m²")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let type = wing.type {
                                        Text(type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            if selectedWing?.id == wing.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Choisir une voile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge": return .red
        case "bleu": return .blue
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        default: return .gray
        }
    }
}

// MARK: - ManualSpotEditView (Saisie manuelle du spot)

struct ManualSpotEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var manualSpot: String?
    @State private var tempSpot: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du spot", text: $tempSpot)
                } header: {
                    Text("Définir le spot manuellement")
                } footer: {
                    Text("Ce spot sera utilisé en priorité sur la détection GPS automatique")
                }

                if manualSpot != nil {
                    Section {
                        Button(role: .destructive) {
                            manualSpot = nil
                            dismiss()
                        } label: {
                            Label("Supprimer et utiliser le GPS", systemImage: "location.fill")
                        }
                    }
                }
            }
            .navigationTitle("Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        if !tempSpot.isEmpty {
                            manualSpot = tempSpot
                        }
                        dismiss()
                    }
                    .disabled(tempSpot.isEmpty)
                }
            }
            .onAppear {
                tempSpot = manualSpot ?? ""
            }
        }
    }
}

// MARK: - FlightSummaryView (Récapitulatif de vol)

struct FlightSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let flight: Flight

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Icône de succès
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)
                    .padding(.top, 40)

                Text("Vol terminé !")
                    .font(.title)
                    .fontWeight(.bold)

                // Résumé du vol
                VStack(spacing: 16) {
                    // Durée
                    HStack {
                        Image(systemName: "timer")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 30)

                        Text("Durée")
                            .font(.headline)

                        Spacer()

                        Text(flight.durationFormatted)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Voile
                    if let wingName = flight.wing?.name {
                        HStack {
                            Image(systemName: "wind")
                                .font(.title3)
                                .foregroundStyle(.purple)
                                .frame(width: 30)

                            Text("Voile")
                                .font(.headline)

                            Spacer()

                            Text(wingName)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Spot
                    if let spot = flight.spotName {
                        HStack {
                            Image(systemName: "location.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                                .frame(width: 30)

                            Text("Spot")
                                .font(.headline)

                            Spacer()

                            Text(spot)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Statistiques de vol
                    if flight.maxAltitude != nil || flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
                        VStack(spacing: 12) {
                            if let maxAlt = flight.maxAltitude {
                                HStack {
                                    Image(systemName: "arrow.up")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                        .frame(width: 30)

                                    Text("Altitude max")
                                        .font(.headline)

                                    Spacer()

                                    Text("\(Int(maxAlt)) m")
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                }
                            }

                            if let distance = flight.totalDistance {
                                HStack {
                                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                        .font(.title3)
                                        .foregroundStyle(.cyan)
                                        .frame(width: 30)

                                    Text("Distance")
                                        .font(.headline)

                                    Spacer()

                                    Text(formatDistance(distance))
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.cyan)
                                }
                            }

                            if let speed = flight.maxSpeed {
                                HStack {
                                    Image(systemName: "speedometer")
                                        .font(.title3)
                                        .foregroundStyle(.purple)
                                        .frame(width: 30)

                                    Text("Vitesse max")
                                        .font(.headline)

                                    Spacer()

                                    Text("\(Int(speed * 3.6)) km/h")
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.purple)
                                }
                            }

                            if let gForce = flight.maxGForce {
                                HStack {
                                    Image(systemName: "waveform.path.ecg")
                                        .font(.title3)
                                        .foregroundStyle(.green)
                                        .frame(width: 30)

                                    Text("G-Force max")
                                        .font(.headline)

                                    Spacer()

                                    Text(String(format: "%.1f G", gForce))
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Date et heure
                    HStack {
                        Image(systemName: "calendar")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 30)

                        Text("Date")
                            .font(.headline)

                        Spacer()

                        Text(flight.dateFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Terminer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .navigationTitle("Récapitulatif")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
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

// MARK: - ArchivedWingsView (Liste des voiles archivées)

struct ArchivedWingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Wing> { $0.isArchived }, sort: \Wing.createdAt, order: .reverse) private var archivedWings: [Wing]
    @State private var selectedWing: Wing?
    @State private var showingDeleteAlert = false
    @State private var wingToDelete: Wing?

    var body: some View {
        List {
            if archivedWings.isEmpty {
                ContentUnavailableView(
                    "Aucune voile archivée",
                    systemImage: "archivebox",
                    description: Text("Les voiles archivées apparaîtront ici")
                )
            } else {
                ForEach(archivedWings) { wing in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            // Photo de la voile ou icône par défaut
                            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                                    .frame(width: 50, height: 50)
                                    .overlay {
                                        Image(systemName: "wind")
                                            .foregroundStyle(colorFromString(wing.color ?? "Gris"))
                                    }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(wing.name)
                                    .font(.headline)

                                HStack(spacing: 12) {
                                    if let size = wing.size {
                                        Text("\(size) m²")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let type = wing.type {
                                        Text(type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                // Nombre de vols
                                let flightCount = wing.flights?.count ?? 0
                                if flightCount > 0 {
                                    Text("\(flightCount) vol\(flightCount > 1 ? "s" : "")")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }

                        // Boutons d'action
                        HStack(spacing: 12) {
                            Button {
                                dataController.unarchiveWing(wing)
                            } label: {
                                Label("Restaurer", systemImage: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                wingToDelete = wing
                                showingDeleteAlert = true
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Voiles archivées")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Supprimer définitivement ?", isPresented: $showingDeleteAlert) {
            Button("Annuler", role: .cancel) { }
            Button("Supprimer", role: .destructive) {
                if let wing = wingToDelete {
                    dataController.permanentlyDeleteWing(wing)
                }
            }
        } message: {
            if let wing = wingToDelete {
                let flightCount = wing.flights?.count ?? 0
                Text("⚠️ Cette action est irréversible ! La voile \"\(wing.name)\" et ses \(flightCount) vol\(flightCount > 1 ? "s" : "") seront définitivement supprimés.")
            }
        }
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge": return .red
        case "bleu": return .blue
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        default: return .gray
        }
    }
}

// MARK: - SpotsManagementView (Gestion des spots)

/// Vue pour gérer les spots détectés dans les vols
struct SpotsManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]
    
    @State private var selectedSpot: SpotInfo?
    @State private var showingMapPicker = false
    
    /// Structure pour regrouper les infos d'un spot
    struct SpotInfo: Identifiable, Hashable {
        let id = UUID()
        let name: String
        var latitude: Double?
        var longitude: Double?
        var flightCount: Int
        
        var hasCoordinates: Bool {
            latitude != nil && longitude != nil
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
        }
        
        static func == (lhs: SpotInfo, rhs: SpotInfo) -> Bool {
            lhs.name == rhs.name
        }
    }
    
    /// Extraire tous les spots uniques des vols
    var spots: [SpotInfo] {
        var spotDict: [String: SpotInfo] = [:]
        
        for flight in flights {
            guard let spotName = flight.spotName, !spotName.isEmpty else { continue }
            
            if var existing = spotDict[spotName] {
                existing.flightCount += 1
                // Mettre à jour les coordonnées si ce vol en a
                if existing.latitude == nil, let lat = flight.latitude, let lon = flight.longitude {
                    existing.latitude = lat
                    existing.longitude = lon
                }
                spotDict[spotName] = existing
            } else {
                spotDict[spotName] = SpotInfo(
                    name: spotName,
                    latitude: flight.latitude,
                    longitude: flight.longitude,
                    flightCount: 1
                )
            }
        }
        
        return spotDict.values.sorted { $0.flightCount > $1.flightCount }
    }
    
    var body: some View {
        List {
            if spots.isEmpty {
                ContentUnavailableView(
                    "Aucun spot",
                    systemImage: "mappin.slash",
                    description: Text("Les spots apparaîtront ici une fois que vous aurez enregistré des vols")
                )
            } else {
                Section {
                    ForEach(spots) { spot in
                        SpotRowView(spot: spot) {
                            selectedSpot = spot
                            showingMapPicker = true
                        }
                    }
                } header: {
                    Text(spotsCountText(spots.count))
                } footer: {
                    Text(String(localized: "Ajoutez des coordonnées GPS à un spot pour les appliquer automatiquement à tous les vols associés"))
                }
            }
        }
        .navigationTitle("Spots")
        .sheet(isPresented: $showingMapPicker) {
            if let spot = selectedSpot {
                SpotMapPicker(spot: spot) { coordinate in
                    updateSpotCoordinates(spotName: spot.name, coordinate: coordinate)
                }
            }
        }
    }
    
    /// Met à jour les coordonnées de tous les vols avec ce nom de spot
    private func updateSpotCoordinates(spotName: String, coordinate: CLLocationCoordinate2D) {
        var updatedCount = 0
        
        for flight in flights {
            if flight.spotName == spotName {
                flight.latitude = coordinate.latitude
                flight.longitude = coordinate.longitude
                updatedCount += 1
            }
        }
        
        Task { @MainActor in
            try? modelContext.save()
            print("✅ Updated \(updatedCount) flights with coordinates for spot: \(spotName)")
        }
    }

    /// Retourne le texte avec pluralisation correcte pour le nombre de spots
    private func spotsCountText(_ count: Int) -> String {
        if count <= 1 {
            return String(localized: "\(count) spot détecté")
        } else {
            return String(localized: "\(count) spots détectés")
        }
    }
}

/// Row pour afficher un spot
struct SpotRowView: View {
    let spot: SpotsManagementView.SpotInfo
    let onMapTap: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Icône
            ZStack {
                Circle()
                    .fill(spot.hasCoordinates ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: spot.hasCoordinates ? "mappin.circle.fill" : "mappin.slash")
                    .font(.title3)
                    .foregroundStyle(spot.hasCoordinates ? .green : .orange)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(spot.name)
                    .font(.headline)
                
                HStack(spacing: 8) {
                    Label(flightsCountText(spot.flightCount), systemImage: "airplane")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if spot.hasCoordinates {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text("GPS ✓")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            
            Spacer()
            
            // Bouton pour ajouter/modifier les coordonnées
            Button {
                onMapTap()
            } label: {
                Image(systemName: spot.hasCoordinates ? "map" : "map.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

/// Retourne le texte avec pluralisation correcte pour le nombre de vols
private func flightsCountText(_ count: Int) -> String {
    if count <= 1 {
        return String(localized: "\(count) vol")
    } else {
        return String(localized: "\(count) vols")
    }
}

/// Retourne le texte avec pluralisation correcte pour le message de mise à jour des vols
private func flightsWillBeUpdatedText(_ count: Int) -> String {
    if count <= 1 {
        return String(localized: "📍 \(count) vol sera mis à jour")
    } else {
        return String(localized: "📍 \(count) vols seront mis à jour")
    }
}

/// Picker de carte pour un spot
struct SpotMapPicker: View {
    @Environment(\.dismiss) private var dismiss
    let spot: SpotsManagementView.SpotInfo
    let onSave: (CLLocationCoordinate2D) -> Void
    
    @State private var cameraPosition: MapCameraPosition
    @State private var markerCoordinate: CLLocationCoordinate2D?
    @State private var searchText: String = ""
    @State private var isSearching = false
    
    init(spot: SpotsManagementView.SpotInfo, onSave: @escaping (CLLocationCoordinate2D) -> Void) {
        self.spot = spot
        self.onSave = onSave
        
        // Position initiale
        if let lat = spot.latitude, let lon = spot.longitude {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
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
        _searchText = State(initialValue: spot.name)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        if let coord = markerCoordinate {
                            Marker(spot.name, coordinate: coord)
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
                        
                        // Info sur le nombre de vols qui seront mis à jour
                        Text(flightsWillBeUpdatedText(spot.flightCount))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding()
                }
            }
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        if let coord = markerCoordinate {
                            onSave(coord)
                        }
                        dismiss()
                    }
                    .disabled(markerCoordinate == nil)
                }
            }
            .onAppear {
                // Si pas de coordonnées, rechercher automatiquement
                if markerCoordinate == nil {
                    searchLocation()
                }
            }
        }
    }
    
    private func searchLocation() {
        guard !searchText.isEmpty else { return }
        
        isSearching = true
        
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(searchText) { placemarks, error in
            DispatchQueue.main.async {
                isSearching = false
                
                guard let location = placemarks?.first?.location else { return }
                
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

// MARK: - SettingsView (Paramètres et import de données)

struct SettingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(\.modelContext) private var modelContext
    @Query private var wings: [Wing]
    @Query private var flights: [Flight]
    @State private var showingImportSuccess = false
    @State private var importMessage = ""
    @State private var showingDocumentPicker = false
    @State private var isImporting = false
    @State private var showingExportView = false

    var body: some View {
        NavigationStack {
            List {
                Section("Chronomètre") {
                    NavigationLink {
                        TimerView()
                    } label: {
                        Label("Lancer un vol", systemImage: "timer")
                    }
                }

                Section("Voiles") {
                    NavigationLink {
                        ArchivedWingsView()
                    } label: {
                        Label("Voiles archivées", systemImage: "archivebox")
                    }
                }

                Section("Spots") {
                    NavigationLink {
                        SpotsManagementView()
                    } label: {
                        Label("Gérer les spots", systemImage: "mappin.and.ellipse")
                    }
                }

                Section("Langue") {
                    Picker("Langue de l'application", selection: Binding(
                        get: { localizationManager.currentLanguage },
                        set: { localizationManager.currentLanguage = $0 }
                    )) {
                        Text("Système").tag(nil as LocalizationManager.Language?)
                        ForEach(LocalizationManager.Language.allCases, id: \.self) { language in
                            Text("\(language.flag) \(language.displayName)")
                                .tag(language as LocalizationManager.Language?)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Apple Watch") {
                    HStack {
                        Text("App Watch")
                        Spacer()
                        if watchManager.isWatchAppInstalled {
                            Label("Installée", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Label("Non installée", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    HStack {
                        Text("Joignable")
                        Spacer()
                        if watchManager.isWatchReachable {
                            Label("Oui", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Label("Non", systemImage: "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }

                    HStack {
                        Text("Nombre de voiles")
                        Spacer()
                        Text("\(wings.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        print("📤 Manual sync button pressed - \(wings.count) wings available")
                        watchManager.sendWingsToWatch()
                        watchManager.sendWingsViaTransfer() // Essayer aussi transferUserInfo
                        importMessage = "\(wings.count) voile(s) envoyée(s) à la Watch"
                        showingImportSuccess = true
                    } label: {
                        Label("Synchroniser les voiles", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "watchAutoWaterLock") },
                        set: { newValue in
                            UserDefaults.standard.set(newValue, forKey: "watchAutoWaterLock")
                            let allowDismiss = UserDefaults.standard.object(forKey: "watchAllowSessionDismiss") as? Bool ?? true
                            watchManager.sendWatchSettings(autoWaterLock: newValue, allowSessionDismiss: allowDismiss)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verrouillage automatique")
                            Text("Active le Water Lock au début d'un vol pour éviter les touches accidentelles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "watchAllowSessionDismiss") as? Bool ?? true },
                        set: { newValue in
                            UserDefaults.standard.set(newValue, forKey: "watchAllowSessionDismiss")
                            let autoWaterLock = UserDefaults.standard.bool(forKey: "watchAutoWaterLock")
                            watchManager.sendWatchSettings(autoWaterLock: autoWaterLock, allowSessionDismiss: newValue)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Autoriser l'annulation de vol")
                            Text("Permet d'annuler un vol en cours sans le sauvegarder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Options Apple Watch")
                } footer: {
                    Text("Ces paramètres sont synchronisés automatiquement avec votre Apple Watch.")
                }

                Section {
                    HStack {
                        Text("Poids équipé")
                        Spacer()
                        TextField("kg", text: Binding(
                            get: {
                                let weight = UserDefaults.standard.double(forKey: "pilotWeight")
                                return weight > 0 ? String(Int(weight)) : ""
                            },
                            set: { newValue in
                                if let weight = Double(newValue) {
                                    UserDefaults.standard.set(weight, forKey: "pilotWeight")
                                } else if newValue.isEmpty {
                                    UserDefaults.standard.removeObject(forKey: "pilotWeight")
                                }
                            }
                        ))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        Text("kg")
                            .foregroundStyle(.secondary)
                    }

                    Picker("Unité de vent", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "windUnit") ?? "knots" },
                        set: { UserDefaults.standard.set($0, forKey: "windUnit") }
                    )) {
                        Text("Noeuds (kn)").tag("knots")
                        Text("km/h").tag("kmh")
                    }
                } header: {
                    Text("Pilote")
                } footer: {
                    Text("Le poids équipé (pilote + sellette + équipement) permet d'améliorer l'estimation du vent.")
                }

                Section("Données") {
                    NavigationLink {
                        BackupExportView(wings: wings, flights: flights)
                    } label: {
                        Label("Exporter backup complet", systemImage: "archivebox")
                    }

                    Button {
                        showingDocumentPicker = true
                    } label: {
                        Label("Importer backup ou Excel", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        exportToCSV()
                    } label: {
                        Label("Exporter en CSV (ancien format)", systemImage: "square.and.arrow.up")
                    }
                }

                Section("Développeur") {
                    Button {
                        generateTestData()
                    } label: {
                        Label("Générer des données de test", systemImage: "wand.and.stars")
                    }

                    Button(role: .destructive) {
                        deleteAllData()
                    } label: {
                        Label("Supprimer toutes les données", systemImage: "trash")
                    }
                }

                Section("À propos") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text("1")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Réglages")
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker { url in
                    importExcelFile(from: url)
                }
            }
            .alert(isImporting ? "Import en cours..." : "Résultat", isPresented: Binding(
                get: { showingImportSuccess || isImporting },
                set: { if !$0 { showingImportSuccess = false; isImporting = false } }
            )) {
                if !isImporting {
                    Button("OK") { }
                }
            } message: {
                if isImporting {
                    Text("Importation des données...")
                } else {
                    Text(importMessage)
                }
            }
        }
    }

    private func generateTestData() {
        // Créer des voiles de test si aucune n'existe
        if wings.isEmpty {
            let testWings = [
                Wing(name: "Flare Props", size: "24", type: "Soaring", color: "Orange"),
                Wing(name: "Rush 5", size: "22", type: "Cross", color: "Bleu"),
                Wing(name: "Enzo 3", size: "23", type: "Cross", color: "Rouge")
            ]

            for wing in testWings {
                modelContext.insert(wing)
            }
        }

        // Créer des vols de test
        let testSpots = ["Chamonix", "Annecy", "Saint-Hilaire", "Passy", "Talloires"]
        let calendar = Calendar.current

        for _ in 0..<20 {
            let daysAgo = Int.random(in: 0...60)
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()

            let startDate = date
            let duration = Int.random(in: 900...7200) // 15min à 2h
            let endDate = startDate.addingTimeInterval(TimeInterval(duration))

            let randomWing = wings.randomElement()
            let randomSpot = testSpots.randomElement()

            // Créer des coordonnées fictives (région d'Annecy/Chamonix)
            let lat = 45.9 + Double.random(in: -0.2...0.2)
            let lon = 6.1 + Double.random(in: -0.2...0.2)

            let flight = Flight(
                wing: randomWing,
                startDate: startDate,
                endDate: endDate,
                durationSeconds: duration,
                spotName: randomSpot,
                latitude: lat,
                longitude: lon
            )

            modelContext.insert(flight)
        }

        Task { @MainActor in
            try? modelContext.save()
            importMessage = "✅ \(wings.count) voiles et 20 vols créés"
            showingImportSuccess = true
        }
    }

    private func importExcelFile(from url: URL) {
        // Détecter le type de fichier (.paraflightlog backup ou Excel/CSV)
        let fileExtension = url.pathExtension.lowercased()
        let isBackupFile = fileExtension == "paraflightlog"

        if isBackupFile {
            // Import fichier backup .paraflightlog
            isImporting = true
            importMessage = "Extraction du backup..."

            ZipBackup.importFromZip(zipURL: url, dataController: dataController, mergeMode: true) { result in
                self.isImporting = false

                switch result {
                case .success(let summary):
                    self.importMessage = summary
                    self.showingImportSuccess = true
                    // Synchroniser les voiles vers la Watch après import
                    self.watchManager.sendWingsToWatch()
                case .failure(let error):
                    self.importMessage = "❌ Erreur d'import:\n\(error.localizedDescription)"
                    self.showingImportSuccess = true
                }
            }
        } else {
            // Import Excel/CSV (existant)
            isImporting = true

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Parse le fichier en arrière-plan
                    let data = try ExcelImporter.parseExcelFile(at: url)

                    print("✅ Parsed \(data.flights.count) flights from file")

                    // Import dans la base DOIT être sur le main thread (SwiftData requirement)
                    DispatchQueue.main.async {
                        do {
                            let result = try ExcelImporter.importToDatabase(data: data, dataController: self.dataController)

                            self.isImporting = false
                            self.importMessage = result.summary
                            self.showingImportSuccess = true
                        } catch {
                            self.isImporting = false
                            self.importMessage = "❌ Erreur d'import:\n\(error.localizedDescription)"
                            self.showingImportSuccess = true
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isImporting = false
                        self.importMessage = "❌ Erreur de lecture:\n\(error.localizedDescription)"
                        self.showingImportSuccess = true
                    }
                }
            }
        }
    }

    private func exportToCSV() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy HH:mm"
        let timestamp = dateFormatter.string(from: Date()).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "h")

        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            importMessage = "❌ Erreur: impossible d'accéder aux documents"
            showingImportSuccess = true
            return
        }

        // Créer un dossier pour les images
        let imagesFolder = documentsPath.appendingPathComponent("ParaFlightLog_Images_\(timestamp)")
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

        // Générer CSV des voiles avec référence aux images
        var wingsCSV = "ID,Nom,Taille,Type,Couleur,Archivé,Date de création,Photo\n"
        var exportedFiles: [URL] = []

        for wing in wings.sorted(by: { $0.createdAt < $1.createdAt }) {
            let id = wing.id.uuidString
            let name = wing.name.replacingOccurrences(of: ",", with: ";")
            let size = wing.size?.replacingOccurrences(of: ",", with: ";") ?? ""
            let type = wing.type?.replacingOccurrences(of: ",", with: ";") ?? ""
            let color = wing.color?.replacingOccurrences(of: ",", with: ";") ?? ""
            let archived = wing.isArchived ? "Oui" : "Non"
            let created = dateFormatter.string(from: wing.createdAt)

            // Sauvegarder l'image si elle existe
            var photoFilename = ""
            if let photoData = wing.photoData {
                photoFilename = "\(id).jpg"
                let photoURL = imagesFolder.appendingPathComponent(photoFilename)
                try? photoData.write(to: photoURL)
            }

            wingsCSV += "\(id),\(name),\(size),\(type),\(color),\(archived),\(created),\(photoFilename)\n"
        }

        // Générer CSV des vols
        var flightsCSV = "ID,Date début,Date fin,Durée (min),Voile,Spot,Latitude,Longitude,Type,Notes\n"
        for flight in flights.sorted(by: { $0.startDate < $1.startDate }) {
            let id = flight.id.uuidString
            let startDate = dateFormatter.string(from: flight.startDate)
            let endDate = dateFormatter.string(from: flight.endDate)
            let duration = "\(flight.durationSeconds / 60)"
            let wingName = flight.wing?.name.replacingOccurrences(of: ",", with: ";") ?? "Inconnu"
            let spotName = flight.spotName?.replacingOccurrences(of: ",", with: ";") ?? ""
            let lat = flight.latitude.map { String($0) } ?? ""
            let lon = flight.longitude.map { String($0) } ?? ""
            let flightType = flight.flightType?.replacingOccurrences(of: ",", with: ";") ?? ""
            let notes = flight.notes?.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ") ?? ""

            flightsCSV += "\(id),\(startDate),\(endDate),\(duration),\(wingName),\(spotName),\(lat),\(lon),\(flightType),\"\(notes)\"\n"
        }

        // Sauvegarder les fichiers
        let wingsFileName = "ParaFlightLog_Wings_\(timestamp).csv"
        let flightsFileName = "ParaFlightLog_Flights_\(timestamp).csv"
        let wingsURL = documentsPath.appendingPathComponent(wingsFileName)
        let flightsURL = documentsPath.appendingPathComponent(flightsFileName)

        do {
            try wingsCSV.write(to: wingsURL, atomically: true, encoding: .utf8)
            try flightsCSV.write(to: flightsURL, atomically: true, encoding: .utf8)

            // Préparer les fichiers à partager
            exportedFiles = [wingsURL, flightsURL]

            // Ajouter le dossier d'images s'il contient des fichiers
            if let imageFiles = try? FileManager.default.contentsOfDirectory(at: imagesFolder, includingPropertiesForKeys: nil),
               !imageFiles.isEmpty {
                exportedFiles.append(imagesFolder)
            }

            // Partager tous les fichiers
            let activityVC = UIActivityViewController(activityItems: exportedFiles, applicationActivities: nil)

            // Support iPad: définir le popover
            if let popover = activityVC.popoverPresentationController {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    popover.sourceView = window
                    popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
            }

            // Présenter le share sheet
            DispatchQueue.main.async {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    var topVC = rootVC
                    while let presented = topVC.presentedViewController {
                        topVC = presented
                    }
                    topVC.present(activityVC, animated: true)
                }
            }
        } catch {
            importMessage = "❌ Erreur d'export: \(error.localizedDescription)"
            showingImportSuccess = true
        }
    }

    private func formatDurationForExport(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }

    private func deleteAllData() {
        // Supprimer tous les vols
        do {
            try modelContext.delete(model: Flight.self)
            try modelContext.delete(model: Wing.self)
            try modelContext.save()
            importMessage = "✅ Toutes les données ont été supprimées"
            showingImportSuccess = true
        } catch {
            importMessage = "❌ Erreur: \(error.localizedDescription)"
            showingImportSuccess = true
        }
    }
}

// MARK: - BackupExportView (Vue dédiée pour l'export)

struct BackupExportView: View {
    let wings: [Wing]
    let flights: [Flight]

    @State private var exportStatus: ExportStatus = .idle
    @State private var backupURL: URL?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    enum ExportStatus {
        case idle
        case exporting
        case completed
        case failed
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icône et statut
            Group {
                switch exportStatus {
                case .idle:
                    Image(systemName: "archivebox")
                        .font(.system(size: 80))
                        .foregroundStyle(.blue)

                case .exporting:
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.blue)

                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.green)

                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.red)
                }
            }
            .frame(height: 100)

            // Texte de statut
            Group {
                switch exportStatus {
                case .idle:
                    Text("Prêt à exporter")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(wings.count) voiles • \(flights.count) vols")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .exporting:
                    Text("Création du backup...")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Veuillez patienter")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .completed:
                    Text("Backup créé !")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Prêt à partager")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .failed:
                    Text("Erreur")
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let error = errorMessage {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }

            Spacer()

            // Boutons d'action
            VStack(spacing: 16) {
                if exportStatus == .idle {
                    Button {
                        startExport()
                    } label: {
                        Label("Créer le backup", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                    }
                } else if exportStatus == .completed, let url = backupURL {
                    Button {
                        shareBackup(url: url)
                    } label: {
                        Label("Partager / Enregistrer", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                    }
                } else if exportStatus == .failed {
                    Button {
                        dismiss()
                    } label: {
                        Text("Retour")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .foregroundStyle(.primary)
                            .cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .navigationTitle("Export Backup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func startExport() {
        exportStatus = .exporting

        ZipBackup.exportToZip(wings: Array(wings), flights: Array(flights)) { result in
            switch result {
            case .success(let url):
                self.backupURL = url
                self.exportStatus = .completed

            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.exportStatus = .failed
            }
        }
    }

    private func shareBackup(url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            return
        }

        let activityVC = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )

        // Pour iPad
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        rootViewController.present(activityVC, animated: true)
    }
}

// MARK: - DocumentPicker (Import Excel/CSV)

import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {
    let onDocumentPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Support CSV, Excel files, and .paraflightlog backup folders
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .commaSeparatedText,
            .plainText,
            .data,
            .folder,
            .package,
            UTType(filenameExtension: "xlsx")!,
            UTType(filenameExtension: "xls")!,
            UTType(filenameExtension: "paraflightlog")!
        ])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentPicked: onDocumentPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentPicked: (URL) -> Void

        init(onDocumentPicked: @escaping (URL) -> Void) {
            self.onDocumentPicked = onDocumentPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onDocumentPicked(url)
        }
    }
}

// MARK: - ShareSheet (Pour partager des fichiers/dossiers)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityVC = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        activityVC.completionWithItemsHandler = { _, completed, _, error in
            if let error = error {
                print("❌ Share error: \(error)")
            }
            onComplete(completed)
        }

        return activityVC
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

