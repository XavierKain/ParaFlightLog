//
//  IOSViews.swift
//  SoarX
//
//  ContentView principal avec TabView (4 onglets)
//  Les autres vues sont dans des fichiers séparés:
//  - TimerViews.swift: TimerView, WingPickerSheet, FlightSummaryView, etc.
//  - FlightsViews.swift: FlightsView, FlightDetailView, FlightRow, EditFlightView, etc.
//  - WingsViews.swift: WingsView, WingDetailView, AddWingView, EditWingView, etc.
//  - StatsViews.swift: StatsView, TotalStatsCard, StatsByWingSection, etc.
//  - SettingsViews.swift: SpotsManagementView, BackupExportView, etc.
//
//  Target: iOS only
//

import SwiftUI
import SwiftData

// MARK: - ContentView (TabView principale)

struct ContentView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocalizationManager.self) private var localizationManager

    // Conserver l'onglet sélectionné lors du changement de langue
    @State private var selectedTab: Int = 0

    // Labels des onglets calculés dynamiquement
    private var flightLabel: String { "Vol".localized }
    private var logbookLabel: String { "Logbook".localized }
    private var mapLabel: String { "Carte".localized }
    private var settingsLabel: String { "Réglages".localized }

    var body: some View {
        TabView(selection: $selectedTab) {
            TimerView()
                .tabItem {
                    Label(flightLabel, systemImage: "stopwatch")
                }
                .tag(0)

            LogbookView()
                .tabItem {
                    Label(logbookLabel, systemImage: "book.closed")
                }
                .tag(1)

            MapTabView()
                .tabItem {
                    Label(mapLabel, systemImage: "map")
                }
                .tag(2)

            SettingsTabView()
                .tabItem {
                    Label(settingsLabel, systemImage: "gearshape")
                }
                .tag(3)
        }
        .id(localizationManager.currentLanguage) // Force re-render de tout le TabView quand la langue change
    }
}
