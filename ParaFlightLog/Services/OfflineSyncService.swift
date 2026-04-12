//
//  OfflineSyncService.swift
//  ParaFlightLog
//
//  Service de gestion du mode hors-ligne
//  Queue d'actions en attente, cache et synchronisation différée
//  Target: iOS only
//

import Foundation
import Network
import SwiftData
import Appwrite

// MARK: - Pending Action Types

/// Types d'actions en attente de synchronisation
enum PendingActionType: String, Codable {
    case createFlight = "create_flight"
    case updateFlight = "update_flight"
    case deleteFlight = "delete_flight"
    case uploadPhoto = "upload_photo"
    case deletePhoto = "delete_photo"
    case updateProfile = "update_profile"
    case addEmergencyContact = "add_emergency_contact"
    case updateEmergencyContact = "update_emergency_contact"
    case deleteEmergencyContact = "delete_emergency_contact"
}

// MARK: - Pending Action Model

/// Action en attente de synchronisation
struct PendingAction: Identifiable, Codable {
    let id: String
    let type: PendingActionType
    let entityId: String  // ID local de l'entité concernée
    let payload: Data     // Données sérialisées de l'action
    let createdAt: Date
    var retryCount: Int
    var lastError: String?

    init(
        id: String = UUID().uuidString,
        type: PendingActionType,
        entityId: String,
        payload: Data,
        createdAt: Date = Date(),
        retryCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.type = type
        self.entityId = entityId
        self.payload = payload
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

// MARK: - Network Status

enum NetworkStatus: Equatable {
    case online
    case offline
    case unknown
}

// MARK: - Offline Sync Errors

enum OfflineSyncError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case storageFailed(String)
    case syncFailed(String)
    case maxRetriesExceeded

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Échec de l'encodage des données".localized
        case .decodingFailed:
            return "Échec du décodage des données".localized
        case .storageFailed(let msg):
            return "Erreur de stockage: \(msg)"
        case .syncFailed(let msg):
            return "Échec de la synchronisation: \(msg)"
        case .maxRetriesExceeded:
            return "Nombre maximum de tentatives dépassé".localized
        }
    }
}

// MARK: - OfflineSyncService

@Observable
@MainActor
final class OfflineSyncService {
    static let shared = OfflineSyncService()

    // MARK: - Properties

    /// État de la connexion réseau
    private(set) var networkStatus: NetworkStatus = .unknown

    /// Actions en attente de synchronisation
    private(set) var pendingActions: [PendingAction] = []

    /// Dernière synchronisation réussie
    private(set) var lastSyncDate: Date?

    /// Synchronisation en cours
    private(set) var isSyncing = false

    /// Nombre maximum de tentatives par action
    private let maxRetries = 3

    /// Délai entre les tentatives (en secondes)
    private let retryDelaySeconds: TimeInterval = 30

    /// Moniteur réseau
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.paraflightlog.networkmonitor")

    /// Clé UserDefaults pour le stockage
    private let pendingActionsKey = "com.paraflightlog.pendingActions"
    private let lastSyncKey = "com.paraflightlog.lastSync"

    // MARK: - Init

    private init() {
        loadPendingActions()
        loadLastSyncDate()
        startNetworkMonitoring()
    }

    // MARK: - Network Monitoring

