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
    // Utiliser des singletons pour éviter les recréations
    @State private var watchConnectivityManager = WatchConnectivityManager.shared
    @State private var locationService = WatchLocationService()
    @State private var localizationManager = WatchLocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(watchConnectivityManager)
                .environment(locationService)
                .environment(localizationManager)
                .environment(\.locale, localizationManager.locale)
            // Supprimé: onAppear qui démarrait la localisation et causait du lag
            // La localisation sera demandée quand nécessaire
        }
    }
}
