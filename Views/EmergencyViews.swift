//
//  EmergencyViews.swift
//  ParaFlightLog
//
//  Vues pour la gestion des urgences
//  - Liste des contacts d'urgence
//  - Ajout/modification de contacts
//  - Écran SOS
//  Target: iOS only
//

import SwiftUI
import CoreLocation
import Combine

// MARK: - EmergencyContactsView

/// Vue principale de gestion des contacts d'urgence
struct EmergencyContactsView: View {
    @State private var contacts: [EmergencyContact] = []
    @State private var isLoading = true
    @State private var showingAddContact = false
    @State private var contactToEdit: EmergencyContact?
    @State private var errorMessage: String?

    var body: some View {
        List {
            // Section info
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.title)
                        .foregroundStyle(.red)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Contacts d'urgence".localized)
                            .font(.headline)
                        Text("Ces personnes seront contactées en cas d'alerte SOS pendant un vol.".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            // Section contacts
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding()
                } else if contacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)

                        Text("Aucun contact d'urgence".localized)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Text("Ajoutez au moins un contact pour pouvoir utiliser la fonction SOS.".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    ForEach(contacts) { contact in
                        EmergencyContactRow(contact: contact) {
                            contactToEdit = contact
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteContact(contact) }
                            } label: {
                                Label("Supprimer".localized, systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if !contact.isPrimary {
                                Button {
                                    Task { await setPrimary(contact) }
                                } label: {
                                    Label("Principal".localized, systemImage: "star.fill")
                                }
                                .tint(.yellow)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Contacts".localized)
                    Spacer()
                    Button {
                        showingAddContact = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            } footer: {
                if !contacts.isEmpty {
                    Text("Glissez vers la gauche pour supprimer, vers la droite pour définir comme contact principal.".localized)
                }
            }

            // Section SOS
            Section {
                NavigationLink {
                    SOSTestView()
                } label: {
                    HStack {
                        Image(systemName: "sos.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)

                        VStack(alignment: .leading) {
                            Text("Tester l'alerte SOS".localized)
                                .font(.headline)
                            Text("Vérifiez que vos contacts reçoivent bien le message".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(contacts.isEmpty)
            } footer: {
                Text("L'alerte SOS enverra un SMS avec votre position GPS à tous vos contacts d'urgence.".localized)
            }
        }
        .navigationTitle("Urgence".localized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadContacts()
        }
        .refreshable {
            await loadContacts()
        }
        .sheet(isPresented: $showingAddContact) {
            AddEmergencyContactView { contact in
                contacts.append(contact)
                contacts.sort { $0.isPrimary && !$1.isPrimary }
            }
        }
        .sheet(item: $contactToEdit) { contact in
            EditEmergencyContactView(contact: contact) { updated in
                if let index = contacts.firstIndex(where: { $0.id == updated.id }) {
                    contacts[index] = updated
                }
                contacts.sort { $0.isPrimary && !$1.isPrimary }
            }
        }
        .alert("Erreur".localized, isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadContacts() async {
        isLoading = true
        await EmergencyService.shared.loadContacts()
        contacts = EmergencyService.shared.contacts
        isLoading = false
    }

    private func deleteContact(_ contact: EmergencyContact) async {
        do {
            try await EmergencyService.shared.deleteContact(contact)
            contacts.removeAll { $0.id == contact.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setPrimary(_ contact: EmergencyContact) async {
        do {
            try await EmergencyService.shared.setPrimaryContact(contact)
            await loadContacts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - EmergencyContactRow

struct EmergencyContactRow: View {
    let contact: EmergencyContact
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(contact.isPrimary ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Text(contact.name.prefix(1).uppercased())
                        .font(.headline)
                        .foregroundStyle(contact.isPrimary ? .red : .blue)
                }

                // Infos
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(contact.name)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if contact.isPrimary {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                        }
                    }

                    Text(contact.phoneNumber)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let relationship = contact.relationship, !relationship.isEmpty {
                        Text(relationship)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AddEmergencyContactView

struct AddEmergencyContactView: View {
    @Environment(\.dismiss) private var dismiss

    let onAdded: (EmergencyContact) -> Void

    @State private var name = ""
    @State private var phoneNumber = ""
    @State private var email = ""
    @State private var relationship = ""
    @State private var isPrimary = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom".localized, text: $name)
                        .textContentType(.name)

                    TextField("Téléphone".localized, text: $phoneNumber)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)

                    TextField("Email (optionnel)".localized, text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)

                    TextField("Relation (ex: Conjoint, Parent)".localized, text: $relationship)
                }

                Section {
                    Toggle("Contact principal".localized, isOn: $isPrimary)
                } footer: {
                    Text("Le contact principal sera contacté en priorité.".localized)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Nouveau contact".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter".localized) {
                        Task { await addContact() }
                    }
                    .disabled(name.isEmpty || phoneNumber.isEmpty || isLoading)
                }
            }
        }
    }

    private func addContact() async {
        isLoading = true
        errorMessage = nil

        do {
            let contact = try await EmergencyService.shared.addContact(
                name: name,
                phoneNumber: phoneNumber,
                email: email.isEmpty ? nil : email,
                relationship: relationship.isEmpty ? nil : relationship,
                isPrimary: isPrimary
            )
            onAdded(contact)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - EditEmergencyContactView

struct EditEmergencyContactView: View {
    @Environment(\.dismiss) private var dismiss

    let contact: EmergencyContact
    let onUpdated: (EmergencyContact) -> Void

    @State private var name: String
    @State private var phoneNumber: String
    @State private var email: String
    @State private var relationship: String
    @State private var isPrimary: Bool
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(contact: EmergencyContact, onUpdated: @escaping (EmergencyContact) -> Void) {
        self.contact = contact
        self.onUpdated = onUpdated
        self._name = State(initialValue: contact.name)
        self._phoneNumber = State(initialValue: contact.phoneNumber)
        self._email = State(initialValue: contact.email ?? "")
        self._relationship = State(initialValue: contact.relationship ?? "")
        self._isPrimary = State(initialValue: contact.isPrimary)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom".localized, text: $name)
                        .textContentType(.name)

                    TextField("Téléphone".localized, text: $phoneNumber)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)

                    TextField("Email (optionnel)".localized, text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)

                    TextField("Relation".localized, text: $relationship)
                }

                Section {
                    Toggle("Contact principal".localized, isOn: $isPrimary)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Modifier".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler".localized) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer".localized) {
                        Task { await updateContact() }
                    }
                    .disabled(name.isEmpty || phoneNumber.isEmpty || isLoading)
                }
            }
        }
    }

    private func updateContact() async {
        isLoading = true
        errorMessage = nil

        var updated = contact
        updated.name = name
        updated.phoneNumber = phoneNumber
        updated.email = email.isEmpty ? nil : email
        updated.relationship = relationship.isEmpty ? nil : relationship
        updated.isPrimary = isPrimary

        do {
            try await EmergencyService.shared.updateContact(updated)
            onUpdated(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - SOSTestView

struct SOSTestView: View {
    @State private var showingSOSConfirmation = false
    @State private var showingSOSActive = false
    @State private var isTriggering = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Warning
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.orange)

                Text("Mode Test".localized)
                    .font(.title)
                    .fontWeight(.bold)

                Text("Cette page permet de tester l'alerte SOS sans envoyer de vraies notifications.".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            // SOS Button
            Button {
                showingSOSConfirmation = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 150, height: 150)
                        .shadow(color: .red.opacity(0.5), radius: 20)

                    VStack(spacing: 4) {
                        Text("SOS")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Appuyer pour tester".localized)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .disabled(isTriggering)

            Spacer()

            // Info
            VStack(spacing: 8) {
                Text("En vol, le bouton SOS sera accessible depuis l'écran de vol.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Il enverra automatiquement un SMS avec votre position GPS à vos contacts d'urgence.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .navigationTitle("Test SOS".localized)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Tester l'alerte SOS?".localized,
            isPresented: $showingSOSConfirmation,
            titleVisibility: .visible
        ) {
            Button("Déclencher le test".localized, role: .destructive) {
                Task { await triggerTestSOS() }
            }
            Button("Annuler".localized, role: .cancel) {}
        } message: {
            Text("Un message de test sera généré mais non envoyé.".localized)
        }
        .sheet(isPresented: $showingSOSActive) {
            SOSActiveView(isTest: true)
        }
        .alert("Erreur".localized, isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func triggerTestSOS() async {
        isTriggering = true

        // Simuler une position
        let testLocation = CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1)

        do {
            _ = try await EmergencyService.shared.triggerSOS(
                location: testLocation,
                altitude: 1500,
                customMessage: "[TEST] Ceci est un test de l'alerte SOS"
            )
            showingSOSActive = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isTriggering = false
    }
}

// MARK: - SOSActiveView

struct SOSActiveView: View {
    let isTest: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isCancelling = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var elapsedSeconds = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Alert animation
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: 200, height: 200)

                    Circle()
                        .fill(Color.red.opacity(0.4))
                        .frame(width: 150, height: 150)

                    Circle()
                        .fill(Color.red)
                        .frame(width: 100, height: 100)

                    Image(systemName: "sos")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }

                if isTest {
                    Text("TEST EN COURS".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.orange)
                } else {
                    Text("ALERTE SOS ACTIVE".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                }

                // Timer
                Text(formatTime(elapsedSeconds))
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)

                // Status
                if let alert = EmergencyService.shared.activeAlert {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "location.fill")
                            Text("Position envoyée".localized)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.green)

                        Text("\(String(format: "%.4f", alert.latitude)), \(String(format: "%.4f", alert.longitude))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Cancel button
                Button {
                    Task { await cancelSOS() }
                } label: {
                    HStack {
                        if isCancelling {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isTest ? "Terminer le test".localized : "Annuler l'alerte".localized)
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isCancelling)
                .padding(.horizontal)

                if !isTest {
                    Text("N'annulez l'alerte que si vous êtes en sécurité.".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .onReceive(timer) { _ in
                elapsedSeconds += 1
            }
        }
        .interactiveDismissDisabled(!isTest)
    }

    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func cancelSOS() async {
        isCancelling = true
        do {
            try await EmergencyService.shared.cancelSOS()
            dismiss()
        } catch {
            logError("Failed to cancel SOS: \(error)", category: .general)
        }
        isCancelling = false
    }
}

// MARK: - SOSButton (pour intégration dans les vues de vol)

struct SOSButton: View {
    let location: CLLocationCoordinate2D?
    let altitude: Double?

    @State private var showingConfirmation = false
    @State private var showingSOSActive = false
    @State private var isTriggering = false

    var body: some View {
        Button {
            showingConfirmation = true
        } label: {
            Image(systemName: "sos.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.red)
                .shadow(color: .red.opacity(0.5), radius: 5)
        }
        .disabled(isTriggering || EmergencyService.shared.contacts.isEmpty)
        .confirmationDialog(
            "Déclencher l'alerte SOS?".localized,
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("DÉCLENCHER SOS".localized, role: .destructive) {
                Task { await triggerSOS() }
            }
            Button("Annuler".localized, role: .cancel) {}
        } message: {
            Text("Un SMS avec votre position sera envoyé à vos contacts d'urgence.".localized)
        }
        .sheet(isPresented: $showingSOSActive) {
            SOSActiveView(isTest: false)
        }
    }

    private func triggerSOS() async {
        guard let location = location else { return }

        isTriggering = true

        do {
            _ = try await EmergencyService.shared.triggerSOS(
                location: location,
                altitude: altitude
            )
            showingSOSActive = true
        } catch {
            logError("Failed to trigger SOS: \(error)", category: .general)
        }

        isTriggering = false
    }
}

// MARK: - Previews

#Preview("Emergency Contacts") {
    NavigationStack {
        EmergencyContactsView()
    }
}

#Preview("SOS Button") {
    SOSButton(
        location: CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
        altitude: 1500
    )
}
