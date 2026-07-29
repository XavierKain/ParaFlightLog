//
//  AuthService.swift
//  ParaFlightLog
//
//  Email + password and OAuth2 (Apple, Google, Facebook) authentication via
//  the Appwrite Account API. Its only purpose (for now) is to back the cloud
//  backup feature (see CloudBackupService).
//  Target: iOS only
//

import Foundation
import Appwrite
import AppwriteEnums // OAuthProvider — not re-exported by the Appwrite module

// MARK: - Auth State

enum AuthState: Equatable {
    case unknown
    case signedOut
    case signedIn(userId: String, email: String)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

// MARK: - Providers

/// The third-party sign-in options offered next to email + password.
///
/// All three run Appwrite's OAuth2 web flow, which the SDK hosts in an
/// `ASWebAuthenticationSession` and closes on the `appwrite-callback-<projectId>`
/// redirect. There is deliberately no native Sign in with Apple button:
/// Appwrite has no endpoint that exchanges an Apple ID token for a session,
/// so the web flow is the only way all three providers share one code path.
enum OAuthProviderKind: String, CaseIterable, Identifiable {
    case apple
    case google
    case facebook

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        case .facebook: return "Facebook"
        }
    }

    /// SF Symbol used on the button. Apple ships its own logo; Google and
    /// Facebook have no symbol, so we use a neutral lettermark rather than
    /// bundling brand artwork (see AUTH_OAUTH_SETUP.md — the official assets
    /// are required before a public App Store release).
    var symbolName: String {
        switch self {
        case .apple: return "apple.logo"
        case .google: return "g.circle.fill"
        case .facebook: return "f.circle.fill"
        }
    }

    fileprivate var appwriteProvider: AppwriteEnums.OAuthProvider {
        switch self {
        case .apple: return .apple
        case .google: return .google
        case .facebook: return .facebook
        }
    }
}

// MARK: - Errors

/// Short, user-facing error messages for authentication failures
enum AuthError: LocalizedError {
    case invalidCredentials
    case emailAlreadyExists
    case invalidInput(String)
    case rateLimited
    case network
    /// The pilot dismissed the provider's web sheet — not worth an alert.
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password."
        case .emailAlreadyExists:
            return "An account with this email already exists."
        case .invalidInput(let message):
            return message
        case .rateLimited:
            return "Too many attempts. Please try again later."
        case .network:
            return "Network error. Check your connection and try again."
        case .cancelled:
            return "Sign-in cancelled."
        case .unknown(let message):
            return message
        }
    }

    /// True when the failure is the pilot backing out, so the UI can stay quiet.
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

// MARK: - Service

@Observable
final class AuthService {
    static let shared = AuthService()

    /// Current authentication state (observed by AccountView)
    private(set) var state: AuthState = .unknown

    /// Name the provider handed back, when there is one. Email + password
    /// accounts have none, and Facebook can withhold the email, so this is the
    /// only label some pilots will ever have.
    private(set) var displayName: String?

    /// How the current session was created, as Appwrite spells it: `"email"`,
    /// `"apple"`, `"google"`, `"facebook"`. Set on sign-in, and refreshed on
    /// demand by `refreshSignInMethod()` after a session restore.
    private(set) var signInMethod: String?

    private var account: Account { AppwriteService.shared.account }

    private init() {}

    // MARK: - Public API

    /// Detects an existing Appwrite session on launch
    @MainActor
    func restoreSession() async {
        do {
            let user = try await account.get()
            // Refresh this device's push target under the restored session
            // (no-op / no prompt unless push was already authorized).
            applySignedIn(userId: user.id, email: user.email, name: user.name, method: nil)
            logInfo("Restored session for user \(user.id)", category: .general)
        } catch {
            // No active session (401) or server unreachable: treat as signed out
            state = .signedOut
            displayName = nil
            signInMethod = nil
        }
    }

