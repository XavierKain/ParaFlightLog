//
//  ParaFlightLogApp.swift
//  ParaFlightLog
//
//  iOS app entry point: SwiftData setup + service injection.
//  Target: iOS only
//

import SwiftUI
import SwiftData

@main
struct ParaFlightLogApp: App {
    // Services - DataController and LocationService are owned by the app
    @State private var dataController = DataController()
    @State private var locationService = LocationService()

    // Singleton - use the shared instance directly instead of storing it in
    // @State, avoiding duplicate instances and potential memory leaks
    private var watchConnectivityManager: WatchConnectivityManager { WatchConnectivityManager.shared }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(dataController)
                .environment(watchConnectivityManager)
                .environment(locationService)
        }
        .modelContainer(dataController.modelContainer)
    }
}

// Wrapper view handling one-time initialization
private struct IOSRootView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocationService.self) private var locationService

    @State private var hasInitialized = false

    var body: some View {
        ContentView()
            .onAppear {
                // Wire the service references (once)
                if !hasInitialized {
                    watchManager.dataController = dataController
                    watchManager.locationService = locationService
                    dataController.watchConnectivityManager = watchManager

                    // Activate the session AFTER injection
                    watchManager.activateSession()

                    locationService.requestAuthorization()

                    // Trigger a wing sync to the Watch shortly after startup
                    DispatchQueue.main.asyncAfter(deadline: .now() + WatchSyncConstants.initialSyncDelay) {
                        watchManager.sendWingsToWatch()
                        logInfo("Startup wing sync to Watch triggered", category: .watchSync)
                    }

                    hasInitialized = true
                }
            }
    }
}
