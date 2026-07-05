//
//  OnboardingView.swift
//  ParaFlightLog
//
//  First-launch onboarding: presents the app's pillars page by page and
//  ends by guiding the pilot to add their first wing.
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
    private let lastPageIndex = 3

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
                    .tag(3)
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