    /// Creates a new account, then signs the user in
    @MainActor
    func signUp(email: String, password: String) async throws {
        do {
            let user = try await account.create(
                userId: ID.unique(),
                email: email,
                password: password
            )
            _ = try await account.createEmailPasswordSession(email: email, password: password)
            applySignedIn(userId: user.id, email: user.email, name: user.name, method: "email")
            logInfo("Signed up user \(user.id)", category: .general)
        } catch {
            logWarning("Sign up failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
    }

    /// Signs in with an existing account
    @MainActor
    func signIn(email: String, password: String) async throws {
        do {
            _ = try await account.createEmailPasswordSession(email: email, password: password)
            let user = try await account.get()
            applySignedIn(userId: user.id, email: user.email, name: user.name, method: "email")
            logInfo("Signed in user \(user.id)", category: .general)
        } catch {
            logWarning("Sign in failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
    }

    /// Signs in through an OAuth2 provider, hosted in a web sheet by the SDK.
    ///
    /// Appwrite attaches the new session to an existing account when the
    /// provider hands back an email that already has one — so a pilot who
    /// signed up with email + password and later taps "Continue with Google"
    /// keeps the same userId, and therefore the same spots, reports, kudos and
    /// cloud backup. Different emails mean different accounts, which is also
    /// what happens when Apple's "Hide My Email" mints a relay address.
    @MainActor
    func signIn(with provider: OAuthProviderKind) async throws {
        do {
            // Scopes are left to Appwrite: its per-provider defaults already
            // request the email, and each provider spells its scopes its own way.
            _ = try await account.createOAuth2Session(provider: provider.appwriteProvider)
            let user = try await account.get()
            applySignedIn(
                userId: user.id,
                email: user.email,
                name: user.name,
                method: provider.rawValue
            )
            logInfo("Signed in user \(user.id) via \(provider.rawValue)", category: .general)
        } catch {
            logWarning("Sign in with \(provider.rawValue) failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
    }

    /// Reads back how the current session was created. Worth a call when the
    /// Account screen appears; not worth slowing down launch for.
    @MainActor
    func refreshSignInMethod() async {
        guard state.isSignedIn, signInMethod == nil else { return }
        do {
            signInMethod = try await account.getSession(sessionId: "current").provider
        } catch {
            logWarning("Could not read the session provider: \(error)", category: .general)
        }
    }

    /// Deletes the current session; always ends signed out locally
    @MainActor
    func signOut() async {
        // Remove this device's push target while the session is still valid
        // (deletePushTarget needs authentication).
        await PushService.shared.onSignOut()
        do {
            _ = try await account.deleteSession(sessionId: "current")
        } catch {
            // Even if the server call fails, treat the user as signed out locally
            logWarning("Sign out request failed: \(error)", category: .general)
        }
        state = .signedOut
        displayName = nil
        signInMethod = nil
        logInfo("Signed out", category: .general)
    }

    // MARK: - State

    /// Single place where a successful authentication lands, whatever the flow.
    /// `method` is nil when we can't tell yet (a restored session), leaving any
    /// previously known value in place for `refreshSignInMethod()` to fill in.
    @MainActor
    private func applySignedIn(userId: String, email: String, name: String, method: String?) {
        state = .signedIn(userId: userId, email: email)
        displayName = name.isEmpty ? nil : name
        if let method {
            signInMethod = method
        }
        PushService.shared.onSignedIn()
    }

    // MARK: - Error Mapping

    /// Maps Appwrite errors to short English user-facing messages
    private static func mapError(_ error: Error) -> AuthError {
        guard let appwriteError = error as? AppwriteError else {
            // Transport-level failure (no server response)
            return .network
        }

        // The SDK's web-auth component reports a dismissed sheet as a typeless
        // error with this exact message — it is also what we get when the
        // provider page itself fails (e.g. the provider isn't enabled in the
        // Appwrite console yet) and the pilot closes it.
        if appwriteError.type == nil, appwriteError.message == "User cancelled login." {
            return .cancelled
        }

        switch appwriteError.type {
        case "user_invalid_credentials", "user_not_found":
            return .invalidCredentials
        case "user_already_exists", "user_email_already_exists":
            return .emailAlreadyExists
        case "general_argument_invalid", "user_password_mismatch":
            // e.g. malformed email or password shorter than 8 characters
            return .invalidInput(appwriteError.message)
        case "general_rate_limit_exceeded":
            return .rateLimited
        default:
            return .unknown(appwriteError.message)
        }
    }
}
