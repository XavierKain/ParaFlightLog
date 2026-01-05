//
//  OfflineViews.swift
//  ParaFlightLog
//
//  Vues pour le mode hors-ligne
//  Indicateur de connexion, actions en attente, gestion de la sync
//  Target: iOS only
//

import SwiftUI

// MARK: - OfflineIndicator

/// Indicateur de connexion dans la barre de navigation
struct OfflineIndicator: View {
    private let offlineService = OfflineSyncService.shared

    var body: some View {
        if offlineService.isOffline {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                Text("Hors ligne".localized)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.orange)
            .clipShape(Capsule())
        }
    }
}

// MARK: - OfflineBanner

/// Bannière d'avertissement hors-ligne
struct OfflineBanner: View {
    private let offlineService = OfflineSyncService.shared
    @State private var isExpanded = false

    var body: some View {
        if offlineService.isOffline {
            VStack(spacing: 0) {
                Button {
                    withAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(.white)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mode hors-ligne".localized)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)

                            if offlineService.pendingActionsCount > 0 {
                                Text("\(offlineService.pendingActionsCount) action(s) en attente".localized)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding()
                    .background(Color.orange)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Vos modifications seront synchronisées automatiquement lorsque la connexion sera rétablie.".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if offlineService.pendingActionsCount > 0 {
                            NavigationLink {
                                PendingActionsView()
                            } label: {
                                Label("Voir les actions en attente".localized, systemImage: "clock.arrow.circlepath")
                                    .font(.subheadline)
                            }
                        }

                        if let lastSync = offlineService.lastSyncDate {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.green)
                                Text("Dernière sync: \(lastSync, style: .relative)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                }
            }
        }
    }
}

// MARK: - PendingActionsView

/// Vue listant toutes les actions en attente de synchronisation
struct PendingActionsView: View {
    private let offlineService = OfflineSyncService.shared
    @State private var showingClearConfirmation = false

    var body: some View {
        List {
            if offlineService.pendingActions.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.green)

                        Text("Aucune action en attente".localized)
                            .font(.headline)

                        Text("Toutes vos données sont synchronisées.".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                Section {
                    ForEach(offlineService.pendingActions) { action in
                        PendingActionRow(action: action)
                    }
                    .onDelete(perform: deleteActions)
                } header: {
                    Text("\(offlineService.pendingActionsCount) action(s) en attente".localized)
                } footer: {
                    Text("Ces actions seront synchronisées automatiquement lorsque la connexion sera rétablie.".localized)
                }

                Section {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label("Supprimer toutes les actions".localized, systemImage: "trash")
                    }
                }
            }

            Section {
                HStack {
                    Text("État de la connexion".localized)
                    Spacer()
                    NetworkStatusBadge()
                }

                if let lastSync = offlineService.lastSyncDate {
                    HStack {
                        Text("Dernière synchronisation".localized)
                        Spacer()
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                if offlineService.networkStatus == .online && !offlineService.pendingActions.isEmpty {
                    Button {
                        Task {
                            await offlineService.processPendingActions()
                        }
                    } label: {
                        if offlineService.isSyncing {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Synchronisation en cours...".localized)
                            }
                        } else {
                            Label("Synchroniser maintenant".localized, systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(offlineService.isSyncing)
                }
            } header: {
                Text("Synchronisation".localized)
            }
        }
        .navigationTitle("Actions en attente".localized)
        .alert("Supprimer les actions ?".localized, isPresented: $showingClearConfirmation) {
            Button("Annuler".localized, role: .cancel) {}
            Button("Supprimer".localized, role: .destructive) {
                offlineService.clearAllPendingActions()
            }
        } message: {
            Text("Cette action est irréversible. Les modifications non synchronisées seront perdues.".localized)
        }
    }

    private func deleteActions(at offsets: IndexSet) {
        for index in offsets {
            let action = offlineService.pendingActions[index]
            offlineService.removeAction(action.id)
        }
    }
}

// MARK: - PendingActionRow

/// Ligne affichant une action en attente
struct PendingActionRow: View {
    let action: PendingAction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: actionIcon)
                .font(.title3)
                .foregroundStyle(actionColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(actionTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Text(action.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if action.retryCount > 0 {
                        Text("(\(action.retryCount) tentative(s))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let error = action.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            if action.retryCount > 0 {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var actionIcon: String {
        switch action.type {
        case .createFlight:
            return "airplane.departure"
        case .updateFlight:
            return "airplane"
        case .deleteFlight:
            return "airplane.circle"
        case .uploadPhoto:
            return "photo.badge.arrow.up"
        case .deletePhoto:
            return "photo.badge.minus"
        case .updateProfile:
            return "person.circle"
        case .addEmergencyContact:
            return "person.badge.plus"
        case .updateEmergencyContact:
            return "person.text.rectangle"
        case .deleteEmergencyContact:
            return "person.badge.minus"
        }
    }

    private var actionColor: Color {
        switch action.type {
        case .createFlight, .addEmergencyContact:
            return .green
        case .updateFlight, .updateProfile, .updateEmergencyContact:
            return .blue
        case .deleteFlight, .deletePhoto, .deleteEmergencyContact:
            return .red
        case .uploadPhoto:
            return .orange
        }
    }

    private var actionTitle: String {
        switch action.type {
        case .createFlight:
            return "Créer un vol".localized
        case .updateFlight:
            return "Modifier un vol".localized
        case .deleteFlight:
            return "Supprimer un vol".localized
        case .uploadPhoto:
            return "Uploader une photo".localized
        case .deletePhoto:
            return "Supprimer une photo".localized
        case .updateProfile:
            return "Mettre à jour le profil".localized
        case .addEmergencyContact:
            return "Ajouter un contact d'urgence".localized
        case .updateEmergencyContact:
            return "Modifier un contact d'urgence".localized
        case .deleteEmergencyContact:
            return "Supprimer un contact d'urgence".localized
        }
    }
}

// MARK: - NetworkStatusBadge

/// Badge affichant l'état de la connexion
struct NetworkStatusBadge: View {
    private let offlineService = OfflineSyncService.shared

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch offlineService.networkStatus {
        case .online:
            return .green
        case .offline:
            return .red
        case .unknown:
            return .gray
        }
    }

    private var statusText: String {
        switch offlineService.networkStatus {
        case .online:
            return "En ligne".localized
        case .offline:
            return "Hors ligne".localized
        case .unknown:
            return "Inconnu".localized
        }
    }
}

// MARK: - OfflineSyncStatusView

/// Vue compacte affichant l'état de synchronisation hors-ligne
struct OfflineSyncStatusView: View {
    private let offlineService = OfflineSyncService.shared

    var body: some View {
        HStack(spacing: 8) {
            if offlineService.isSyncing {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Synchronisation...".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if offlineService.isOffline {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.orange)
                Text("Hors ligne".localized)
                    .font(.caption)
                    .foregroundStyle(.orange)

                if offlineService.pendingActionsCount > 0 {
                    Text("(\(offlineService.pendingActionsCount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if offlineService.pendingActionsCount > 0 {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.blue)
                Text("\(offlineService.pendingActionsCount) en attente".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("Synchronisé".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - OfflineAwareModifier

/// Modificateur pour afficher automatiquement la bannière hors-ligne
struct OfflineAwareModifier: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            OfflineBanner()
            content
        }
    }
}

extension View {
    /// Ajoute la bannière hors-ligne en haut de la vue
    func offlineAware() -> some View {
        modifier(OfflineAwareModifier())
    }
}

// MARK: - Previews

#Preview("Offline Banner") {
    VStack {
        OfflineBanner()
        Spacer()
    }
}

#Preview("Pending Actions") {
    NavigationStack {
        PendingActionsView()
    }
}

#Preview("Network Status Badge") {
    NetworkStatusBadge()
        .padding()
}
