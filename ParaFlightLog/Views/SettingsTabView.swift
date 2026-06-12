//
//  SettingsTabView.swift
//  ParaFlightLog
//
//  Onglet Settings dédié avec 5 catégories organisées :
//  1. Pilote (profil local)
//  2. Equipment & Flight
//  3. Apple Watch
//  4. Data & Backup
//  5. App Preferences
//

import SwiftUI
import SwiftData

struct SettingsTabView: View {
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(DataController.self) private var dataController
    @Environment(\.dismiss) private var dismiss

    // Profil pilote local (remplace l'ancien profil cloud)
    @AppStorage("pilotName") private var pilotName: String = ""

    // Pour les wings et flights (nécessaires pour BackupExportView)
    @Query private var wings: [Wing]
    @Query private var flights: [Flight]

    // État pour l'import de backup / Excel / CSV
    @State private var showingDocumentPicker = false
    @State private var isImporting = false
    @State private var importMessage = ""
    @State private var showingImportResult = false

    var body: some View {
        NavigationStack {
            List {
                // 1. PILOTE (profil local, stocké en UserDefaults)
                Section("Pilote".localized) {
                    HStack {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.blue)
                        TextField("Nom du pilote".localized, text: $pilotName)
                            .textContentType(.name)
                            .autocorrectionDisabled()
                    }
                }

                // 2. EQUIPMENT & FLIGHT
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

                // 3. APPLE WATCH
                Section("Apple Watch") {
                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Apple Watch".localized, systemImage: "applewatch")
                    }
                }

                // 4. DATA & BACKUP
                Section("Data & Backup".localized) {
                    NavigationLink {
                        BackupExportView(wings: wings, flights: flights)
                    } label: {
                        Label("Exporter backup".localized, systemImage: "archivebox")
                    }

                    Button {
                        showingDocumentPicker = true
                    } label: {
                        Label("Importer backup ou Excel".localized, systemImage: "square.and.arrow.down")
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
                                Text("SoarX")
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
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker { url in
                    importFile(from: url)
                }
            }
            .alert(isImporting ? "Import en cours...".localized : "Résultat".localized, isPresented: Binding(
                get: { showingImportResult || isImporting },
                set: { if !$0 { showingImportResult = false; isImporting = false } }
            )) {
                if !isImporting {
                    Button("OK") { }
                }
            } message: {
                if isImporting {
                    Text("Importation des données...".localized)
                } else {
                    Text(importMessage)
                }
            }
        }
    }

    // MARK: - Import backup / Excel / CSV

    /// Importe un fichier backup (.paraflightlog) ou Excel/CSV
    private func importFile(from url: URL) {
        let fileExtension = url.pathExtension.lowercased()
        let isBackupFile = fileExtension == "paraflightlog"

        isImporting = true

        if isBackupFile {
            // Import fichier backup .paraflightlog (completion appelée sur le main thread)
            ZipBackup.importFromZip(zipURL: url, dataController: dataController, mergeMode: true) { result in
                self.isImporting = false

                switch result {
                case .success(let summary):
                    self.importMessage = summary
                    self.showingImportResult = true
                    // Synchroniser les voiles vers la Watch après import
                    self.watchManager.sendWingsToWatch()
                case .failure(let error):
                    self.importMessage = "❌ Erreur d'import:\n\(error.localizedDescription)"
                    self.showingImportResult = true
                }
            }
        } else {
            // Import Excel/CSV
            Task {
                do {
                    let data = try ExcelImporter.parseExcelFile(at: url)
                    logInfo("Parsed \(data.flights.count) flights from file", category: .dataController)

                    let result = try ExcelImporter.importToDatabase(data: data, dataController: dataController)
                    isImporting = false
                    importMessage = result.summary
                    showingImportResult = true
                } catch {
                    isImporting = false
                    importMessage = "❌ Erreur d'import:\n\(error.localizedDescription)"
                    showingImportResult = true
                }
            }
        }
    }
}

#Preview {
    let dataController = DataController()
    return SettingsTabView()
        .environment(LocalizationManager.shared)
        .environment(WatchConnectivityManager.shared)
        .environment(dataController)
        .modelContainer(dataController.modelContainer)
}
