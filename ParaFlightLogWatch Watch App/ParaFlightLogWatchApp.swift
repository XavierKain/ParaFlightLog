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

    init() {
        print("⏱️ [PERF] ========== WATCH APP LAUNCH START ==========")
        print("⏱️ [PERF] App init() called at \(Date())")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(watchConnectivityManager)
                .environment(locationService)
                .environment(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .onAppear {
                    print("⏱️ [PERF] ========== FIRST VIEW APPEARED ==========")
                }
            // Supprimé: onAppear qui démarrait la localisation et causait du lag
            // La localisation sera demandée quand nécessaire
        }
    }
}
