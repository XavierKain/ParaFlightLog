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
    // Singletons initialisés une seule fois
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
                .onAppear {
                    // Démarrer la localisation dès le lancement de l'app
                    // pour que le spot soit affiché sur FlightStartView
                    locationService.requestAuthorization()
                    locationService.startUpdatingLocation()
                }
        }
    }
}
