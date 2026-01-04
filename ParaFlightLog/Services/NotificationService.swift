//
//  NotificationService.swift
//  ParaFlightLog
//
//  Service de gestion des notifications push et cloud
//  Demande de permission, enregistrement et gestion de l'historique
//  Target: iOS only
//

import Foundation
import UserNotifications
import UIKit
import Appwrite

// MARK: - Notification Errors

enum NotificationError: LocalizedError {
    case permissionDenied
    case registrationFailed
    case notAuthenticated
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Permission de notification refusée"
        case .registrationFailed:
            return "Échec de l'enregistrement aux notifications"
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - App Notification Model

/// Représente une notification dans l'app (stockée dans Appwrite)
struct AppNotification: Identifiable, Equatable {
    let id: String
    let userId: String
    let type: NotificationType
    let title: String
    let body: String
    let data: [String: String]
    var isRead: Bool
    let createdAt: Date

    enum NotificationType: String, CaseIterable {
        case flightStarted = "flight_started"       // Un pilote suivi a démarré un vol
        case badgeEarned = "badge_earned"           // Vous avez gagné un badge
        case spotActivity = "spot_activity"          // Activité sur un spot suivi
        case newFollower = "new_follower"           // Quelqu'un vous suit
        case flightLiked = "flight_liked"           // Quelqu'un a aimé votre vol
        case flightComment = "flight_comment"       // Commentaire sur votre vol
        case levelUp = "level_up"                   // Vous avez monté de niveau
        case system = "system"                      // Message système

        var icon: String {
            switch self {
            case .flightStarted: return "airplane.departure"
            case .badgeEarned: return "medal.fill"
            case .spotActivity: return "mappin.circle.fill"
            case .newFollower: return "person.badge.plus"
            case .flightLiked: return "heart.fill"
            case .flightComment: return "bubble.left.fill"
            case .levelUp: return "arrow.up.circle.fill"
            case .system: return "bell.fill"
            }
        }

        var color: String {
            switch self {
            case .flightStarted: return "blue"
            case .badgeEarned: return "yellow"
            case .spotActivity: return "green"
            case .newFollower: return "purple"
            case .flightLiked: return "red"
            case .flightComment: return "orange"
            case .levelUp: return "cyan"
            case .system: return "gray"
            }
        }
    }

    /// Initialisation depuis un dictionnaire Appwrite
    init(from data: [String: Any]) throws {
        guard let id = data["$id"] as? String else {
            throw NotificationError.unknown("Missing notification ID")
        }

        self.id = id
        self.userId = data["userId"] as? String ?? ""
        self.title = data["title"] as? String ?? ""
        self.body = data["body"] as? String ?? ""
        self.isRead = data["isRead"] as? Bool ?? false

        // Parse type
        let typeString = data["type"] as? String ?? "system"
        self.type = NotificationType(rawValue: typeString) ?? .system

        // Parse data JSON
        if let dataJson = data["data"] as? String,
           let jsonData = dataJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String] {
            self.data = parsed
        } else {
            self.data = [:]
        }

        // Parse date
        if let createdAtStr = data["$createdAt"] as? String,
           let createdAt = ISO8601DateFormatter().date(from: createdAtStr) {
            self.createdAt = createdAt
        } else {
            self.createdAt = Date()
        }
    }

    /// Texte relatif de la date
    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
}

// MARK: - NotificationService

@Observable
final class NotificationService {
    static let shared = NotificationService()

    // MARK: - Properties

    private(set) var isAuthorized: Bool = false
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Notifications cloud chargées
    private(set) var notifications: [AppNotification] = []

    /// Nombre de notifications non lues
    private(set) var unreadCount: Int = 0

    /// Indique si on charge les notifications
    private(set) var isLoadingNotifications: Bool = false

