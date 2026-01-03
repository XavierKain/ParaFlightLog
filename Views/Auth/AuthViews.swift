//
//  AuthViews.swift
//  ParaFlightLog
//
//  Vues d'authentification: SignIn, SignUp, ForgotPassword
//  Note: WelcomeAuthView et AuthContainerView sont dans ProfileViews.swift
//  Target: iOS only
//

import SwiftUI
import AuthenticationServices

// MARK: - Sign In View

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var authService

    @State private var email = ""
    @State private var password = ""
    @State private var showForgotPassword = false
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email".localized, text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    SecureField("Mot de passe".localized, text: $password)
                        .textContentType(.password)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        Task {
                            await signIn()
                        }
                    } label: {
                        if isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else {
                            Text("Se connecter".localized)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || isLoading)
                }

                Section {
                    Button("Mot de passe oublié ?".localized) {
                        showForgotPassword = true
                    }
                    .foregroundStyle(.blue)
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
            .sheet(isPresented: $showForgotPassword) {
                ForgotPasswordView(email: email)
            }
        }
    }

    private func signIn() async {
        isLoading = true
        errorMessage = nil

        do {
            try await authService.signIn(email: email, password: password)

            // Après connexion, s'assurer que le profil utilisateur existe
            await ensureUserProfileExists()

            dismiss()
        } catch let error as AuthError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
            // Silently fail - profile will be created later if needed
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

// MARK: - Sign Up View

struct SignUpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var authService

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    private var isFormValid: Bool {
        !name.isEmpty &&
        !email.isEmpty &&
        password.count >= 8 &&
        password == confirmPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Informations".localized)) {
                    TextField("Nom".localized, text: $name)
                        .textContentType(.name)
                        .autocapitalization(.words)

                    TextField("Email".localized, text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }

                Section(header: Text("Mot de passe".localized), footer: Text("Minimum 8 caractères".localized)) {
                    SecureField("Mot de passe".localized, text: $password)
                        .textContentType(.newPassword)

                    SecureField("Confirmer".localized, text: $confirmPassword)
                        .textContentType(.newPassword)
                }

                if password != confirmPassword && !confirmPassword.isEmpty {
                    Section {
                        Text("Les mots de passe ne correspondent pas".localized)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        Task {
                            await signUp()
                        }
                    } label: {
                        if isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else {
                            Text("Créer mon compte".localized)
                                .frame(maxWidth: .infinity)
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
            try await authService.signUp(email: email, password: password, name: name)
            dismiss()
        } catch let error as AuthError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Forgot Password View

struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var authService

    @State var email: String
    @State private var isLoading = false
    @State private var showSuccess = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Un email de réinitialisation sera envoyé à cette adresse".localized)) {
                    TextField("Email".localized, text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button {
                        Task {
                            await resetPassword()
                        }
                    } label: {
                        if isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else {
                            Text("Envoyer le lien".localized)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(email.isEmpty || isLoading)
                }
            }
            .navigationTitle("Mot de passe oublié".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }
            }
            .alert("Email envoyé".localized, isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Vérifiez votre boîte mail pour réinitialiser votre mot de passe".localized)
            }
        }
    }

    private func resetPassword() async {
        isLoading = true
        errorMessage = nil

        do {
            try await authService.sendPasswordReset(email: email)
            showSuccess = true
        } catch let error as AuthError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Previews

#Preview("Sign In") {
    SignInView()
        .environment(AuthService.shared)
}

#Preview("Sign Up") {
    SignUpView()
        .environment(AuthService.shared)
}
