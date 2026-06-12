//
//  EmergencyService.swift
//  ParaFlightLog
//
//  Service de gestion des urgences et contacts d'urgence (100 % local)
//  - Gestion des contacts d'urgence (persistance UserDefaults en JSON)
//  - Déclenchement d'alertes SOS locales
//  - Génération de SMS/appels vers les contacts (sms: / tel:)
//  Target: iOS only
//

import Foundation
import CoreLocation
import MessageUI

// MARK: - Emergency Models

/// Contact d'urgence
struct EmergencyContact: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var phoneNumber: String
    var email: String?
    var relationship: String?
    var isPrimary: Bool
    let createdAt: Date

    /// Initialisation directe
    init(
        id: String = UUID().uuidString,
        name: String,
        phoneNumber: String,
        email: String? = nil,
        relationship: String? = nil,
        isPrimary: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
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
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let message: String?
    let isActive: Bool
    let triggeredAt: Date
    let resolvedAt: Date?

    /// Initialisation directe
    init(
        id: String = UUID().uuidString,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        message: String? = nil,
        isActive: Bool = true,
        triggeredAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.message = message
        self.isActive = isActive
        self.triggeredAt = triggeredAt
        self.resolvedAt = resolvedAt
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
    case invalidData(String)
    case noContacts
    case messagingNotAvailable
    case persistenceError(String)

    var errorDescription: String? {
        switch self {
        case .invalidData(let msg):
            return "Données invalides: \(msg)"
        case .noContacts:
            return "Aucun contact d'urgence configuré".localized
        case .messagingNotAvailable:
            return "L'envoi de SMS n'est pas disponible sur cet appareil".localized
        case .persistenceError(let msg):
            return "Erreur d'enregistrement: \(msg)"
        }
    }
}

// MARK: - EmergencyService

@Observable
@MainActor
final class EmergencyService {
    static let shared = EmergencyService()

    // MARK: - Properties

    /// Clés de persistance locale (UserDefaults)
    private static let contactsKey = "emergency_contacts"
    private static let activeAlertKey = "emergency_active_sos_alert"

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
        // Restaure immédiatement les données locales
        contacts = Self.loadContactsFromDisk()
        activeAlert = Self.loadActiveAlertFromDisk()
    }

    // MARK: - Local Persistence

    /// Charge les contacts depuis UserDefaults
    private static func loadContactsFromDisk() -> [EmergencyContact] {
        guard let data = UserDefaults.standard.data(forKey: contactsKey) else { return [] }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([EmergencyContact].self, from: data)
        } catch {
            return []
        }
    }

    /// Charge l'alerte SOS active depuis UserDefaults
    private static func loadActiveAlertFromDisk() -> SOSAlert? {
        guard let data = UserDefaults.standard.data(forKey: activeAlertKey) else { return nil }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let alert = try decoder.decode(SOSAlert.self, from: data)
            return alert.isActive ? alert : nil
        } catch {
            return nil
        }
    }

    /// Sauvegarde les contacts dans UserDefaults
    private func saveContacts() throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(contacts)
            UserDefaults.standard.set(data, forKey: Self.contactsKey)
        } catch {
            throw EmergencyError.persistenceError(error.localizedDescription)
        }
    }

    /// Sauvegarde (ou efface) l'alerte SOS active dans UserDefaults
    private func saveActiveAlert() throws {
        guard let alert = activeAlert else {
            UserDefaults.standard.removeObject(forKey: Self.activeAlertKey)
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(alert)
            UserDefaults.standard.set(data, forKey: Self.activeAlertKey)
        } catch {
            throw EmergencyError.persistenceError(error.localizedDescription)
        }
    }

    // MARK: - Contacts Management

    /// Charge les contacts d'urgence depuis la persistance locale
    func loadContacts() async {
        isLoading = true
        defer { isLoading = false }

        contacts = Self.loadContactsFromDisk()
        contacts.sort { $0.isPrimary && !$1.isPrimary }

        logInfo("Loaded \(contacts.count) emergency contacts", category: .general)
    }

    /// Ajoute un contact d'urgence
    func addContact(
        name: String,
        phoneNumber: String,
        email: String? = nil,
        relationship: String? = nil,
        isPrimary: Bool = false
    ) async throws -> EmergencyContact {
        // Si c'est le premier contact, le rendre principal
        let shouldBePrimary = isPrimary || contacts.isEmpty

        let contact = EmergencyContact(
            name: name,
            phoneNumber: phoneNumber,
            email: email,
            relationship: relationship,
            isPrimary: shouldBePrimary
        )

        // Si le nouveau contact est principal, retirer ce statut des autres
        if shouldBePrimary {
            for index in contacts.indices {
                contacts[index].isPrimary = false
            }
        }

        contacts.append(contact)
        contacts.sort { $0.isPrimary && !$1.isPrimary }
        try saveContacts()

        logInfo("Added emergency contact: \(name)", category: .general)
        return contact
    }

    /// Met à jour un contact d'urgence
    func updateContact(_ contact: EmergencyContact) async throws {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        }
        contacts.sort { $0.isPrimary && !$1.isPrimary }
        try saveContacts()

        logInfo("Updated emergency contact: \(contact.name)", category: .general)
    }

    /// Supprime un contact d'urgence
    func deleteContact(_ contact: EmergencyContact) async throws {
        contacts.removeAll { $0.id == contact.id }
        try saveContacts()

        logInfo("Deleted emergency contact: \(contact.name)", category: .general)
    }

    /// Définit un contact comme principal
    func setPrimaryContact(_ contact: EmergencyContact) async throws {
        for index in contacts.indices {
            contacts[index].isPrimary = (contacts[index].id == contact.id)
        }
        contacts.sort { $0.isPrimary && !$1.isPrimary }
        try saveContacts()

        logInfo("Set primary emergency contact: \(contact.name)", category: .general)
    }

    // MARK: - SOS Alerts

    /// Déclenche une alerte SOS locale
    func triggerSOS(
        location: CLLocationCoordinate2D,
        altitude: Double? = nil,
        customMessage: String? = nil
    ) async throws -> SOSAlert {
        guard !contacts.isEmpty else {
            throw EmergencyError.noContacts
        }

        let alert = SOSAlert(
            latitude: location.latitude,
            longitude: location.longitude,
            altitude: altitude,
            message: customMessage ?? defaultSOSMessage
        )

        activeAlert = alert
        try saveActiveAlert()

        logInfo("SOS Alert triggered at \(location.latitude), \(location.longitude)", category: .general)

        return alert
    }

    /// Annule une alerte SOS
    func cancelSOS() async throws {
        guard activeAlert != nil else { return }

        activeAlert = nil
        try saveActiveAlert()

        logInfo("SOS Alert cancelled", category: .general)
    }

    /// Vérifie s'il y a une alerte SOS active (restaurée depuis la persistance locale)
    func checkActiveAlert() async {
        activeAlert = Self.loadActiveAlertFromDisk()
    }

    // MARK: - SMS / Call Generation

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

    /// Génère l'URL pour appeler un contact (tel:)
    func generateCallURL(for contact: EmergencyContact) -> URL? {
        let sanitized = contact.phoneNumber.filter { !$0.isWhitespace }
        return URL(string: "tel:\(sanitized)")
    }

    // MARK: - Cleanup

    /// Nettoie les données locales
    func clearLocalData() {
        contacts = []
        activeAlert = nil
        UserDefaults.standard.removeObject(forKey: Self.contactsKey)
        UserDefaults.standard.removeObject(forKey: Self.activeAlertKey)
    }
}
