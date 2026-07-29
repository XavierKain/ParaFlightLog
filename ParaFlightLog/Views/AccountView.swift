//
//  AccountView.swift
//  ParaFlightLog
//
//  Account & cloud backup screen (email + password via Appwrite).
//  Designed to be pushed from Settings. The caller injects the closures
//  that create the local backup archive (onBackup) and import a
//  downloaded one (onRestore) — typically wired to the backup manager.
//  Target: iOS only
//

import SwiftUI

struct AccountView: View {
    /// Creates the local backup archive and returns its file URL
    let onBackup: () async throws -> URL
    /// Imports the downloaded cloud backup file
    let onRestore: (URL) async throws -> Void

    private var auth: AuthService { .shared }
    private var cloudBackup: CloudBackupService { .shared }

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    /// Neutral (non-red) hint, used when a provider flow ends without a session.
    @State private var noticeMessage: String?
    @State private var isWorking = false
    @State private var showRestoreConfirmation = false
    /// Provider whose web sheet is open, so only that row spins.
    @State private var pendingProvider: OAuthProviderKind?

    init(
        onBackup: @escaping () async throws -> URL,
        onRestore: @escaping (URL) async throws -> Void
    ) {
        self.onBackup = onBackup
        self.onRestore = onRestore
    }

    var body: some View {
        Form {
            switch auth.state {
            case .unknown:
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            case .signedOut:
                signedOutSections
            case .signedIn(_, let userEmail):
                signedInSections(userEmail: userEmail)
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if auth.state == .unknown {
                await auth.restoreSession()
            }
            if auth.state.isSignedIn {
                await auth.refreshSignInMethod()
                await cloudBackup.refreshLastBackupDate()
            }
        }
        .confirmationDialog(
            "Restore Backup?",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                restore()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restoring will merge the cloud backup into your current data.")
        }
    }

    // MARK: - Signed Out

    @ViewBuilder
    private var signedOutSections: some View {
        Section {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
        } header: {
            Text("Account")
        } footer: {
            Text("Sign in to back up your logbook in the cloud and restore it on a new device. Passwords must be at least 8 characters.")
        }

        Section {
            Button {
                signIn()
            } label: {
                HStack {
                    Text("Sign In")
                    // Only spin here when it's this button doing the work —
                    // an OAuth flow spins on its own row.
                    if isWorking, pendingProvider == nil {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            Button("Create Account") {
                signUp()
            }
        }
        .disabled(isWorking || !isFormValid)

        Section {
            OAuthSignInButtons(pending: pendingProvider, isDisabled: isWorking) { provider in
                signIn(with: provider)
            }
        } header: {
            Text("Or continue with")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("No password to remember. If the provider gives us an email you already have an account with, you land back in the same logbook.")
                if let noticeMessage {
                    Text(noticeMessage)
                }
            }
        }

        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
    }

    private var isFormValid: Bool {
        email.contains("@") && password.count >= 8
    }

    // MARK: - Signed In

    @ViewBuilder
    private func signedInSections(userEmail: String) -> some View {
        Section("Account") {
            // Facebook can withhold the email, and Apple's "Hide My Email"
            // gives a relay address — fall back to whatever name we got.
            if userEmail.isEmpty {
                LabeledContent("Signed in as", value: auth.displayName ?? "Pilot")
            } else {
                LabeledContent("Email", value: userEmail)
            }
            if let method = auth.signInMethod,
               let provider = OAuthProviderKind(rawValue: method) {
                LabeledContent("Signed in with", value: provider.displayName)
            }
        }

        Section {
            Button {
                backUpNow()
            } label: {
                HStack {
                    Text("Back Up Now")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            Button("Restore Backup") {
                showRestoreConfirmation = true
            }
        } header: {
            Text("Cloud Backup")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let date = cloudBackup.lastBackupDate {
                    Text("Last backup: \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("No cloud backup yet.")
                }
                Text("Restoring will merge the cloud backup into your current data.")
                    .foregroundStyle(.red)
                if let statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.green)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(isWorking)

        Section {
            Button("Sign Out", role: .destructive) {
                signOut()
            }
            .disabled(isWorking)
        }
    }

    // MARK: - Actions

    private func signIn() {
        run {
            try await auth.signIn(email: email, password: password)
            password = ""
            await cloudBackup.refreshLastBackupDate()
        }
    }

    private func signIn(with provider: OAuthProviderKind) {
        pendingProvider = provider
        run {
            defer { pendingProvider = nil }
            do {
                try await auth.signIn(with: provider)
            } catch let error as AuthError where error.isCancellation {
                // Backing out of the sheet and "this provider isn't configured
                // yet" are indistinguishable from here, and staying silent
                // leaves a tester with a button that does nothing. Say something
                // neutral instead of nothing, and in grey rather than red.
                noticeMessage = "Sign-in with \(provider.displayName) didn't complete."
                return
            }
            await cloudBackup.refreshLastBackupDate()
        }
    }

    private func signUp() {
        run {
            try await auth.signUp(email: email, password: password)
            password = ""
            await cloudBackup.refreshLastBackupDate()
        }
    }

    private func signOut() {
        run {
            await auth.signOut()
            await cloudBackup.refreshLastBackupDate()
        }
    }

    private func backUpNow() {
        run {
            let localBackup = try await onBackup()
            try await cloudBackup.upload(backupFile: localBackup)
            statusMessage = "Backup uploaded."
        }
    }

    private func restore() {
        run {
            let downloaded = try await cloudBackup.downloadLatestBackup()
            try await onRestore(downloaded)
            statusMessage = "Backup restored."
        }
    }

    /// Runs an async operation with shared loading/error handling
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        statusMessage = nil
        noticeMessage = nil
        isWorking = true
        Task { @MainActor in
            do {
                try await operation()
            } catch let authError as AuthError where authError.isCancellation {
                // Closing the provider's web sheet isn't worth a red line.
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AccountView(
            onBackup: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("preview-backup.zip")
            },
            onRestore: { _ in }
        )
    }
}
