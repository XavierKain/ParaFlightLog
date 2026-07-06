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
                                // Snapshot models on the main actor (SwiftData requirement).
                                // Cloud upload needs a single regular file (Appwrite
                                // InputFile.fromPath), not the folder bundle.
                                let allWings = dataController.fetchWings(includeArchived: true)
                                let allFlights = dataController.fetchFlights()
                                let allSpots = dataController.fetchSpots()
                                BackupManager.exportCloudBackup(wings: allWings, flights: allFlights, spots: allSpots) { result in
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

