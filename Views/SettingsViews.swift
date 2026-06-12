//
//  SettingsViews.swift
//  ParaFlightLog
//
//  Vues liées aux réglages : gestion spots, export backup, import de documents
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

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
            do {
                try modelContext.save()
                logInfo("Updated \(updatedCount) flights with coordinates for spot: \(spotName)", category: .location)
            } catch {
                logError("Failed to save spot coordinates: \(error.localizedDescription)", category: .dataController)
            }
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

    /// Retourne le texte avec pluralisation correcte pour le nombre de vols
    private func flightsCountText(_ count: Int) -> String {
        if count <= 1 {
            return String(localized: "\(count) vol")
        } else {
            return String(localized: "\(count) vols")
        }
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

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
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

struct DocumentPicker: UIViewControllerRepresentable {
    let onDocumentPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Support CSV, Excel files, and .paraflightlog backup folders
        // Construire la liste des types supportés (éviter les force unwraps)
        var contentTypes: [UTType] = [
            .commaSeparatedText,
            .plainText,
            .data,
            .folder,
            .package
        ]
        // Ajouter les types personnalisés s'ils existent
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            contentTypes.append(xlsxType)
        }
        if let xlsType = UTType(filenameExtension: "xls") {
            contentTypes.append(xlsType)
        }
        if let backupType = UTType(filenameExtension: "paraflightlog") {
            contentTypes.append(backupType)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
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
                logError("Share error: \(error)", category: .general)
            }
            onComplete(completed)
        }

        return activityVC
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
