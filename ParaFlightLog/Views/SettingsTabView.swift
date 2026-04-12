//
//  SettingsTabView.swift
//  ParaFlightLog
//
//  Onglet Settings dédié avec 5 catégories organisées :
//  1. Equipment & Flight
//  2. Apple Watch
//  3. Account & Sync
//  4. Data & Backup
//  5. App Preferences
//

import SwiftUI
import SwiftData

struct SettingsTabView: View {
    @Environment(UserService.self) private var userService
    @Environment(AuthService.self) private var authService
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(DataController.self) private var dataController
    @Environment(\.dismiss) private var dismiss

    // Pour les wings et flights (nécessaires pour BackupExportView)
    @Query private var wings: [Wing]
    @Query private var flights: [Flight]

    // État pour l'opération de développeur en cours
    @State private var isDevOperationRunning = false

    // État pour la synchronisation cloud
    @State private var syncStatus: SyncStatus = .idle

    var body: some View {
        NavigationStack {
            List {
                // 1. EQUIPMENT & FLIGHT
                Section("Equipment & Flight".localized) {
                    NavigationLink {
                        WingsView()
                    } label: {
                        Label("Mes voiles".localized, systemImage: "wind")
                    }

                    NavigationLink {
                        TimerView()
                    } label: {
                        Label("Chronomètre".localized, systemImage: "timer")
                    }

                    NavigationLink {
                        SpotsManagementView()
                    } label: {
                        Label("Gérer les spots".localized, systemImage: "mappin.and.ellipse")
                    }

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
                }

                // 2. APPLE WATCH
                Section("Apple Watch") {
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Apple Watch".localized, systemImage: "applewatch")
                    }
                }

                // 3. ACCOUNT & SYNC (si authentifié)
                if authService.isAuthenticated {
                    Section("Account & Sync".localized) {
                        if let profile = userService.currentUserProfile {
                            NavigationLink {
                                EditProfileView(profile: profile) { updatedProfile in
                                    Task {
                                        try? await userService.updateProfile(
                                            displayName: updatedProfile.displayName,
                                            bio: updatedProfile.bio,
                                            username: updatedProfile.username,
                                            homeLocationLat: updatedProfile.homeLocationLat,
                                            homeLocationLon: updatedProfile.homeLocationLon,
                                            homeLocationName: updatedProfile.homeLocationName,
                                            pilotWeight: updatedProfile.pilotWeight
                                        )
                                    }
                                }
                            } label: {
                                Label("Modifier le profil".localized, systemImage: "person.crop.circle")
                            }
                        }

                        NavigationLink {
                            NotificationsView()
                        } label: {
                            HStack {
                                Label("Notifications".localized, systemImage: "bell.fill")
                                Spacer()
                                if NotificationService.shared.unreadCount > 0 {
                                    Text("\(NotificationService.shared.unreadCount)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(.red)
                                        .clipShape(Capsule())
                                }
                            }
                        }

                        Button(role: .destructive) {
                            Task {
                                try? await authService.signOut()
                            }
                        } label: {
                            Label("Se déconnecter".localized, systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else if case .skipped = authService.authState {
                    // Mode hors-ligne : proposer de se connecter
                    Section("Account & Sync".localized) {
                        VStack(spacing: 12) {
                            Text("Mode hors-ligne".localized)
                                .font(.headline)
                            Text("Connectez-vous pour synchroniser vos vols et accéder aux fonctionnalités sociales.".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)

                        Button {
                            Task {
                                await authService.forceLogout()
                            }
                        } label: {
                            Label("Se connecter".localized, systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                }

                // 4. DATA & BACKUP
                Section("Data & Backup".localized) {
                    // Cloud synchronisation (si authentifié)
                    if authService.isAuthenticated {
                        SyncStatusView(status: syncStatus)

                        Button {
                            Task {
                                await performSync()
                            }
                        } label: {
                            HStack {
                                Label("Synchroniser maintenant".localized, systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if case .syncing = syncStatus {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(syncStatus.isSyncing)

                        // Vols en attente
                        let pendingCount = flights.filter { $0.needsSync }.count
                        if pendingCount > 0 {
                            HStack {
                                Label("\(pendingCount) vol(s) en attente".localized, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.orange)
                                Spacer()
                            }
                        }

                        if let date = FlightSyncService.shared.lastSyncDate {
                            Text("Dernière sync: \(date.formatted(date: .abbreviated, time: .shortened))".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        BackupExportView(wings: wings, flights: flights)
                    } label: {
                        Label("Exporter backup".localized, systemImage: "archivebox")
                    }

                    NavigationLink {
                        PendingActionsView()
                    } label: {
                        HStack {
                            Label("Synchronisation".localized, systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            OfflineSyncStatusView()
                        }
                    }
                }

                // 5. APP PREFERENCES
                Section("App Preferences".localized) {
                    Picker("Langue".localized, selection: Binding(
                        get: { localizationManager.currentLanguage },
                        set: { localizationManager.currentLanguage = $0 }
                    )) {
                        Text("Système".localized).tag(nil as LocalizationManager.Language?)
                        ForEach(LocalizationManager.Language.allCases, id: \.self) { language in
                            Text("\(language.flag) \(language.displayName)")
                                .tag(language as LocalizationManager.Language?)
                        }
                    }
                    .pickerStyle(.menu)

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
                            Text("Mode développeur".localized)
                            Text("Active les logs détaillés".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Mode démo (seulement si mode développeur actif)
                    if UserDefaults.standard.bool(forKey: UserDefaultsKeys.developerModeEnabled) {
                        Toggle(isOn: Binding(
                            get: { DemoDataService.shared.isDemoModeEnabled },
                            set: { DemoDataService.shared.isDemoModeEnabled = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Mode démo Live".localized)
                                    Image(systemName: "airplane.circle.fill")
                                        .foregroundStyle(.orange)
                                }
                                Text("Affiche des pilotes simulés sur la carte Live".localized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            reuploadAllFlights()
                        } label: {
                            HStack {
                                Label("Réuploader tous les vols".localized, systemImage: "arrow.triangle.2.circlepath.icloud")
                                Spacer()
                                if isDevOperationRunning {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isDevOperationRunning)

                        Button {
                            recalculateAllBadges()
                        } label: {
                            HStack {
                                Label("Recalculer tous les badges".localized, systemImage: "medal.fill")
                                Spacer()
                                if isDevOperationRunning {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isDevOperationRunning)
                    }

                    // Section À propos
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "paraglider.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .foregroundStyle(.blue)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.blue.opacity(0.1))
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text("ParaFlightLog")
                                    .font(.headline)
                                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                   let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                                    Text("Version \(version) (\(build))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Text("Développé avec ❤️ pour la communauté parapente")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Cloud Sync

    private func performSync() async {
        syncStatus = .syncing

        do {
            let modelContext = dataController.modelContext
            let result = try await FlightSyncService.shared.performFullSync(modelContext: modelContext)
            syncStatus = .success(result.uploaded, result.downloaded)

            // Reset après 3 secondes
            try? await Task.sleep(for: .seconds(3))
            syncStatus = .idle
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Developer Operations

    private func reuploadAllFlights() {
        isDevOperationRunning = true
        Task {
            defer {
                Task { @MainActor in
                    isDevOperationRunning = false
                }
            }
            do {
                // Marquer tous les vols comme non synchronisés
                for flight in flights {
                    flight.needsSync = true
                }

                // Utiliser le modelContext du DataController (fiable même si flights est vide)
                let context = dataController.modelContext
                try context.save()
                _ = try await FlightSyncService.shared.performFullSync(modelContext: context)
                logInfo("All flights re-uploaded successfully", category: .sync)
            } catch {
                logError("Failed to re-upload flights: \(error)", category: .sync)
            }
        }
    }

    private func recalculateAllBadges() {
        isDevOperationRunning = true
        Task {
            defer {
                Task { @MainActor in
                    isDevOperationRunning = false
                }
            }

            guard var profile = userService.currentUserProfile else {
                logError("❌ User must be authenticated to recalculate badges", category: .general)
                return
            }

            // Calculer les stats à partir de tous les vols locaux
            let totalFlightsLocal = flights.count
            let totalSecondsLocal = flights.reduce(0) { $0 + $1.durationSeconds }

            profile.totalFlights = totalFlightsLocal
            profile.totalFlightSeconds = totalSecondsLocal

            // Recalculer les badges
            do {
                let badges = try await BadgeService.shared.checkAndAwardBadges(profile: profile)
                logInfo("✅ All badges recalculated: \(badges.count) badges", category: .general)
            } catch {
                logError("❌ Failed to recalculate badges: \(error)", category: .general)
            }
        }
    }
}

#Preview {
    let dataController = DataController()
    return SettingsTabView()
        .environment(UserService.shared)
        .environment(AuthService.shared)
        .environment(LocalizationManager.shared)
        .environment(WatchConnectivityManager.shared)
        .environment(dataController)
        .modelContainer(dataController.modelContainer)
}
