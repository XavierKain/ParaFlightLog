//
//  PushService.swift
//  ParaFlightLog
//
//  Phase 1 of the community loop: APNs push notifications via Appwrite
//  Messaging. This service owns the *client* half:
//    - asks for UNUserNotificationCenter authorization (lazily — only when the
//      user opts into a push-driven feature, e.g. subscribing to a spot);
//    - registers for remote notifications and receives the APNs device token
//      (forwarded from the AppDelegate hook in ParaFlightLogApp);
//    - registers that token with Appwrite as a *push target*
//      (`account.createPushTarget`) so the `notify-fanout` Appwrite Function
//      can address this device by userId.
//
//  Push-target lifecycle (mirrors the account session):
//    - sign-in / session restore  -> create (or refresh) the target
//    - APNs token change           -> updatePushTarget
//    - sign-out                    -> deletePushTarget (before the session dies)
//
//  Everything is best-effort and fail-soft: no APNs provider configured in
//  the Appwrite console yet, signed out, denied authorization, or an offline
//  server must never affect the app — the entry points only log (under the
//  `community` category; PushService is not allowed to add a log category).
//
//  Server side: see functions/notify-fanout/ and APNS_SETUP.md.
//  Target: iOS only
//

import Foundation
import UIKit
import UserNotifications
import Appwrite

// MARK: - Deep-link plumbing

extension Notification.Name {
    /// Posted when the user taps a push whose payload carries a `spotKey`.
    /// The UI (Explore / spot pages, wired later) observes this and navigates
    /// to that spot. `userInfo` carries `["spotKey": String]`.
    ///
    /// Kept deliberately minimal: PushService/AppDelegate only translate the
    /// APNs payload into an in-app NotificationCenter event — no navigation
    /// logic lives here, so the UI agents own the routing without a
    /// cross-file dependency on this service.
    static let spotDeepLink = Notification.Name("com.xavierkain.ParaFlightLog2.spotDeepLink")
}

// MARK: - Service

@Observable @MainActor
final class PushService {
    static let shared = PushService()

    /// Continuation resumed by the AppDelegate device-token callback while a
    /// registration is in flight. Nil when no one is awaiting a token (an
    /// unsolicited token from iOS is then synced directly).
    private var tokenContinuation: CheckedContinuation<String, Error>?

    /// Generation counter guarding the safety timeout: a timeout only fires
    /// for the registration it was scheduled for.
    private var tokenGeneration = 0

    /// True while a request-token → sync-target round trip is running, so
    /// overlapping triggers (launch refresh + session restore + a UI opt-in
    /// firing at once) don't create duplicate targets.
    private var isSyncing = false

    private init() {}

    // MARK: - Persisted lifecycle state

