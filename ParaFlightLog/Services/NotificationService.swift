//
//  NotificationService.swift
//  ParaFlightLog
//
//  Service de gestion des notifications push
//  Demande de permission, enregistrement et gestion de l'historique
//  Target: iOS only
//

import Foundation
import UserNotifications
import UIKit

// MARK: - Notification Errors

enum NotificationError: LocalizedError {
    case permissionDenied
    case registrationFailed
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Permission de notification refusée"
        case .registrationFailed:
            return "Échec de l'enregistrement aux notifications"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - NotificationService

@Observable
final class NotificationService {
    static let shared = NotificationService()

    // MARK: - Properties

    private(set) var isAuthorized: Bool = false
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Init

    private init() {
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
