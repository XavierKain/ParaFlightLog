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
    
    // ID pour forcer le rafraîchissement en douceur
    @State private var languageRefreshID = UUID()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(watchConnectivityManager)
                .environment(locationService)
                .environment(localizationManager)
                .environment(\.locale, localizationManager.locale)
                // Animation douce au changement de langue
                .id(languageRefreshID)
                .onChange(of: localizationManager.currentLanguage) { _, _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        languageRefreshID = UUID()
                    }
                }
                .onAppear {
                    locationService.requestAuthorization()
                }
        }
    }
}
