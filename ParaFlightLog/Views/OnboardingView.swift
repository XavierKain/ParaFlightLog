//
//  OnboardingView.swift
//  ParaFlightLog
//
//  First-launch onboarding: presents the app's pillars page by page, offers
//  the "flyable tomorrow" alerts as an explicit opt-in, and ends by guiding
//  the pilot to add their first wing.
//  Shown once (UserDefaultsKeys.hasCompletedOnboarding).
//  Target: iOS only
//

import SwiftUI

struct OnboardingView: View {
    /// Called when the pilot taps "Add My Wing" on the last page.
    let onAddWing: () -> Void
    /// Called when onboarding is finished or skipped without adding a wing.
    let onSkip: () -> Void

    @State private var currentPage = 0
    private let lastPageIndex = 4

    /// Forecast-alerts opt-in, bound to the SAME UserDefaults key the Settings
    /// toggle uses (ForecastAlertService.enabledKey), so Settings always shows
    /// what was chosen here and stays the single source of truth.
    /// Default OFF on purpose: this page is an explicit, informed opt-in.
    /// Flipping it here only PERSISTS the preference — notification
    /// authorization is still requested lazily by ForecastAlertService
    /// (PushService.ensureAuthorized) when there is a first alert to schedule.
    @AppStorage(ForecastAlertService.enabledKey) private var forecastAlertsEnabled = false

    var body: some View {
        ZStack {
            // Sky-like backdrop
            LinearGradient(
                colors: [Color.blue.opacity(0.25), Color.cyan.opacity(0.10), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button (hidden on the last page — it has its own actions)
                HStack {
                    Spacer()
                    if currentPage < lastPageIndex {
                        Button("Skip") {
                            onSkip()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 20)
                        .padding(.top, 8)
                    }
                }
                .frame(height: 44)

                TabView(selection: $currentPage) {
                    OnboardingPage(
                        symbol: "wind",
                        symbolColor: .blue,
                        title: "Welcome to SoarX",
                        message: "Your paragliding logbook. Every flight, every wing, every spot — in one place."
                    )
                    .tag(0)

                    OnboardingPage(
                        symbol: "applewatch.radiowaves.left.and.right",
                        symbolColor: .green,
                        title: "Track from your wrist",
                        message: "Start a flight on your Apple Watch: altitude, speed, G-force and GPS track are recorded live. No flight is ever lost — even offline, it syncs to your iPhone when reconnected."
                    )
                    .tag(1)

                    OnboardingPage(
                        symbol: "view.3d",
                        symbolColor: .purple,
                        title: "Relive & analyze",
                        message: "Replay flights in 3D over real terrain, export GPX/IGC tracks, and follow your hours, spots and progression in Stats."
                    )
                    .tag(2)

                    // Forecast alerts: explicit opt-in, no system prompt here.
                    VStack(spacing: 22) {
                        Spacer()

                        Image(systemName: "bell.badge")
                            .font(.system(size: 72))
                            .foregroundStyle(.indigo)

                        Text("Never miss a good day")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)

                        Text("SoarX follows the spots you fly, so it knows where to look from your very first flight. Turn this on and you get one notification the morning before — the spot, the wind direction and its strength — and only when the forecast matches what that spot actually needs.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Toggle(isOn: $forecastAlertsEnabled) {
                            Text("Alert me on flyable days")
                                .font(.headline)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 32)

                        Text("iOS only asks for notification permission when the first alert is ready. You can change this any time in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Spacer()
                        Spacer()
                    }
                    .tag(3)

                    // Final page: guided first action
                    VStack(spacing: 24) {
                        Spacer()

                        Image(systemName: "backpack")
                            .font(.system(size: 72))
                            .foregroundStyle(.orange)

                        Text("First: your wing")
                            .font(.title.bold())

                        Text("Flights are linked to a wing. Add yours now — pick it from the online library or enter it manually.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Spacer()

                        Button {
                            onAddWing()
                        } label: {
                            Label("Add My Wing", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 32)

                        Button("I'll do it later") {
                            onSkip()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        // Clear the page-indicator dots rendered at the very
                        // bottom of the TabView (they overlapped this button)
                        .padding(.bottom, 56)
                    }
                    .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                // Next button (all pages except the last)
                if currentPage < lastPageIndex {
                    Button {
                        withAnimation(.snappy) {
                            currentPage += 1
                        }
                    } label: {
                        Text("Next")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                } else {
                    // Keep the layout height stable across pages
                    Color.clear
                        .frame(height: 74)
                }
            }
        }
    }
}

// MARK: - OnboardingPage (one feature page)

private struct OnboardingPage: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: symbol)
                .font(.system(size: 72))
                .foregroundStyle(symbolColor)

            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
    }
}

#Preview {
    OnboardingView(onAddWing: {}, onSkip: {})
}
