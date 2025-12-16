//
//  FlightSessionManager.swift
//  ParaFlightLogWatch Watch App
//
//  Gère la persistance des sessions de vol pour éviter la perte de données en cas de crash
//  - Sauvegarde automatique périodique (toutes les 30 secondes)
//  - Récupération de session après crash/redémarrage
//  Target: Watch only
//

import Foundation

/// Données d'une session de vol en cours, sérialisables
struct FlightSession: Codable {
    let wingId: UUID
    let wingName: String
    let wingSize: String?
    let startDate: Date
    let spotName: String?

    // Données de tracking
    var startAltitude: Double?
    var maxAltitude: Double?
    var currentAltitude: Double?
    var totalDistance: Double
    var maxSpeed: Double
    var maxGForce: Double

    // Trace GPS (limitée aux 500 derniers points pour économiser la mémoire)
    var gpsTrackPoints: [GPSTrackPoint]

    // Métadonnées
    var lastSaveDate: Date
    var isActive: Bool

    init(wing: WingDTO, startDate: Date, spotName: String?) {
        self.wingId = wing.id
        self.wingName = wing.name
        self.wingSize = wing.size
        self.startDate = startDate
        self.spotName = spotName
        self.startAltitude = nil
        self.maxAltitude = nil
        self.currentAltitude = nil
        self.totalDistance = 0.0
        self.maxSpeed = 0.0
        self.maxGForce = 1.0
        self.gpsTrackPoints = []
        self.lastSaveDate = Date()
        self.isActive = true
    }
}

/// Manager singleton pour la persistance des sessions de vol
final class FlightSessionManager {
    static let shared = FlightSessionManager()

    private let sessionKey = "activeFlightSession"
    private let saveInterval: TimeInterval = 30.0  // Sauvegarde toutes les 30 secondes
    private var saveTimer: Timer?

    // Session en cours
    private(set) var activeSession: FlightSession?

    // Limite de points GPS pour éviter les problèmes mémoire
    // 500 points * 5 secondes = ~42 minutes de vol
    // Pour des vols plus longs, on garde un point sur 2
    private let maxGPSPoints = 500

    private init() {
        // Charger une éventuelle session récupérable au démarrage
        loadSavedSession()
    }

    // MARK: - Session Lifecycle

    /// Démarre une nouvelle session de vol
    func startSession(wing: WingDTO, spotName: String?) {
        let session = FlightSession(wing: wing, startDate: Date(), spotName: spotName)
        activeSession = session

        // Sauvegarder immédiatement
        saveSession()

        // Démarrer la sauvegarde périodique
        startPeriodicSave()

        print("📝 Flight session started and saved")
    }

    /// Met à jour les données de la session en cours
    func updateSession(
        startAltitude: Double?,
        maxAltitude: Double?,
        currentAltitude: Double?,
        totalDistance: Double,
        maxSpeed: Double,
        maxGForce: Double,
        gpsTrackPoints: [GPSTrackPoint]
    ) {
        guard var session = activeSession else { return }

        session.startAltitude = startAltitude
        session.maxAltitude = maxAltitude
        session.currentAltitude = currentAltitude
        session.totalDistance = totalDistance
        session.maxSpeed = maxSpeed
        session.maxGForce = maxGForce

        // Limiter les points GPS pour économiser la mémoire
        if gpsTrackPoints.count > maxGPSPoints {
            // Garder un point sur 2 pour les anciens points
            var limitedPoints: [GPSTrackPoint] = []
            for (index, point) in gpsTrackPoints.enumerated() {
                // Garder tous les 100 derniers points, et 1 sur 2 pour les anciens
                if index >= gpsTrackPoints.count - 100 || index % 2 == 0 {
                    limitedPoints.append(point)
                }
            }
            session.gpsTrackPoints = limitedPoints
        } else {
            session.gpsTrackPoints = gpsTrackPoints
        }

        activeSession = session
    }

    /// Termine la session proprement (vol sauvegardé)
    func endSession() {
        stopPeriodicSave()
        clearSavedSession()
        activeSession = nil
        print("✅ Flight session ended and cleared")
    }

    /// Annule la session (vol annulé par l'utilisateur)
    func discardSession() {
        stopPeriodicSave()
        clearSavedSession()
        activeSession = nil
        print("🗑️ Flight session discarded")
    }

    // MARK: - Persistence

    /// Sauvegarde la session en cours dans UserDefaults
    func saveSession() {
        guard var session = activeSession else { return }
        session.lastSaveDate = Date()
        activeSession = session

        do {
            let data = try JSONEncoder().encode(session)
            UserDefaults.standard.set(data, forKey: sessionKey)
            print("💾 Flight session saved (\(session.gpsTrackPoints.count) GPS points)")
        } catch {
            print("❌ Failed to save flight session: \(error)")
        }
    }

    /// Charge une session sauvegardée (pour récupération après crash)
    private func loadSavedSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey) else {
            print("📭 No saved flight session found")
            return
        }

        do {
            let session = try JSONDecoder().decode(FlightSession.self, from: data)

            // Vérifier si la session est récupérable
            // Une session est récupérable si elle a moins de 4 heures
            let maxAge: TimeInterval = 4 * 60 * 60  // 4 heures
            let sessionAge = Date().timeIntervalSince(session.lastSaveDate)

            if session.isActive && sessionAge < maxAge {
                activeSession = session
                print("🔄 Recovered flight session from \(session.lastSaveDate)")
                print("   Duration so far: \(Int(sessionAge / 60)) minutes")
                print("   GPS points: \(session.gpsTrackPoints.count)")
            } else {
                // Session trop vieille, la supprimer
                clearSavedSession()
                print("🗑️ Cleared expired session (age: \(Int(sessionAge / 60)) min)")
            }
        } catch {
            print("❌ Failed to load flight session: \(error)")
            clearSavedSession()
        }
    }

    /// Supprime la session sauvegardée
    private func clearSavedSession() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    // MARK: - Periodic Save

    /// Démarre la sauvegarde périodique
    private func startPeriodicSave() {
        stopPeriodicSave()

        saveTimer = Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: true) { [weak self] _ in
            self?.saveSession()
        }
    }

    /// Arrête la sauvegarde périodique
    private func stopPeriodicSave() {
        saveTimer?.invalidate()
        saveTimer = nil
    }

    // MARK: - Recovery Check

    /// Vérifie s'il y a une session à récupérer
    var hasRecoverableSession: Bool {
        return activeSession != nil
    }

    /// Calcule la durée du vol récupéré
    var recoveredFlightDuration: Int? {
        guard let session = activeSession else { return nil }
        return Int(Date().timeIntervalSince(session.startDate))
    }

    /// Retourne les données de la session récupérée pour créer un FlightDTO
    func getRecoveredFlightData() -> (
        wingId: UUID,
        startDate: Date,
        spotName: String?,
        startAltitude: Double?,
        maxAltitude: Double?,
        endAltitude: Double?,
        totalDistance: Double,
        maxSpeed: Double,
        maxGForce: Double,
        gpsTrack: [GPSTrackPoint]
    )? {
        guard let session = activeSession else { return nil }

        return (
            wingId: session.wingId,
            startDate: session.startDate,
            spotName: session.spotName,
            startAltitude: session.startAltitude,
            maxAltitude: session.maxAltitude,
            endAltitude: session.currentAltitude,
            totalDistance: session.totalDistance,
            maxSpeed: session.maxSpeed,
            maxGForce: session.maxGForce,
            gpsTrack: session.gpsTrackPoints
        )
    }
}
