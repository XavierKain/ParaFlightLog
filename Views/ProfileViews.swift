//
//  ProfileViews.swift
//  ParaFlightLog
//
//  Vues du profil utilisateur, authentification et paramètres du compte
//  Target: iOS only
//

import SwiftUI
import SwiftData
import AppwriteEnums

// MARK: - AuthContainerView (Gestion de l'état d'authentification)

/// Vue conteneur qui affiche soit l'écran de connexion soit l'app principale
/// selon l'état d'authentification de l'utilisateur
struct AuthContainerView: View {
    @Environment(AuthService.self) private var authService

    var body: some View {
        Group {
            switch authService.authState {
            case .unknown:
                // État de chargement initial
                ProgressView("Vérification de la session...".localized)
                    .task {
                        await authService.restoreSession()
                    }

            case .authenticated, .skipped:
                // Utilisateur connecté ou mode hors-ligne - afficher l'app principale
                ContentView()

            case .unauthenticated:
                // Utilisateur non connecté - afficher l'écran de connexion
                WelcomeAuthView()
            }
        }
    }
}

// MARK: - WelcomeAuthView (Écran d'accueil / Connexion moderne style Apple/Strava)

struct WelcomeAuthView: View {
    @Environment(AuthService.self) private var authService
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingEmailSignIn = false
    @State private var showingSignUp = false
    @State private var isLoadingOAuth = false
    @State private var loadingProvider: String?
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Fond avec dégradé subtil
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(.systemBackground), Color.blue.opacity(0.15)]
                        : [Color(.systemBackground), Color.blue.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    // Logo et titre
                    VStack(spacing: 20) {
                        // Icône avec effet
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.blue, Color.blue.opacity(0.7)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 100, height: 100)
                                .shadow(color: .blue.opacity(0.3), radius: 20, x: 0, y: 10)

                            Image(systemName: "paraglider")
                                .font(.system(size: 50))
                                .foregroundStyle(.white)
                        }

                        VStack(spacing: 8) {
                            Text("ParaFlightLog")
                                .font(.system(size: 32, weight: .bold, design: .rounded))

                            Text("Votre carnet de vol parapente".localized)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.bottom, 50)

                    Spacer()

                    // Zone de connexion
                    VStack(spacing: 16) {
                        // Sign in with Apple (priorité Apple)
                        AppleSignInButton(isLoading: loadingProvider == "apple") {
                            await signInWithOAuth(.apple)
                        }

                        // Sign in with Google
                        GoogleSignInButton(isLoading: loadingProvider == "google") {
                            await signInWithOAuth(.google)
                        }

                        // Séparateur
                        HStack(spacing: 16) {
                            Rectangle()
                                .fill(Color(.separator).opacity(0.5))
                                .frame(height: 1)
                            Text("ou".localized)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Rectangle()
                                .fill(Color(.separator).opacity(0.5))
                                .frame(height: 1)
                        }
                        .padding(.vertical, 8)

                        // Email Sign In
                        Button {
                            showingEmailSignIn = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "envelope.fill")
                                    .font(.body)
                                Text("Continuer avec email".localized)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // Create Account
                        Button {
                            showingSignUp = true
                        } label: {
                            Text("Créer un compte".localized)
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(.secondarySystemBackground))
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 24)
                    .disabled(isLoadingOAuth)

                    // Skip (continue without account)
                    Button {
                        authService.skipAuthentication()
                    } label: {
                        Text("Continuer sans compte".localized)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 16)
                    }

                    Spacer()
                        .frame(height: 20)

                    // Conditions d'utilisation
                    Text("En continuant, vous acceptez nos conditions d'utilisation".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 16)
                }
            }
            .sheet(isPresented: $showingEmailSignIn) {
                SignInView()
            }
            .sheet(isPresented: $showingSignUp) {
                SignUpView()
            }
            .alert("Erreur".localized, isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "Une erreur est survenue".localized)
            }
            .overlay {
                if isLoadingOAuth {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Connexion en cours...".localized)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                    }
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private func signInWithOAuth(_ provider: OAuthProvider) async {
        isLoadingOAuth = true
        loadingProvider = provider.rawValue

        do {
            try await authService.signInWithOAuth(provider: provider)

            // Après OAuth, vérifier/créer le profil utilisateur dans la collection users
            await ensureUserProfileExists()
        } catch {
            logError("OAuth \(provider) failed: \(error)", category: .auth)
            errorMessage = "Connexion \(provider.rawValue.capitalized) échouée. Veuillez réessayer.".localized
            showError = true
        }

        isLoadingOAuth = false
        loadingProvider = nil
    }

    /// S'assure qu'un profil utilisateur existe dans la collection users après connexion
    private func ensureUserProfileExists() async {
        guard let userId = authService.currentUserId,
              let email = authService.currentEmail else {
            return
        }

        do {
            // Vérifier si le profil existe déjà
            if let _ = try await UserService.shared.getCurrentProfile() {
                logInfo("Profile already exists for user: \(email)", category: .auth)
                return
            }
        } catch {
            // Le profil n'existe pas, on va le créer
            logInfo("Profile not found, creating one for: \(email)", category: .auth)
        }

        // Créer le profil
        let displayName = email.components(separatedBy: "@").first ?? "Pilote"
        let username = generateUsername(from: email)

        do {
            _ = try await UserService.shared.createProfile(
                authUserId: userId,
                email: email,
                displayName: displayName,
                username: username
            )
            logInfo("Profile created for user: \(email)", category: .auth)
        } catch {
            logError("Failed to create profile: \(error.localizedDescription)", category: .auth)
        }
    }

    private func generateUsername(from email: String) -> String {
        let base = email
            .components(separatedBy: "@").first?
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" } ?? "pilot"

        let randomSuffix = Int.random(in: 100...999)
        return "\(base)\(randomSuffix)"
    }
}

// MARK: - Apple Sign In Button (Style officiel Apple)

struct AppleSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task {
                await action()
            }
        } label: {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(colorScheme == .dark ? .black : .white)
                } else {
                    Image(systemName: "apple.logo")
                        .font(.title3)
                }
                Text("Continuer avec Apple".localized)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(colorScheme == .dark ? Color.white : Color.black)
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isLoading)
    }
}

