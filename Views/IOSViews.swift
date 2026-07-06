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

// MARK: - LazyView

/// Defers building the wrapped view until it is actually displayed.
/// NavigationLink constructs its destination eagerly when the row renders;
/// wrap heavy destinations (services, audio, sensors in their init) in this.
struct LazyView<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder _ content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
    }
}

// MARK: - ContentView (main TabView)

struct ContentView: View {
    /// Phone-only mode: the iPhone timer is the main flight tracker,
    /// so an extra "Timer" tab is shown.
    @AppStorage(UserDefaultsKeys.phoneOnlyMode) private var phoneOnlyMode = false

    // First-launch onboarding: presents the app and guides adding the first
    // wing. Shown once, and only for an empty logbook.
    @AppStorage(UserDefaultsKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @Query(filter: #Predicate<Wing> { !$0.isArchived }) private var wings: [Wing]
    @Query private var flights: [Flight]
    @State private var showingOnboarding = false
    @State private var showingAddWingFromOnboarding = false
    /// Set by onboarding's "Add wing" action; the sheet is presented once the
    /// fullScreenCover is actually gone (see onChange(of: showingOnboarding)).
    @State private var pendingAddWingFromOnboarding = false

    @State private var selectedTab: Int = Tab.home

    /// Tab tags, kept in one place.
    private enum Tab {
        static let home = 5
        static let flights = 0
        static let wings = 1
        static let stats = 2
        static let settings = 3
        static let timer = 4
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Home dashboard: the essentials of every tab at a glance
            DashboardView(onOpenTab: { tab in
                selectedTab = tab
            })
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(Tab.home)

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
        .onAppear {
            guard !hasCompletedOnboarding else { return }
            if wings.isEmpty && flights.isEmpty {
                // Brand-new logbook: run the onboarding once.
                showingOnboarding = true
            } else {
                // Upgrader with existing data: onboarding never showed, so the
                // flag stayed false forever and everything gated on it (e.g.
                // the keyboard prewarm) was skipped. Mark it completed.
                hasCompletedOnboarding = true
            }
        }
        // Dev tool "Replay Onboarding" resets the flag → re-present it,
        // regardless of existing data.
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed {
                showingOnboarding = true
            }
        }
        // Deterministic onboarding → add-wing handoff: present the sheet only
        // once the fullScreenCover state has flipped off (a fixed asyncAfter
        // delay could be swallowed).
        .onChange(of: showingOnboarding) { _, isShowing in
            if !isShowing && pendingAddWingFromOnboarding {
                pendingAddWingFromOnboarding = false
                showingAddWingFromOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView(
                onAddWing: {
                    hasCompletedOnboarding = true
                    selectedTab = Tab.wings
                    // The add-wing sheet opens from onChange(of: showingOnboarding)
                    // once the cover is dismissed.
                    pendingAddWingFromOnboarding = true
                    showingOnboarding = false
                },
                onSkip: {
                    hasCompletedOnboarding = true
                    showingOnboarding = false
                }
            )
        }
        .sheet(isPresented: $showingAddWingFromOnboarding) {
            AddWingView()
        }
    }
}
