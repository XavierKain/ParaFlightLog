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
import Combine // NotificationCenter publisher for the .spotDeepLink observer

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

    /// Local spot to open from a push-tap deep link (nil = no sheet).
    /// Optional so an un-injected context (previews, or a `.spotDeepLink`
    /// arriving before the root environment is wired) fails soft instead of
    /// trapping with "No Observable object of type DataController found".
    @Environment(DataController.self) private var dataController: DataController?
    @State private var deepLinkSpot: Spot?

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
        // Push-tap deep link (WARM): the observer is attached, so route the
        // posted event straight to the matching local spot.
        .onReceive(NotificationCenter.default.publisher(for: .spotDeepLink)) { note in
            selectedTab = Tab.home
            if let key = PushService.spotKey(from: note.userInfo ?? [:]) {
                presentSpot(forKey: key)
            }
        }
        // Push-tap deep link (COLD START): `didReceive` fired before this view
        // attached its observer, so the event was lost. Drain the buffer
        // PushService stashed it in, once, as the UI comes on screen.
        .task {
            if let key = PushService.shared.consumePendingDeepLink() {
                selectedTab = Tab.home
                presentSpot(forKey: key)
            }
        }
        .sheet(item: $deepLinkSpot) { spot in
            NavigationStack {
                SpotDetailView(spot: spot)
            }
        }
    }

    /// Resolves a community `spotKey` to a local Spot and presents it as a
    /// sheet. Clears any buffered cold-start link so a later `.task` on a re-
    /// created view can't replay it. No local match → no sheet (safe fallback).
    private func presentSpot(forKey spotKey: String) {
        _ = PushService.shared.consumePendingDeepLink()
        guard let dataController else { return }
        deepLinkSpot = dataController.fetchSpots().first { spot in
            spot.communitySpotKey == spotKey
                || CommunitySpotKey.make(
                    name: spot.name,
                    latitude: spot.latitude,
                    longitude: spot.longitude
                ) == spotKey
        }
    }
}
