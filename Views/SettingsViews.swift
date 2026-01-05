//
//  SettingsViews.swift
//  ParaFlightLog
//
//  Vues liées aux réglages : settings, gestion spots, export/import
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
                        logInfo("Manual sync button pressed - \(wings.count) wings available", category: .watchSync)
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
                        get: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock) },
                        set: { newValue in
                            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.watchAutoWaterLock)
                            let allowDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
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
                        get: { UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true },
                        set: { newValue in
                            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.watchAllowSessionDismiss)
                            let autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
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

                // Section Sécurité
                Section {
                    NavigationLink {
                        EmergencyContactsView()
                    } label: {
                        HStack {
                            Image(systemName: "sos.circle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Contacts d'urgence".localized)
                                Text("Configurez vos contacts SOS".localized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Sécurité".localized)
                } footer: {
                    Text("En cas d'urgence pendant un vol, vous pourrez envoyer votre position GPS à vos contacts.".localized)
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

                Section {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.developerModeEnabled) },
                        set: { newValue in
                            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.developerModeEnabled)
                            // Synchroniser avec la Watch
                            let autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
                            let allowDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
                            watchManager.sendWatchSettings(autoWaterLock: autoWaterLock, allowSessionDismiss: allowDismiss, developerMode: newValue)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Mode développeur"))
                            Text(String(localized: "Active les logs détaillés (peut ralentir l'app)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { DemoDataService.shared.isDemoModeEnabled },
                        set: { DemoDataService.shared.isDemoModeEnabled = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(String(localized: "Mode démo Live"))
                                Image(systemName: "airplane.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Text(String(localized: "Affiche des pilotes simulés sur la carte Live"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        generateTestData()
                    } label: {
                        Label(String(localized: "Générer des données de test"), systemImage: "wand.and.stars")
                    }

                    Button {
                        reuploadAllFlights()
                    } label: {
                        Label(String(localized: "Réuploader tous les vols"), systemImage: "arrow.triangle.2.circlepath.icloud")
                    }

                    Button {
                        recalculateAllBadges()
                    } label: {
                        Label(String(localized: "Recalculer tous les badges"), systemImage: "medal.fill")
                    }

                    Button(role: .destructive) {
                        deleteAllData()
                    } label: {
                        Label(String(localized: "Supprimer toutes les données"), systemImage: "trash")
                    }
                } header: {
                    Text(String(localized: "Développeur"))
                }

                Section("À propos") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
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
            do {
                try modelContext.save()
                importMessage = "✅ \(wings.count) voiles et 20 vols créés"
                showingImportSuccess = true
            } catch {
                logError("Failed to save demo data: \(error.localizedDescription)", category: .dataController)
                importMessage = "❌ Erreur lors de la création des données démo"
                showingImportSuccess = true
            }
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

                    logInfo("Parsed \(data.flights.count) flights from file", category: .dataController)

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
        let imagesFolder = documentsPath.appendingPathComponent("SOARX_Images_\(timestamp)")
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
        let wingsFileName = "SOARX_Wings_\(timestamp).csv"
        let flightsFileName = "SOARX_Flights_\(timestamp).csv"
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

    /// Réupload tous les vols vers le cloud (force sync)
    private func reuploadAllFlights() {
        isImporting = true
        importMessage = "Réupload en cours..."

        Task {
            do {
                // Marquer tous les vols comme non synchronisés pour forcer le réupload
                for flight in flights {
                    flight.needsSync = true
                }
                try modelContext.save()

                // Lancer la synchronisation complète
                let result = try await FlightSyncService.shared.performFullSync(modelContext: modelContext)

                await MainActor.run {
                    isImporting = false
                    importMessage = "✅ \(result.uploaded) vols réuploadés\n\(result.downloaded) vols téléchargés"
                    if !result.errors.isEmpty {
                        importMessage += "\n⚠️ Erreurs: \(result.errors.joined(separator: ", "))"
                    }
                    showingImportSuccess = true
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importMessage = "❌ Erreur: \(error.localizedDescription)"
                    showingImportSuccess = true
                }
            }
        }
    }

    /// Recalcule tous les badges en fonction des vols actuels
    private func recalculateAllBadges() {
        isImporting = true
        importMessage = "Calcul des badges..."

        Task {
            guard let profile = UserService.shared.currentUserProfile else {
                await MainActor.run {
                    isImporting = false
                    importMessage = "❌ Vous devez être connecté pour recalculer les badges"
                    showingImportSuccess = true
                }
                return
            }

            // Calculer les stats à partir de tous les vols
            let uniqueSpots = Set(flights.compactMap { $0.spotName }).count
            let maxAltitude = flights.compactMap { $0.maxAltitude }.max() ?? 0
            let maxDistance = flights.compactMap { $0.totalDistance }.max() ?? 0
            let longestFlight = flights.map { $0.durationSeconds }.max() ?? 0

            do {
                // Charger tous les badges disponibles
                await BadgeService.shared.loadAllBadges()

                // Charger les badges déjà obtenus
                await BadgeService.shared.loadUserBadges(userId: profile.id)

                // Vérifier et attribuer les badges manquants
                let newBadges = try await BadgeService.shared.checkAndAwardBadges(
                    profile: profile,
                    uniqueSpots: uniqueSpots,
                    maxAltitude: maxAltitude,
                    maxDistance: maxDistance,
                    longestFlightSeconds: longestFlight
                )

                await MainActor.run {
                    isImporting = false
                    if newBadges.isEmpty {
                        importMessage = "✅ Badges vérifiés - Aucun nouveau badge obtenu"
                    } else {
                        let badgeNames = newBadges.map { $0.localizedName }.joined(separator: ", ")
                        importMessage = "🎉 \(newBadges.count) nouveau(x) badge(s) obtenu(s) !\n\(badgeNames)"
                    }
                    showingImportSuccess = true
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importMessage = "❌ Erreur: \(error.localizedDescription)"
                    showingImportSuccess = true
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
