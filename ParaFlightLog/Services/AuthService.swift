//
//  AuthService.swift
//  ParaFlightLog
//
//  Service d'authentification Appwrite
//  Gère l'inscription, connexion, OAuth et session
//  Target: iOS only
//

import Foundation
import Appwrite
import AppwriteEnums

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case notAuthenticated
    case invalidCredentials
    case emailAlreadyExists
    case weakPassword
    case networkError(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous n'êtes pas connecté"
        case .invalidCredentials:
            return "Email ou mot de passe incorrect"
        case .emailAlreadyExists:
            return "Un compte existe déjà avec cet email"
        case .weakPassword:
            return "Le mot de passe doit contenir au moins 8 caractères"
        case .networkError(let message):
            return "Erreur réseau: \(message)"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Auth State

enum AuthState: Equatable {
    case unknown
    case authenticated(userId: String)
    case unauthenticated
    case skipped  // User chose to continue without account
}

// MARK: - AuthService

@Observable
final class AuthService {
    static let shared = AuthService()

    // MARK: - Properties

    private let account: Account

    private(set) var authState: AuthState = .unknown
    private(set) var currentUserId: String?
    private(set) var currentEmail: String?
    private(set) var isLoading: Bool = false

    var isAuthenticated: Bool {
        if case .authenticated = authState {
            return true
        }
        return false
    }

    /// Returns true if user can access the app (authenticated or skipped)
    var canAccessApp: Bool {
        switch authState {
        case .authenticated, .skipped:
            return true
        default:
            return false
        }
    }

    // MARK: - Init

    private init() {
        self.account = AppwriteService.shared.account
    }

    // MARK: - Session Management

    /// Restaure la session au lancement de l'app
    func restoreSession() async {
        isLoading = true
        defer { isLoading = false }

        logInfo("Attempting to restore session...", category: .auth)

        do {
            // Vérifier d'abord si une session existe
            let session = try await account.getSession(sessionId: "current")
            logInfo("Found existing session: \(session.id), provider: \(session.provider), expires: \(session.expire)", category: .auth)

            // Récupérer les infos utilisateur
            let user = try await account.get()
            currentUserId = user.id
            currentEmail = user.email
            authState = .authenticated(userId: user.id)
            logInfo("Session restored successfully for user: \(user.email) (id: \(user.id))", category: .auth)
        } catch let error as AppwriteError {
            currentUserId = nil
            currentEmail = nil
            authState = .unauthenticated
            logInfo("No active session - Appwrite: \(error.message) (type: \(error.type ?? "unknown"))", category: .auth)
        } catch {
            currentUserId = nil
            currentEmail = nil
            authState = .unauthenticated
            logInfo("No active session - error: \(error.localizedDescription)", category: .auth)
        }
    }

    /// Vérifie si une session existe
    func getCurrentSession() async throws -> Bool {
        do {
            _ = try await account.getSession(sessionId: "current")
            return true
        } catch {
            return false
        }
    }

    /// Continue sans compte - crée une session anonyme pour permettre l'utilisation locale
    /// avec possibilité de synchroniser plus tard
    func skipAuthentication() {
        Task { @MainActor in
            isLoading = true
            defer { isLoading = false }

            do {
                // Créer une session anonyme pour permettre certaines fonctionnalités
                let session = try await account.createAnonymousSession()
                let user = try await account.get()
                currentUserId = user.id
                currentEmail = nil
                authState = .skipped
                logInfo("Anonymous session created: \(session.userId)", category: .auth)
            } catch {
                // Si la session anonyme échoue, continuer en mode complètement hors-ligne
                logError("Failed to create anonymous session: \(error)", category: .auth)
                currentUserId = nil
                currentEmail = nil
                authState = .skipped
                logInfo("User chose to skip authentication (offline mode)", category: .auth)
            }
        }
    }

    /// Continue sans compte de manière synchrone (pour les cas où async n'est pas possible)
    func skipAuthenticationSync() {
        currentUserId = nil
        currentEmail = nil
        authState = .skipped
        logInfo("User chose to skip authentication (sync)", category: .auth)
    }

    /// Force la déconnexion et supprime toute session existante
    func forceLogout() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Essayer de supprimer toutes les sessions
            _ = try await account.deleteSessions()
            logInfo("All sessions deleted", category: .auth)
        } catch {
            logError("Failed to delete sessions: \(error)", category: .auth)
        }

        // Réinitialiser l'état local dans tous les cas
        currentUserId = nil
        currentEmail = nil
        authState = .unauthenticated
    }

    // MARK: - Sign Up

    /// Inscription avec email et mot de passe
    @discardableResult
    func signUp(email: String, password: String, name: String) async throws -> String {
        isLoading = true
        defer { isLoading = false }

        do {
            // Créer le compte
            let user = try await account.create(
                userId: ID.unique(),
                email: email,
                password: password,
                name: name
            )

            // Connecter automatiquement après inscription
            try await signIn(email: email, password: password)

            logInfo("User signed up: \(email)", category: .auth)
            return user.id
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Sign In

    /// Connexion avec email et mot de passe
    @discardableResult
    func signIn(email: String, password: String) async throws -> String {
        isLoading = true
        defer { isLoading = false }

        do {
            // Vérifier si une session existe déjà
            if let existingSession = try? await account.getSession(sessionId: "current") {
                // Une session existe déjà, récupérer les infos utilisateur
                let user = try await account.get()
                currentUserId = user.id
                currentEmail = user.email
                authState = .authenticated(userId: user.id)
                logInfo("Session already exists for user: \(user.email)", category: .auth)
                return existingSession.userId
            }

            let session = try await account.createEmailPasswordSession(
                email: email,
                password: password
            )

            // Récupérer les infos utilisateur
            let user = try await account.get()
            currentUserId = user.id
            currentEmail = user.email
            authState = .authenticated(userId: user.id)

            logInfo("User signed in: \(email)", category: .auth)
            return session.userId
        } catch let error as AppwriteError {
            // Si l'erreur est "session active", essayer de restaurer la session
            let message = error.message
            if message.contains("session") || message.contains("active") || message.contains("Creation of a session is prohibited") {
                do {
                    let user = try await account.get()
                    currentUserId = user.id
                    currentEmail = user.email
                    authState = .authenticated(userId: user.id)
                    logInfo("Restored existing session for user: \(user.email)", category: .auth)
                    return user.id
                } catch {
                    // La session n'est plus valide, continuer avec l'erreur originale
                }
            }
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    // MARK: - OAuth

    /// Connexion OAuth (Google, Apple)
    /// Le SDK Appwrite gère automatiquement le callback via ASWebAuthenticationSession
    /// avec le schéma appwrite-callback-{projectId}
    func signInWithOAuth(provider: OAuthProvider) async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            // Créer la session OAuth
            // Note: Ne pas passer de success/failure URLs - le SDK gère le callback automatiquement
            // via ASWebAuthenticationSession avec le schéma appwrite-callback-{projectId}
            _ = try await account.createOAuth2Session(
                provider: provider
            )

            // Récupérer les infos utilisateur après OAuth
            let user = try await account.get()
            currentUserId = user.id
            currentEmail = user.email
            authState = .authenticated(userId: user.id)

            logInfo("User signed in with OAuth: \(provider)", category: .auth)
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Sign Out

    /// Déconnexion
    func signOut() async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await account.deleteSession(sessionId: "current")
            currentUserId = nil
            currentEmail = nil
            authState = .unauthenticated
            logInfo("User signed out", category: .auth)
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Password Reset

    /// Envoie un email de réinitialisation de mot de passe
    func sendPasswordReset(email: String) async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await account.createRecovery(
                email: email,
                url: "paraflightlog://reset-password"
            )
            logInfo("Password reset email sent to: \(email)", category: .auth)
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    /// Confirme la réinitialisation du mot de passe
    func confirmPasswordReset(userId: String, secret: String, newPassword: String) async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await account.updateRecovery(
                userId: userId,
                secret: secret,
                password: newPassword
            )
            logInfo("Password reset confirmed for user: \(userId)", category: .auth)
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Account Management

    /// Supprime le compte utilisateur
    func deleteAccount() async throws {
        isLoading = true
        defer { isLoading = false }

        guard isAuthenticated else {
            throw AuthError.notAuthenticated
        }

        do {
            // Note: La suppression complète nécessite une Appwrite Function
            // car le client ne peut pas supprimer son propre compte directement
            // Pour l'instant, on déconnecte simplement
            try await signOut()
            logInfo("Account deletion requested", category: .auth)
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    /// Met à jour le nom de l'utilisateur
    func updateName(_ name: String) async throws {
        guard isAuthenticated else {
            throw AuthError.notAuthenticated
        }

        do {
            _ = try await account.updateName(name: name)
            logInfo("User name updated", category: .auth)
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    /// Met à jour l'email de l'utilisateur
    func updateEmail(_ email: String, password: String) async throws {
        guard isAuthenticated else {
            throw AuthError.notAuthenticated
        }

        do {
            _ = try await account.updateEmail(email: email, password: password)
            currentEmail = email
            logInfo("User email updated", category: .auth)
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    /// Met à jour le mot de passe
    func updatePassword(oldPassword: String, newPassword: String) async throws {
        guard isAuthenticated else {
            throw AuthError.notAuthenticated
        }

        do {
            _ = try await account.updatePassword(password: newPassword, oldPassword: oldPassword)
            logInfo("User password updated", category: .auth)
        } catch let error as AppwriteError {
            throw mapAppwriteError(error)
        } catch {
            throw AuthError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    private func mapAppwriteError(_ error: AppwriteError) -> AuthError {
        let message = error.message

        if message.contains("Invalid credentials") || message.contains("Invalid email") || message.contains("Invalid password") {
            return .invalidCredentials
        }
        if message.contains("already exists") || message.contains("email already") {
            return .emailAlreadyExists
        }
        if message.contains("password") && (message.contains("weak") || message.contains("short") || message.contains("8")) {
            return .weakPassword
        }
        if message.contains("network") || message.contains("connection") {
            return .networkError(message)
        }

        return .unknown(message)
    }
}