    private let databases: Databases

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases
        Task {
            await checkCurrentStatus()
        }
    }

    // MARK: - Permission

    /// Demande la permission pour les notifications push
    @MainActor
    func requestPermission() async throws -> Bool {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            isAuthorized = granted

            if granted {
                // S'enregistrer pour les notifications distantes
                await registerForRemoteNotifications()
                logInfo("Push notification permission granted", category: .notification)
            } else {
                logWarning("Push notification permission denied", category: .notification)
            }

            // Mettre à jour le statut
            await checkCurrentStatus()

            return granted
        } catch {
            logError("Failed to request notification permission: \(error.localizedDescription)", category: .notification)
            throw NotificationError.unknown(error.localizedDescription)
        }
    }

    /// Vérifie le statut actuel des permissions
    @MainActor
    func checkCurrentStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        authorizationStatus = settings.authorizationStatus
        isAuthorized = settings.authorizationStatus == .authorized

        logInfo("Notification status: \(settings.authorizationStatus.rawValue)", category: .notification)
    }

    /// Enregistre l'app pour recevoir les notifications distantes
    @MainActor
    private func registerForRemoteNotifications() async {
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Badge Management

    /// Met à jour le badge de l'application
    @MainActor
    func updateBadge(count: Int) async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(count)
        } catch {
            logError("Failed to update badge: \(error.localizedDescription)", category: .notification)
        }
    }

    /// Efface le badge
    @MainActor
    func clearBadge() async {
        await updateBadge(count: 0)
    }

    // MARK: - Local Notifications

    /// Programme une notification locale (pour tests ou rappels)
    func scheduleLocalNotification(
        title: String,
        body: String,
        identifier: String,
        timeInterval: TimeInterval = 5,
        userInfo: [String: Any] = [:]
    ) async throws {
        guard isAuthorized else {
            throw NotificationError.permissionDenied
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            logInfo("Local notification scheduled: \(identifier)", category: .notification)
        } catch {
            throw NotificationError.unknown(error.localizedDescription)
        }
    }

    /// Annule une notification programmée
    func cancelNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Annule toutes les notifications programmées
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: - Settings

    /// Ouvre les réglages de l'app pour activer les notifications
    @MainActor
    func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        if UIApplication.shared.canOpenURL(settingsURL) {
            UIApplication.shared.open(settingsURL)
        }
    }

    // MARK: - Cloud Notifications

    /// Récupère les notifications depuis Appwrite
    func fetchNotifications() async throws -> [AppNotification] {
        guard AuthService.shared.isAuthenticated,
              let userId = AuthService.shared.currentUserId else {
            throw NotificationError.notAuthenticated
        }

        isLoadingNotifications = true
        defer { isLoadingNotifications = false }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.notificationsCollectionId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.orderDesc("$createdAt"),
                    Query.limit(50)
                ]
            )

            var fetchedNotifications: [AppNotification] = []
            for doc in documents.documents {
                var nativeData: [String: Any] = [:]
                for (key, value) in doc.data {
                    if let anyCodable = value as? AnyCodable {
                        nativeData[key] = anyCodable.value
                    } else {
                        nativeData[key] = value
                    }
                }

                if let notification = try? AppNotification(from: nativeData) {
                    fetchedNotifications.append(notification)
                }
            }

            await MainActor.run {
                self.notifications = fetchedNotifications
                self.unreadCount = fetchedNotifications.filter { !$0.isRead }.count
            }

            logInfo("Fetched \(fetchedNotifications.count) notifications (\(unreadCount) unread)", category: .notification)
            return fetchedNotifications

        } catch let error as AppwriteError {
            // Si la collection n'existe pas, retourner vide silencieusement
            if error.message.contains("Collection with the requested ID could not be found") {
                logInfo("Notifications collection not found - feature not yet available", category: .notification)
                return []
            }
            logError("Failed to fetch notifications: \(error.message)", category: .notification)
            throw NotificationError.unknown(error.message)
        }
    }

    /// Marque une notification comme lue
    func markAsRead(notificationId: String) async throws {
        guard AuthService.shared.isAuthenticated else {
            throw NotificationError.notAuthenticated
        }

        do {
            _ = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.notificationsCollectionId,
                documentId: notificationId,
                data: ["isRead": true]
            )

            // Mettre à jour localement
            await MainActor.run {
                if let index = notifications.firstIndex(where: { $0.id == notificationId }) {
                    var updated = notifications[index]
                    updated.isRead = true
                    notifications[index] = updated
                    unreadCount = notifications.filter { !$0.isRead }.count
                }
            }

            logInfo("Notification marked as read: \(notificationId)", category: .notification)

        } catch let error as AppwriteError {
            logError("Failed to mark notification as read: \(error.message)", category: .notification)
            throw NotificationError.unknown(error.message)
        }
    }

    /// Marque toutes les notifications comme lues
    func markAllAsRead() async throws {
        guard AuthService.shared.isAuthenticated else {
            throw NotificationError.notAuthenticated
        }

        let unreadNotifications = notifications.filter { !$0.isRead }

        for notification in unreadNotifications {
            do {
                _ = try await databases.updateDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: AppwriteConfig.notificationsCollectionId,
                    documentId: notification.id,
                    data: ["isRead": true]
                )
            } catch {
                logWarning("Failed to mark notification \(notification.id) as read", category: .notification)
            }
        }

        await MainActor.run {
            for i in notifications.indices {
                var updated = notifications[i]
                updated.isRead = true
                notifications[i] = updated
            }
            unreadCount = 0
        }

        logInfo("All notifications marked as read", category: .notification)
    }

    /// Récupère le nombre de notifications non lues
    func getUnreadCount() async throws -> Int {
        guard AuthService.shared.isAuthenticated,
              let userId = AuthService.shared.currentUserId else {
            return 0
        }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.notificationsCollectionId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.equal("isRead", value: false),
                    Query.limit(100)
                ]
            )

            let count = documents.total
            await MainActor.run {
                self.unreadCount = count
            }
            return count

        } catch {
            return 0
        }
    }

    /// Supprime une notification
    func deleteNotification(notificationId: String) async throws {
        guard AuthService.shared.isAuthenticated else {
            throw NotificationError.notAuthenticated
        }

        do {
            _ = try await databases.deleteDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.notificationsCollectionId,
                documentId: notificationId
            )

            await MainActor.run {
                notifications.removeAll { $0.id == notificationId }
                unreadCount = notifications.filter { !$0.isRead }.count
            }

            logInfo("Notification deleted: \(notificationId)", category: .notification)

        } catch let error as AppwriteError {
            logError("Failed to delete notification: \(error.message)", category: .notification)
            throw NotificationError.unknown(error.message)
        }
    }

    /// Efface les données locales (déconnexion)
    func clearLocalData() {
        notifications = []
        unreadCount = 0
    }
}

// MARK: - Notification Prompt View Helper

extension NotificationService {
    /// Vérifie si on doit demander la permission (premier lancement ou pas encore déterminé)
    var shouldPromptForPermission: Bool {
        authorizationStatus == .notDetermined
    }

    /// Vérifie si les notifications sont désactivées dans les réglages
    var isDisabledInSettings: Bool {
        authorizationStatus == .denied
    }
}
