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
    // Services - DataController et LocationService sont des instances propres à l'app
    @State private var dataController = DataController()
    @State private var locationService = LocationService()

    // Singletons - on utilise directement les instances partagées sans les stocker en @State
    // Cela évite la création de doubles instances et les memory leaks potentiels
    private var watchConnectivityManager: WatchConnectivityManager { WatchConnectivityManager.shared }
    private var localizationManager: LocalizationManager { LocalizationManager.shared }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(dataController)
                .environment(watchConnectivityManager)
                .environment(locationService)
                .environment(localizationManager)
                .environment(\.locale, localizationManager.locale)
        }
        .modelContainer(dataController.modelContainer)
    }
}

// Vue wrapper pour gérer l'initialisation
private struct IOSRootView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocationService.self) private var locationService
    @Environment(LocalizationManager.self) private var localizationManager

    @State private var hasInitialized = false

    var body: some View {
        ContentView()
            .environment(\.locale, localizationManager.locale)
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + WatchSyncConstants.initialSyncDelay) {
                        watchManager.sendWingsToWatch()
                        logInfo("Manually triggered wing sync to Watch", category: .watchSync)
                    }

                    hasInitialized = true
                }
            }
    }
}