// MARK: - Google Sign In Button (Style officiel Google)

struct GoogleSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task {
                await action()
            }
        } label: {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(.primary)
                } else {
                    // Logo Google (cercle coloré)
                    GoogleLogoView()
                        .frame(width: 20, height: 20)
                }
                Text("Continuer avec Google".localized)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 1)
            )
        }
        .disabled(isLoading)
    }
}

// MARK: - Google Logo View

struct GoogleLogoView: View {
    var body: some View {
        // Logo Google simplifié avec les couleurs officielles
        ZStack {
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.red, .yellow, .green, .blue, .red],
                        center: .center
                    ),
                    lineWidth: 3
                )
            Text("G")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.blue)
        }
    }
}

// MARK: - SignInView (Écran de connexion)

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var authService

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingForgotPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email".localized, text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Mot de passe".localized, text: $password)
                        .textContentType(.password)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await signIn()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Se connecter".localized)
                            }
                            Spacer()
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || isLoading)
                }

                Section {
                    Button {
                        showingForgotPassword = true
                    } label: {
                        Text("Mot de passe oublié ?".localized)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Connexion".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingForgotPassword) {
                ForgotPasswordView()
            }
        }
    }

    private func signIn() async {
        isLoading = true
        errorMessage = nil

        do {
            _ = try await authService.signIn(email: email, password: password)

            // Après connexion, s'assurer que le profil utilisateur existe
            await ensureUserProfileExists()

            await MainActor.run {
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// S'assure qu'un profil utilisateur existe dans la collection users après connexion
    private func ensureUserProfileExists() async {
        guard let userId = authService.currentUserId,
              let email = authService.currentEmail else {
            return
        }

        do {
            // Vérifier si le profil existe déjà
            if let _ = try await UserService.shared.getCurrentProfile() {
                return
            }
        } catch {
            // Le profil n'existe pas
        }

        // Créer le profil
        let displayName = email.components(separatedBy: "@").first ?? "Pilote"
        let username = generateUsername(from: email)

        do {
            _ = try await UserService.shared.createProfile(
                authUserId: userId,
                email: email,
                displayName: displayName,
                username: username
            )
        } catch {
            logError("Failed to create profile: \(error.localizedDescription)", category: .auth)
        }
    }

    private func generateUsername(from email: String) -> String {
        let base = email
            .components(separatedBy: "@").first?
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" } ?? "pilot"

        let randomSuffix = Int.random(in: 100...999)
        return "\(base)\(randomSuffix)"
    }
}

// MARK: - SignUpView (Écran d'inscription)

struct SignUpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var authService

    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var isFormValid: Bool {
        !displayName.isEmpty &&
        !email.isEmpty &&
        password.count >= 8 &&
        password == confirmPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom affiché".localized, text: $displayName)
                        .textContentType(.name)

                    TextField("Email".localized, text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    SecureField("Mot de passe".localized, text: $password)
                        .textContentType(.newPassword)

                    SecureField("Confirmer le mot de passe".localized, text: $confirmPassword)
                        .textContentType(.newPassword)
                } footer: {
                    Text("Le mot de passe doit contenir au moins 8 caractères".localized)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await signUp()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Créer mon compte".localized)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!isFormValid || isLoading)
                }
            }
            .navigationTitle("Inscription".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func signUp() async {
        isLoading = true
        errorMessage = nil

        do {
            _ = try await authService.signUp(email: email, password: password, name: displayName)

            // Créer le profil utilisateur
            if let userId = authService.currentUserId {
                let username = generateUsername(from: displayName)
                _ = try await UserService.shared.createProfile(
                    authUserId: userId,
                    email: email,
                    displayName: displayName,
                    username: username
                )
            }

            await MainActor.run {
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func generateUsername(from name: String) -> String {
        let base = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }

        let randomSuffix = Int.random(in: 100...999)
        return "\(base)\(randomSuffix)"
    }
}

// MARK: - ForgotPasswordView

struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var authService

    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email".localized, text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Entrez votre email pour recevoir un lien de réinitialisation".localized)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                if let success = successMessage {
                    Section {
                        Label(success, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button {
                        Task {
                            await sendResetEmail()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Envoyer le lien".localized)
                            }
                            Spacer()
                        }
                    }
                    .disabled(email.isEmpty || isLoading || successMessage != nil)
                }
            }
            .navigationTitle("Mot de passe oublié".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer".localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func sendResetEmail() async {
        isLoading = true
        errorMessage = nil

        do {
            try await authService.sendPasswordReset(email: email)
            await MainActor.run {
                successMessage = "Un email de réinitialisation a été envoyé".localized
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - ProfileView (Onglet Profil principal)

struct ProfileView: View {
    @Environment(AuthService.self) private var authService
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(\.modelContext) private var modelContext
    @Query private var wings: [Wing]
    @Query private var flights: [Flight]

    @State private var userProfile: CloudUserProfile?
    @State private var isLoading = false
    @State private var showingEditProfile = false
    @State private var showingSettings = false
    @State private var syncStatus: SyncStatus = .idle

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case success(Int, Int) // uploaded, downloaded
        case error(String)

        var isSyncing: Bool {
            if case .syncing = self { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Section Profil
                if let profile = userProfile {
                    Section {
                        ProfileHeaderView(profile: profile)
                            .onTapGesture {
                                showingEditProfile = true
                            }
                    }

                    // Stats rapides
                    Section("Statistiques") {
                        HStack {
                            StatItem(value: "\(flights.count)", label: "Vols".localized)
                            Divider()
                            StatItem(value: formatTotalDuration(), label: "Temps total".localized)
                            Divider()
                            StatItem(value: "\(wings.filter { !$0.isArchived }.count)", label: "Voiles".localized)
                        }
                        .padding(.vertical, 8)
                    }

                    // Synchronisation Cloud
                    Section {
                        SyncStatusView(status: syncStatus)

                        Button {
                            Task {
                                await performSync()
                            }
                        } label: {
                            HStack {
                                Label("Synchroniser maintenant".localized, systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if case .syncing = syncStatus {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(syncStatus.isSyncing)

                        // Vols en attente
                        let pendingCount = flights.filter { $0.needsSync }.count
                        if pendingCount > 0 {
                            HStack {
                                Label("\(pendingCount) vol(s) en attente".localized, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.orange)
                                Spacer()
                            }
                        }
                    } header: {
                        Text("Cloud".localized)
                    } footer: {
                        if let date = FlightSyncService.shared.lastSyncDate {
                            Text("Dernière sync: \(date.formatted(date: .abbreviated, time: .shortened))".localized)
                        }
                    }
                } else if isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Chargement du profil...".localized)
                            Spacer()
                        }
                        .padding()
                    }
                } else {
                    // Pas de profil - inviter à se connecter
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)

                            Text("Connectez-vous pour synchroniser vos vols".localized)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }

                // Section Réglages (toujours visible)
                Section("Réglages".localized) {
                    NavigationLink {
                        WingsView()
                    } label: {
                        Label("Mes voiles".localized, systemImage: "wind")
                    }

                    NavigationLink {
                        TimerView()
                    } label: {
                        Label("Chronomètre".localized, systemImage: "timer")
                    }

                    NavigationLink {
                        SpotsManagementView()
                    } label: {
                        Label("Gérer les spots".localized, systemImage: "mappin.and.ellipse")
                    }

                    NavigationLink {
                        WatchSettingsView()
                    } label: {
                        Label("Apple Watch".localized, systemImage: "applewatch")
                    }
                }

                // Section Préférences
                Section("Préférences".localized) {
                    Picker("Langue".localized, selection: Binding(
                        get: { localizationManager.currentLanguage },
                        set: { localizationManager.currentLanguage = $0 }
                    )) {
                        Text("Système".localized).tag(nil as LocalizationManager.Language?)
                        ForEach(LocalizationManager.Language.allCases, id: \.self) { language in
                            Text("\(language.flag) \(language.displayName)")
                                .tag(language as LocalizationManager.Language?)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // Section Données
                Section("Données".localized) {
                    NavigationLink {
                        BackupExportView(wings: wings, flights: flights)
                    } label: {
                        Label("Exporter backup".localized, systemImage: "archivebox")
                    }
                }

                // Section Compte
                if authService.isAuthenticated {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                try? await authService.signOut()
                                userProfile = nil
                            }
                        } label: {
                            Label("Se déconnecter".localized, systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else if case .skipped = authService.authState {
                    // User is in skip mode - offer to sign in
                    Section("Compte".localized) {
                        VStack(spacing: 12) {
                            Text("Mode hors-ligne".localized)
                                .font(.headline)
                            Text("Connectez-vous pour synchroniser vos vols et accéder aux fonctionnalités sociales.".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)

                        Button {
                            Task {
                                await authService.forceLogout()
                            }
                        } label: {
                            Label("Se connecter".localized, systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                }

                // À propos
                Section("À propos".localized) {
                    HStack {
                        Text("Version".localized)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Build".localized)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Profil".localized)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if userProfile != nil {
                        Button {
                            showingEditProfile = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingEditProfile) {
                if let profile = userProfile {
                    EditProfileView(profile: profile) { updatedProfile in
                        userProfile = updatedProfile
                    }
                }
            }
            .task {
                await loadProfile()
            }
            .refreshable {
                await loadProfile()
            }
            .onChange(of: authService.authState) { _, newState in
                // Recharger le profil quand l'état d'authentification change
                Task {
                    await loadProfile()
                }
            }
        }
    }

    private func loadProfile() async {
        // Vérifier si l'utilisateur peut accéder à l'app (authenticated ou skipped)
        guard authService.canAccessApp else {
            userProfile = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        // Si mode skipped (anonyme), créer un profil local
        if case .skipped = authService.authState {
            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            userProfile = CloudUserProfile(
                id: authService.currentUserId ?? UUID().uuidString,
                authUserId: authService.currentUserId ?? "",
                email: "local@paraflightlog.app",
                displayName: "Pilote Local".localized,
                username: "local_pilot",
                bio: nil,
                profilePhotoFileId: nil,
                homeLocationLat: nil,
                homeLocationLon: nil,
                homeLocationName: nil,
                pilotWeight: nil,
                isPremium: false,
                premiumUntil: nil,
                notificationsEnabled: false,
                totalFlights: flights.count,
                totalFlightSeconds: totalSeconds,
                xpTotal: 0,
                level: 1,
                currentStreak: 0,
                longestStreak: 0,
                createdAt: Date(),
                lastActiveAt: Date()
            )
            return
        }

        // Utilisateur authentifié - charger le profil cloud
        // Note: La collection 'users' doit exister dans Appwrite pour que cela fonctionne
        // En attendant, on utilise un profil local
        do {
            if let profile = try await UserService.shared.getCurrentProfile() {
                await MainActor.run {
                    userProfile = profile
                }
                return
            }
        } catch {
            // La collection n'existe peut-être pas encore ou autre erreur
            logError("Failed to load cloud profile: \(error.localizedDescription)", category: .auth)
        }

        // Profil cloud non trouvé ou erreur - essayer de le créer automatiquement
        if let userId = authService.currentUserId, let email = authService.currentEmail {
            logInfo("Creating cloud profile...", category: .auth)
            let username = generateUsername(from: email)
            let displayName = email.components(separatedBy: "@").first ?? "Pilote"

            do {
                let newProfile = try await UserService.shared.createProfile(
                    authUserId: userId,
                    email: email,
                    displayName: displayName,
                    username: username
                )
                await MainActor.run {
                    userProfile = newProfile
                }
                return
            } catch {
                logError("Failed to create cloud profile: \(error.localizedDescription)", category: .auth)
            }
        }

        // Fallback: créer un profil local temporaire
        await MainActor.run {
            createLocalFallbackProfile()
        }
    }

    private func createLocalFallbackProfile() {
        // Créer un profil local basique avec les infos de auth
        if let userId = authService.currentUserId, let email = authService.currentEmail {
            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            userProfile = CloudUserProfile(
                id: userId,
                authUserId: userId,
                email: email,
                displayName: email.components(separatedBy: "@").first ?? "Pilote",
                username: email.components(separatedBy: "@").first ?? "pilot",
                bio: nil,
                profilePhotoFileId: nil,
                homeLocationLat: nil,
                homeLocationLon: nil,
                homeLocationName: nil,
                pilotWeight: nil,
                isPremium: false,
                premiumUntil: nil,
                notificationsEnabled: true,
                totalFlights: flights.count,
                totalFlightSeconds: totalSeconds,
                xpTotal: 0,
                level: 1,
                currentStreak: 0,
                longestStreak: 0,
                createdAt: Date(),
                lastActiveAt: Date()
            )
        }
    }

    private func generateUsername(from email: String) -> String {
        let base = email
            .components(separatedBy: "@").first?
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" } ?? "pilot"

        let randomSuffix = Int.random(in: 100...999)
        return "\(base)\(randomSuffix)"
    }

    private func performSync() async {
        syncStatus = .syncing

        do {
            let result = try await FlightSyncService.shared.performFullSync(modelContext: modelContext)
            syncStatus = .success(result.uploaded, result.downloaded)

            // Reset après 3 secondes
            try? await Task.sleep(for: .seconds(3))
            syncStatus = .idle
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    private func formatTotalDuration() -> String {
        let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }
}

// MARK: - ProfileHeaderView

struct ProfileHeaderView: View {
    let profile: CloudUserProfile

    var body: some View {
        HStack(spacing: 16) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 70, height: 70)

                if profile.profilePhotoFileId != nil {
                    // TODO: Charger l'image depuis Appwrite
                    Image(systemName: "person.fill")
                        .font(.title)
                        .foregroundStyle(.blue)
                } else {
                    Text(profile.displayName.prefix(1).uppercased())
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("@\(profile.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - StatItem

struct StatItem: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - SyncStatusView

struct SyncStatusView: View {
    let status: ProfileView.SyncStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()

        case .syncing:
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Synchronisation en cours...".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .success(let uploaded, let downloaded):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(uploaded) uploadé(s), \(downloaded) téléchargé(s)".localized)
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }

        case .error(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - EditProfileView

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: CloudUserProfile
    let onSave: (CloudUserProfile) -> Void

    @State private var displayName: String
    @State private var username: String
    @State private var bio: String
    @State private var pilotWeight: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var usernameAvailable: Bool? = nil
    @State private var checkingUsername = false

    init(profile: CloudUserProfile, onSave: @escaping (CloudUserProfile) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _displayName = State(initialValue: profile.displayName)
        _username = State(initialValue: profile.username)
        _bio = State(initialValue: profile.bio ?? "")
        _pilotWeight = State(initialValue: profile.pilotWeight.map { String(Int($0)) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Informations".localized) {
                    TextField("Nom affiché".localized, text: $displayName)

                    HStack {
                        Text("@")
                            .foregroundStyle(.secondary)
                        TextField("username".localized, text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: username) { _, newValue in
                                checkUsernameAvailability(newValue)
                            }

                        if checkingUsername {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else if let available = usernameAvailable {
                            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(available ? .green : .red)
                        }
                    }

                    TextField("Bio".localized, text: $bio, axis: .vertical)
                        .lineLimit(3...5)
                }

                Section("Pilote".localized) {
                    HStack {
                        TextField("Poids (kg)".localized, text: $pilotWeight)
                            .keyboardType(.numberPad)
                        Text("kg")
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Modifier le profil".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer".localized) {
                        Task {
                            await saveProfile()
                        }
                    }
                    .disabled(isSaving || displayName.isEmpty || username.isEmpty)
                }
            }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView("Enregistrement...".localized)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            }
        }
    }

    private func checkUsernameAvailability(_ newUsername: String) {
        // Ne pas vérifier si c'est le même username
        guard newUsername.lowercased() != profile.username.lowercased() else {
            usernameAvailable = true
            return
        }

        // Vérifier le format
        guard UserService.shared.isValidUsername(newUsername) else {
            usernameAvailable = false
            return
        }

        checkingUsername = true
        usernameAvailable = nil

        Task {
            do {
                let available = try await UserService.shared.isUsernameAvailable(newUsername)
                await MainActor.run {
                    checkingUsername = false
                    usernameAvailable = available
                }
            } catch {
                await MainActor.run {
                    checkingUsername = false
                    usernameAvailable = nil
                }
            }
        }
    }

    private func saveProfile() async {
        isSaving = true
        errorMessage = nil

        do {
            let weight = Double(pilotWeight)

            try await UserService.shared.updateProfile(
                displayName: displayName,
                bio: bio.isEmpty ? nil : bio,
                username: username.lowercased() != profile.username ? username : nil,
                pilotWeight: weight
            )

            if let updatedProfile = try await UserService.shared.getCurrentProfile() {
                await MainActor.run {
                    onSave(updatedProfile)
                    dismiss()
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - WatchSettingsView

struct WatchSettingsView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Query private var wings: [Wing]

    @State private var showingImportSuccess = false
    @State private var importMessage = ""

    var body: some View {
        List {
            Section("Statut".localized) {
                HStack {
                    Text("App Watch".localized)
                    Spacer()
                    if watchManager.isWatchAppInstalled {
                        Label("Installée".localized, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Non installée".localized, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                HStack {
                    Text("Joignable".localized)
                    Spacer()
                    if watchManager.isWatchReachable {
                        Label("Oui".localized, systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Non".localized, systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                HStack {
                    Text("Voiles synchronisées".localized)
                    Spacer()
                    Text("\(wings.filter { !$0.isArchived }.count)")
                        .foregroundStyle(.secondary)
                }

                Button {
                    watchManager.sendWingsToWatch()
                    watchManager.sendWingsViaTransfer()
                    importMessage = "\(wings.filter { !$0.isArchived }.count) voile(s) envoyée(s)".localized
                    showingImportSuccess = true
                } label: {
                    Label("Synchroniser les voiles".localized, systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock) },
                    set: { newValue in
                        UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.watchAutoWaterLock)
                        let allowDismiss = UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true
                        watchManager.sendWatchSettings(autoWaterLock: newValue, allowSessionDismiss: allowDismiss)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verrouillage automatique".localized)
                        Text("Active le Water Lock au début d'un vol".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: UserDefaultsKeys.watchAllowSessionDismiss) as? Bool ?? true },
                    set: { newValue in
                        UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.watchAllowSessionDismiss)
                        let autoWaterLock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchAutoWaterLock)
                        watchManager.sendWatchSettings(autoWaterLock: autoWaterLock, allowSessionDismiss: newValue)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Autoriser l'annulation".localized)
                        Text("Permet d'annuler un vol sans le sauvegarder".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Options".localized)
            } footer: {
                Text("Ces paramètres sont synchronisés avec votre Watch".localized)
            }
        }
        .navigationTitle("Apple Watch".localized)
        .alert("Synchronisation".localized, isPresented: $showingImportSuccess) {
            Button("OK") { }
        } message: {
            Text(importMessage)
        }
    }
}
