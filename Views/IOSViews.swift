//
//  IOSViews.swift
//  ParaFlightLog
//
//  ContentView principal avec TabView
//  Les autres vues sont dans des fichiers séparés:
//  - FlightsViews.swift: FlightsView, FlightDetailView, FlightRow, EditFlightView, etc.
//  - WingsViews.swift: WingsView, WingDetailView, AddWingView, EditWingView, etc.
//  - StatsViews.swift: StatsView, TotalStatsCard, StatsByWingSection, etc.
//  - TimerViews.swift: TimerView, WingPickerSheet, FlightSummaryView, etc.
//  - SettingsViews.swift: SettingsView, SpotsManagementView, BackupExportView, etc.
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
    private var wingsLabel: String { "Voiles".localized }
    private var flightsLabel: String { "Vols".localized }
    private var statsLabel: String { "Stats".localized }
    private var chartsLabel: String { "Graphiques".localized }
    private var settingsLabel: String { "Réglages".localized }

    var body: some View {
        TabView(selection: $selectedTab) {
            WingsView()
                .tabItem {
                    Label(wingsLabel, systemImage: "wind")
                }
                .tag(0)

            FlightsView()
                .tabItem {
                    Label(flightsLabel, systemImage: "airplane")
                }
                .tag(1)

            StatsView()
                .tabItem {
                    Label(statsLabel, systemImage: "chart.bar")
                }
                .tag(2)

            ChartsView()
                .tabItem {
                    Label(chartsLabel, systemImage: "chart.xyaxis.line")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label(settingsLabel, systemImage: "gearshape")
                }
                .tag(4)
        }
        .id(localizationManager.currentLanguage) // Force re-render de tout le TabView quand la langue change
    }
}
