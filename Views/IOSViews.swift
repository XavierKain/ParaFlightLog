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

    var body: some View {
        TabView(selection: $selectedTab) {
            WingsView()
                .tabItem {
                    Label("Voiles", systemImage: "wind")
                }
                .tag(0)

            FlightsView()
                .tabItem {
                    Label("Vols", systemImage: "airplane")
                }
                .tag(1)

            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar")
                }
                .tag(2)

            ChartsView()
                .tabItem {
                    Label("Graphiques", systemImage: "chart.xyaxis.line")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Réglages", systemImage: "gearshape")
                }
                .tag(4)
        }
    }
}
