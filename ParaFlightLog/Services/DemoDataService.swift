//
//  DemoDataService.swift
//  ParaFlightLog
//
//  Service de génération de données de démonstration
//  Permet de tester les vols en direct avec des pilotes simulés
//  Target: iOS only
//

import Foundation
import CoreLocation

// MARK: - Demo Pilot Data

/// Pilotes fictifs pour la démonstration des vols en direct
struct DemoPilot {
    let id: String
    let name: String
    let username: String
    let wingName: String
    let spotName: String
    let baseCoordinate: CLLocationCoordinate2D
    let flightDurationMinutes: Int

    /// Génère une position simulée avec un léger déplacement aléatoire
    func simulatedCoordinate(elapsedMinutes: Int) -> CLLocationCoordinate2D {
        // Simuler un déplacement thermique/soaring
        let progress = Double(elapsedMinutes) / Double(max(flightDurationMinutes, 1))
        let randomOffset = Double.random(in: -0.005...0.005)

        // Mouvement en spirale/cercle simulant un thermique
        let angle = progress * 2 * .pi * 3 // 3 tours pendant le vol
        let radius = 0.01 * (1 + progress) // rayon qui augmente

        let latOffset = sin(angle) * radius + randomOffset
        let lonOffset = cos(angle) * radius + randomOffset

        return CLLocationCoordinate2D(
            latitude: baseCoordinate.latitude + latOffset,
            longitude: baseCoordinate.longitude + lonOffset
        )
    }

    /// Génère une altitude simulée
    func simulatedAltitude(elapsedMinutes: Int) -> Double {
        // Altitude de départ + gain thermique
        let baseAltitude = Double.random(in: 800...1200)
        let progress = Double(elapsedMinutes) / Double(max(flightDurationMinutes, 1))

        // Simuler une montée en thermique puis descente
        let thermalGain = sin(progress * .pi) * Double.random(in: 500...1500)

        return baseAltitude + thermalGain
    }
}

// MARK: - DemoDataService

@Observable
final class DemoDataService {
    static let shared = DemoDataService()

    // MARK: - Properties