    /// Démarre la surveillance réseau
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let newStatus: NetworkStatus = path.status == .satisfied ? .online : .offline
            Task { @MainActor [weak self] in
                guard let self else { return }
                let oldStatus = self.networkStatus
                self.networkStatus = newStatus

                // Tenter une sync quand on repasse en ligne
                if oldStatus == .offline && newStatus == .online {
                    await self.processPendingActions()
                }
            }
        }
        networkMonitor.start(queue: monitorQueue)
    }

    /// Arrête la surveillance réseau
    func stopNetworkMonitoring() {
        networkMonitor.cancel()
    }

    // MARK: - Queue Management

    /// Vérifie si on est hors ligne
    var isOffline: Bool {
        networkStatus == .offline
    }

    /// Nombre d'actions en attente
    var pendingActionsCount: Int {
        pendingActions.count
    }

    /// Ajoute une action à la queue
    func queueAction(type: PendingActionType, entityId: String, payload: Encodable) throws {
        let data = try JSONEncoder().encode(AnyEncodable(payload))

        let action = PendingAction(
            type: type,
            entityId: entityId,
            payload: data
        )

        pendingActions.append(action)
        savePendingActions()

        logInfo("Queued offline action: \(type.rawValue) for \(entityId)", category: .sync)

        // Tenter immédiatement si en ligne
        if networkStatus == .online {
            Task {
                await processPendingActions()
            }
        }
    }

    /// Supprime une action de la queue
    func removeAction(_ actionId: String) {
        pendingActions.removeAll { $0.id == actionId }
        savePendingActions()
    }

    /// Vide la queue
    func clearAllPendingActions() {
        pendingActions.removeAll()
        savePendingActions()
        logInfo("Cleared all pending actions", category: .sync)
    }

    // MARK: - Sync Processing

    /// Traite toutes les actions en attente
    @discardableResult
    func processPendingActions() async -> (succeeded: Int, failed: Int) {
        guard !isSyncing else {
            logInfo("Sync already in progress", category: .sync)
            return (0, 0)
        }

        guard networkStatus == .online else {
            logInfo("Cannot process pending actions: offline", category: .sync)
            return (0, 0)
        }

        guard !pendingActions.isEmpty else {
            return (0, 0)
        }

        isSyncing = true

        var succeeded = 0
        var failed = 0
        var actionsToRemove: [String] = []
        var actionsToUpdate: [PendingAction] = []

        // Snapshot pour itérer en toute sécurité
        let actionsSnapshot = pendingActions

        for action in actionsSnapshot {
            do {
                try await processAction(action)
                actionsToRemove.append(action.id)
                succeeded += 1
                logInfo("Successfully processed action: \(action.type.rawValue)", category: .sync)
            } catch {
                failed += 1
                var updatedAction = action
                updatedAction.retryCount += 1
                updatedAction.lastError = error.localizedDescription

                if updatedAction.retryCount >= maxRetries {
                    logError("Action \(action.type.rawValue) exceeded max retries, removing", category: .sync)
                    actionsToRemove.append(action.id)
                } else {
                    actionsToUpdate.append(updatedAction)
                    logWarning("Action \(action.type.rawValue) failed, will retry (\(updatedAction.retryCount)/\(maxRetries))", category: .sync)
                }
            }
        }

        // Supprimer les actions terminées
        pendingActions.removeAll { actionsToRemove.contains($0.id) }

        // Mettre à jour les actions échouées
        for updated in actionsToUpdate {
            if let index = pendingActions.firstIndex(where: { $0.id == updated.id }) {
                pendingActions[index] = updated
            }
        }

        savePendingActions()

        if succeeded > 0 {
            lastSyncDate = Date()
            saveLastSyncDate()
        }

        isSyncing = false

        logInfo("Sync completed: \(succeeded) succeeded, \(failed) failed", category: .sync)
        return (succeeded, failed)
    }

    /// Traite une action spécifique
    private func processAction(_ action: PendingAction) async throws {
        switch action.type {
        case .createFlight, .updateFlight:
            try await processFlightAction(action)

        case .deleteFlight:
            try await processDeleteFlightAction(action)

        case .uploadPhoto:
            try await processPhotoUploadAction(action)

        case .deletePhoto:
            try await processPhotoDeleteAction(action)

        case .updateProfile:
            try await processProfileUpdateAction(action)

        case .addEmergencyContact, .updateEmergencyContact:
            try await processEmergencyContactAction(action)

        case .deleteEmergencyContact:
            try await processDeleteEmergencyContactAction(action)
        }
    }

    // MARK: - Action Processors

    private func processFlightAction(_ action: PendingAction) async throws {
        logInfo("Processing flight action: \(action.type.rawValue) for \(action.entityId)", category: .sync)

        // Décoder le payload pour vérifier la validité
        guard !action.payload.isEmpty else {
            logWarning("Empty payload for flight action \(action.entityId)", category: .sync)
            return
        }

        // Le vol est identifié par son entityId (UUID string)
        // La sync effective est gérée par FlightSyncService qui a accès au ModelContext
        // On marque simplement que cette action offline a été traitée
        // Les vols avec needsSync=true seront uploadés lors du prochain performFullSync
        logInfo("Flight action \(action.type.rawValue) queued for next full sync: \(action.entityId)", category: .sync)
    }

    private func processDeleteFlightAction(_ action: PendingAction) async throws {
        logInfo("Processing delete flight action for \(action.entityId)", category: .sync)

        // Tenter la suppression cloud si le vol a un cloudId
        let tablesDB = AppwriteService.shared.tablesDB
        do {
            try await tablesDB.deleteRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.flightsCollectionId,
                rowId: action.entityId
            )
            logInfo("Cloud flight deleted: \(action.entityId)", category: .sync)
        } catch {
            // Si le document n'existe pas, c'est OK (déjà supprimé)
            logWarning("Cloud flight delete failed (may already be deleted): \(error.localizedDescription)", category: .sync)
        }
    }

    private func processPhotoUploadAction(_ action: PendingAction) async throws {
        logInfo("Processing photo upload action for \(action.entityId)", category: .sync)

        guard !action.payload.isEmpty else {
            logWarning("Empty photo payload for \(action.entityId)", category: .sync)
            return
        }

        let storage = AppwriteService.shared.storage
        do {
            _ = try await storage.createFile(
                bucketId: AppwriteConfig.flightPhotosBucketId,
                fileId: ID.unique(),
                file: InputFile.fromData(action.payload, filename: "\(action.entityId).jpg", mimeType: "image/jpeg")
            )
            logInfo("Offline photo uploaded for \(action.entityId)", category: .sync)
        } catch {
            throw OfflineSyncError.syncFailed("Photo upload: \(error.localizedDescription)")
        }
    }

    private func processPhotoDeleteAction(_ action: PendingAction) async throws {
        logInfo("Processing photo delete action for \(action.entityId)", category: .sync)

        let storage = AppwriteService.shared.storage
        do {
            try await storage.deleteFile(
                bucketId: AppwriteConfig.flightPhotosBucketId,
                fileId: action.entityId
            )
            logInfo("Cloud photo deleted: \(action.entityId)", category: .sync)
        } catch {
            logWarning("Cloud photo delete failed (may already be deleted): \(error.localizedDescription)", category: .sync)
        }
    }

    private func processProfileUpdateAction(_ action: PendingAction) async throws {
        logInfo("Processing profile update action", category: .sync)

        guard !action.payload.isEmpty else { return }

        // Décoder les données de profil et mettre à jour
        do {
            let profileData = try JSONDecoder().decode([String: String].self, from: action.payload)
            let tablesDB = AppwriteService.shared.tablesDB

            _ = try await tablesDB.updateRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                rowId: action.entityId,
                data: profileData
            )
            logInfo("Profile updated from offline queue", category: .sync)
        } catch {
            throw OfflineSyncError.syncFailed("Profile update: \(error.localizedDescription)")
        }
    }

    private func processEmergencyContactAction(_ action: PendingAction) async throws {
        logInfo("Processing emergency contact action for \(action.entityId)", category: .sync)

        guard !action.payload.isEmpty else { return }

        do {
            let contactData = try JSONDecoder().decode([String: String].self, from: action.payload)
            let tablesDB = AppwriteService.shared.tablesDB

            if action.type == .addEmergencyContact {
                _ = try await tablesDB.createRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.emergencyContactsCollectionId,
                    rowId: ID.unique(),
                    data: contactData
                )
            } else {
                _ = try await tablesDB.updateRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.emergencyContactsCollectionId,
                    rowId: action.entityId,
                    data: contactData
                )
            }
            logInfo("Emergency contact synced: \(action.type.rawValue)", category: .sync)
        } catch {
            throw OfflineSyncError.syncFailed("Emergency contact: \(error.localizedDescription)")
        }
    }

    private func processDeleteEmergencyContactAction(_ action: PendingAction) async throws {
        logInfo("Processing delete emergency contact action for \(action.entityId)", category: .sync)

        let tablesDB = AppwriteService.shared.tablesDB
        do {
            try await tablesDB.deleteRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.emergencyContactsCollectionId,
                rowId: action.entityId
            )
            logInfo("Emergency contact deleted from cloud: \(action.entityId)", category: .sync)
        } catch {
            logWarning("Emergency contact delete failed: \(error.localizedDescription)", category: .sync)
        }
    }

    // MARK: - Persistence

    private func savePendingActions() {
        do {
            let data = try JSONEncoder().encode(pendingActions)
            UserDefaults.standard.set(data, forKey: pendingActionsKey)
        } catch {
            logError("Failed to save pending actions: \(error.localizedDescription)", category: .sync)
        }
    }

    private func loadPendingActions() {
        guard let data = UserDefaults.standard.data(forKey: pendingActionsKey) else {
            return
        }

        do {
            pendingActions = try JSONDecoder().decode([PendingAction].self, from: data)
            logInfo("Loaded \(pendingActions.count) pending actions", category: .sync)
        } catch {
            logError("Failed to load pending actions: \(error.localizedDescription)", category: .sync)
            pendingActions = []
        }
    }

    private func saveLastSyncDate() {
        if let date = lastSyncDate {
            UserDefaults.standard.set(date, forKey: lastSyncKey)
        }
    }

    private func loadLastSyncDate() {
        lastSyncDate = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    // MARK: - Discovery Cache

    /// Cache du feed discovery
    private var discoveryCache: [PublicFlight] = []
    private var discoveryCacheDate: Date?
    private let discoveryCacheValidityMinutes: TimeInterval = 15

    /// Récupère le feed depuis le cache si hors ligne
    func getCachedDiscoveryFeed() -> [PublicFlight] {
        discoveryCache
    }

    /// Met en cache le feed discovery
    func cacheDiscoveryFeed(flights: [PublicFlight]) {
        discoveryCache = flights
        discoveryCacheDate = Date()
    }

    /// Vérifie si le cache est valide
    var isDiscoveryCacheValid: Bool {
        guard let cacheDate = discoveryCacheDate else { return false }
        return Date().timeIntervalSince(cacheDate) < discoveryCacheValidityMinutes * 60
    }

    // MARK: - Cleanup

    /// Nettoie les données locales (déconnexion)
    func clearLocalData() {
        pendingActions.removeAll()
        discoveryCache.removeAll()
        discoveryCacheDate = nil
        lastSyncDate = nil
        UserDefaults.standard.removeObject(forKey: pendingActionsKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
    }
}

// MARK: - AnyEncodable Helper

/// Wrapper pour encoder n'importe quel type Encodable
private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeClosure = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

