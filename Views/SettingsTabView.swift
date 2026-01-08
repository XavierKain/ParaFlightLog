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

struct SettingsTabView: View {
    @Environment(UserService.self) private var userService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Contenu temporaire - sera implémenté en Phase 5
                Section("Preview") {
                    Text("Settings organisés en 5 catégories")
                        .foregroundStyle(.secondary)
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
}

#Preview {
    SettingsTabView()
        .environment(UserService.shared)
}
