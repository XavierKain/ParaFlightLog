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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(watchConnectivityManager)
                .environment(locationService)
                .onAppear {
                    locationService.requestAuthorization()
                }
        }
    }
}
