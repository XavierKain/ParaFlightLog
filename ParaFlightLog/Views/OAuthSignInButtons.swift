//
//  OAuthSignInButtons.swift
//  ParaFlightLog
//
//  The "Continue with Apple / Google / Facebook" rows, shared by the Account
//  screen and the inline sign-in form in the condition-report sheet so both
//  offer exactly the same providers.
//  Target: iOS only
//

import SwiftUI

struct OAuthSignInButtons: View {
    /// Provider whose web sheet is running, if any — drives the row spinner.
    let pending: OAuthProviderKind?
    /// Set while another sign-in (email or provider) is in flight.
    let isDisabled: Bool
    let action: (OAuthProviderKind) -> Void

    var body: some View {
        ForEach(OAuthProviderKind.allCases) { provider in
            Button {
                action(provider)
            } label: {
                HStack {
                    Image(systemName: provider.symbolName)
                        .frame(width: 22)
                        .foregroundStyle(.primary)
                    Text("Continue with \(provider.displayName)")
                    if pending == provider {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isDisabled)
        }
    }
}

// MARK: - Preview

#Preview {
    Form {
        Section {
            OAuthSignInButtons(pending: .google, isDisabled: false) { _ in }
        } header: {
            Text("Or continue with")
        }
    }
}