    /// Appwrite push-target `$id` for this device on the current account.
    private var storedTargetId: String? {
        get { UserDefaults.standard.string(forKey: UserDefaultsKeys.pushTargetId) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.pushTargetId) }
    }

    /// The APNs token last registered as the target identifier.
    private var storedDeviceToken: String? {
        get { UserDefaults.standard.string(forKey: UserDefaultsKeys.pushDeviceToken) }
        set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.pushDeviceToken) }
    }

    // MARK: - Public API (called by UI, App, AuthService)

    /// Whether a push target already exists for this device — the app uses
    /// this at launch to decide whether to refresh silently.
    var hasPushTarget: Bool { storedTargetId != nil }

    /// Called by the UI when the user opts into a push-driven feature
    /// (enables sharing / subscribes to a spot). Prompts for notification
    /// authorization if not asked before, then registers the push target.
    func ensureAuthorized() async {
        await register(promptIfNeeded: true)
    }

    /// Called once at app start. Refreshes the APNs token silently, but only
    /// if a push target already exists (so a brand-new user is never prompted
    /// at launch). Never shows the system permission dialog.
    func refreshAtLaunch() {
        guard hasPushTarget else { return }
        Task { await register(promptIfNeeded: false) }
    }

    /// Called by AuthService right after a successful sign-in / session
    /// restore. Registers the push target for the now-signed-in user, but
    /// only if notification authorization was already granted (never prompts).
    func onSignedIn() {
        Task { await register(promptIfNeeded: false) }
    }

    /// Called by AuthService BEFORE the session is deleted (deletePushTarget
    /// needs the authenticated session). Best-effort: a failure is fine — the
    /// stale target is harmless and the TTL/console cleanup covers it.
    func onSignOut() async {
        guard let targetId = storedTargetId else { return }
        do {
            _ = try await AppwriteService.shared.account.deletePushTarget(targetId: targetId)
            logInfo("Push target deleted on sign-out", category: .community)
        } catch {
            logWarning("Push target delete on sign-out failed: \(error)", category: .community)
        }
        // Clear the target regardless; the device token stays (device-level).
        storedTargetId = nil
    }

    // MARK: - Device-token callbacks (forwarded from the AppDelegate)

    /// APNs delivered a device token. Resumes a pending registration, or —
    /// when iOS delivers a fresh token unprompted (token rotation) — syncs it
    /// straight away.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        if let continuation = tokenContinuation {
            tokenContinuation = nil
            tokenGeneration &+= 1 // invalidate the pending timeout
            continuation.resume(returning: hex)
        } else {
            logInfo("APNs token refreshed by the system", category: .community)
            Task { await syncPushTarget(token: hex) }
        }
    }

    /// APNs registration failed. Resumes a pending registration with the
    /// error, otherwise just logs.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        if let continuation = tokenContinuation {
            tokenContinuation = nil
            tokenGeneration &+= 1
            continuation.resume(throwing: error)
        } else {
            logWarning("APNs registration failed: \(error)", category: .community)
        }
    }

    // MARK: - Registration flow

    /// Ensures notification authorization (prompting only when allowed), then
    /// fetches an APNs token and registers/refreshes the Appwrite push target.
    private func register(promptIfNeeded: Bool) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            guard promptIfNeeded else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else {
                    logInfo("Push authorization declined by the user", category: .community)
                    return
                }
            } catch {
                logWarning("Push authorization request failed: \(error)", category: .community)
                return
            }
        case .denied:
            // The user turned notifications off in Settings — nothing to do.
            return
        default:
            break // authorized / provisional / ephemeral
        }

        do {
            let token = try await requestDeviceToken()
            await syncPushTarget(token: token)
        } catch {
            logWarning("APNs token registration failed: \(error)", category: .community)
        }
    }

    /// Triggers `registerForRemoteNotifications()` and awaits the token via the
    /// AppDelegate callback, with a safety timeout so a silent APNs failure
    /// (e.g. the simulator, or no network) never leaves the flow hung.
    private func requestDeviceToken(timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Should never happen (isSyncing serializes callers), but stay safe.
            if let stale = tokenContinuation {
                tokenContinuation = nil
                stale.resume(throwing: CancellationError())
            }
            tokenContinuation = continuation
            tokenGeneration &+= 1
            let generation = tokenGeneration

            UIApplication.shared.registerForRemoteNotifications()

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // Only fire if THIS registration is still pending.
                guard tokenGeneration == generation, let pending = tokenContinuation else { return }
                tokenContinuation = nil
                pending.resume(throwing: PushError.tokenTimeout)
            }
        }
    }

    /// Creates, updates, or (on a lost target) recreates the Appwrite push
    /// target for the current user. When signed out, only remembers the token
    /// so the target can be created at the next sign-in.
    private func syncPushTarget(token: String) async {
        guard case .signedIn = AuthService.shared.state else {
            storedDeviceToken = token
            logInfo("APNs token stored; push target deferred until sign-in", category: .community)
            return
        }

        let account = AppwriteService.shared.account
        do {
            if let targetId = storedTargetId {
                guard storedDeviceToken != token else { return } // already current
                _ = try await account.updatePushTarget(targetId: targetId, identifier: token)
                storedDeviceToken = token
                logInfo("Push target refreshed", category: .community)
            } else {
                try await createTarget(token: token, account: account)
            }
        } catch {
            // The server may have dropped the target (project reset, manual
            // deletion). Recreate once instead of silently going dark.
            if storedTargetId != nil, Self.isTargetNotFound(error) {
                storedTargetId = nil
                do {
                    try await createTarget(token: token, account: account)
                } catch {
                    logWarning("Push target recreate failed: \(error)", category: .community)
                }
            } else {
                logWarning("Push target sync failed: \(error)", category: .community)
            }
        }
    }

    private func createTarget(token: String, account: Account) async throws {
        let target = try await account.createPushTarget(
            targetId: ID.unique(),
            identifier: token,
            providerId: nil
        )
        storedTargetId = target.id
        storedDeviceToken = token
        logInfo("Push target created (\(target.id))", category: .community)
    }

    // MARK: - Error classification

    /// True when Appwrite reports the push target no longer exists (404 /
    /// `target_not_found`), so the client should recreate it.
    private static func isTargetNotFound(_ error: Error) -> Bool {
        guard let appwriteError = error as? AppwriteError else { return false }
        return appwriteError.code == 404 || (appwriteError.type?.contains("target_not_found") ?? false)
    }
}

// MARK: - Errors

/// Internal, non-user-facing failures of the push registration flow.
private enum PushError: LocalizedError {
    case tokenTimeout

    var errorDescription: String? {
        switch self {
        case .tokenTimeout:
            return "Timed out waiting for the APNs device token."
        }
    }
}
