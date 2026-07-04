//
//  AuthService.swift
//  ParaFlightLog
//
//  Email + password authentication via the Appwrite Account API.
//  Its only purpose (for now) is to back the cloud backup feature
//  (see CloudBackupService).
//  Target: iOS only
//

import Foundation
import Appwrite

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

// MARK: - Errors

/// Short, user-facing error messages for authentication failures
enum AuthError: LocalizedError {
    case invalidCredentials
    case emailAlreadyExists
    case invalidInput(String)
    case rateLimited
    case network
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
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Service

@Observable
final class AuthService {
    static let shared = AuthService()

    /// Current authentication state (observed by AccountView)
    private(set) var state: AuthState = .unknown

    private var account: Account { AppwriteService.shared.account }

    private init() {}

    // MARK: - Public API

    /// Detects an existing Appwrite session on launch
    @MainActor
    func restoreSession() async {
        do {
            let user = try await account.get()
            state = .signedIn(userId: user.id, email: user.email)
            logInfo("Restored session for user \(user.id)", category: .general)
        } catch {
            // No active session (401) or server unreachable: treat as signed out
            state = .signedOut
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
            state = .signedIn(userId: user.id, email: user.email)
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
            state = .signedIn(userId: user.id, email: user.email)
            logInfo("Signed in user \(user.id)", category: .general)
        } catch {
            logWarning("Sign in failed: \(error)", category: .general)
            throw Self.mapError(error)
        }
    }

    /// Deletes the current session; always ends signed out locally
    @MainActor
    func signOut() async {
        do {
            _ = try await account.deleteSession(sessionId: "current")
        } catch {
            // Even if the server call fails, treat the user as signed out locally
            logWarning("Sign out request failed: \(error)", category: .general)
        }
        state = .signedOut
        logInfo("Signed out", category: .general)
    }

    // MARK: - Error Mapping

    /// Maps Appwrite errors to short English user-facing messages
    private static func mapError(_ error: Error) -> AuthError {
        guard let appwriteError = error as? AppwriteError else {
            // Transport-level failure (no server response)
            return .network
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
