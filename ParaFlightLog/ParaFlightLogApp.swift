//
//  ParaFlightLogApp.swift
//  ParaFlightLog
//
//  iOS app entry point: SwiftData setup + service injection.
//  Target: iOS only
//

import SwiftUI
import SwiftData
import UIKit
import UserNotifications

@main
struct ParaFlightLogApp: App {
    // Bridges UIKit app-lifecycle hooks SwiftUI doesn't expose: the APNs
    // device-token callbacks and the notification-center delegate (Phase 1
    // push). Everything it does forwards to PushService / NotificationCenter.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

// MARK: - App Delegate (push notifications)

/// UIKit lifecycle bridge for Phase 1 push. Owns nothing beyond translating
/// APNs / notification-center callbacks into PushService calls and a single
/// `.spotDeepLink` NotificationCenter event the UI observes for routing.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Assign the notification-center delegate as EARLY as possible. On a cold
    /// start from a push tap, iOS calls `didReceive` right after launch — the
    /// delegate must already be set (Apple: "no later than the end of
    /// application(_:didFinishLaunchingWithOptions:)"). Doing it in
    /// `willFinishLaunching` is the safest slot and guarantees a launch tap is
    /// captured (then buffered by PushService for the not-yet-attached UI).
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Delegate is wired in willFinishLaunching (above); nothing else needed.
        return true
    }

    // MARK: APNs device-token registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushService.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushService.shared.didFailToRegisterForRemoteNotifications(error: error)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Foreground presentation: still show the banner/sound/badge so a report
    /// alert isn't swallowed while the app is open, and record it in the
    /// in-app notification center (unread — the pilot hasn't opened it yet).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        NotificationInboxService.shared.record(
            title: content.title,
            body: content.body,
            spotKey: PushService.spotKey(from: content.userInfo),
            reportId: PushService.value(forKey: "reportId", in: content.userInfo),
            kindRaw: PushService.value(forKey: "kind", in: content.userInfo),
            date: notification.date,
            markRead: false
        )
        return [.banner, .list, .sound, .badge]
    }

    /// Tap handling: record the push in the notification center (read — the
    /// pilot engaged with it) and route its `spotKey` to the UI. The tolerant
    /// extraction + cold-start buffering lives in PushService; no navigation
    /// logic here (see Notification.Name.spotDeepLink).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        // Extract Sendable values HERE (nonisolated static helpers) so the
        // non-Sendable userInfo dictionary never crosses onto the main actor.
        let spotKey = PushService.spotKey(from: content.userInfo)
        let rawShape = PushService.payloadShapeDescription(content.userInfo)
        NotificationInboxService.shared.record(
            title: content.title,
            body: content.body,
            spotKey: spotKey,
            reportId: PushService.value(forKey: "reportId", in: content.userInfo),
            kindRaw: PushService.value(forKey: "kind", in: content.userInfo),
            date: response.notification.date,
            markRead: true
        )
        PushService.shared.deliverDeepLink(spotKey: spotKey, rawShape: rawShape)
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
/// Same sky gradient as the onboarding, the app icon gently floating, the app
/// name and a subtle indeterminate bar — designed to read as a splash screen,
/// not an error state.
private struct LaunchLoadingView: View {
    @State private var floating = false
    @State private var barProgress: CGFloat = 0

    var body: some View {
        ZStack {
            // Sky-like backdrop (matches OnboardingView).
            LinearGradient(
                colors: [Color.blue.opacity(0.25), Color.cyan.opacity(0.10), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                // Real app icon (falls back to a symbol if not loadable),
                // drifting slowly like a wing on a light breeze.
                Group {
                    if let icon = UIImage(named: "AppIcon") {
                        Image(uiImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 14, y: 8)
                    } else {
                        Image(systemName: "wind")
                            .font(.system(size: 64, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                .offset(y: floating ? -6 : 6)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: floating)

                Text("SoarX")
                    .font(.largeTitle.bold())

                Text("Your flights, your spots, your sky.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                // Indeterminate loading bar (sweeps until the store is ready)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Color.blue.gradient)
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: barProgress * geo.size.width)
                    }
                }
                .frame(width: 160, height: 4)
                .clipShape(Capsule())
                .padding(.bottom, 70)
            }
        }
        .onAppear {
            floating = true
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

                    // Drop trashed flights past their week. There is no
                    // background scheduler, and there doesn't need to be:
                    // retention only has to hold the next time the app opens.
                    dataController.purgeExpiredTrash()

                    locationService.requestAuthorization()

                    // Restore the Appwrite session NOW, not lazily on the first
                    // Account/Community screen: every auth-gated feature (report
                    // sheet, kudos, follows) reads AuthService.state and treated
                    // the never-restored `.unknown` as signed out.
                    Task { await AuthService.shared.restoreSession() }

                    // Refresh this device's APNs token silently, but only if a
                    // push target already exists (never prompts at launch —
                    // authorization is requested lazily when the user opts in).
                    PushService.shared.refreshAtLaunch()

                    // Smart notification defaults + historical weather backfill.
                    // Deferred, best-effort, off the first-paint path:
                    //  1. auto-follow the community spots the pilot flies,
                    //  2. back-fill takeoff weather on flights that predate the
                    //     weather feature (this is what un-blanks learned
                    //     flyability), auto-run only until one full pass done,
                    //  3. schedule "flyable tomorrow" local alerts for followed
                    //     spots — after the backfill so learned windows are fresh.
                    Task { @MainActor in
                        await SpotAutoFollowService.shared.reconcile(dataController: dataController)
                        if !WeatherBackfillService.shared.hasCompletedPass {
                            await WeatherBackfillService.shared.backfillMissingTakeoffWeather(dataController: dataController)
                        }
                        await ForecastAlertService.shared.refreshAlerts(dataController: dataController)
                        // Reschedule the wing trim reminders (deadlines may
                        // have moved while the app was closed). Fail-soft;
                        // prompts only when a reminder actually needs
                        // scheduling.
                        await WingMaintenance.scheduleTrimReminders(wings: dataController.fetchWings())
                    }

                    // Keep WatchConnectivity setup off the first-paint path.
                    DispatchQueue.main.async {
                        watchManager.activateSession()
                        // Clean up Live Activities orphaned by a crash or
                        // force-quit mid-flight (fail-soft: no-op when
                        // ActivityKit is unavailable/disabled or nothing runs).
                        FlightActivityController.shared.endAllOrphans()
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
