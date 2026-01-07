//
//  NOTAMViews.swift
//  ParaFlightLog
//
//  Vues pour l'affichage et la gestion des NOTAM et zones d'alerte
//  Target: iOS only
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - NOTAM List View

/// Vue principale de la liste des NOTAM
struct NOTAMListView: View {
    @State private var notamService = NOTAMService.shared
    @State private var selectedFilter: NOTAMType? = nil
    @State private var showingAlertZones = false
    @State private var showingMap = false
    @State private var showingCountryPicker = false

    var body: some View {
        NavigationStack {
            List {
                // Section sélection pays
                Section {
                    Button {
                        showingCountryPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundStyle(Color.accentColor)
                            Text("Pays sélectionnés")
                            Spacer()
                            Text(selectedCountriesText)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Régions")
                }

                // Section filtres par type
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            NOTAMFilterChip(
                                title: "Tous",
                                isSelected: selectedFilter == nil,
                                action: { selectedFilter = nil }
                            )

                            ForEach(NOTAMType.allCases) { type in
                                NOTAMFilterChip(
                                    title: type.displayName,
                                    isSelected: selectedFilter == type,
                                    chipColor: Color.fromHex(type.color) ?? .gray,
                                    action: { selectedFilter = type }
                                )
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                } header: {
                    Text("Filtres")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                // Section NOTAM actifs
                Section {
                    if notamService.isLoading {
                        HStack {
                            ProgressView()
                            Text("Chargement des NOTAM...")
                                .foregroundStyle(.secondary)
                        }
                    } else if filteredNOTAMs.isEmpty {
                        ContentUnavailableView(
                            "Aucun NOTAM",
                            systemImage: "checkmark.circle",
                            description: Text("Aucun NOTAM actif dans cette catégorie")
                        )
                    } else {
                        ForEach(filteredNOTAMs) { notam in
                            NavigationLink(destination: NOTAMDetailView(notam: notam)) {
                                NOTAMRowView(notam: notam)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("NOTAM Actifs")
                        Spacer()
                        if let lastRefresh = notamService.lastRefreshDate {
                            Text("Màj: \(lastRefresh, style: .relative)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("NOTAM")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingAlertZones = true
                    } label: {
                        Label("Zones d'alerte", systemImage: "bell.badge")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button {
                            showingMap = true
                        } label: {
                            Label("Carte", systemImage: "map")
                        }

                        Button {
                            Task {
                                await notamService.refreshNOTAMs()
                            }
                        } label: {
                            Label("Actualiser", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable {
                await notamService.refreshNOTAMs()
            }
            .sheet(isPresented: $showingAlertZones) {
                AlertZonesView()
            }
            .sheet(isPresented: $showingMap) {
                NOTAMMapView()
            }
            .sheet(isPresented: $showingCountryPicker) {
                CountryPickerView()
            }
            .task {
                await notamService.refreshIfNeeded()
            }
        }
    }

    private var filteredNOTAMs: [NOTAM] {
        let active = notamService.cachedNOTAMs.filter { $0.isActive }
        if let filter = selectedFilter {
            return active.filter { $0.type == filter }
        }
        return active
    }

    private var selectedCountriesText: String {
        let countries = notamService.selectedCountries
        if countries.isEmpty {
            return "Aucun"
        } else if countries.count == 1 {
            return countries.first!.flag + " " + countries.first!.displayName
        } else if countries.count <= 3 {
            return countries.map { $0.flag }.joined(separator: " ")
        } else {
            return "\(countries.count) pays"
        }
    }
}

// MARK: - Country Picker View

struct CountryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notamService = NOTAMService.shared
    @State private var selectedCountries: Set<NOTAMCountry> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(NOTAMCountry.allCases), id: \.self) { country in
                        Button {
                            if selectedCountries.contains(country) {
                                selectedCountries.remove(country)
                            } else {
                                selectedCountries.insert(country)
                            }
                        } label: {
                            HStack {
                                Text(country.flag)
                                    .font(.title2)
                                Text(country.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(country.notamSource)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if selectedCountries.contains(country) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Sélectionnez les pays pour lesquels vous souhaitez voir les NOTAM")
                }
            }
            .navigationTitle("Pays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Appliquer") {
                        notamService.selectedCountries = selectedCountries
                        Task {
                            await notamService.refreshNOTAMs()
                        }
                        dismiss()
                    }
                    .disabled(selectedCountries.isEmpty)
                }
            }
            .onAppear {
                selectedCountries = notamService.selectedCountries
            }
        }
    }
}

// MARK: - NOTAM Filter Chip (local version to avoid conflicts)

struct NOTAMFilterChip: View {
    let title: String
    let isSelected: Bool
    var chipColor: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? chipColor.opacity(0.2) : Color(.systemGray6))
                .foregroundStyle(isSelected ? chipColor : .primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? chipColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - NOTAM Row View

struct NOTAMRowView: View {
    let notam: NOTAM

    var body: some View {
        HStack(spacing: 12) {
            // Icône du type
            Image(systemName: notam.type.iconName)
                .font(.title2)
                .foregroundStyle(Color(notam.type.color))
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(notam.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(notam.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(notam.altitudes.displayString, systemImage: "arrow.up.arrow.down")
                    Spacer()
                    if notam.expiresSoon {
                        Label(notam.remainingTimeFormatted, systemImage: "clock")
                            .foregroundStyle(.orange)
                    } else {
                        Label(notam.remainingTimeFormatted, systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - NOTAM Detail View

struct NOTAMDetailView: View {
    let notam: NOTAM
    @State private var mapRegion: MKCoordinateRegion

    init(notam: NOTAM) {
        self.notam = notam

        // Calculer la région de la carte
        let center: CLLocationCoordinate2D
        let span: MKCoordinateSpan

        switch notam.geometry {
        case .circle(let c, let radiusNM):
            center = c
            let radiusDegrees = radiusNM / 60.0 * 2.5  // Approximation
            span = MKCoordinateSpan(latitudeDelta: radiusDegrees, longitudeDelta: radiusDegrees)
        case .polygon(let coords):
            let lats = coords.map { $0.latitude }
            let lons = coords.map { $0.longitude }
            center = CLLocationCoordinate2D(
                latitude: (lats.min()! + lats.max()!) / 2,
                longitude: (lons.min()! + lons.max()!) / 2
            )
            span = MKCoordinateSpan(
                latitudeDelta: (lats.max()! - lats.min()!) * 1.3,
                longitudeDelta: (lons.max()! - lons.min()!) * 1.3
            )
        }

        _mapRegion = State(initialValue: MKCoordinateRegion(center: center, span: span))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // En-tête avec type
                HStack {
                    Image(systemName: notam.type.iconName)
                        .font(.largeTitle)
                        .foregroundStyle(Color(notam.type.color))

                    VStack(alignment: .leading) {
                        Text(notam.type.displayName)
                            .font(.headline)
                            .foregroundStyle(Color(notam.type.color))
                        Text("Source: \(notam.source)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if notam.isActive {
                        Label("Actif", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Carte
                Map {
                    Annotation("", coordinate: mapRegion.center) {
                        Image(systemName: notam.type.iconName)
                            .font(.title)
                            .foregroundStyle(Color(notam.type.color))
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .mapStyle(.standard)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Informations
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(title: "Altitudes", value: notam.altitudes.displayString, icon: "arrow.up.arrow.down")

                    InfoRow(
                        title: "Début",
                        value: notam.effectiveStart.formatted(date: .abbreviated, time: .shortened),
                        icon: "play.fill"
                    )

                    InfoRow(
                        title: "Fin",
                        value: notam.effectiveEnd.formatted(date: .abbreviated, time: .shortened),
                        icon: "stop.fill"
                    )

                    InfoRow(title: "Temps restant", value: notam.remainingTimeFormatted, icon: "clock")
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(.headline)

                    Text(notam.description)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Texte brut si disponible
                if let rawText = notam.rawText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Texte original")
                            .font(.headline)

                        Text(rawText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .navigationTitle(notam.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Alert Zones View

struct AlertZonesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notamService = NOTAMService.shared
    @State private var showingAddZone = false
    @State private var selectedZone: AlertZone?

    var body: some View {
        NavigationStack {
            List {
                if notamService.alertZones.isEmpty {
                    ContentUnavailableView(
                        "Aucune zone d'alerte",
                        systemImage: "bell.slash",
                        description: Text("Créez des zones pour recevoir des alertes NOTAM")
                    )
                } else {
                    ForEach(notamService.alertZones) { zone in
                        AlertZoneRowView(zone: zone)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedZone = zone
                            }
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                try? await notamService.deleteAlertZone(notamService.alertZones[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Zones d'alerte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddZone = true
                    } label: {
                        Label("Ajouter", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddZone) {
                AddAlertZoneView()
            }
            .sheet(item: $selectedZone) { zone in
                EditAlertZoneView(zone: zone)
            }
        }
    }
}

// MARK: - Alert Zone Row

struct AlertZoneRowView: View {
    let zone: AlertZone
    @State private var notamService = NOTAMService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(zone.name)
                        .font(.headline)

                    if let description = zone.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        if zone.notifyOnNewNOTAM {
                            Label("Nouveaux", systemImage: "bell.fill")
                        }
                        if zone.notifyBeforeFlight {
                            Label("Pré-vol", systemImage: "airplane.departure")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { zone.isEnabled },
                    set: { _ in
                        Task {
                            try? await notamService.toggleAlertZone(zone)
                        }
                    }
                ))
                .labelsHidden()
            }

            // Mini-carte de la zone
            AlertZoneMiniMap(zone: zone)
                .frame(height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Alert Zone Mini Map

struct AlertZoneMiniMap: UIViewRepresentable {
    let zone: AlertZone

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.isUserInteractionEnabled = false
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)

        let center = zone.geometry.center
        let radiusMeters: Double

        switch zone.geometry {
        case .circle(_, let r):
            radiusMeters = r
            let circle = MKCircle(center: center, radius: r)
            mapView.addOverlay(circle)
        case .polygon(let coords):
            radiusMeters = zone.geometry.approximateRadius
            var coordinates = coords
            let polygon = MKPolygon(coordinates: &coordinates, count: coords.count)
            mapView.addOverlay(polygon)
        }

        // Ajuster la région pour montrer toute la zone
        let regionRadius = radiusMeters * 1.5
        let region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: regionRadius * 2,
            longitudinalMeters: regionRadius * 2
        )
        mapView.setRegion(region, animated: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6)
                renderer.lineWidth = 2
                return renderer
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6)
                renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Add Alert Zone View (Interactive Map)

struct AddAlertZoneView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var locationService
    @State private var notamService = NOTAMService.shared

    @State private var name = ""
    @State private var description = ""
    @State private var notifyOnNewNOTAM = true
    @State private var notifyBeforeFlight = true
    @State private var notifyOnExpiration = false

    // Position sur la carte (sera mise à jour avec la localisation GPS)
    @State private var centerCoordinate = CLLocationCoordinate2D(latitude: 45.0, longitude: 6.0)
    @State private var radiusKm: Double = 1.0
    @State private var hasSetInitialLocation = false

    @State private var isSaving = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Carte interactive avec le cercle
                AlertZoneMapEditor(
                    centerCoordinate: $centerCoordinate,
                    radiusKm: $radiusKm
                )
                .ignoresSafeArea(edges: .bottom)

                // Panneau d'informations en bas
                VStack {
                    Spacer()

                    VStack(spacing: 16) {
                        // Slider pour le rayon
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "circle.dashed")
                                    .foregroundStyle(Color.accentColor)
                                Text("Rayon: \(Int(radiusKm)) km")
                                    .font(.headline)
                                Spacer()
                            }

                            Slider(value: $radiusKm, in: 1...200, step: 1) {
                                Text("Rayon")
                            }
                            .tint(Color.accentColor)
                        }

                        // Nom de la zone
                        TextField("Nom de la zone", text: $name)
                            .textFieldStyle(.roundedBorder)

                        // Bouton pour les paramètres avancés
                        Button {
                            showingSettings = true
                        } label: {
                            HStack {
                                Image(systemName: "gear")
                                Text("Paramètres de notification")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
            .navigationTitle("Nouvelle zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        saveZone()
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $showingSettings) {
                AlertZoneSettingsSheet(
                    notifyOnNewNOTAM: $notifyOnNewNOTAM,
                    notifyBeforeFlight: $notifyBeforeFlight,
                    notifyOnExpiration: $notifyOnExpiration,
                    description: $description
                )
                .presentationDetents([.medium])
            }
            .onAppear {
                // Utiliser la dernière position GPS connue, ou demander la position
                if !hasSetInitialLocation {
                    if let lastLocation = locationService.lastKnownLocation {
                        centerCoordinate = lastLocation.coordinate
                        hasSetInitialLocation = true
                    } else {
                        // Demander la position GPS
                        locationService.requestLocation { location in
                            if let location = location {
                                centerCoordinate = location.coordinate
                            }
                            hasSetInitialLocation = true
                        }
                    }
                }
            }
        }
    }

    private func saveZone() {
        isSaving = true

        let zone = AlertZone(
            name: name,
            description: description.isEmpty ? nil : description,
            notifyOnNewNOTAM: notifyOnNewNOTAM,
            notifyBeforeFlight: notifyBeforeFlight,
            notifyOnExpiration: notifyOnExpiration,
            geometry: .circle(
                center: centerCoordinate,
                radiusMeters: radiusKm * 1000
            )
        )

        Task {
            do {
                try await notamService.addAlertZone(zone)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                logError("Failed to save alert zone: \(error.localizedDescription)", category: .notification)
                isSaving = false
            }
        }
    }
}

// MARK: - Alert Zone Map Editor

struct AlertZoneMapEditor: UIViewRepresentable {
    @Binding var centerCoordinate: CLLocationCoordinate2D
    @Binding var radiusKm: Double
    var shouldRecenter: Bool = false

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true

        // Région initiale centrée sur le point avec un zoom adapté au rayon
        let region = MKCoordinateRegion(
            center: centerCoordinate,
            latitudinalMeters: radiusKm * 1000 * 4,
            longitudinalMeters: radiusKm * 1000 * 4
        )
        mapView.setRegion(region, animated: false)
        context.coordinator.lastCenteredCoordinate = centerCoordinate

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Mettre à jour le cercle
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })

        // Ajouter le cercle de la zone
        let circle = MKCircle(center: centerCoordinate, radius: radiusKm * 1000)
        mapView.addOverlay(circle)

        // Ajouter un pin au centre
        let annotation = MKPointAnnotation()
        annotation.coordinate = centerCoordinate
        annotation.title = "Centre de la zone"
        mapView.addAnnotation(annotation)

        // Recentrer si les coordonnées ont changé significativement (GPS arrivé)
        let lastCoord = context.coordinator.lastCenteredCoordinate
        let distanceMoved = sqrt(pow(centerCoordinate.latitude - lastCoord.latitude, 2) +
                                  pow(centerCoordinate.longitude - lastCoord.longitude, 2))
        if distanceMoved > 0.1 {  // Plus de 0.1 degré de différence = recentrer
            let region = MKCoordinateRegion(
                center: centerCoordinate,
                latitudinalMeters: radiusKm * 1000 * 4,
                longitudinalMeters: radiusKm * 1000 * 4
            )
            mapView.setRegion(region, animated: true)
            context.coordinator.lastCenteredCoordinate = centerCoordinate
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: AlertZoneMapEditor
        var lastCenteredCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()

        init(_ parent: AlertZoneMapEditor) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Mettre à jour les coordonnées du centre quand la carte bouge
            parent.centerCoordinate = mapView.centerCoordinate
            lastCenteredCoordinate = mapView.centerCoordinate
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8)
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }

            let identifier = "CenterPin"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView

            if annotationView == nil {
                annotationView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = false
                annotationView?.markerTintColor = .systemBlue
                annotationView?.glyphImage = UIImage(systemName: "scope")
            } else {
                annotationView?.annotation = annotation
            }

            return annotationView
        }
    }
}

// MARK: - Alert Zone Settings Sheet

struct AlertZoneSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var notifyOnNewNOTAM: Bool
    @Binding var notifyBeforeFlight: Bool
    @Binding var notifyOnExpiration: Bool
    @Binding var description: String

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Toggle(isOn: $notifyOnNewNOTAM) {
                        Label("Nouveaux NOTAM", systemImage: "bell.badge")
                    }

                    Toggle(isOn: $notifyBeforeFlight) {
                        Label("Avant chaque vol", systemImage: "airplane.departure")
                    }

                    Toggle(isOn: $notifyOnExpiration) {
                        Label("Expiration de NOTAM", systemImage: "clock.badge.exclamationmark")
                    }
                }

                Section("Description") {
                    TextField("Description (optionnel)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Paramètres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Edit Alert Zone View

struct EditAlertZoneView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notamService = NOTAMService.shared
    let zone: AlertZone

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var notifyOnNewNOTAM: Bool = true
    @State private var notifyBeforeFlight: Bool = true
    @State private var notifyOnExpiration: Bool = false
    @State private var centerCoordinate: CLLocationCoordinate2D
    @State private var radiusKm: Double

    @State private var isSaving = false
    @State private var showingDeleteConfirmation = false

    init(zone: AlertZone) {
        self.zone = zone
        // Initialiser les coordonnées directement depuis la zone
        switch zone.geometry {
        case .circle(let center, let radiusMeters):
            _centerCoordinate = State(initialValue: center)
            _radiusKm = State(initialValue: radiusMeters / 1000.0)
        case .polygon:
            _centerCoordinate = State(initialValue: zone.geometry.center)
            _radiusKm = State(initialValue: zone.geometry.approximateRadius / 1000.0)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Carte de la zone
                    AlertZoneMapEditor(
                        centerCoordinate: $centerCoordinate,
                        radiusKm: $radiusKm
                    )
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    // Slider pour le rayon
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "circle.dashed")
                                .foregroundStyle(Color.accentColor)
                            Text("Rayon: \(Int(radiusKm)) km")
                                .font(.headline)
                            Spacer()
                        }

                        Slider(value: $radiusKm, in: 1...200, step: 1) {
                            Text("Rayon")
                        }
                        .tint(Color.accentColor)
                    }
                    .padding(.horizontal)

                    // Informations
                    VStack(spacing: 16) {
                        TextField("Nom de la zone", text: $name)
                            .textFieldStyle(.roundedBorder)

                        TextField("Description (optionnel)", text: $description, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                    }
                    .padding(.horizontal)

                    // Options de notification
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Notifications")
                            .font(.headline)

                        Toggle(isOn: $notifyOnNewNOTAM) {
                            Label("Nouveaux NOTAM", systemImage: "bell.badge")
                        }

                        Toggle(isOn: $notifyBeforeFlight) {
                            Label("Avant chaque vol", systemImage: "airplane.departure")
                        }

                        Toggle(isOn: $notifyOnExpiration) {
                            Label("Expiration de NOTAM", systemImage: "clock.badge.exclamationmark")
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    // Bouton supprimer
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Supprimer cette zone", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                    .padding(.top, 10)
                }
                .padding(.vertical)
            }
            .navigationTitle("Modifier la zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saveChanges()
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .confirmationDialog("Supprimer cette zone ?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    deleteZone()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Cette action est irréversible")
            }
            .onAppear {
                loadZoneData()
            }
        }
    }

    private func loadZoneData() {
        name = zone.name
        description = zone.description ?? ""
        notifyOnNewNOTAM = zone.notifyOnNewNOTAM
        notifyBeforeFlight = zone.notifyBeforeFlight
        notifyOnExpiration = zone.notifyOnExpiration
        // Les coordonnées sont déjà initialisées dans init()
    }

    private func saveChanges() {
        isSaving = true

        let updatedZone = AlertZone(
            id: zone.id,
            name: name,
            description: description.isEmpty ? nil : description,
            isEnabled: zone.isEnabled,
            notifyOnNewNOTAM: notifyOnNewNOTAM,
            notifyBeforeFlight: notifyBeforeFlight,
            notifyOnExpiration: notifyOnExpiration,
            geometry: .circle(center: centerCoordinate, radiusMeters: radiusKm * 1000),
            createdAt: zone.createdAt,
            updatedAt: Date()
        )

        Task {
            do {
                try await notamService.updateAlertZone(updatedZone)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                logError("Failed to update alert zone: \(error.localizedDescription)", category: .notification)
                isSaving = false
            }
        }
    }

    private func deleteZone() {
        Task {
            try? await notamService.deleteAlertZone(zone)
            await MainActor.run {
                dismiss()
            }
        }
    }
}

// MARK: - NOTAM Map View with Overlays

struct NOTAMMapView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notamService = NOTAMService.shared
    @State private var selectedNOTAM: NOTAM?
    @State private var showNOTAMDetail = false

    var body: some View {
        NavigationStack {
            NOTAMMapWithOverlays(
                notams: notamService.cachedNOTAMs.filter { $0.isActive },
                alertZones: notamService.alertZones,
                onNOTAMSelected: { notam in
                    selectedNOTAM = notam
                    showNOTAMDetail = true
                }
            )
            .navigationTitle("Carte NOTAM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(isPresented: $showNOTAMDetail) {
                if let notam = selectedNOTAM {
                    NavigationStack {
                        NOTAMDetailView(notam: notam)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Fermer") { showNOTAMDetail = false }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
        }
    }
}

// MARK: - NOTAM Map with Overlays (UIKit MapView)

struct NOTAMMapWithOverlays: UIViewRepresentable {
    let notams: [NOTAM]
    let alertZones: [AlertZone]
    var onNOTAMSelected: ((NOTAM) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator

        // Centrer sur la France par défaut
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 46.0, longitude: 2.5),
            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
        )
        mapView.setRegion(region, animated: false)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Supprimer les overlays et annotations existants
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        // Ajouter les zones NOTAM
        for notam in notams {
            addNOTAMOverlay(notam, to: mapView, context: context)
        }

        // Ajouter les zones d'alerte utilisateur
        for zone in alertZones where zone.isEnabled {
            addAlertZoneOverlay(zone, to: mapView, context: context)
        }
    }

    private func addNOTAMOverlay(_ notam: NOTAM, to mapView: MKMapView, context: Context) {
        switch notam.geometry {
        case .circle(let center, let radiusNM):
            let radiusMeters = radiusNM * 1852  // 1 NM = 1852 m
            let circle = NOTAMCircle(center: center, radius: radiusMeters)
            circle.notam = notam
            mapView.addOverlay(circle)

            // Ajouter une annotation au centre
            let annotation = NOTAMAnnotation(notam: notam, coordinate: center)
            mapView.addAnnotation(annotation)

        case .polygon(let coordinates):
            guard coordinates.count >= 3 else { return }
            var coords = coordinates
            let polygon = NOTAMPolygon(coordinates: &coords, count: coordinates.count)
            polygon.notam = notam
            mapView.addOverlay(polygon)

            // Ajouter une annotation au centre
            let center = polygonCenter(coordinates)
            let annotation = NOTAMAnnotation(notam: notam, coordinate: center)
            mapView.addAnnotation(annotation)
        }
    }

    private func addAlertZoneOverlay(_ zone: AlertZone, to mapView: MKMapView, context: Context) {
        switch zone.geometry {
        case .circle(let center, let radiusMeters):
            let circle = AlertZoneCircle(center: center, radius: radiusMeters)
            circle.alertZone = zone
            mapView.addOverlay(circle, level: .aboveLabels)

        case .polygon(let coordinates):
            guard coordinates.count >= 3 else { return }
            var coords = coordinates
            let polygon = AlertZonePolygon(coordinates: &coords, count: coordinates.count)
            polygon.alertZone = zone
            mapView.addOverlay(polygon, level: .aboveLabels)
        }
    }

    private func polygonCenter(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !coordinates.isEmpty else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        let sumLat = coordinates.reduce(0.0) { $0 + $1.latitude }
        let sumLon = coordinates.reduce(0.0) { $0 + $1.longitude }
        return CLLocationCoordinate2D(
            latitude: sumLat / Double(coordinates.count),
            longitude: sumLon / Double(coordinates.count)
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NOTAMMapWithOverlays

        init(_ parent: NOTAMMapWithOverlays) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? NOTAMCircle, let notam = circle.notam {
                let renderer = MKCircleRenderer(circle: circle)
                let color = UIColor(Color.fromHex(notam.type.color) ?? .red)
                renderer.fillColor = color.withAlphaComponent(0.2)
                renderer.strokeColor = color.withAlphaComponent(0.8)
                renderer.lineWidth = 2
                return renderer
            }

            if let polygon = overlay as? NOTAMPolygon, let notam = polygon.notam {
                let renderer = MKPolygonRenderer(polygon: polygon)
                let color = UIColor(Color.fromHex(notam.type.color) ?? .red)
                renderer.fillColor = color.withAlphaComponent(0.2)
                renderer.strokeColor = color.withAlphaComponent(0.8)
                renderer.lineWidth = 2
                return renderer
            }

            if overlay is AlertZoneCircle {
                let renderer = MKCircleRenderer(circle: overlay as! MKCircle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.1)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.5)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [8, 4]
                return renderer
            }

            if overlay is AlertZonePolygon {
                let renderer = MKPolygonRenderer(polygon: overlay as! MKPolygon)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.1)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.5)
                renderer.lineWidth = 2
                renderer.lineDashPattern = [8, 4]
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let notamAnnotation = annotation as? NOTAMAnnotation else { return nil }

            let identifier = "NOTAMAnnotation"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)

            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = true
                annotationView?.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            } else {
                annotationView?.annotation = annotation
            }

            // Créer l'icône
            let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
            let image = UIImage(systemName: notamAnnotation.notam.type.iconName, withConfiguration: config)
            let color = UIColor(Color.fromHex(notamAnnotation.notam.type.color) ?? .red)

            annotationView?.image = image?.withTintColor(color, renderingMode: .alwaysOriginal)

            return annotationView
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let notamAnnotation = view.annotation as? NOTAMAnnotation {
                parent.onNOTAMSelected?(notamAnnotation.notam)
            }
        }
    }
}

// MARK: - Custom Overlay Classes

class NOTAMCircle: MKCircle {
    var notam: NOTAM?
}

class NOTAMPolygon: MKPolygon {
    var notam: NOTAM?
}

class AlertZoneCircle: MKCircle {
    var alertZone: AlertZone?
}

class AlertZonePolygon: MKPolygon {
    var alertZone: AlertZone?
}

// MARK: - NOTAM Annotation

class NOTAMAnnotation: NSObject, MKAnnotation {
    let notam: NOTAM
    let coordinate: CLLocationCoordinate2D

    var title: String? { notam.title }
    var subtitle: String? { notam.type.displayName }

    init(notam: NOTAM, coordinate: CLLocationCoordinate2D) {
        self.notam = notam
        self.coordinate = coordinate
    }
}

// MARK: - Preview

#Preview {
    NOTAMListView()
}
