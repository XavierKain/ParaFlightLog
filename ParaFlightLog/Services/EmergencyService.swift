//
//  EmergencyService.swift
//  ParaFlightLog
//
//  Service de gestion des urgences et contacts d'urgence
//  - Gestion des contacts d'urgence
//  - Déclenchement d'alertes SOS
//  - Envoi de SMS/notifications aux contacts
//  Target: iOS only
//

import Foundation
import Appwrite
import CoreLocation
import MessageUI

// MARK: - Emergency Models

/// Contact d'urgence
struct EmergencyContact: Identifiable, Codable, Equatable {
    let id: String
    let userId: String
    var name: String
    var phoneNumber: String
    var email: String?
    var relationship: String?
    var isPrimary: Bool
    let createdAt: Date

    /// Initialisation depuis Appwrite
    init(from data: [String: Any]) throws {
        guard let id = data["$id"] as? String else {
            throw EmergencyError.invalidData("Missing $id")
        }

        self.id = id
        self.userId = data["userId"] as? String ?? ""
        self.name = data["name"] as? String ?? ""
        self.phoneNumber = data["phoneNumber"] as? String ?? ""
        self.email = data["email"] as? String
        self.relationship = data["relationship"] as? String
        self.isPrimary = data["isPrimary"] as? Bool ?? false

        if let createdAtStr = data["createdAt"] as? String,
           let date = ISO8601DateFormatter().date(from: createdAtStr) {
            self.createdAt = date
        } else {
            self.createdAt = Date()
        }
    }

    /// Initialisation directe
    init(
        id: String = UUID().uuidString,
        userId: String,
        name: String,
        phoneNumber: String,
        email: String? = nil,
        relationship: String? = nil,
        isPrimary: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.phoneNumber = phoneNumber
        self.email = email
        self.relationship = relationship
        self.isPrimary = isPrimary
        self.createdAt = createdAt
    }
}

/// Alerte SOS
struct SOSAlert: Identifiable, Codable {
    let id: String
    let oderId: String
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let message: String?
    let isActive: Bool
    let triggeredAt: Date
    let resolvedAt: Date?

    /// Initialisation depuis Appwrite
    init(from data: [String: Any]) throws {
        guard let id = data["$id"] as? String else {
            throw EmergencyError.invalidData("Missing $id")
        }

        self.id = id
        self.oderId = data["userId"] as? String ?? ""
        self.latitude = data["latitude"] as? Double ?? 0
        self.longitude = data["longitude"] as? Double ?? 0
        self.altitude = data["altitude"] as? Double
        self.message = data["message"] as? String
        self.isActive = data["isActive"] as? Bool ?? true

        if let triggeredAtStr = data["triggeredAt"] as? String,
           let date = ISO8601DateFormatter().date(from: triggeredAtStr) {
            self.triggeredAt = date
        } else {
            self.triggeredAt = Date()
        }

        if let resolvedAtStr = data["resolvedAt"] as? String {
            self.resolvedAt = ISO8601DateFormatter().date(from: resolvedAtStr)
        } else {
            self.resolvedAt = nil
        }
    }

    /// Coordonnées CLLocation
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// URL Google Maps
    var googleMapsURL: URL? {
        URL(string: "https://maps.google.com/?q=\(latitude),\(longitude)")
    }

    /// URL Apple Maps
    var appleMapsURL: URL? {
        URL(string: "maps://?ll=\(latitude),\(longitude)")
    }
}

// MARK: - Emergency Errors

enum EmergencyError: LocalizedError {
    case notAuthenticated
    case invalidData(String)
    case noContacts
    case messagingNotAvailable
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté".localized
        case .invalidData(let msg):
            return "Données invalides: \(msg)"
        case .noContacts:
            return "Aucun contact d'urgence configuré".localized
        case .messagingNotAvailable:
            return "L'envoi de SMS n'est pas disponible sur cet appareil".localized
        case .networkError(let msg):
            return "Erreur réseau: \(msg)"
        }
    }
}

// MARK: - EmergencyService

@Observable
final class EmergencyService {
    static let shared = EmergencyService()

    // MARK: - Properties

    private let databases: Databases

    /// Contacts d'urgence de l'utilisateur
    private(set) var contacts: [EmergencyContact] = []

    /// Alerte SOS active
    private(set) var activeAlert: SOSAlert?

    /// État de chargement
    private(set) var isLoading = false

