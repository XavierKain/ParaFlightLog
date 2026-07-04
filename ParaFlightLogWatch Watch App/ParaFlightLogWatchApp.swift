//
//  ParaFlightLogWatchApp.swift
//  ParaFlightLogWatch Watch App
//
//  Main watchOS app with WatchConnectivity setup
//  Target: Watch only
//

import SwiftUI

@main
struct ParaFlightLogWatch_Watch_AppApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Singletons initialized once
    @State private var watchConnectivityManager = WatchConnectivityManager.shared
    @State private var locationService = WatchLocationService()

    // WorkoutManager reference for preloading
    private let workoutManager = WorkoutManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(watchConnectivityManager)
                .environment(locationService)
                .onAppear {
                    // Start location updates at launch so the spot is
                    // already shown on FlightStartView
                    locationService.requestAuthorization()
                    locationService.startUpdatingLocation()

                    // Preload HealthKit in the background to avoid lag on the first flight
                    Task(priority: .background) {
                        _ = await workoutManager.requestAuthorization()
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Retry delivery of any flight still in the outbox whenever
            // the app becomes active
            if newPhase == .active {
                watchConnectivityManager.retryPendingFlights()
            }
        }
    }
}
