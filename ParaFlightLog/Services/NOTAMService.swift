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

// MARK: - Supported Countries

/// Pays supportés pour les NOTAM
enum NOTAMCountry: String, CaseIterable, Identifiable {
    case france = "FR"
    case spain = "ES"
    case switzerland = "CH"
    case italy = "IT"
    case austria = "AT"
    case germany = "DE"
    case slovenia = "SI"
    case portugal = "PT"
    case greece = "GR"
    case morocco = "MA"
    case turkey = "TR"
    case colombia = "CO"
    case nepal = "NP"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .france: return "France"
        case .spain: return "Espagne"
        case .switzerland: return "Suisse"
        case .italy: return "Italie"
        case .austria: return "Autriche"
        case .germany: return "Allemagne"
        case .slovenia: return "Slovénie"
        case .portugal: return "Portugal"
        case .greece: return "Grèce"
        case .morocco: return "Maroc"
        case .turkey: return "Turquie"
        case .colombia: return "Colombie"
        case .nepal: return "Népal"
        }
    }

    var flag: String {
        switch self {
        case .france: return "🇫🇷"
        case .spain: return "🇪🇸"
        case .switzerland: return "🇨🇭"
        case .italy: return "🇮🇹"
        case .austria: return "🇦🇹"
        case .germany: return "🇩🇪"
        case .slovenia: return "🇸🇮"
        case .portugal: return "🇵🇹"
        case .greece: return "🇬🇷"
        case .morocco: return "🇲🇦"
        case .turkey: return "🇹🇷"
        case .colombia: return "🇨🇴"
        case .nepal: return "🇳🇵"
        }
    }

    /// Coordonnées centrales du pays (pour les demo NOTAM)
    var centerCoordinate: CLLocationCoordinate2D {
        switch self {
        case .france: return CLLocationCoordinate2D(latitude: 46.2, longitude: 2.2)
        case .spain: return CLLocationCoordinate2D(latitude: 40.4, longitude: -3.7)
        case .switzerland: return CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2)
        case .italy: return CLLocationCoordinate2D(latitude: 41.9, longitude: 12.5)
        case .austria: return CLLocationCoordinate2D(latitude: 47.5, longitude: 14.5)
        case .germany: return CLLocationCoordinate2D(latitude: 51.2, longitude: 10.5)
        case .slovenia: return CLLocationCoordinate2D(latitude: 46.1, longitude: 14.8)
        case .portugal: return CLLocationCoordinate2D(latitude: 39.4, longitude: -8.2)
        case .greece: return CLLocationCoordinate2D(latitude: 39.1, longitude: 21.8)
        case .morocco: return CLLocationCoordinate2D(latitude: 31.8, longitude: -7.1)
        case .turkey: return CLLocationCoordinate2D(latitude: 39.0, longitude: 35.2)
        case .colombia: return CLLocationCoordinate2D(latitude: 4.6, longitude: -74.1)
        case .nepal: return CLLocationCoordinate2D(latitude: 28.4, longitude: 84.1)
        }
    }

    /// Source NOTAM pour ce pays
    var notamSource: String {
        switch self {
        case .france: return "SIA France"
        case .spain: return "ENAIRE"
        case .switzerland: return "BAZL"
        case .italy: return "ENAV"
        case .austria: return "Austro Control"
        case .germany: return "DFS"
        case .slovenia: return "Slovenia Control"
        case .portugal: return "NAV Portugal"
        case .greece: return "HCAA"
        case .morocco: return "ONDA"
        case .turkey: return "DHMI"
        case .colombia: return "Aerocivil"
        case .nepal: return "CAAN"
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

    /// Pays sélectionnés pour le chargement des NOTAM
    var selectedCountries: Set<NOTAMCountry> = [.france]

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
        // - API SIA France (DGAC) - https://www.sia.aviation-civile.gouv.fr/
        // - ICAO API - https://www.icao.int/
        // - Eurocontrol - https://www.eurocontrol.int/
        // - OpenAIP - https://www.openaip.net/
        // - FAA NOTAM API - https://www.faa.gov/

        // Pour l'instant, retourner des données de démonstration pour les pays sélectionnés
        var allNOTAMs: [NOTAM] = []
        for country in selectedCountries {
            allNOTAMs.append(contentsOf: generateDemoNOTAMs(for: country))
        }
        return allNOTAMs
    }

    /// Génère des NOTAM de démonstration pour un pays
    private func generateDemoNOTAMs(for country: NOTAMCountry) -> [NOTAM] {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        // Spots de parapente populaires par pays avec des NOTAM réalistes
        switch country {
        case .france:
            return [
                NOTAM(
                    id: "FR-NOTAM-001",
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
                    source: country.notamSource,
                    rawText: nil
                ),
                NOTAM(
                    id: "FR-NOTAM-002",
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
                    source: country.notamSource,
                    rawText: nil
                ),
                NOTAM(
                    id: "FR-NOTAM-003",
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
                    source: country.notamSource,
                    rawText: nil
                ),
                NOTAM(
                    id: "FR-NOTAM-004",
                    type: .military,
                    title: "Exercice militaire Puy de Dôme",
                    description: "Vol basse altitude militaire. Prudence recommandée.",
                    effectiveStart: now,
                    effectiveEnd: Calendar.current.date(byAdding: .hour, value: 6, to: now)!,
                    altitudes: AltitudeRange(floor: 0, ceiling: 5000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 45.772, longitude: 2.963),
                        radiusNM: 4.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .spain:
            return [
                NOTAM(
                    id: "ES-NOTAM-001",
                    type: .restricted,
                    title: "Zona restringida Algodonales",
                    description: "Restricción temporal por evento de vuelo libre. Solo participantes autorizados.",
                    effectiveStart: now,
                    effectiveEnd: nextWeek,
                    altitudes: AltitudeRange(floor: 0, ceiling: 6000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 36.878, longitude: -5.405),
                        radiusNM: 2.5
                    ),
                    source: country.notamSource,
                    rawText: nil
                ),
                NOTAM(
                    id: "ES-NOTAM-002",
                    type: .parachute,
                    title: "Paracaidismo Empuriabrava",
                    description: "Actividad intensiva de paracaidismo. Evitar zona.",
                    effectiveStart: now,
                    effectiveEnd: tomorrow,
                    altitudes: AltitudeRange(floor: 0, ceiling: 14000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 42.257, longitude: 3.117),
                        radiusNM: 3.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .switzerland:
            return [
                NOTAM(
                    id: "CH-NOTAM-001",
                    type: .tra,
                    title: "Übungszone Interlaken",
                    description: "Helikopterübung für Bergrettung. Zone gesperrt.",
                    effectiveStart: now,
                    effectiveEnd: tomorrow,
                    altitudes: AltitudeRange(floor: 0, ceiling: 9000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 46.686, longitude: 7.868),
                        radiusNM: 2.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                ),
                NOTAM(
                    id: "CH-NOTAM-002",
                    type: .danger,
                    title: "Zone dangereuse Verbier",
                    description: "Travaux d'entretien téléphérique. Danger câbles.",
                    effectiveStart: now,
                    effectiveEnd: Calendar.current.date(byAdding: .day, value: 3, to: now)!,
                    altitudes: AltitudeRange(floor: 0, ceiling: 4000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 46.096, longitude: 7.229),
                        radiusNM: 1.5
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .italy:
            return [
                NOTAM(
                    id: "IT-NOTAM-001",
                    type: .parachute,
                    title: "Paracadutismo Bassano del Grappa",
                    description: "Attività paracadutismo intensiva. Evitare la zona.",
                    effectiveStart: now,
                    effectiveEnd: tomorrow,
                    altitudes: AltitudeRange(floor: 0, ceiling: 13000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 45.765, longitude: 11.735),
                        radiusNM: 2.5
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .austria:
            return [
                NOTAM(
                    id: "AT-NOTAM-001",
                    type: .airshow,
                    title: "Flugshow Zell am See",
                    description: "Flugveranstaltung. Luftraum gesperrt.",
                    effectiveStart: nextWeek,
                    effectiveEnd: Calendar.current.date(byAdding: .day, value: 1, to: nextWeek)!,
                    altitudes: AltitudeRange(floor: 0, ceiling: 8000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 47.323, longitude: 12.796),
                        radiusNM: 4.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .germany:
            return [
                NOTAM(
                    id: "DE-NOTAM-001",
                    type: .restricted,
                    title: "Sperrzone Garmisch",
                    description: "Militärische Übung. Flugverbot für nicht autorisierte Luftfahrzeuge.",
                    effectiveStart: now,
                    effectiveEnd: Calendar.current.date(byAdding: .day, value: 2, to: now)!,
                    altitudes: AltitudeRange(floor: 0, ceiling: 10000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 47.500, longitude: 11.095),
                        radiusNM: 3.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .slovenia:
            return [
                NOTAM(
                    id: "SI-NOTAM-001",
                    type: .tra,
                    title: "Začasno rezervirano območje Tolmin",
                    description: "Tekmovanje jadralnih padalcev. Omejitev za druge uporabnike.",
                    effectiveStart: now,
                    effectiveEnd: tomorrow,
                    altitudes: AltitudeRange(floor: 0, ceiling: 7000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 46.186, longitude: 13.732),
                        radiusNM: 3.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .portugal:
            return [
                NOTAM(
                    id: "PT-NOTAM-001",
                    type: .parachute,
                    title: "Paraquedismo Alentejo",
                    description: "Atividade de paraquedismo. Evitar a zona.",
                    effectiveStart: now,
                    effectiveEnd: tomorrow,
                    altitudes: AltitudeRange(floor: 0, ceiling: 12000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 38.566, longitude: -7.909),
                        radiusNM: 2.5
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .greece:
            return [
                NOTAM(
                    id: "GR-NOTAM-001",
                    type: .military,
                    title: "Στρατιωτική άσκηση Ολυμπος",
                    description: "Military exercise in progress. Avoid area.",
                    effectiveStart: now,
                    effectiveEnd: Calendar.current.date(byAdding: .day, value: 2, to: now)!,
                    altitudes: AltitudeRange(floor: 0, ceiling: 9000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 40.085, longitude: 22.358),
                        radiusNM: 5.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .morocco:
            return [
                NOTAM(
                    id: "MA-NOTAM-001",
                    type: .restricted,
                    title: "Zone restreinte Aguergour",
                    description: "Zone de vol libre restreinte. Coordination requise.",
                    effectiveStart: now,
                    effectiveEnd: nextWeek,
                    altitudes: AltitudeRange(floor: 0, ceiling: 6000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 30.434, longitude: -9.344),
                        radiusNM: 3.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .turkey:
            return [
                NOTAM(
                    id: "TR-NOTAM-001",
                    type: .tra,
                    title: "Geçici Hava Sahası Ölüdeniz",
                    description: "Paragliding competition. Restricted access.",
                    effectiveStart: now,
                    effectiveEnd: Calendar.current.date(byAdding: .day, value: 5, to: now)!,
                    altitudes: AltitudeRange(floor: 0, ceiling: 8000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 36.549, longitude: 29.116),
                        radiusNM: 2.5
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .colombia:
            return [
                NOTAM(
                    id: "CO-NOTAM-001",
                    type: .danger,
                    title: "Zona peligrosa Roldanillo",
                    description: "Actividad aérea intensa. Precaución.",
                    effectiveStart: now,
                    effectiveEnd: tomorrow,
                    altitudes: AltitudeRange(floor: 0, ceiling: 11000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 4.416, longitude: -76.153),
                        radiusNM: 4.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]

        case .nepal:
            return [
                NOTAM(
                    id: "NP-NOTAM-001",
                    type: .restricted,
                    title: "Restricted Zone Pokhara",
                    description: "Airport operations. Paragliders maintain distance.",
                    effectiveStart: now,
                    effectiveEnd: Calendar.current.date(byAdding: .day, value: 30, to: now)!,
                    altitudes: AltitudeRange(floor: 0, ceiling: 5000),
                    geometry: .circle(
                        center: CLLocationCoordinate2D(latitude: 28.200, longitude: 83.982),
                        radiusNM: 3.0
                    ),
                    source: country.notamSource,
                    rawText: nil
                )
            ]
        }
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