    /// Message SOS par défaut
    let defaultSOSMessage = "URGENCE: Je suis en difficulté pendant un vol en parapente. Ma position GPS est indiquée ci-dessous. Veuillez contacter les secours."

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases
    }

    // MARK: - Contacts Management

    /// Charge les contacts d'urgence de l'utilisateur
    func loadContacts() async {
        guard let userId = AuthService.shared.currentUserId else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.emergencyContactsCollectionId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.orderDesc("isPrimary"),
                    Query.limit(10)
                ]
            )

            var loadedContacts: [EmergencyContact] = []
            for doc in documents.documents {
                var nativeData: [String: Any] = [:]
                for (key, value) in doc.data {
                    if let anyCodable = value as? AnyCodable {
                        nativeData[key] = anyCodable.value
                    } else {
                        nativeData[key] = value
                    }
                }

                if let contact = try? EmergencyContact(from: nativeData) {
                    loadedContacts.append(contact)
                }
            }

            await MainActor.run {
                self.contacts = loadedContacts
            }

            logInfo("Loaded \(loadedContacts.count) emergency contacts", category: .general)
        } catch {
            logError("Failed to load emergency contacts: \(error.localizedDescription)", category: .general)
        }
    }

    /// Ajoute un contact d'urgence
    func addContact(
        name: String,
        phoneNumber: String,
        email: String? = nil,
        relationship: String? = nil,
        isPrimary: Bool = false
    ) async throws -> EmergencyContact {
        guard let userId = AuthService.shared.currentUserId else {
            throw EmergencyError.notAuthenticated
        }

        // Si c'est le premier contact, le rendre principal
        let shouldBePrimary = isPrimary || contacts.isEmpty

        do {
            let document = try await databases.createDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.emergencyContactsCollectionId,
                documentId: ID.unique(),
                data: [
                    "userId": userId,
                    "name": name,
                    "phoneNumber": phoneNumber,
                    "email": email as Any,
                    "relationship": relationship as Any,
                    "isPrimary": shouldBePrimary,
                    "createdAt": Date().ISO8601Format()
                ]
            )

            var nativeData: [String: Any] = [:]
            for (key, value) in document.data {
                if let anyCodable = value as? AnyCodable {
                    nativeData[key] = anyCodable.value
                } else {
                    nativeData[key] = value
                }
            }

            let contact = try EmergencyContact(from: nativeData)

            await MainActor.run {
                self.contacts.append(contact)
                self.contacts.sort { $0.isPrimary && !$1.isPrimary }
            }

            logInfo("Added emergency contact: \(name)", category: .general)
            return contact
        } catch let error as AppwriteError {
            throw EmergencyError.networkError(error.message)
        }
    }

    /// Met à jour un contact d'urgence
    func updateContact(_ contact: EmergencyContact) async throws {
        do {
            _ = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.emergencyContactsCollectionId,
                documentId: contact.id,
                data: [
                    "name": contact.name,
                    "phoneNumber": contact.phoneNumber,
                    "email": contact.email as Any,
                    "relationship": contact.relationship as Any,
                    "isPrimary": contact.isPrimary
                ]
            )

            await MainActor.run {
                if let index = self.contacts.firstIndex(where: { $0.id == contact.id }) {
                    self.contacts[index] = contact
                }
                self.contacts.sort { $0.isPrimary && !$1.isPrimary }
            }

            logInfo("Updated emergency contact: \(contact.name)", category: .general)
        } catch let error as AppwriteError {
            throw EmergencyError.networkError(error.message)
        }
    }

    /// Supprime un contact d'urgence
    func deleteContact(_ contact: EmergencyContact) async throws {
        do {
            _ = try await databases.deleteDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.emergencyContactsCollectionId,
                documentId: contact.id
            )

            await MainActor.run {
                self.contacts.removeAll { $0.id == contact.id }
            }

            logInfo("Deleted emergency contact: \(contact.name)", category: .general)
        } catch let error as AppwriteError {
            throw EmergencyError.networkError(error.message)
        }
    }

    /// Définit un contact comme principal
    func setPrimaryContact(_ contact: EmergencyContact) async throws {
        // D'abord, retirer le statut principal des autres contacts
        for existingContact in contacts where existingContact.isPrimary && existingContact.id != contact.id {
            var updated = existingContact
            updated.isPrimary = false
            try await updateContact(updated)
        }

        // Ensuite, définir ce contact comme principal
        var updatedContact = contact
        updatedContact.isPrimary = true
        try await updateContact(updatedContact)
    }

    // MARK: - SOS Alerts

    /// Déclenche une alerte SOS
    func triggerSOS(
        location: CLLocationCoordinate2D,
        altitude: Double? = nil,
        customMessage: String? = nil
    ) async throws -> SOSAlert {
        guard let userId = AuthService.shared.currentUserId else {
            throw EmergencyError.notAuthenticated
        }

        guard !contacts.isEmpty else {
            throw EmergencyError.noContacts
        }

        do {
            let document = try await databases.createDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.sosAlertsCollectionId,
                documentId: ID.unique(),
                data: [
                    "userId": userId,
                    "latitude": location.latitude,
                    "longitude": location.longitude,
                    "altitude": altitude as Any,
                    "message": customMessage ?? defaultSOSMessage,
                    "isActive": true,
                    "triggeredAt": Date().ISO8601Format()
                ]
            )

            var nativeData: [String: Any] = [:]
            for (key, value) in document.data {
                if let anyCodable = value as? AnyCodable {
                    nativeData[key] = anyCodable.value
                } else {
                    nativeData[key] = value
                }
            }

            let alert = try SOSAlert(from: nativeData)

            await MainActor.run {
                self.activeAlert = alert
            }

            logInfo("SOS Alert triggered at \(location.latitude), \(location.longitude)", category: .general)

            return alert
        } catch let error as AppwriteError {
            throw EmergencyError.networkError(error.message)
        }
    }

    /// Annule une alerte SOS
    func cancelSOS() async throws {
        guard let alert = activeAlert else { return }

        do {
            _ = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.sosAlertsCollectionId,
                documentId: alert.id,
                data: [
                    "isActive": false,
                    "resolvedAt": Date().ISO8601Format()
                ]
            )

            await MainActor.run {
                self.activeAlert = nil
            }

            logInfo("SOS Alert cancelled", category: .general)
        } catch let error as AppwriteError {
            throw EmergencyError.networkError(error.message)
        }
    }

    /// Vérifie s'il y a une alerte SOS active
    func checkActiveAlert() async {
        guard let userId = AuthService.shared.currentUserId else { return }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.sosAlertsCollectionId,
                queries: [
                    Query.equal("userId", value: userId),
                    Query.equal("isActive", value: true),
                    Query.limit(1)
                ]
            )

            if let doc = documents.documents.first {
                var nativeData: [String: Any] = [:]
                for (key, value) in doc.data {
                    if let anyCodable = value as? AnyCodable {
                        nativeData[key] = anyCodable.value
                    } else {
                        nativeData[key] = value
                    }
                }

                if let alert = try? SOSAlert(from: nativeData) {
                    await MainActor.run {
                        self.activeAlert = alert
                    }
                }
            }
        } catch {
            logError("Failed to check active SOS alert: \(error.localizedDescription)", category: .general)
        }
    }

    // MARK: - SMS Generation

    /// Génère le message SMS pour l'alerte SOS
    func generateSOSMessage(for alert: SOSAlert, pilotName: String) -> String {
        var message = "🆘 ALERTE SOS - PARAPENTE\n\n"
        message += "Pilote: \(pilotName)\n"
        message += "Heure: \(alert.triggeredAt.formatted(date: .abbreviated, time: .shortened))\n\n"
        message += "📍 Position GPS:\n"
        message += "Lat: \(String(format: "%.6f", alert.latitude))\n"
        message += "Lon: \(String(format: "%.6f", alert.longitude))\n"

        if let altitude = alert.altitude {
            message += "Alt: \(Int(altitude))m\n"
        }

        message += "\n🗺️ Voir sur la carte:\n"
        message += "https://maps.google.com/?q=\(alert.latitude),\(alert.longitude)\n\n"

        if let customMessage = alert.message, customMessage != defaultSOSMessage {
            message += "Message: \(customMessage)\n\n"
        }

        message += "⚠️ Contactez les secours si nécessaire!"

        return message
    }

    /// Génère l'URL pour envoyer un SMS à tous les contacts
    func generateSMSURL(for alert: SOSAlert, pilotName: String) -> URL? {
        let phoneNumbers = contacts.map { $0.phoneNumber }.joined(separator: ",")
        let message = generateSOSMessage(for: alert, pilotName: pilotName)

        guard let encodedMessage = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        return URL(string: "sms:\(phoneNumbers)&body=\(encodedMessage)")
    }

    // MARK: - Cleanup

    /// Nettoie les données locales
    func clearLocalData() {
        contacts = []
        activeAlert = nil
    }
}
