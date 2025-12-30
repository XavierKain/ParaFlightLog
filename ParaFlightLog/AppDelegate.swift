//
//  AppDelegate.swift
//  ParaFlightLog
//
//  AppDelegate pour gérer les push notifications APNs
//  Target: iOS only
//

import UIKit
import UserNotifications
import Appwrite

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    // MARK: - Application Lifecycle

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configurer le delegate des notifications
        UNUserNotificationCenter.current().delegate = self

        // Restaurer la session d'authentification
        Task {
            await AuthService.shared.restoreSession()
        }

        return true
    }

    // MARK: - Push Notifications Registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Convertir le token en string hexadécimale
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        logInfo("APNs device token: \(tokenString)", category: .notification)

        // Enregistrer le token dans le profil utilisateur
        Task {
            do {
                try await UserService.shared.registerDeviceToken(tokenString)
                logInfo("Device token registered with server", category: .notification)
            } catch {
                logError("Failed to register device token: \(error.localizedDescription)", category: .notification)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logError("Failed to register for remote notifications: \(error.localizedDescription)", category: .notification)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Appelé quand une notification est reçue alors que l'app est au premier plan
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        logInfo("Notification received in foreground: \(userInfo)", category: .notification)

        // Afficher la notification même si l'app est au premier plan
        completionHandler([.banner, .sound, .badge])
    }

    /// Appelé quand l'utilisateur tape sur une notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        logInfo("Notification tapped: \(userInfo)", category: .notification)

        // Traiter l'action de la notification
        handleNotificationAction(userInfo: userInfo)

        completionHandler()
    }

    // MARK: - Notification Handling

    private func handleNotificationAction(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else {
            return
        }

        switch type {
        case "zone_alert", "friend_flight", "spot_alert":
            // Ouvrir le détail du vol
            if let flightId = userInfo["flightId"] as? String {
                NotificationCenter.default.post(
                    name: .openFlightDetail,
                    object: nil,
                    userInfo: ["flightId": flightId]
                )
            }

        case "like", "comment":
            // Ouvrir le détail du vol liké/commenté
            if let flightId = userInfo["flightId"] as? String {
                NotificationCenter.default.post(
                    name: .openFlightDetail,
                    object: nil,
                    userInfo: ["flightId": flightId]
                )
            }

        case "follow":
            // Ouvrir le profil du nouveau follower
            if let userId = userInfo["fromUserId"] as? String {
                NotificationCenter.default.post(
                    name: .openPilotProfile,
                    object: nil,
                    userInfo: ["userId": userId]
                )
            }

        default:
            logWarning("Unknown notification type: \(type)", category: .notification)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openFlightDetail = Notification.Name("openFlightDetail")
    static let openPilotProfile = Notification.Name("openPilotProfile")
    static let openSpotDetail = Notification.Name("openSpotDetail")
}

// MARK: - UserService Extension for Device Token

extension UserService {
    /// Enregistre le device token APNs dans le profil utilisateur
    func registerDeviceToken(_ token: String) async throws {
        guard let profile = currentUserProfile else {
            throw UserProfileError.notAuthenticated
        }

        do {
            // Récupérer les tokens existants ou créer un nouveau tableau
            var tokens: [String] = []

            // Récupérer le document actuel pour obtenir les tokens existants
            let document = try await AppwriteService.shared.databases.getDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                documentId: profile.id
            )

            if let existingTokens = document.data["deviceTokens"]?.value as? [String] {
                tokens = existingTokens
            }

            // Ajouter le nouveau token s'il n'existe pas déjà
            if !tokens.contains(token) {
                tokens.append(token)

                // Limiter à 5 tokens max (pour gérer plusieurs appareils)
                if tokens.count > 5 {
                    tokens = Array(tokens.suffix(5))
                }

                // Mettre à jour le document
                _ = try await AppwriteService.shared.databases.updateDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: AppwriteConfig.usersCollectionId,
                    documentId: profile.id,
                    data: [
                        "deviceTokens": tokens,
                        "lastActiveAt": Date().ISO8601Format()
                    ]
                )

                logInfo("Device token added to profile", category: .notification)
            }
        } catch {
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }

    /// Supprime un device token du profil utilisateur
    func removeDeviceToken(_ token: String) async throws {
        guard let profile = currentUserProfile else {
            throw UserProfileError.notAuthenticated
        }

        do {
            let document = try await AppwriteService.shared.databases.getDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                documentId: profile.id
            )

            if var tokens = document.data["deviceTokens"]?.value as? [String] {
                tokens.removeAll { $0 == token }

                _ = try await AppwriteService.shared.databases.updateDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: AppwriteConfig.usersCollectionId,
                    documentId: profile.id,
                    data: [
                        "deviceTokens": tokens
                    ]
                )

                logInfo("Device token removed from profile", category: .notification)
            }
        } catch {
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }
}
