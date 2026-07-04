//
//  SettingsViews.swift
//  ParaFlightLog
//
//  Settings-related views: settings, spot management, backup export/import
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

// MARK: - SpotsManagementView

/// View to manage the spots detected in flights
struct SpotsManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]

    @State private var selectedSpot: SpotInfo?
    @State private var showingMapPicker = false

    /// Groups the info of a single spot
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

    /// Extracts all unique spots from the flights
    var spots: [SpotInfo] {
        var spotDict: [String: SpotInfo] = [:]

        for flight in flights {
            guard let spotName = flight.spotName, !spotName.isEmpty else { continue }

            if var existing = spotDict[spotName] {
                existing.flightCount += 1
                // Update the coordinates if this flight has some
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
                    "No Spots",
                    systemImage: "mappin.slash",
                    description: Text("Spots will appear here once you have recorded flights")
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
                    Text("Add GPS coordinates to a spot to apply them automatically to all associated flights")
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

    /// Updates the coordinates of all flights with this spot name
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

    /// Correctly pluralized spot count text
    private func spotsCountText(_ count: Int) -> String {
        count == 1 ? "1 spot detected" : "\(count) spots detected"
    }
}

/// Row displaying a spot
struct SpotRowView: View {
    let spot: SpotsManagementView.SpotInfo
    let onMapTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
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

            // Add/edit coordinates button
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

    /// Correctly pluralized flight count text
    private func flightsCountText(_ count: Int) -> String {
        count == 1 ? "1 flight" : "\(count) flights"
    }
}

/// Correctly pluralized "flights will be updated" text
private func flightsWillBeUpdatedText(_ count: Int) -> String {
    count == 1 ? "📍 1 flight will be updated" : "📍 \(count) flights will be updated"
}

/// Map picker for a spot
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

        // Initial position
        if let lat = spot.latitude, let lon = spot.longitude {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )))
            _markerCoordinate = State(initialValue: coord)
        } else {
            // France by default
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
                        // Search bar
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search for a place...", text: $searchText)
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

                        Text("Tap the map to place the marker")
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

                        // How many flights will be updated
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
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let coord = markerCoordinate {
                            onSave(coord)
                        }
                        dismiss()
                    }
                    .disabled(markerCoordinate == nil)
                }
            }
            .onAppear {
                // Search automatically when there are no coordinates yet
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

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(\.modelContext) private var modelContext
    @Query private var wings: [Wing]
    @Query private var flights: [Flight]

    @AppStorage(UserDefaultsKeys.phoneOnlyMode) private var phoneOnlyMode = false
    @AppStorage(UserDefaultsKeys.varioEnabled) private var varioEnabled = false
    @AppStorage(UserDefaultsKeys.developerModeEnabled) private var developerModeEnabled = false

    @State private var showingImportResult = false
    @State private var importMessage = ""
    @State private var showingDocumentPicker = false
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            List {
                trackingSection
                appleWatchSection
                wingsSection
                dataSection
                accountSection
                comingSoonSection
                developerSection
                aboutSection
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker { url in
                    importBackupFile(from: url)
                }
            }
            .alert(isImporting ? "Importing..." : "Result", isPresented: Binding(
                get: { showingImportResult || isImporting },
                set: { if !$0 { showingImportResult = false; isImporting = false } }
            )) {
                if !isImporting {
                    Button("OK") { }
                }
            } message: {
                if isImporting {
                    Text("Importing data...")
                } else {
                    Text(importMessage)
                }
            }
        }
    }

    // MARK: - Sections

    private var trackingSection: some View {
        Section {
            Toggle(isOn: $phoneOnlyMode) {
                Text("Use iPhone as tracker")
            }

            NavigationLink {
                TimerView()
            } label: {
                Label("Flight Timer", systemImage: "timer")
            }

            Toggle(isOn: $varioEnabled) {
                Text("Vario sound & haptics")
            }
        } header: {
            Text("Tracking")
        } footer: {
            Text("Use iPhone as tracker adds a Timer tab so you can track flights without an Apple Watch. The vario plays climb beeps and sink alerts while a flight is running.")
        }
    }

    private var appleWatchSection: some View {
        Section {
            HStack {
                Text("Watch App")
                Spacer()
                if watchManager.isWatchAppInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("Not installed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            HStack {
                Text("Reachable")
                Spacer()
                if watchManager.isWatchReachable {
                    Label("Yes", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("No", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            HStack {
                Text("Wings")
                Spacer()
                Text("\(wings.count)")
                    .foregroundStyle(.secondary)
            }

            Button {
                logInfo("Manual sync button pressed - \(wings.count) wings available", category: .watchSync)
                watchManager.sendWingsToWatch()
                importMessage = wings.count == 1 ? "1 wing sent to the Watch" : "\(wings.count) wings sent to the Watch"
                showingImportResult = true
            } label: {
                Label("Sync Wings", systemImage: "arrow.triangle.2.circlepath")
            }

            Toggle(isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock) },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.watchAutoWaterLock)
                    let allowDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
                    watchManager.sendWatchSettings(autoWaterLock: newValue, allowSessionDismiss: allowDismiss)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic Water Lock")
                    Text("Enables Water Lock at takeoff to prevent accidental taps")
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
                    Text("Allow flight cancellation")
                    Text("Lets you cancel an ongoing flight without saving it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("These settings are synced automatically with your Apple Watch.")
        }
    }

    private var wingsSection: some View {
        Section("Wings") {
            NavigationLink {
                ArchivedWingsView()
            } label: {
                Label("Archived Wings", systemImage: "archivebox")
            }
        }
    }

    private var dataSection: some View {
        Section {
            HStack {
                Text("iCloud Sync")
                Spacer()
                if dataController.isCloudSyncActive {
                    Label("Active", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("Off", systemImage: "icloud.slash")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            NavigationLink {
                BackupExportView(wings: wings, flights: flights)
            } label: {
                Label("Export Backup", systemImage: "archivebox")
            }

            Button {
                showingDocumentPicker = true
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down")
            }

            NavigationLink {
                SpotsManagementView()
            } label: {
                Label("Manage Spots", systemImage: "mappin.and.ellipse")
            }
        } header: {
            Text("Data")
        } footer: {
            if dataController.isCloudSyncActive {
                Text("Backups use the .paraflightlog format and include wings, flights, photos and GPS tracks.")
            } else {
                Text("Enable iCloud in Settings to sync across devices. Backups use the .paraflightlog format and include wings, flights, photos and GPS tracks.")
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            NavigationLink {
                AccountView(
                    onBackup: {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                            Task { @MainActor in
                                // Snapshot models on the main actor (SwiftData requirement)
                                let allWings = dataController.fetchWings(includeArchived: true)
                                let allFlights = dataController.fetchFlights()
                                BackupManager.exportBackup(wings: allWings, flights: allFlights) { result in
                                    continuation.resume(with: result)
                                }
                            }
                        }
                    },
                    onRestore: { url in
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            Task { @MainActor in
                                BackupManager.importBackup(from: url, dataController: dataController, mode: .merge) { result in
                                    switch result {
                                    case .success(let summary):
                                        logInfo("Cloud restore: \(summary.message)", category: .dataImport)
                                        watchManager.sendWingsToWatch()
                                        continuation.resume()
                                    case .failure(let error):
                                        continuation.resume(throwing: error)
                                    }
                                }
                            }
                        }
                    }
                )
            } label: {
                Label("Account & Cloud Backup", systemImage: "person.icloud")
            }
        }
    }

    private var comingSoonSection: some View {
        Section {
            HStack {
                Label("SoarX Voice — in-flight voice assistant", systemImage: "waveform.circle")
                Spacer()
            }
            .foregroundStyle(.secondary)
        } header: {
            Text("Coming Soon")
        } footer: {
            Text("Talk to your logbook while flying. Coming in a future version.")
        }
    }

    private var developerSection: some View {
        Section {
            Toggle(isOn: $developerModeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer mode")
                    Text("Enables detailed logging (may slow down the app)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: developerModeEnabled) { _, newValue in
                // Sync developer mode with the Watch
                let autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
                let allowDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
                watchManager.sendWatchSettings(autoWaterLock: autoWaterLock, allowSessionDismiss: allowDismiss, developerMode: newValue)
            }

            if developerModeEnabled {
                NavigationLink {
                    TimerView(simulated: true)
                } label: {
                    Label("Simulate a Flight (Live)", systemImage: "play.circle")
                }

                Button {
                    generateTestData()
                } label: {
                    Label("Generate Test Flights", systemImage: "wand.and.stars")
                }

                Button(role: .destructive) {
                    deleteAllData()
                } label: {
                    Label("Delete All Data", systemImage: "trash")
                }
            }
        } header: {
            Text("Developer")
        }
    }

    private var aboutSection: some View {
        Section("About") {
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

    // MARK: - Actions

    private func generateTestData() {
        // Create test wings if none exist
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

        // Create test flights
        let testSpots = ["Chamonix", "Annecy", "Saint-Hilaire", "Passy", "Talloires"]
        let calendar = Calendar.current

        for _ in 0..<20 {
            let daysAgo = Int.random(in: 0...60)
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()

            let startDate = date
            let duration = Int.random(in: 900...7200) // 15 min to 2 h
            let endDate = startDate.addingTimeInterval(TimeInterval(duration))

            let randomWing = wings.randomElement()
            let randomSpot = testSpots.randomElement()

            // Fake coordinates (Annecy/Chamonix area)
            let lat = 45.9 + Double.random(in: -0.2...0.2)
            let lon = 6.1 + Double.random(in: -0.2...0.2)

            let flight = Flight(
                wing: randomWing,
                startDate: startDate,
                endDate: endDate,
                durationSeconds: duration,
                spotName: randomSpot,
                latitude: lat,
                longitude: lon,
                flightType: FlightType.allCases.randomElement()?.rawValue
            )

            modelContext.insert(flight)
        }

        Task { @MainActor in
            do {
                try modelContext.save()
                importMessage = "✅ \(wings.count) wings and 20 flights created"
                showingImportResult = true
            } catch {
                logError("Failed to save demo data: \(error.localizedDescription)", category: .dataController)
                importMessage = "❌ Error while creating demo data"
                showingImportResult = true
            }
        }
    }

    /// Imports a `.paraflightlog` backup bundle (v2 JSON or legacy v1 CSV,
    /// auto-detected by BackupManager).
    private func importBackupFile(from url: URL) {
        isImporting = true

        BackupManager.importBackup(from: url, dataController: dataController, mode: .merge) { result in
            self.isImporting = false

            switch result {
            case .success(let summary):
                self.importMessage = summary.message
                self.showingImportResult = true
                // Sync wings to the Watch after import
                self.watchManager.sendWingsToWatch()
            case .failure(let error):
                self.importMessage = "❌ Import failed:\n\(error.localizedDescription)"
                self.showingImportResult = true
            }
        }
    }

    private func deleteAllData() {
        // Delete all flights and wings
        do {
            try modelContext.delete(model: Flight.self)
            try modelContext.delete(model: Wing.self)
            try modelContext.save()
            importMessage = "✅ All data has been deleted"
            showingImportResult = true
        } catch {
            importMessage = "❌ Error: \(error.localizedDescription)"
            showingImportResult = true
        }
    }
}

// MARK: - BackupExportView (dedicated export screen)

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

            // Icon and status
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

            // Status text
            Group {
                switch exportStatus {
                case .idle:
                    Text("Ready to export")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(wings.count) wings • \(flights.count) flights")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .exporting:
                    Text("Creating backup...")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Please wait")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .completed:
                    Text("Backup created!")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Ready to share")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .failed:
                    Text("Error")
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

            // Action buttons
            VStack(spacing: 16) {
                if exportStatus == .idle {
                    Button {
                        startExport()
                    } label: {
                        Label("Create Backup", systemImage: "arrow.down.doc")
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
                        Label("Share / Save", systemImage: "square.and.arrow.up")
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
                        Text("Back")
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

        BackupManager.exportBackup(wings: Array(wings), flights: Array(flights)) { result in
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

        // iPad support
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        rootViewController.present(activityVC, animated: true)
    }
}

// MARK: - DocumentPicker (backup import)

struct DocumentPicker: UIViewControllerRepresentable {
    let onDocumentPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .paraflightlog backups are folder bundles (v2 JSON or legacy v1 CSV)
        var contentTypes: [UTType] = [
            .folder,
            .package
        ]
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

// MARK: - ShareSheet (share files/folders)

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