    /// Indique si le mode démo est activé
    var isDemoModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.demoModeEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.demoModeEnabled)
            if newValue {
                startDemoFlights()
            } else {
                stopDemoFlights()
            }
        }
    }

    /// Pilotes de démonstration actuellement "en vol"
    private(set) var demoLiveFlights: [LiveFlight] = []

    /// Timer pour mettre à jour les positions
    private var updateTimer: Timer?

    /// Heure de démarrage des vols de démo
    private var demoStartTime: Date?

    /// Pilotes pour lesquels une notification a déjà été envoyée
    private var notifiedPilotIds: Set<String> = []

    // MARK: - Demo Pilots Configuration

    /// Liste des pilotes de démonstration
    private let demoPilots: [DemoPilot] = [
        DemoPilot(
            id: "demo-pilot-1",
            name: "Marie Dupont",
            username: "marie_para",
            wingName: "Ozone Alpina 4",
            spotName: "Saint-Hilaire-du-Touvet",
            baseCoordinate: CLLocationCoordinate2D(latitude: 45.3067, longitude: 5.8867),
            flightDurationMinutes: 45
        ),
        DemoPilot(
            id: "demo-pilot-2",
            name: "Jean Martin",
            username: "jeanm_free",
            wingName: "Advance Xi",
            spotName: "Annecy - Planfait",
            baseCoordinate: CLLocationCoordinate2D(latitude: 45.8567, longitude: 6.1533),
            flightDurationMinutes: 60
        ),
        DemoPilot(
            id: "demo-pilot-3",
            name: "Sophie Bernard",
            username: "sophiefly",
            wingName: "Niviuk Ikuma 2",
            spotName: "Puy de Dôme",
            baseCoordinate: CLLocationCoordinate2D(latitude: 45.7722, longitude: 2.9644),
            flightDurationMinutes: 35
        ),
        DemoPilot(
            id: "demo-pilot-4",
            name: "Pierre Dubois",
            username: "pierreD",
            wingName: "BGD Cure 2",
            spotName: "Chamonix - Planpraz",
            baseCoordinate: CLLocationCoordinate2D(latitude: 45.9367, longitude: 6.8700),
            flightDurationMinutes: 50
        ),
        DemoPilot(
            id: "demo-pilot-5",
            name: "Claire Moreau",
            username: "claire_vol",
            wingName: "Gin Explorer 2",
            spotName: "Millau - Brunas",
            baseCoordinate: CLLocationCoordinate2D(latitude: 44.0947, longitude: 3.0833),
            flightDurationMinutes: 40
        )
    ]

    // MARK: - Init

    private init() {
        // Restaurer l'état au démarrage si le mode démo était activé
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.demoModeEnabled) {
            startDemoFlights()
        }
    }

    // MARK: - Public Methods

    /// Démarre les vols de démonstration
    func startDemoFlights() {
        demoStartTime = Date()
        notifiedPilotIds = [] // Réinitialiser les notifications
        updateDemoFlights()

        // Mettre à jour les positions toutes les 5 secondes
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateDemoFlights()
        }

        logInfo("Demo mode started with \(demoPilots.count) simulated pilots", category: .sync)
    }

    /// Arrête les vols de démonstration
    func stopDemoFlights() {
        updateTimer?.invalidate()
        updateTimer = nil
        demoLiveFlights = []
        demoStartTime = nil
        notifiedPilotIds = []

        logInfo("Demo mode stopped", category: .sync)
    }

    /// Retourne les vols en direct (réels + démo si activé)
    func getDemoFlights() -> [LiveFlight] {
        guard isDemoModeEnabled else { return [] }
        return demoLiveFlights
    }

    // MARK: - Private Methods

    /// Met à jour les positions des vols de démo
    private func updateDemoFlights() {
        guard let startTime = demoStartTime else { return }

        let elapsedMinutes = Int(Date().timeIntervalSince(startTime) / 60)

        // Générer les vols en cours (certains peuvent avoir "atterri")
        var flights: [LiveFlight] = []

        for pilot in demoPilots {
            // Vérifier si ce pilote est encore "en vol"
            guard elapsedMinutes < pilot.flightDurationMinutes else { continue }

            // Simuler un décalage de départ pour chaque pilote
            let pilotStartOffset = abs(pilot.id.hashValue % 10) // 0-9 minutes de décalage
            let pilotElapsed = max(0, elapsedMinutes - pilotStartOffset)

            // Le pilote n'a pas encore décollé
            if pilotElapsed <= 0 { continue }

            // Envoyer une notification si c'est le premier décollage de ce pilote
            if !notifiedPilotIds.contains(pilot.id) {
                notifiedPilotIds.insert(pilot.id)
                sendTakeoffNotification(for: pilot)
            }

            let coordinate = pilot.simulatedCoordinate(elapsedMinutes: pilotElapsed)
            let altitude = pilot.simulatedAltitude(elapsedMinutes: pilotElapsed)

            let liveFlight = LiveFlight(
                id: pilot.id,
                userId: pilot.id,
                pilotName: pilot.name,
                pilotUsername: pilot.username,
                pilotPhotoFileId: nil, // Pas de photo pour les pilotes démo
                startedAt: startTime.addingTimeInterval(TimeInterval(pilotStartOffset * 60)),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                altitude: altitude,
                spotName: pilot.spotName,
                wingName: pilot.wingName,
                isActive: true
            )

            flights.append(liveFlight)
        }

        // Si tous les pilotes ont atterri, relancer les vols
        if flights.isEmpty && elapsedMinutes > 10 {
            demoStartTime = Date()
            notifiedPilotIds = [] // Réinitialiser pour les nouveaux décollages
            updateDemoFlights()
            return
        }

        demoLiveFlights = flights
    }

    /// Envoie une notification locale pour le décollage d'un pilote démo
    private func sendTakeoffNotification(for pilot: DemoPilot) {
        Task {
            do {
                try await NotificationService.shared.scheduleLocalNotification(
                    title: "\(pilot.name) est en vol !",
                    body: "Décollage depuis \(pilot.spotName) avec une \(pilot.wingName)",
                    identifier: "demo-takeoff-\(pilot.id)",
                    timeInterval: 1, // Notification quasi immédiate
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
    }
}

