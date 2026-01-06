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

    var body: some View {
        NavigationStack {
            List {
                // Section filtres
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
                                    chipColor: Color(type.color),
                                    action: { selectedFilter = type }
                                )
                            }
                        }
                        .padding(.horizontal, 4)
                    }
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
                Map(coordinateRegion: .constant(mapRegion), annotationItems: [notam]) { item in
                    MapAnnotation(coordinate: mapRegion.center) {
                        Image(systemName: item.type.iconName)
                            .font(.title)
                            .foregroundStyle(Color(item.type.color))
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
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
        }
    }
}

// MARK: - Alert Zone Row

struct AlertZoneRowView: View {
    let zone: AlertZone
    @State private var notamService = NOTAMService.shared

    var body: some View {
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
    }
}

// MARK: - Add Alert Zone View

struct AddAlertZoneView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notamService = NOTAMService.shared

    @State private var name = ""
    @State private var description = ""
    @State private var notifyOnNewNOTAM = true
    @State private var notifyBeforeFlight = true
    @State private var notifyOnExpiration = false

    @State private var centerLatitude: Double = 45.0
    @State private var centerLongitude: Double = 6.0
    @State private var radiusKm: Double = 50.0

    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Informations") {
                    TextField("Nom de la zone", text: $name)
                    TextField("Description (optionnel)", text: $description)
                }

                Section("Position") {
                    HStack {
                        Text("Latitude")
                        Spacer()
                        TextField("Latitude", value: $centerLatitude, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }

                    HStack {
                        Text("Longitude")
                        Spacer()
                        TextField("Longitude", value: $centerLongitude, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }

                    HStack {
                        Text("Rayon")
                        Spacer()
                        TextField("km", value: $radiusKm, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("km")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notifications") {
                    Toggle("Nouveaux NOTAM", isOn: $notifyOnNewNOTAM)
                    Toggle("Avant chaque vol", isOn: $notifyBeforeFlight)
                    Toggle("Expiration de NOTAM", isOn: $notifyOnExpiration)
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
                center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
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

// MARK: - NOTAM Map View

struct NOTAMMapView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notamService = NOTAMService.shared
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 45.5, longitude: 5.5),
        span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
    )

    var body: some View {
        NavigationStack {
            Map(coordinateRegion: $region, annotationItems: notamService.cachedNOTAMs.filter { $0.isActive }) { notam in
                MapAnnotation(coordinate: notamCenter(notam)) {
                    VStack {
                        Image(systemName: notam.type.iconName)
                            .font(.title2)
                            .foregroundStyle(Color(notam.type.color))
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())

                        Text(notam.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                }
            }
            .navigationTitle("Carte NOTAM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    private func notamCenter(_ notam: NOTAM) -> CLLocationCoordinate2D {
        switch notam.geometry {
        case .circle(let center, _):
            return center
        case .polygon(let coords):
            guard !coords.isEmpty else {
                return CLLocationCoordinate2D(latitude: 0, longitude: 0)
            }
            let sumLat = coords.reduce(0.0) { $0 + $1.latitude }
            let sumLon = coords.reduce(0.0) { $0 + $1.longitude }
            return CLLocationCoordinate2D(
                latitude: sumLat / Double(coords.count),
                longitude: sumLon / Double(coords.count)
            )
        }
    }
}

// MARK: - Preview

#Preview {
    NOTAMListView()
}
