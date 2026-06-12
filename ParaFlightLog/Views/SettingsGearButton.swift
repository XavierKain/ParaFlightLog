//
//  SettingsGearButton.swift
//  ParaFlightLog
//
//  Composant réutilisable : bouton engrenage qui ouvre les Settings en modal
//  Accessible depuis tous les onglets de l'app
//

import SwiftUI
import SwiftData

struct SettingsGearButton: View {
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(DataController.self) private var dataController

    @State private var showSettings = false

    var body: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .sheet(isPresented: $showSettings) {
            SettingsTabView()
                .environment(localizationManager)
                .environment(watchManager)
                .environment(dataController)
                .modelContainer(dataController.modelContainer)
        }
    }
}

#Preview {
    SettingsGearButton()
}
