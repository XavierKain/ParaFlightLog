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

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(\.modelContext) private var modelContext
    @Query private var wings: [Wing]
    @Query private var flights: [Flight]

    @AppStorage(UserDefaultsKeys.phoneOnlyMode) private var phoneOnlyMode = false
    @AppStorage(UserDefaultsKeys.varioEnabled) private var varioEnabled = false
    // Default TRUE (matches WeatherService.autoSnapshotEnabled's fallback)
    @AppStorage(UserDefaultsKeys.autoWeatherSnapshot) private var autoWeatherSnapshot = true
    @AppStorage(UserDefaultsKeys.developerModeEnabled) private var developerModeEnabled = false
    @AppStorage(UserDefaultsKeys.simulateFlightEnabled) private var simulateFlightEnabled = false
    // Reactive so changes made on the Watch (pushed back via WCSession) show live here.
    @AppStorage(UserDefaultsKeys.watchAutoWaterLock) private var watchAutoWaterLock = false
    @AppStorage(UserDefaultsKeys.watchAllowSessionDismiss) private var watchAllowSessionDismiss = true

    @State private var showingImportResult = false
    @State private var importMessage = ""
    @State private var showingDocumentPicker = false
    @State private var isImporting = false

    // IGC/GPX track import
    @State private var showingTrackFilePicker = false
    @State private var pendingTrackImports: [PendingTrackImport] = []
    @State private var trackParseFailures: [String] = []
    @State private var showingTrackImportSheet = false
    /// Import result handed back by TrackImportSheet, presented as an alert
    /// from the sheet's onDismiss (same runloop as dismiss() gets swallowed).
    @State private var pendingTrackResultMessage: String?

    var body: some View {
        NavigationStack {
            List {
                trackingSection
                appleWatchSection
                wingsSection
                dataSection
                accountSection
                CommunitySettingsSection(flights: flights)
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
            .fileImporter(
                isPresented: $showingTrackFilePicker,
                allowedContentTypes: Self.trackImportContentTypes,
                allowsMultipleSelection: true
            ) { result in
                handleTrackFileSelection(result)
            }
            .sheet(isPresented: $showingTrackImportSheet, onDismiss: {
                // Release the parsed tracks (they can hold hours of GPS
                // points) instead of retaining them until the next import.
                pendingTrackImports = []
                trackParseFailures = []
                // Present the result alert only once the sheet is gone;
                // setting it in the same runloop as dismiss() can swallow
                // it. Same one-runloop-hop workaround as the sheet
                // presentation in finishTrackFileSelection.
                if let message = pendingTrackResultMessage {
                    pendingTrackResultMessage = nil
                    Task { @MainActor in
                        importMessage = message
                        showingImportResult = true
                    }
                }
            }) {
                TrackImportSheet(files: pendingTrackImports, parseFailures: trackParseFailures) { message in
                    pendingTrackResultMessage = message
                }
            }
            .disabled(isImporting)
            // Progress is shown as an overlay (not an alert) so the result
            // alert below can always be presented once the import finishes.
            .overlay {
                if isImporting {
                    ZStack {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Importing data...")
                                .font(.subheadline)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .alert("Result", isPresented: $showingImportResult) {
                Button("OK") { }
            } message: {
                Text(importMessage)
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

            Toggle(isOn: $autoWeatherSnapshot) {
                Text("Record weather at takeoff")
            }
        } header: {
            Text("Tracking")
        } footer: {
            Text("Use iPhone as tracker adds a Timer tab so you can track flights without an Apple Watch. The vario plays climb beeps and sink alerts while a flight is running. Record weather at takeoff saves wind and temperature (Open-Meteo) with each new flight.")
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

            Toggle(isOn: $watchAutoWaterLock) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic Water Lock")
                    Text("Enables Water Lock at takeoff to prevent accidental taps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: watchAutoWaterLock) { _, newValue in
                // Skip the echo when this change just arrived FROM the Watch
                guard !watchManager.isApplyingRemoteSettings else { return }
                watchManager.sendWatchSettings(autoWaterLock: newValue, allowSessionDismiss: watchAllowSessionDismiss)
            }

            Toggle(isOn: $watchAllowSessionDismiss) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow flight cancellation")
                    Text("Lets you cancel an ongoing flight without saving it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: watchAllowSessionDismiss) { _, newValue in
                guard !watchManager.isApplyingRemoteSettings else { return }
                watchManager.sendWatchSettings(autoWaterLock: watchAutoWaterLock, allowSessionDismiss: newValue)
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
                BackupExportView(wings: wings, flights: flights, spots: dataController.fetchSpots())
            } label: {
                Label("Export Backup", systemImage: "archivebox")
            }

            Button {
                showingDocumentPicker = true
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down")
            }

            Button {
                showingTrackFilePicker = true
            } label: {
                Label("Import IGC / GPX Track", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
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
                Text("Backups use the .paraflightlog format and include wings, flights, photos and GPS tracks. Import IGC / GPX Track turns tracks recorded by other vario apps into flights.")
            } else {
                Text("Enable iCloud in Settings to sync across devices. Backups use the .paraflightlog format and include wings, flights, photos and GPS tracks. Import IGC / GPX Track turns tracks recorded by other vario apps into flights.")
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
                                // Snapshot models on the main actor (SwiftData requirement).
                                // Cloud backups are stored in an Appwrite database
                                // column (CloudBackupService), so this must be the small
                                // single-file variant WITHOUT base64 wing photos.
                                let allWings = dataController.fetchWings(includeArchived: true)
                                let allFlights = dataController.fetchFlights()
                                let allSpots = dataController.fetchSpots()
                                BackupManager.exportCloudBackup(wings: allWings, flights: allFlights, spots: allSpots, includeImages: false) { result in
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
                    // LazyView: TimerView's init builds FlightSimulator +
                    // PhoneVarioService (barometer/audio). Without laziness that
                    // ran the moment this row appeared — i.e. the first toggle of
                    // Developer mode froze the UI.
                    LazyView { TimerView(simulated: true) }
                } label: {
                    Label("Simulate a Flight (Live)", systemImage: "play.circle")
                }

                Toggle(isOn: $simulateFlightEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Simulate flight on Watch", systemImage: "applewatch.radiowaves.left.and.right")
                        Text("Starting a flight on the Watch shows a fake feed (altitude, speed, G) so you can check readability without moving.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: simulateFlightEnabled) { _, newValue in
                    guard !watchManager.isApplyingRemoteSettings else { return }
                    let autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
                    let allowDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
                    watchManager.sendWatchSettings(autoWaterLock: autoWaterLock, allowSessionDismiss: allowDismiss, developerMode: developerModeEnabled, simulateFlight: newValue)
                }

                Button {
                    generateTestData()
                } label: {
                    Label("Generate Test Flights", systemImage: "wand.and.stars")
                }

                Button {
                    // ContentView watches this flag and re-presents the onboarding
                    UserDefaults.standard.set(false, forKey: UserDefaultsKeys.hasCompletedOnboarding)
                } label: {
                    Label("Replay Onboarding", systemImage: "sparkles.tv")
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

    // MARK: - IGC/GPX Track Import

    /// Content types accepted by the track file picker: XML/GPX plus the
    /// custom "igc" extension (dynamic UTType), with broad text/data
    /// fallbacks so IGC files served with a generic type stay selectable.
    private static var trackImportContentTypes: [UTType] {
        var types: [UTType] = [.xml]
        if let gpxType = UTType(filenameExtension: "gpx") {
            types.append(gpxType)
        }
        if let igcType = UTType(filenameExtension: "igc") {
            types.append(igcType)
        } else {
            types.append(.plainText)
            types.append(.data)
        }
        return types
    }

    /// Reads and parses every picked IGC/GPX file off the main thread
    /// (behind the same isImporting overlay as the backup import — IGC/GPX
    /// files can hold hours of track points), then opens the confirmation
    /// sheet with the parsed previews. Files that fail to parse are listed
    /// in the sheet and counted as skipped.
    private func handleTrackFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importMessage = "Could not open the selected files: \(error.localizedDescription)"
            showingImportResult = true

        case .success(let urls):
            isImporting = true
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    Self.parseTrackFiles(at: urls)
                }.value
                isImporting = false
                finishTrackFileSelection(parsed: outcome.parsed, failures: outcome.failures)
            }
        }
    }

    /// Blocking read + parse of the picked track files (security-scoped
    /// access handled here). Pure work: runs detached from the main actor.
    private nonisolated static func parseTrackFiles(
        at urls: [URL]
    ) -> (parsed: [PendingTrackImport], failures: [String]) {
        var parsed: [PendingTrackImport] = []
        var failures: [String] = []

        for url in urls {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                let track = try TrackImporter.parse(data: data, filename: url.lastPathComponent)
                parsed.append(PendingTrackImport(filename: url.lastPathComponent, track: track))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (parsed, failures)
    }

    /// Back on the main actor: shows either the confirmation sheet or the
    /// nothing-imported alert for the parse results.
    private func finishTrackFileSelection(parsed: [PendingTrackImport], failures: [String]) {
        for failure in failures {
            logWarning("Track parse failed for \(failure)", category: .dataImport)
        }

        if parsed.isEmpty {
            importMessage = failures.isEmpty
                ? "No files were selected."
                : "0 imported, \(failures.count) skipped (duplicates/errors).\n" + failures.joined(separator: "\n")
            showingImportResult = true
        } else {
            pendingTrackImports = parsed.sorted { $0.track.startDate < $1.track.startDate }
            trackParseFailures = failures
            // One runloop hop: presenting a sheet in the same cycle the
            // file picker dismisses can silently fail.
            Task { @MainActor in
                showingTrackImportSheet = true
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

// MARK: - TrackImportSheet (IGC/GPX import confirmation)

/// Confirmation sheet for the IGC/GPX track import: one preview line per
/// parsed file plus a shared wing (required) and flight type (optional)
/// applied to all of them. Import creates the flights and reports
/// "N imported, M skipped (duplicates/errors)" back to the Settings alert.
private struct TrackImportSheet: View {
    let files: [PendingTrackImport]
    let parseFailures: [String]
    /// Called with the result message; the presenting view shows the alert.
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(DataController.self) private var dataController
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    @State private var selectedWing: Wing?
    @State private var selectedType: FlightType?
    @State private var hasAppeared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("^[\(files.count) flight](inflect: true) to import") {
                    ForEach(files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.filename)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(preview(for: file.track))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Wing") {
                    if wings.isEmpty {
                        Text("Add a wing in the Wings tab first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Wing", selection: $selectedWing) {
                            ForEach(wings) { wing in
                                Text(wing.name).tag(wing as Wing?)
                            }
                        }
                    }
                }

                Section("Flight Type") {
                    Picker("Flight Type", selection: $selectedType) {
                        Text("None").tag(FlightType?.none)
                        ForEach(FlightType.allCases) { type in
                            Label(type.rawValue, systemImage: type.symbolName)
                                .tag(type as FlightType?)
                        }
                    }
                }

                if !parseFailures.isEmpty {
                    Section("Skipped Files") {
                        ForEach(parseFailures, id: \.self) { failure in
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Import Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importAll()
                    }
                    .disabled(selectedWing == nil)
                }
            }
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                // Pre-select the last used wing (same behavior as AddFlightView)
                if let idString = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastUsedWingId),
                   let id = UUID(uuidString: idString),
                   let lastWing = wings.first(where: { $0.id == id }) {
                    selectedWing = lastWing
                } else {
                    selectedWing = wings.first
                }
            }
        }
    }

    /// "Jul 4, 2026, 11:20 · 1h23 · 12.4 km · max 1850 m"
    private func preview(for track: ParsedTrack) -> String {
        var parts: [String] = [
            track.startDate.formatted(date: .abbreviated, time: .shortened),
            durationText(track.durationSeconds)
        ]
        if let distance = track.totalDistance, distance > 0 {
            parts.append(String(format: "%.1f km", distance / 1000))
        }
        if let maxAltitude = track.maxAltitude {
            parts.append(String(format: "max %.0f m", maxAltitude))
        }
        return parts.joined(separator: " · ")
    }

    /// Same "1h23" / "45min" style as Flight.durationFormatted.
    private func durationText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(minutes)min"
    }

    private func importAll() {
        guard let wing = selectedWing else { return }

        var imported = 0
        var skippedDetails: [String] = parseFailures

        for file in files {
            do {
                try TrackImporter.createFlight(
                    from: file.track,
                    wing: wing,
                    flightType: selectedType,
                    dataController: dataController
                )
                imported += 1
            } catch {
                skippedDetails.append("\(file.filename): \(error.localizedDescription)")
            }
        }

        UserDefaults.standard.set(wing.id.uuidString, forKey: UserDefaultsKeys.lastUsedWingId)

        var message = "\(imported) imported, \(skippedDetails.count) skipped (duplicates/errors)."
        if !skippedDetails.isEmpty {
            message += "\n" + skippedDetails.joined(separator: "\n")
        }
        onFinish(message)
        dismiss()
    }
}

// MARK: - CommunitySettingsSection (opt-in sharing, roadmap Step C)

/// The "Community" section of Settings: master opt-in, public pilot name,
/// live presence opt-in, history backfill and the withdraw-everything
/// button. Settings are bound via @AppStorage (NOT by observing
/// CommunityService — its UserDefaults-backed properties don't emit
/// @Observable changes).
private struct CommunitySettingsSection: View {
    let flights: [Flight]

    @Environment(DataController.self) private var dataController

    private var auth: AuthService { .shared }

    @AppStorage(UserDefaultsKeys.communitySharingEnabled) private var sharingEnabled = false
    @AppStorage(UserDefaultsKeys.presenceEnabled) private var presenceEnabled = false
    @AppStorage(UserDefaultsKeys.pilotDisplayName) private var pilotDisplayName = ""

    /// Shown after trying to enable sharing while signed out.
    @State private var showSignInHint = false
    @State private var showingShareConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var isWorking = false
    @State private var progressDone = 0
    @State private var progressTotal = 0
    @State private var resultMessage: String?
    @State private var showingResult = false

    /// Flights that CAN be shared: those with a spot that has coordinates
    /// (same rule as CommunityService.shareHistory).
    private var eligibleCount: Int {
        flights.filter { flight in
            guard let spot = flight.spot else { return false }
            return CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude) != nil
        }.count
    }

    var body: some View {
        Section {
            Toggle(isOn: $sharingEnabled) {
                Text("Share my flights")
            }
            .onChange(of: sharingEnabled) { _, newValue in
                guard newValue else { return }
                Task { await validateSharingEnabled() }
            }
            // The result alert lives on this always-visible row so it can be
            // presented whatever the toggle states are.
            .alert("Community", isPresented: $showingResult) {
                Button("OK") { }
            } message: {
                Text(resultMessage ?? "")
            }

            if showSignInHint {
                Label("Sign in first (Account section above)", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if sharingEnabled {
                LabeledContent("Pilot name (public)") {
                    TextField("A pilot", text: $pilotDisplayName)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }

                Toggle(isOn: $presenceEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show me as flying now")
                        Text("Pilots checking your spot see \"🪂 flying now\" for up to 2 hours after takeoff. Anonymous — your name is never shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: presenceEnabled) { _, newValue in
                    guard newValue else { return }
                    Task { await validatePresenceEnabled() }
                }

                if auth.state.isSignedIn {
                    Button {
                        showingShareConfirm = true
                    } label: {
                        if isWorking && progressTotal > 0 {
                            HStack {
                                Text("Sharing \(progressDone) / \(progressTotal)…")
                                Spacer()
                                ProgressView()
                            }
                        } else {
                            Label("Share my flight history", systemImage: "square.and.arrow.up")
                        }
                    }
                    .confirmationDialog(
                        "Share your flight history?",
                        isPresented: $showingShareConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Share ^[\(eligibleCount) flight](inflect: true)") {
                            shareAllHistory()
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("For each flight at a located spot, this shares the spot, date, duration and flight type — never your GPS tracks or notes. Flights without a located spot are skipped.")
                    }
                }
            }

            // Withdrawal must stay available even after sharing is turned off.
            if auth.state.isSignedIn {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete all my shared data", systemImage: "trash")
                }
                .confirmationDialog(
                    "Delete all your shared data?",
                    isPresented: $showingDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete Shared Data", role: .destructive) {
                        deleteSharedData()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Removes every flight you shared with the community, and your live presence. Your local logbook is not affected.")
                }
            }
        } header: {
            Text("Community")
                // On the header (a plain view), NOT on the Section: modifiers
                // on a Section inside a List can break its section rendering.
                .task {
                    if auth.state == .unknown {
                        await auth.restoreSession()
                    }
                }
        } footer: {
            Text("Off by default. Sharing sends flight summaries only — spot, date, duration and type. GPS tracks and notes never leave your device.")
        }
        .disabled(isWorking)
    }

    // MARK: Actions

    /// Sharing requires an account: if the user enables the toggle while
    /// signed out, flip it back off and point at the Account section above
    /// (no auto-navigation).
    private func validateSharingEnabled() async {
        if auth.state == .unknown {
            await auth.restoreSession()
        }
        if auth.state.isSignedIn {
            showSignInHint = false
        } else {
            sharingEnabled = false
            showSignInHint = true
        }
    }

    /// Presence needs an account too (the heartbeat is written as the
    /// signed-in user): same flip-back + hint pattern as the sharing toggle.
    private func validatePresenceEnabled() async {
        if auth.state == .unknown {
            await auth.restoreSession()
        }
        if auth.state.isSignedIn {
            showSignInHint = false
        } else {
            presenceEnabled = false
            showSignInHint = true
        }
    }

    private func shareAllHistory() {
        isWorking = true
        progressDone = 0
        progressTotal = 0

        Task { @MainActor in
            do {
                let shared = try await CommunityService.shared.shareHistory(flights: flights) { done, total in
                    progressDone = done
                    progressTotal = total
                }
                // shareHistory sets communitySpotKey on the shared spots.
                dataController.saveContext()
                resultMessage = shared == 0
                    ? "No flights to share. Only flights at a spot with coordinates can be shared."
                    : (shared == 1 ? "1 flight shared with the community." : "\(shared) flights shared with the community.")
            } catch {
                // Keys set before the failure are still valid — persist them.
                dataController.saveContext()
                resultMessage = progressDone == 0
                    ? "Sharing failed: \(error.localizedDescription)"
                    : "Sharing stopped after \(progressDone) of \(progressTotal) flights: \(error.localizedDescription)"
            }
            showingResult = true
            isWorking = false
            progressTotal = 0
        }
    }

    private func deleteSharedData() {
        isWorking = true

        Task { @MainActor in
            do {
                try await CommunityService.shared.unshareAllMyFlights()
                resultMessage = "All your shared flights and your live presence have been deleted."
            } catch {
                resultMessage = "Could not delete your shared data: \(error.localizedDescription)"
            }
            showingResult = true
            isWorking = false
        }
    }
}

