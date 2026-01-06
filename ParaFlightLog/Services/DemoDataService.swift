//
//  DemoDataService.swift
//  ParaFlightLog
//
//  Service de génération de données de démonstration
//  Crée de vrais documents live_flights dans Appwrite pour tester
//  le flux complet (persistance, notifications, synchronisation)
//  Target: iOS only
//

import Foundation
import CoreLocation
import Appwrite

// MARK: - Demo Pilot Data

/// Pilotes fictifs pour la démonstration des vols en direct
struct DemoPilot: Identifiable {
    let id: String
    let name: String
    let username: String
    let wingName: String
    let spotName: String
    let baseCoordinate: CLLocationCoordinate2D
    let flightDurationMinutes: Int
    let startDelayMinutes: Int // Décalage de départ

    /// Génère une position simulée avec un léger déplacement
    func simulatedCoordinate(elapsedMinutes: Int) -> CLLocationCoordinate2D {
        let progress = Double(elapsedMinutes) / Double(max(flightDurationMinutes, 1))

        // Mouvement en spirale/cercle simulant un thermique
        let angle = progress * 2 * .pi * 3 // 3 tours pendant le vol
        let radius = 0.008 * (1 + progress) // rayon qui augmente

        let latOffset = sin(angle) * radius
        let lonOffset = cos(angle) * radius

        return CLLocationCoordinate2D(
            latitude: baseCoordinate.latitude + latOffset,
            longitude: baseCoordinate.longitude + lonOffset
        )
    }

    /// Génère une altitude simulée
    func simulatedAltitude(elapsedMinutes: Int) -> Double {
        let baseAltitude = 1000.0
        let progress = Double(elapsedMinutes) / Double(max(flightDurationMinutes, 1))

        // Simuler une montée en thermique puis descente
        let thermalGain = sin(progress * .pi) * 800

        return baseAltitude + thermalGain
    }
}

// MARK: - DemoDataService

@Observable
final class DemoDataService {
    static let shared = DemoDataService()

    // MARK: - Properties

    private let databases: Databases

