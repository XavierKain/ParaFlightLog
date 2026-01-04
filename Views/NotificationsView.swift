//
//  NotificationsView.swift
//  ParaFlightLog
//
//  Vue affichant les notifications de l'utilisateur
//  Target: iOS only
//

import SwiftUI

// MARK: - NotificationsView

struct NotificationsView: View {
    @Environment(AuthService.self) private var authService
    @State private var notifications: [AppNotification] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if !authService.isAuthenticated {
                    NotAuthenticatedNotificationsView()
                } else if isLoading && notifications.isEmpty {
                    ProgressView("Chargement...".localized)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if notifications.isEmpty {
                    EmptyNotificationsView()
                } else {
                    notificationsList
                }
            }
            .navigationTitle("Notifications".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !notifications.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                Task {
                                    await markAllAsRead()
                                }
                            } label: {
                                Label("Tout marquer comme lu".localized, systemImage: "checkmark.circle")
                            }

                            Button(role: .destructive) {
                                Task {
                                    await refreshNotifications()
                                }
                            } label: {
                                Label("Actualiser".localized, systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .task {
                await refreshNotifications()
            }
        }
    }

    private var notificationsList: some View {
        List {
            ForEach(notifications) { notification in
                NotificationRowView(notification: notification)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                await deleteNotification(notification)
                            }
                        } label: {
                            Label("Supprimer".localized, systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !notification.isRead {
                            Button {
                                Task {
                                    await markAsRead(notification)
                                }
                            } label: {
                                Label("Lu".localized, systemImage: "checkmark")
                            }
                            .tint(.blue)
                        }
                    }
                    .onTapGesture {
                        Task {
                            await markAsRead(notification)
                            handleNotificationTap(notification)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await refreshNotifications()
        }
    }

    // MARK: - Actions

    private func refreshNotifications() async {
        isLoading = true
        errorMessage = nil

        do {
            notifications = try await NotificationService.shared.fetchNotifications()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func markAsRead(_ notification: AppNotification) async {
        guard !notification.isRead else { return }

        do {
            try await NotificationService.shared.markAsRead(notificationId: notification.id)
            if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                var updated = notifications[index]
                updated.isRead = true
                notifications[index] = updated
            }
        } catch {
            // Silently fail
        }
    }

    private func markAllAsRead() async {
        do {
            try await NotificationService.shared.markAllAsRead()
            for i in notifications.indices {
                var updated = notifications[i]
                updated.isRead = true
                notifications[i] = updated
            }
        } catch {
            // Silently fail
        }
    }

    private func deleteNotification(_ notification: AppNotification) async {
        do {
            try await NotificationService.shared.deleteNotification(notificationId: notification.id)
            notifications.removeAll { $0.id == notification.id }
        } catch {
            // Silently fail
        }
    }

    private func handleNotificationTap(_ notification: AppNotification) {
        // Navigation basée sur le type de notification
        switch notification.type {
        case .flightStarted, .flightLiked, .flightComment:
            // Naviguer vers le vol si flightId est dans les data
            if let flightId = notification.data["flightId"] {
                // TODO: NavigationPath vers PublicFlightDetailView
                logInfo("Navigate to flight: \(flightId)", category: .notification)
            }
        case .badgeEarned, .levelUp:
            // Naviguer vers les badges
            logInfo("Navigate to badges", category: .notification)
        case .newFollower:
            // Naviguer vers le profil du follower
            if let followerId = notification.data["followerId"] {
                logInfo("Navigate to profile: \(followerId)", category: .notification)
            }
        case .spotActivity:
            // Naviguer vers le spot
            if let spotId = notification.data["spotId"] {
                logInfo("Navigate to spot: \(spotId)", category: .notification)
            }
        case .system:
            break
        }
    }
}

// MARK: - NotificationRowView

struct NotificationRowView: View {
    let notification: AppNotification

    var body: some View {
        HStack(spacing: 12) {
            // Icône du type
            notificationIcon
                .frame(width: 44, height: 44)
                .background(iconBackgroundColor.opacity(0.15))
                .clipShape(Circle())

            // Contenu
            VStack(alignment: .leading, spacing: 4) {
                Text(notification.title)
                    .font(.subheadline)
                    .fontWeight(notification.isRead ? .regular : .semibold)
                    .foregroundStyle(notification.isRead ? .secondary : .primary)

                Text(notification.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(notification.relativeDate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Indicateur non lu
            if !notification.isRead {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var notificationIcon: some View {
        Image(systemName: notification.type.icon)
            .font(.title3)
            .foregroundStyle(iconBackgroundColor)
    }

    private var iconBackgroundColor: Color {
        switch notification.type.color {
        case "blue": return .blue
        case "yellow": return .yellow
        case "green": return .green
        case "purple": return .purple
        case "red": return .red
        case "orange": return .orange
        case "cyan": return .cyan
        default: return .gray
        }
    }
}

// MARK: - EmptyNotificationsView

struct EmptyNotificationsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("Aucune notification".localized)
                .font(.headline)

            Text("Vos notifications apparaîtront ici".localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - NotAuthenticatedNotificationsView

struct NotAuthenticatedNotificationsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("Connectez-vous".localized)
                .font(.headline)

            Text("Connectez-vous pour recevoir des notifications".localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Notification Badge View (pour TabView)

struct NotificationBadgeView: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Previews

#Preview {
    NotificationsView()
        .environment(AuthService.shared)
}
