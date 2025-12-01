//
//  ParaFlightLogWatchApp.swift
//  ParaFlightLogWatch Watch App
//
//  App principale watchOS avec setup WatchConnectivity
//  Target: Watch only
//

import SwiftUI

@main
struct ParaFlightLogWatch_Watch_AppApp: App {
    @State private var watchConnectivityManager = WatchConnectivityManager.shared
    @State private var locationService = WatchLocationService()
    @State private var localizationManager = WatchLocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(watchConnectivityManager)
                .environment(locationService)
                .environment(localizationManager)
                // Forcer le rechargement quand la langue change
                .id(localizationManager.currentLanguage?.rawValue ?? "system")
                .environment(\.locale, localizationManager.locale)
                .onAppear {
                    locationService.requestAuthorization()
                }
        }
    }
}
