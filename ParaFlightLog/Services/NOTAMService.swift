//
//  NOTAMService.swift
//  ParaFlightLog
//
//  Service de gestion des NOTAM (Notice to Airmen) et zones d'alerte
//  Récupère les NOTAM depuis des APIs publiques et gère les zones d'alerte utilisateur
//  Target: iOS only
//

import Foundation
import CoreLocation
import Appwrite
import UserNotifications

// MARK: - NOTAM Service Errors

enum NOTAMServiceError: LocalizedError {
    case notAuthenticated
    case networkError(String)
    case parseError(String)
    case noDataAvailable
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté pour accéder aux zones d'alerte"
        case .networkError(let msg):
            return "Erreur réseau: \(msg)"
        case .parseError(let msg):
            return "Erreur de parsing: \(msg)"
        case .noDataAvailable:
            return "Aucune donnée NOTAM disponible"
        case .rateLimited:
            return "Trop de requêtes - réessayez plus tard"
        }
    }
}

// MARK: - NOTAM Service

@Observable
final class NOTAMService {
    static let shared = NOTAMService()

    // MARK: - Properties

    private let databases: Databases

    /// Cache local des NOTAM
    private(set) var cachedNOTAMs: [NOTAM] = []

    /// Date du dernier refresh
    private(set) var lastRefreshDate: Date?

    /// Zones d'alerte de l'utilisateur
    private(set) var alertZones: [AlertZone] = []

    /// Indique si un chargement est en cours
    private(set) var isLoading = false

    /// Intervalle de refresh automatique (6 heures)
    private let refreshInterval: TimeInterval = 6 * 3600

