//
//  WatchSettingsView.swift
//  ParaFlightLog
//
//  Réglages Apple Watch : statut de connexion, synchronisation des voiles,
//  options locales (Water Lock automatique, annulation de vol).
//  Les paramètres sont envoyés à la Watch via WatchConnectivityManager.
//

import SwiftUI
import SwiftData

struct WatchSettingsView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Query private var wings: [Wing]

    @State private var showingImportSuccess = false
    @State private var importMessage = ""

    // États locaux pour les settings Watch - permettent le rafraîchissement instantané
    @State private var autoWaterLock: Bool = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
    @State private var allowSessionDismiss: Bool = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true

    var body: some View {
        List {
            Section("Statut".localized) {
                HStack {
                    Text("App Watch".localized)
                    Spacer()
                    if watchManager.isWatchAppInstalled {
                        Label("Installée".localized, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Non installée".localized, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                HStack {
                    Text("Joignable".localized)
                    Spacer()
                    if watchManager.isWatchReachable {
                        Label("Oui".localized, systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Non".localized, systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                HStack {
                    Text("Voiles synchronisées".localized)
                    Spacer()
                    Text("\(wings.filter { !$0.isArchived }.count)")
                        .foregroundStyle(.secondary)
                }

                Button {
                    watchManager.sendWingsToWatch()
                    watchManager.sendWingsViaTransfer()
                    importMessage = "\(wings.filter { !$0.isArchived }.count) voile(s) envoyée(s)".localized
                    showingImportSuccess = true
                } label: {
                    Label("Synchroniser les voiles".localized, systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section {
                Toggle(isOn: $autoWaterLock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verrouillage automatique".localized)
                        Text("Active le Water Lock au début d'un vol".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: autoWaterLock) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.watchAutoWaterLock)
                    watchManager.sendWatchSettings(autoWaterLock: newValue, allowSessionDismiss: allowSessionDismiss)
                }

                Toggle(isOn: $allowSessionDismiss) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Autoriser l'annulation".localized)
                        Text("Permet d'annuler un vol sans le sauvegarder".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: allowSessionDismiss) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.watchAllowSessionDismiss)
                    watchManager.sendWatchSettings(autoWaterLock: autoWaterLock, allowSessionDismiss: newValue)
                }
            } header: {
                Text("Options".localized)
            } footer: {
                Text("Ces paramètres sont synchronisés avec votre Watch".localized)
            }
        }
        .navigationTitle("Apple Watch".localized)
        .alert("Synchronisation".localized, isPresented: $showingImportSuccess) {
            Button("OK") { }
        } message: {
            Text(importMessage)
        }
        .onAppear {
            // Rafraîchir les états locaux depuis UserDefaults à chaque apparition de la vue
            // Cela garantit que les valeurs affichées sont toujours à jour
            autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
            allowSessionDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchSettingsDidUpdate)) { _ in
            // Rafraîchir les états locaux quand la Watch envoie des changements
            autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
            allowSessionDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
        }
    }
}

#Preview {
    NavigationStack {
        WatchSettingsView()
            .environment(WatchConnectivityManager.shared)
    }
}