    /// Indique si le mode démo est activé
    var isDemoModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.demoModeEnabled) }
        set {
            let wasEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.demoModeEnabled)
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.demoModeEnabled)

            if newValue && !wasEnabled {
                startDemoFlights()
            } else if !newValue && wasEnabled {
                stopDemoFlights()
            }
        }
    }

    /// Timer pour mettre à jour les positions dans Appwrite
    private var updateTimer: Timer?

    /// Heure de démarrage des vols de démo (persistée)
    private var demoStartTime: Date? {
        get {
            UserDefaults.standard.object(forKey: "demoStartTime") as? Date
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "demoStartTime")
        }
    }

    /// IDs des documents créés dans Appwrite pour les nettoyer
    private var createdDocumentIds: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "demoDocumentIds") ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "demoDocumentIds")
        }
    }

    /// Pilotes pour lesquels une notification a déjà été envoyée
    private var notifiedPilotIds: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "demoNotifiedPilots") ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "demoNotifiedPilots")
        }
    }

    // MARK: - Demo Pilots Configuration

    /// Liste des pilotes de démonstration
    /// Chaque pilote décolle avec 1 minute de décalage (0, 1, 2, 3, 4 min)
    private let demoPilots: [DemoPilot] = [
        DemoPilot(
            id: "demo-pilot-1",
            name: "Marie Dupont",
            username: "marie_para",
            wingName: "Ozone Alpina 4",
            spotName: "Saint-Hilaire-du-Touvet",
            baseCoordinate: CLLocationCoordinate2D(latitude: 45.3067, longitude: 5.8867),
            flightDurationMinutes: 15,
            startDelayMinutes: 0  // Immédiat
        ),
        DemoPilot(
            id: "demo-pilot-2",
            name: "Jean Martin",
            username: "jeanm_free",
            wingName: "Advance Xi",
            spotName: "Annecy - Planfait",
            baseCoordinate: CLLocationCoordinate2D(latitude: 45.8567, longitude: 6.1533),
            flightDurationMinutes: 18,
            startDelayMinutes: 1  // +1 minute
        ),
        DemoPilot(
            id: "demo-pilot-3",
            name: "Sophie Bernard",
            username: "sophiefly",
            wingName: "Niviuk Ikuma 2",
            spotName: "Puy de Dôme",
            baseCoordinate: CLLocationCoordinate2D(latitude: 45.7722, longitude: 2.9644),
            flightDurationMinutes: 12,
            startDelayMinutes: 2  // +2 minutes
        ),
        DemoPilot(
            id: "demo-pilot-4",
            name: "Pierre Dubois",
            username: "pierreD",
            wingName: "BGD Cure 2",
            spotName: "Chamonix - Planpraz",
            baseCoordinate: CLLocationCoordinate2D(latitude: 45.9367, longitude: 6.8700),
            flightDurationMinutes: 20,
            startDelayMinutes: 3  // +3 minutes
        ),
        DemoPilot(
            id: "demo-pilot-5",
            name: "Claire Moreau",
            username: "claire_vol",
            wingName: "Gin Explorer 2",
            spotName: "Millau - Brunas",
            baseCoordinate: CLLocationCoordinate2D(latitude: 44.0947, longitude: 3.0833),
            flightDurationMinutes: 16,
            startDelayMinutes: 4  // +4 minutes
        )
    ]

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases

        // Restaurer le timer si le mode démo était activé
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.demoModeEnabled) {
            // Vérifier si les vols sont encore actifs
            if let startTime = demoStartTime {
                let elapsed = Date().timeIntervalSince(startTime) / 60
                let maxDuration = demoPilots.map { $0.flightDurationMinutes + $0.startDelayMinutes }.max() ?? 60

                if elapsed < Double(maxDuration) {
                    // Les vols sont encore en cours, reprendre les mises à jour
                    startUpdateTimer()
                    logInfo("Demo mode resumed - flights still active", category: .sync)
                } else {
                    // Les vols sont terminés, relancer
                    startDemoFlights()
                }
            } else {
                startDemoFlights()
            }
        }
    }

    // MARK: - Public Methods

    /// Démarre les vols de démonstration (crée les documents dans Appwrite)
    func startDemoFlights() {
        // Nettoyer les anciens vols démo d'abord
        Task {
            await cleanupDemoFlights()

            // Réinitialiser l'état
            demoStartTime = Date()
            notifiedPilotIds = []
            createdDocumentIds = []

            // Créer les vols dans Appwrite
            await createDemoFlightsInAppwrite()

            // Démarrer le timer de mise à jour
            await MainActor.run {
                startUpdateTimer()
            }

            logInfo("Demo mode started with \(demoPilots.count) simulated pilots in Appwrite", category: .sync)
        }
    }

    /// Arrête les vols de démonstration (supprime les documents d'Appwrite)
    func stopDemoFlights() {
        updateTimer?.invalidate()
        updateTimer = nil

        Task {
            await cleanupDemoFlights()

            await MainActor.run {
                demoStartTime = nil
                notifiedPilotIds = []
                createdDocumentIds = []
            }

            logInfo("Demo mode stopped - all demo flights removed from Appwrite", category: .sync)
        }
    }

    /// Retourne les vols de démo (pour compatibilité, mais maintenant ils sont dans Appwrite)
    func getDemoFlights() -> [LiveFlight] {
        // Les vols démo sont maintenant dans Appwrite, donc on retourne vide
        // LiveFlightService les récupère directement depuis Appwrite
        return []
    }

    // MARK: - Private Methods

    /// Démarre le timer de mise à jour des positions
    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateDemoFlightsInAppwrite()
        }
        // Exécuter immédiatement une première mise à jour
        updateDemoFlightsInAppwrite()
    }

    /// Crée les documents live_flights dans Appwrite
    private func createDemoFlightsInAppwrite() async {
        guard let startTime = demoStartTime else { return }

        for pilot in demoPilots {
            let coordinate = pilot.baseCoordinate
            let altitude = pilot.simulatedAltitude(elapsedMinutes: 0)
            let pilotStartTime = startTime.addingTimeInterval(TimeInterval(pilot.startDelayMinutes * 60))

            // Le premier pilote (délai 0) est actif immédiatement
            let isActiveNow = pilot.startDelayMinutes == 0

            let flightData: [String: Any] = [
                "userId": pilot.id,
                "pilotName": pilot.name,
                "pilotUsername": pilot.username,
                "startedAt": pilotStartTime.ISO8601Format(),
                "latitude": coordinate.latitude,
                "longitude": coordinate.longitude,
                "altitude": altitude,
                "spotName": pilot.spotName,
                "wingName": pilot.wingName,
                "isActive": isActiveNow,
                "isDemo": true // Flag pour identifier les vols démo
            ]

            // Envoyer notification immédiatement pour le premier pilote
            if isActiveNow {
                await checkAndSendNotification(for: pilot)
            }

            do {
                let document = try await databases.createDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: AppwriteConfig.liveFlightsCollectionId,
                    documentId: pilot.id, // Utiliser l'ID du pilote comme ID document
                    data: flightData
                )

                await MainActor.run {
                    var ids = createdDocumentIds
                    ids.insert(document.id)
                    createdDocumentIds = ids
                }

                logInfo("Created demo flight in Appwrite for: \(pilot.name)", category: .sync)

            } catch let error as AppwriteError {
                // Si le document existe déjà, essayer de le mettre à jour
                if error.message.contains("already exists") {
                    do {
                        _ = try await databases.updateDocument(
                            databaseId: AppwriteConfig.databaseId,
                            collectionId: AppwriteConfig.liveFlightsCollectionId,
                            documentId: pilot.id,
                            data: flightData
                        )

                        await MainActor.run {
                            var ids = createdDocumentIds
                            ids.insert(pilot.id)
                            createdDocumentIds = ids
                        }

                        logInfo("Updated existing demo flight for: \(pilot.name)", category: .sync)
                    } catch {
                        logWarning("Failed to update demo flight for \(pilot.name): \(error.localizedDescription)", category: .sync)
                    }
                } else {
                    logWarning("Failed to create demo flight for \(pilot.name): \(error.message)", category: .sync)
                }
            } catch {
                logWarning("Failed to create demo flight for \(pilot.name): \(error.localizedDescription)", category: .sync)
            }
        }
    }

    /// Met à jour les positions des vols démo dans Appwrite
    private func updateDemoFlightsInAppwrite() {
        guard let startTime = demoStartTime else { return }

        let elapsedSeconds = Date().timeIntervalSince(startTime)
        let elapsedMinutes = Int(elapsedSeconds / 60)

        Task {
            var allPilotsLanded = true

            for pilot in demoPilots {
                let pilotDelaySeconds = Double(pilot.startDelayMinutes * 60)
                let pilotElapsedSeconds = elapsedSeconds - pilotDelaySeconds
                let pilotElapsedMinutes = Int(pilotElapsedSeconds / 60)

                // Le pilote n'a pas encore décollé
                if pilotElapsedSeconds < 0 {
                    allPilotsLanded = false
                    continue
                }

                // Le pilote a atterri
                if pilotElapsedMinutes >= pilot.flightDurationMinutes {
                    await markPilotAsLanded(pilot)
                    continue
                }

                allPilotsLanded = false

                // Envoyer notification au moment du décollage (première fois que pilotElapsedSeconds >= 0)
                await checkAndSendNotification(for: pilot)

                // Mettre à jour la position et activer le vol
                let coordinate = pilot.simulatedCoordinate(elapsedMinutes: max(0, pilotElapsedMinutes))
                let altitude = pilot.simulatedAltitude(elapsedMinutes: max(0, pilotElapsedMinutes))

                do {
                    _ = try await databases.updateDocument(
                        databaseId: AppwriteConfig.databaseId,
                        collectionId: AppwriteConfig.liveFlightsCollectionId,
                        documentId: pilot.id,
                        data: [
                            "latitude": coordinate.latitude,
                            "longitude": coordinate.longitude,
                            "altitude": altitude,
                            "isActive": true
                        ]
                    )
                } catch {
                    // Silently fail - position updates are best effort
                }
            }

            // Si tous les pilotes ont atterri, relancer les vols
            if allPilotsLanded && elapsedMinutes > 0 {
                logInfo("All demo pilots landed - restarting flights", category: .sync)
                await MainActor.run {
                    startDemoFlights()
                }
            }
        }
    }

    /// Marque un pilote comme ayant atterri
    private func markPilotAsLanded(_ pilot: DemoPilot) async {
        do {
            _ = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.liveFlightsCollectionId,
                documentId: pilot.id,
                data: ["isActive": false]
            )
        } catch {
            // Ignore errors
        }
    }

    /// Vérifie et envoie une notification de décollage
    private func checkAndSendNotification(for pilot: DemoPilot) async {
        let currentNotified = notifiedPilotIds
        guard !currentNotified.contains(pilot.id) else { return }

        await MainActor.run {
            var updated = notifiedPilotIds
            updated.insert(pilot.id)
            notifiedPilotIds = updated
        }

        // Envoyer notification locale
        do {
            try await NotificationService.shared.scheduleLocalNotification(
                title: "\(pilot.name) est en vol !",
                body: "Décollage depuis \(pilot.spotName) avec une \(pilot.wingName)",
                identifier: "demo-takeoff-\(pilot.id)-\(Date().timeIntervalSince1970)",
                timeInterval: 1,
                userInfo: [
                    "type": "flight_started",
                    "pilotId": pilot.id,
                    "pilotName": pilot.name,
                    "spotName": pilot.spotName,
                    "isDemo": "true"
                ]
            )
            logInfo("Demo notification sent for pilot: \(pilot.name)", category: .notification)
        } catch {
            logWarning("Failed to send demo notification: \(error.localizedDescription)", category: .notification)
        }
    }

    /// Nettoie tous les vols démo d'Appwrite
    private func cleanupDemoFlights() async {
        // Supprimer les documents qu'on a créés
        for docId in createdDocumentIds {
            do {
                _ = try await databases.deleteDocument(
                    databaseId: AppwriteConfig.databaseId,
                    collectionId: AppwriteConfig.liveFlightsCollectionId,
                    documentId: docId
                )
                logInfo("Deleted demo flight: \(docId)", category: .sync)
            } catch {
                // Document déjà supprimé ou n'existe pas
            }
        }

        // Aussi chercher et supprimer tous les documents avec isDemo=true (au cas où)
        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.liveFlightsCollectionId,
                queries: [
                    Query.equal("isDemo", value: true)
                ]
            )

            for doc in documents.documents {
                do {
                    _ = try await databases.deleteDocument(
                        databaseId: AppwriteConfig.databaseId,
                        collectionId: AppwriteConfig.liveFlightsCollectionId,
                        documentId: doc.id
                    )
                } catch {
                    // Ignore
                }
            }

            if documents.documents.count > 0 {
                logInfo("Cleaned up \(documents.documents.count) demo flights from Appwrite", category: .sync)
            }
        } catch {
            // Collection might not have isDemo attribute yet
            logWarning("Could not query demo flights: \(error.localizedDescription)", category: .sync)
        }
    }
}
