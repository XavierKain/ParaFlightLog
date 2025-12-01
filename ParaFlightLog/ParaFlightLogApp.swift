//
//  ParaFlightLogApp.swift
//  ParaFlightLog
//
//  App principale iOS avec setup SwiftData + injection des services
//  Target: iOS only
//

import SwiftUI
import SwiftData

@main
struct ParaFlightLogApp: App {
    // Services
    @State private var dataController = DataController()
    @State private var watchConnectivityManager = WatchConnectivityManager.shared
    @State private var locationService = LocationService()
    @State private var localizationManager = LocalizationManager.shared

    init() {
        // L'initialisation sera faite dans IOSRootView.onAppear
        // car on a besoin des instances @State créées, pas de nouvelles instances
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(dataController)
                .environment(watchConnectivityManager)
                .environment(locationService)
                .environment(localizationManager)
        }
        .modelContainer(dataController.modelContainer)
    }
}

// Vue wrapper pour gérer l'initialisation
private struct IOSRootView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocationService.self) private var locationService

    @State private var hasInitialized = false

    var body: some View {
        ContentView()
            .onAppear {
                // Configurer les bonnes références (une seule fois)
                if !hasInitialized {
                    watchManager.dataController = dataController
                    watchManager.locationService = locationService
                    dataController.watchConnectivityManager = watchManager

                    // Activer la session APRÈS injection
                    watchManager.activateSession()

                    locationService.requestAuthorization()

                    // Forcer l'envoi des voiles à la Watch après activation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        watchManager.sendWingsToWatch()
                        print("🔄 Manually triggered wing sync to Watch")
                    }

                    hasInitialized = true
                }
            }
    }
}