    /// Cache file URL
    private var notamCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notam_cache.json")
    }

    private var alertZonesCacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alert_zones.json")
    }

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases
        loadLocalCache()
    }

    // MARK: - Public Methods

    /// Rafraîchit les NOTAM si nécessaire
    func refreshIfNeeded() async {
        guard shouldRefresh else { return }
        await refreshNOTAMs()
    }

    /// Force le rafraîchissement des NOTAM
    func refreshNOTAMs() async {
        guard !isLoading else { return }

        await MainActor.run { isLoading = true }
        defer { Task { await MainActor.run { isLoading = false } } }

        do {
            // TODO: Intégrer une vraie API NOTAM (ICAO, Eurocontrol, SIA France)
            // Pour l'instant, on utilise des données de démonstration
            let notams = try await fetchNOTAMsFromAPI()

            await MainActor.run {
                self.cachedNOTAMs = notams
                self.lastRefreshDate = Date()
            }

            saveNOTAMCache()
            logInfo("NOTAM refresh completed: \(notams.count) NOTAMs", category: .sync)

            // Vérifier les alertes
            await checkAlertZonesForNewNOTAMs(notams)

        } catch {
            logError("Failed to refresh NOTAMs: \(error.localizedDescription)", category: .sync)
        }
    }

    /// Vérifie les NOTAM actifs pour une position donnée
    func checkNOTAMs(at coordinate: CLLocationCoordinate2D, altitude: Double? = nil) -> NOTAMCheckResult {
        let activeNOTAMs = cachedNOTAMs.filter { notam in
            notam.isActive && notam.affects(coordinate: coordinate, altitude: altitude)
        }

        var warnings: [String] = []

        for notam in activeNOTAMs {
            if notam.type == .prohibited || notam.type == .tfr {
                warnings.append("Zone interdite: \(notam.title)")
            } else if notam.expiresSoon {
                warnings.append("NOTAM expire bientôt: \(notam.title)")
            }
        }

        return NOTAMCheckResult(
            checkDate: Date(),
            location: coordinate,
            activeNOTAMs: activeNOTAMs,
            warnings: warnings
        )
    }

    /// Récupère les NOTAM actifs dans une zone géographique
    func getNOTAMs(in region: (center: CLLocationCoordinate2D, radiusKm: Double)) -> [NOTAM] {
        return cachedNOTAMs.filter { notam in
            notam.isActive && notam.geometry.contains(coordinate: region.center)
        }
    }

    // MARK: - Alert Zones

    /// Ajoute une nouvelle zone d'alerte
    func addAlertZone(_ zone: AlertZone) async throws {
        var zones = alertZones
        zones.append(zone)

        await MainActor.run {
            self.alertZones = zones
        }

        saveAlertZonesLocally()
        try await syncAlertZoneToCloud(zone)

        logInfo("Alert zone added: \(zone.name)", category: .notification)
    }

    /// Met à jour une zone d'alerte existante
    func updateAlertZone(_ zone: AlertZone) async throws {
        var zones = alertZones
        if let index = zones.firstIndex(where: { $0.id == zone.id }) {
            var updatedZone = zone
            updatedZone.updatedAt = Date()
            zones[index] = updatedZone

            await MainActor.run {
                self.alertZones = zones
            }

            saveAlertZonesLocally()
            try await syncAlertZoneToCloud(updatedZone)
        }
    }

    /// Supprime une zone d'alerte
    func deleteAlertZone(_ zone: AlertZone) async throws {
        var zones = alertZones
        zones.removeAll { $0.id == zone.id }

        await MainActor.run {
            self.alertZones = zones
        }

        saveAlertZonesLocally()
        try await deleteAlertZoneFromCloud(zone)

        logInfo("Alert zone deleted: \(zone.name)", category: .notification)
    }

    /// Active/désactive une zone d'alerte
    func toggleAlertZone(_ zone: AlertZone) async throws {
        var updatedZone = zone
        updatedZone.isEnabled = !zone.isEnabled
        try await updateAlertZone(updatedZone)
    }

    /// Récupère les zones d'alerte depuis le cloud
    func fetchAlertZonesFromCloud() async throws {
        guard AuthService.shared.isAuthenticated,
              let profile = UserService.shared.currentUserProfile else {
            // Pas connecté, utiliser le cache local
            return
        }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: "alert_zones",
                queries: [
                    Query.equal("userId", value: profile.id),
                    Query.orderDesc("createdAt")
                ]
            )

            var zones: [AlertZone] = []
            for doc in documents.documents {
                if let zone = try? parseAlertZone(from: doc.data) {
                    zones.append(zone)
                }
            }

            await MainActor.run {
                self.alertZones = zones
            }

            saveAlertZonesLocally()
            logInfo("Fetched \(zones.count) alert zones from cloud", category: .sync)

        } catch {
            logWarning("Failed to fetch alert zones from cloud: \(error.localizedDescription)", category: .sync)
        }
    }

    // MARK: - Pre-flight Check

    /// Effectue une vérification pré-vol complète
    func preFlightCheck(at location: CLLocationCoordinate2D) async -> NOTAMCheckResult {
        // Rafraîchir les NOTAM si nécessaire
        await refreshIfNeeded()

        // Vérifier les NOTAM à la position
        let result = checkNOTAMs(at: location)

        // Logger le résultat
        if result.hasActiveNOTAMs {
            logWarning("Pre-flight check: \(result.activeNOTAMs.count) active NOTAMs", category: .flight)
        } else {
            logInfo("Pre-flight check: Clear - no active NOTAMs", category: .flight)
        }

        return result
    }

    // MARK: - Private Methods

    private var shouldRefresh: Bool {
        guard let lastRefresh = lastRefreshDate else { return true }
        return Date().timeIntervalSince(lastRefresh) > refreshInterval
    }

    /// Récupère les NOTAM depuis l'API (à implémenter avec une vraie API)
    private func fetchNOTAMsFromAPI() async throws -> [NOTAM] {
        // TODO: Intégrer avec une vraie API NOTAM
        // Options possibles:
        // - API SIA France (DGAC)
        // - ICAO API
        // - Eurocontrol
        // - OpenAIP

        // Pour l'instant, retourner des données de démonstration pour les zones françaises
        return generateDemoNOTAMs()
    }

    /// Génère des NOTAM de démonstration pour tester l'interface
    private func generateDemoNOTAMs() -> [NOTAM] {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        return [
            NOTAM(
                id: "NOTAM-DEMO-001",
                type: .parachute,
                title: "Activité parachutage Gap-Tallard",
                description: "Activité de parachutage intensive. Éviter la zone ou contacter la tour.",
                effectiveStart: now,
                effectiveEnd: tomorrow,
                altitudes: AltitudeRange(floor: 0, ceiling: 15000),
                geometry: .circle(
                    center: CLLocationCoordinate2D(latitude: 44.455, longitude: 6.037),
                    radiusNM: 3.0
                ),
                source: "SIA France",
                rawText: nil
            ),
            NOTAM(
                id: "NOTAM-DEMO-002",
                type: .tra,
                title: "Zone réservée temporaire Chamonix",
                description: "Exercice de secours héliporté. Zone interdite aux aéronefs non autorisés.",
                effectiveStart: now,
                effectiveEnd: tomorrow,
                altitudes: AltitudeRange(floor: 0, ceiling: 8000),
                geometry: .circle(
                    center: CLLocationCoordinate2D(latitude: 45.923, longitude: 6.869),
                    radiusNM: 2.0
                ),
                source: "SIA France",
                rawText: nil
            ),
            NOTAM(
                id: "NOTAM-DEMO-003",
                type: .airshow,
                title: "Meeting aérien Salon-de-Provence",
                description: "Meeting aérien de la Patrouille de France. Espace aérien fermé.",
                effectiveStart: nextWeek,
                effectiveEnd: Calendar.current.date(byAdding: .day, value: 1, to: nextWeek)!,
                altitudes: AltitudeRange(floor: 0, ceiling: 10000),
                geometry: .circle(
                    center: CLLocationCoordinate2D(latitude: 43.606, longitude: 5.109),
                    radiusNM: 5.0
                ),
                source: "SIA France",
                rawText: nil
            )
        ]
    }

    /// Vérifie si de nouveaux NOTAM affectent les zones d'alerte
    private func checkAlertZonesForNewNOTAMs(_ notams: [NOTAM]) async {
        for zone in alertZones where zone.isEnabled && zone.notifyOnNewNOTAM {
            let affectingNOTAMs = notams.filter { notam in
                notam.isActive && notam.geometry.contains(coordinate: zone.geometry.center)
            }

            if !affectingNOTAMs.isEmpty {
                await sendNOTAMAlert(for: zone, notams: affectingNOTAMs)
            }
        }
    }

    /// Envoie une notification pour une zone d'alerte
    private func sendNOTAMAlert(for zone: AlertZone, notams: [NOTAM]) async {
        let content = UNMutableNotificationContent()
        content.title = "NOTAM - \(zone.name)"
        content.body = "\(notams.count) NOTAM(s) actif(s) dans votre zone d'alerte"
        content.sound = .default
        content.categoryIdentifier = "NOTAM_ALERT"

        let request = UNNotificationRequest(
            identifier: "notam-alert-\(zone.id.uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            logInfo("NOTAM alert sent for zone: \(zone.name)", category: .notification)
        } catch {
            logError("Failed to send NOTAM alert: \(error.localizedDescription)", category: .notification)
        }
    }

    // MARK: - Cloud Sync

    private func syncAlertZoneToCloud(_ zone: AlertZone) async throws {
        guard AuthService.shared.isAuthenticated,
              let profile = UserService.shared.currentUserProfile else {
            return
        }

        let data: [String: Any] = [
            "userId": profile.id,
            "name": zone.name,
            "description": zone.description ?? "",
            "isEnabled": zone.isEnabled,
            "notifyOnNewNOTAM": zone.notifyOnNewNOTAM,
            "notifyBeforeFlight": zone.notifyBeforeFlight,
            "notifyOnExpiration": zone.notifyOnExpiration,
            "geometry": encodeGeometry(zone.geometry),
            "createdAt": zone.createdAt.ISO8601Format(),
            "updatedAt": zone.updatedAt.ISO8601Format()
        ]

        do {
            _ = try await databases.createDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: "alert_zones",
                documentId: zone.id.uuidString,
                data: data
            )
        } catch {
            // Si le document existe déjà, le mettre à jour
            _ = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: "alert_zones",
                documentId: zone.id.uuidString,
                data: data
            )
        }
    }

    private func deleteAlertZoneFromCloud(_ zone: AlertZone) async throws {
        guard AuthService.shared.isAuthenticated else { return }

        do {
            _ = try await databases.deleteDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: "alert_zones",
                documentId: zone.id.uuidString
            )
        } catch {
            logWarning("Failed to delete alert zone from cloud: \(error.localizedDescription)", category: .sync)
        }
    }

    private func encodeGeometry(_ geometry: ZoneGeometry) -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(geometry),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }

    private func parseAlertZone(from data: [String: AnyCodable]) -> AlertZone? {
        guard let name = data["name"]?.value as? String,
              let geometryStr = data["geometry"]?.value as? String,
              let geometryData = geometryStr.data(using: .utf8),
              let geometry = try? JSONDecoder().decode(ZoneGeometry.self, from: geometryData) else {
            return nil
        }

        let id: UUID
        if let idStr = data["$id"]?.value as? String, let parsedId = UUID(uuidString: idStr) {
            id = parsedId
        } else {
            id = UUID()
        }

        return AlertZone(
            id: id,
            name: name,
            description: data["description"]?.value as? String,
            isEnabled: data["isEnabled"]?.value as? Bool ?? true,
            notifyOnNewNOTAM: data["notifyOnNewNOTAM"]?.value as? Bool ?? true,
            notifyBeforeFlight: data["notifyBeforeFlight"]?.value as? Bool ?? true,
            notifyOnExpiration: data["notifyOnExpiration"]?.value as? Bool ?? false,
            geometry: geometry
        )
    }

    // MARK: - Local Cache

    private func loadLocalCache() {
        // Charger les NOTAM du cache
        if let data = try? Data(contentsOf: notamCacheURL),
           let cached = try? JSONDecoder().decode([NOTAM].self, from: data) {
            cachedNOTAMs = cached
            logInfo("Loaded \(cached.count) NOTAMs from cache", category: .dataController)
        }

        // Charger les zones d'alerte
        if let data = try? Data(contentsOf: alertZonesCacheURL),
           let zones = try? JSONDecoder().decode([AlertZone].self, from: data) {
            alertZones = zones
            logInfo("Loaded \(zones.count) alert zones from cache", category: .dataController)
        }
    }

    private func saveNOTAMCache() {
        if let data = try? JSONEncoder().encode(cachedNOTAMs) {
            try? data.write(to: notamCacheURL)
        }
    }

    private func saveAlertZonesLocally() {
        if let data = try? JSONEncoder().encode(alertZones) {
            try? data.write(to: alertZonesCacheURL)
        }
    }

    /// Nettoie les données locales (déconnexion)
    func clearLocalData() {
        cachedNOTAMs = []
        alertZones = []
        lastRefreshDate = nil
        try? FileManager.default.removeItem(at: notamCacheURL)
        try? FileManager.default.removeItem(at: alertZonesCacheURL)
    }
}
