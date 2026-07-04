//
//  IOSViews.swift
//  ParaFlightLog
//
//  Main ContentView with the TabView.
//  The other views live in separate files:
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

// MARK: - ContentView (main TabView)

struct ContentView: View {
    /// Phone-only mode: the iPhone timer is the main flight tracker,
    /// so an extra "Timer" tab is shown.
    @AppStorage(UserDefaultsKeys.phoneOnlyMode) private var phoneOnlyMode = false

    @State private var selectedTab: Int = Tab.flights

    /// Tab tags, kept in one place.
    private enum Tab {
        static let flights = 0
        static let wings = 1
        static let stats = 2
        static let settings = 3
        static let timer = 4
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            FlightsView()
                .tabItem {
                    Label("Flights", systemImage: "airplane")
                }
                .tag(Tab.flights)

            WingsView()
                .tabItem {
                    Label("Wings", systemImage: "wind")
                }
                .tag(Tab.wings)

            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar")
                }
                .tag(Tab.stats)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)

            if phoneOnlyMode {
                TimerView()
                    .tabItem {
                        Label("Timer", systemImage: "stopwatch")
                    }
                    .tag(Tab.timer)
            }
        }
        .onChange(of: phoneOnlyMode) { _, isEnabled in
            // If the Timer tab disappears while selected, fall back to Flights
            if !isEnabled && selectedTab == Tab.timer {
                selectedTab = Tab.flights
            }
        }
    }
}
