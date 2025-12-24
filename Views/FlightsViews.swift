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
                    Button {
                        showingEditSheet = true
                    } label: {
                        Label("Modifier", systemImage: "pencil")
                    }
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                EditFlightView(flight: flight)
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
                    logError("Geocoding error: \(error.localizedDescription)", category: .location)
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
