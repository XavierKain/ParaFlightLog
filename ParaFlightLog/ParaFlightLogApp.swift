//
//  ParaFlightLogApp.swift
//  ParaFlightLog
//
//  iOS app entry point: SwiftData setup + service injection.
//  Target: iOS only
//

import SwiftUI
import SwiftData

@main
struct ParaFlightLogApp: App {
    // Built asynchronously at launch so the ~1.2s ModelContainer creation no
    // longer blocks the first frame (was a black screen). Nil until ready.
    @State private var dataController: DataController?
    @State private var locationService = LocationService()

    // Singleton - use the shared instance directly instead of storing it in
    // @State, avoiding duplicate instances and potential memory leaks
    private var watchConnectivityManager: WatchConnectivityManager { WatchConnectivityManager.shared }

    var body: some Scene {
        WindowGroup {
            if let dataController {
                IOSRootView()
                    .environment(dataController)
                    .environment(watchConnectivityManager)
                    .environment(locationService)
                    .modelContainer(dataController.modelContainer)
            } else {
                LaunchLoadingView()
                    .task {
                        if dataController == nil {
                            dataController = await DataController.makeAsync()
                        }
                    }
            }
        }
    }
}

/// Pre-warms the system keyboard by summoning it once on an invisible,
/// off-screen text field. The first keyboard bring-up of a process is
/// expensive (~1-3s under the debugger) — paying it at idle right after
/// launch makes the first real text-field tap feel instant.
@MainActor
private func prewarmKeyboard() {
    guard let windowScene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
          let window = windowScene.windows.first else { return }

    let textField = UITextField(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
    textField.autocorrectionType = .no
    window.addSubview(textField)
    // No animations: the keyboard summon must not nudge the visible layout
    UIView.performWithoutAnimation {
        textField.becomeFirstResponder()
        textField.resignFirstResponder()
    }
    textField.removeFromSuperview()
}

/// Shown for the ~1s while the SwiftData store opens, instead of a black screen.
/// App icon + name + an animated loading bar.
private struct LaunchLoadingView: View {
    @State private var barProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                // Real app icon (falls back to a symbol if not loadable)
                if let icon = UIImage(named: "AppIcon") {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                } else {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.tint)
                }

                Text("SoarX")
                    .font(.title2.weight(.semibold))

                Spacer()

                // Indeterminate loading bar (sweeps until the store is ready)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: barProgress * geo.size.width)
                    }
                }
                .frame(width: 180, height: 5)
                .clipShape(Capsule())
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                barProgress = 0.65
            }
        }
    }
}

// Wrapper view handling one-time initialization
private struct IOSRootView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocationService.self) private var locationService

    @State private var hasInitialized = false

    var body: some View {
        ContentView()
            .onAppear {
                // Wire the service references (once)
                if !hasInitialized {
                    hasInitialized = true
                    logInfo("IOSRootView first appear (UI is now on screen)", category: .general)

                    watchManager.dataController = dataController
                    watchManager.locationService = locationService
                    dataController.watchConnectivityManager = watchManager

                    // Spot migration: link legacy spotName-only flights to Spot
                    // entities. Runs ONCE ever (persisted flag) — repeating it
                    // every launch resurrected deleted spots from the spotName
                    // their flights keep after deleteSpot.
                    dataController.runSpotMigrationIfNeeded()

                    locationService.requestAuthorization()

                    // Keep WatchConnectivity setup off the first-paint path.
                    DispatchQueue.main.async {
                        watchManager.activateSession()
                    }

                    // Trigger a wing sync to the Watch shortly after startup
                    DispatchQueue.main.asyncAfter(deadline: .now() + WatchSyncConstants.initialSyncDelay) {
                        watchManager.sendWingsToWatch()
                        logInfo("Startup wing sync to Watch triggered", category: .watchSync)
                    }

                    // Pre-warm slow first-use costs during post-launch idle so the
                    // FIRST real interaction doesn't pay them:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        // 1. Keyboard: the first keyboard bring-up of a process is
                        //    expensive (input services spin-up). Summon + dismiss an
                        //    invisible text field once, off-screen.
                        //    Skipped while onboarding is on screen — the keyboard
                        //    summon nudged its layout (screen jump / doubled button).
                        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.hasCompletedOnboarding) {
                            prewarmKeyboard()
                        }
                        // 2. Wing library: singleton init reads + decodes the cached
                        //    catalog from disk; do it now instead of on first open.
                        _ = WingLibraryService.shared
                    }
                }
            }
    }
}
