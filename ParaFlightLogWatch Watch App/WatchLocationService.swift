//
//  WatchLocationService.swift
//  ParaFlightLogWatch Watch App
//
//  Service simple de localisation pour Apple Watch
//  Target: Watch only
//

import Foundation
import CoreLocation
import CoreMotion
import MapKit

@Observable
final class WatchLocationService: NSObject, CLLocationManagerDelegate {
    // CLLocationManager initialisé en background pour éviter le lag
    private var _locationManager: CLLocationManager?
    private var isInitialized = false

    // CoreMotion pour le tracking du G-force
    private var motionManager: CMMotionManager?
    private var gForceBuffer: [Double] = []  // Buffer pour moyenne mobile
    private let gForceBufferSize = 3  // Fenêtre de 3 échantillons pour filtrage

    private var locationManager: CLLocationManager {
        if let manager = _locationManager {
            return manager
        }
        // Fallback synchrone si pas encore initialisé - créer et sauvegarder immédiatement
        initializeLocationManagerSync()
        // _locationManager est maintenant garanti d'être initialisé par initializeLocationManagerSync()
        guard let manager = _locationManager else {
            fatalError("CLLocationManager not initialized after initializeLocationManagerSync() - this should never happen")
        }
        return manager
    }

    var lastKnownLocation: CLLocation?
    var currentSpotName: String = String(localized: "Searching...")
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // Données de tracking pour le vol en cours
    var isTracking: Bool = false
    var startAltitude: Double?
    var maxAltitude: Double?
    var currentAltitude: Double?
    var totalDistance: Double = 0.0
    var maxSpeed: Double = 0.0
    var currentGForce: Double = 1.0  // G-force actuel (1.0 = immobile)
    var maxGForce: Double = 1.0      // G-force max pendant le vol
    private var previousLocation: CLLocation?

    // Nom du spot verrouillé pendant le vol (pour éviter qu'il change)
    private var lockedSpotName: String?

    // Trace GPS du vol en cours - protégé par gpsQueue pour thread safety
    private var gpsTrackPoints: [GPSTrackPoint] = []
    private var lastTrackPointTime: Date?
    private let trackPointInterval: TimeInterval = 5.0  // Un point toutes les 5 secondes
    private let gpsQueue = DispatchQueue(label: "com.paraflightlog.gpstrack", qos: .userInitiated)

    // Limite de points GPS en mémoire pour éviter les crashes sur vols longs
    // 500 points max * 5 secondes = ~42 minutes de vol détaillé
    // La compaction démarre à 400 points pour garder de la marge
    // Après compaction, on peut stocker ~2h de vol avec résolution dégradée progressive
    private let maxGPSPointsInMemory = 500
    private let compactionThreshold = 400  // Déclencher la compaction à 80% de la limite

    override init() {
        super.init()
        // Initialiser le CLLocationManager immédiatement sur le main thread
        // mais de façon synchrone pour éviter les problèmes de timing
        initializeLocationManagerSync()
    }

    /// Initialise le CLLocationManager de façon synchrone
    private func initializeLocationManagerSync() {
        guard !isInitialized else { return }
        isInitialized = true

        // CLLocationManager doit être créé sur le main thread
        let manager = CLLocationManager()
        manager.delegate = self
        // Précision maximale pour le tracking pendant les vols
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5.0  // Mise à jour tous les 5 mètres
        // Note: allowsBackgroundLocationUpdates n'est pas nécessaire sur watchOS
        // Les updates continuent automatiquement pendant que l'app est active
        _locationManager = manager
        authorizationStatus = manager.authorizationStatus
    }

    func requestAuthorization() {
        authorizationStatus = locationManager.authorizationStatus
        if authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func startUpdatingLocation() {
        authorizationStatus = locationManager.authorizationStatus
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            currentSpotName = String(localized: "Permission refusée")
            return
        }
        locationManager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        _locationManager?.stopUpdatingLocation()
    }

    // MARK: - Flight Tracking

    /// Démarre le tracking des données de vol
    func startFlightTracking() {
        isTracking = true
        startAltitude = nil
        maxAltitude = nil
        currentAltitude = nil
        totalDistance = 0.0
        maxSpeed = 0.0
        currentGForce = 1.0
        maxGForce = 1.0
        previousLocation = nil
        gForceBuffer = []

        // Verrouiller le nom du spot actuel seulement s'il ne s'agit pas de "Searching..."
        // Sinon, on attendra la première vraie localisation
        let searchingText = String(localized: "Searching...")
        let unknownSpot = String(localized: "Spot inconnu")
        let unavailable = String(localized: "Position indisponible")

        if currentSpotName != searchingText &&
           currentSpotName != unknownSpot &&
           currentSpotName != unavailable {
            lockedSpotName = currentSpotName
        } else {
            lockedSpotName = nil  // On attendra la première vraie position
        }

        // Reset de la trace GPS (thread-safe)
        gpsQueue.sync {
            gpsTrackPoints = []
            lastTrackPointTime = nil
        }

        startMotionUpdates()
    }

    /// Arrête le tracking et retourne l'altitude finale
    func stopFlightTracking() -> Double? {
        isTracking = false
        let endAltitude = currentAltitude
        previousLocation = nil
        lockedSpotName = nil  // Déverrouiller le nom du spot
        stopMotionUpdates()
        return endAltitude
    }

    /// Retourne les données du vol en cours
    func getFlightData() -> (startAlt: Double?, maxAlt: Double?, endAlt: Double?, distance: Double, speed: Double, maxGForce: Double) {
        return (startAltitude, maxAltitude, currentAltitude, totalDistance, maxSpeed, maxGForce)
    }

    /// Retourne la trace GPS du vol (thread-safe)
    func getGPSTrack() -> [GPSTrackPoint] {
        return gpsQueue.sync { gpsTrackPoints }
    }

    /// Compacte la trace GPS pour économiser la mémoire (version interne - appelée depuis gpsQueue)
    /// Stratégie : garder 1 point sur 2 dans la première moitié (anciens points)
    /// et tous les points dans la deuxième moitié (points récents = plus de précision)
    /// ATTENTION: Cette méthode doit être appelée depuis gpsQueue.sync {}
    private func compactGPSTrackInternal() {
        let count = gpsTrackPoints.count

        // Ne pas compacter si on est en dessous du seuil
        guard count >= compactionThreshold else { return }

        // Réserver la capacité pour éviter les réallocations
        var compacted: [GPSTrackPoint] = []
        compacted.reserveCapacity(count / 2 + count / 4)  // ~75% du tableau original

        let halfCount = count / 2

        // Première moitié : un point sur 2 (résolution réduite pour les anciens)
        for i in stride(from: 0, to: halfCount, by: 2) {
            compacted.append(gpsTrackPoints[i])
        }

        // Deuxième moitié : tous les points (pleine résolution pour les récents)
        for i in halfCount..<count {
            compacted.append(gpsTrackPoints[i])
        }

        gpsTrackPoints = compacted
    }

    // MARK: - Motion Tracking (G-Force)

    /// Démarre les mises à jour du capteur de mouvement
    private func startMotionUpdates() {
        // Créer le motion manager si nécessaire
        if motionManager == nil {
            motionManager = CMMotionManager()
        }

        guard let motionManager = motionManager,
              motionManager.isDeviceMotionAvailable else {
            watchLogWarning("Device motion not available", category: .location)
            return
        }

        // Configurer l'intervalle de mise à jour (10 Hz = 0.1s)
        motionManager.deviceMotionUpdateInterval = 0.1

        // Démarrer les mises à jour sur la queue principale
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, let motion = motion, error == nil else {
                return
            }

            // Calculer le G-force total
            let gravity = motion.gravity
            let userAccel = motion.userAcceleration

            // Accélération totale = accélération utilisateur + gravité
            let totalAccelX = userAccel.x + gravity.x
            let totalAccelY = userAccel.y + gravity.y
            let totalAccelZ = userAccel.z + gravity.z

            // Magnitude du vecteur d'accélération totale
            let magnitude = sqrt(totalAccelX * totalAccelX +
                               totalAccelY * totalAccelY +
                               totalAccelZ * totalAccelZ)

            // Filtrer les valeurs aberrantes (> 10G)
            guard magnitude <= 10.0 else {
                return
            }

            // Ajouter au buffer pour moyenne mobile
            self.gForceBuffer.append(magnitude)
            if self.gForceBuffer.count > self.gForceBufferSize {
                self.gForceBuffer.removeFirst()
            }

            // Calculer la moyenne mobile
            let averageGForce = self.gForceBuffer.reduce(0.0, +) / Double(self.gForceBuffer.count)
            self.currentGForce = averageGForce

            // Mettre à jour le max
            if averageGForce > self.maxGForce {
                self.maxGForce = averageGForce
            }
        }
    }

    /// Arrête les mises à jour du capteur de mouvement
    private func stopMotionUpdates() {
        motionManager?.stopDeviceMotionUpdates()
        gForceBuffer = []
    }

    // MARK: - Reverse Geocoding avec MKReverseGeocodingRequest (watchOS 26+)

    private var isGeocodingInProgress = false
    private var lastGeocodedSpot: String?
    private var lastGeocodingTime: Date?
    // Rate limiting : 1 requête toutes les 5 secondes (12 req/min, bien sous la limite Apple de 50/min)
    private let geocodingMinInterval: TimeInterval = 5.0

    private func reverseGeocode(location: CLLocation) {
        // Si un vol est en cours et qu'on a un spot verrouillé, ne pas changer le nom
        if isTracking, let locked = lockedSpotName {
            // Garder le nom verrouillé pendant le vol
            if currentSpotName != locked {
                currentSpotName = locked
            }
            return
        }

        // Rate limiting : éviter le throttling Apple (50 req/60s)
        // On limite à 1 requête toutes les 30 secondes
        if let lastTime = lastGeocodingTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < geocodingMinInterval {
                return
            }
        }

        // Éviter les multiples appels simultanés
        guard !isGeocodingInProgress else { return }
        isGeocodingInProgress = true
        lastGeocodingTime = Date()

        // Faire le geocoding en background pour ne pas bloquer l'UI
        Task.detached(priority: .utility) { [weak self] in
            do {
                guard let request = MKReverseGeocodingRequest(location: location) else {
                    await MainActor.run { [weak self] in
                        self?.isGeocodingInProgress = false
                    }
                    return
                }
                let mapItems = try await request.mapItems
                let mapItem = mapItems.first

                // watchOS 26+ : utiliser addressRepresentations (nouvelle API)
                // Stratégie : cityName > regionName > name
                let unknownSpot = String(localized: "Spot inconnu")
                let spotName: String
                if let addr = mapItem?.addressRepresentations {
                    spotName = addr.cityName ?? addr.regionName ?? mapItem?.name ?? unknownSpot
                } else {
                    spotName = mapItem?.name ?? unknownSpot
                }

                await MainActor.run { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.isGeocodingInProgress = false

                    // Si un vol est en cours et qu'on n'a pas encore de spot verrouillé,
                    // verrouiller le premier spot valide obtenu
                    if strongSelf.isTracking && strongSelf.lockedSpotName == nil {
                        strongSelf.lockedSpotName = spotName
                        strongSelf.currentSpotName = spotName
                        strongSelf.lastGeocodedSpot = spotName
                        return
                    }

                    // Ne pas modifier si un vol est en cours (spot déjà verrouillé)
                    guard !strongSelf.isTracking else { return }

                    // Ne mettre à jour que si le nom change (évite les re-renders inutiles)
                    if strongSelf.lastGeocodedSpot != spotName {
                        strongSelf.lastGeocodedSpot = spotName
                        strongSelf.currentSpotName = spotName
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.isGeocodingInProgress = false
                    // Ne pas modifier si un vol est en cours
                    guard !strongSelf.isTracking else { return }
                    let unknownSpot = String(localized: "Spot inconnu")
                    if strongSelf.currentSpotName != unknownSpot {
                        strongSelf.currentSpotName = unknownSpot
                    }
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastKnownLocation = location

        // Mise à jour des données de tracking si un vol est en cours
        if isTracking {
            let altitude = location.altitude

            // Altitude actuelle
            currentAltitude = altitude

            // Altitude de départ (première mesure)
            if startAltitude == nil {
                startAltitude = altitude
            }

            // Altitude max
            if let max = maxAltitude {
                if altitude > max {
                    maxAltitude = altitude
                }
            } else {
                maxAltitude = altitude
            }

            // Distance et vitesse
            if let previous = previousLocation {
                // Distance parcourue depuis la dernière position
                let distance = location.distance(from: previous)

                // Filtres pour éviter le bruit GPS :
                // 1. Distance minimale de 3m (le GPS peut fluctuer de 1-3m à l'arrêt)
                // 2. Distance maximale de 100m entre 2 points (éviter les sauts GPS)
                // 3. Précision horizontale acceptable (< 20m)
                // 4. Vitesse GPS cohérente (> 0.5 m/s = 1.8 km/h, sinon considéré à l'arrêt)
                let hasGoodAccuracy = location.horizontalAccuracy > 0 && location.horizontalAccuracy < 20
                let isMoving = location.speed > 0.5  // Plus de 1.8 km/h
                let isValidDistance = distance >= 3 && distance < 100

                if isValidDistance && hasGoodAccuracy && isMoving {
                    totalDistance += distance
                }

                // Vitesse max (location.speed est en m/s, -1 si invalide)
                let speed = location.speed
                if speed > 0 && speed < 100 {  // Filtrer les vitesses aberrantes (< 360 km/h)
                    if speed > maxSpeed {
                        maxSpeed = speed
                    }
                }
            }

            previousLocation = location

            // Ajouter un point à la trace GPS (tous les X secondes) - thread-safe
            let now = Date()
            gpsQueue.sync {
                let shouldAddPoint: Bool
                if let lastTime = lastTrackPointTime {
                    shouldAddPoint = now.timeIntervalSince(lastTime) >= trackPointInterval
                } else {
                    shouldAddPoint = true  // Pas de point précédent, on ajoute le premier
                }

                if shouldAddPoint {
                    let trackPoint = GPSTrackPoint(
                        timestamp: now,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        altitude: altitude,
                        speed: location.speed > 0 ? location.speed : nil
                    )
                    gpsTrackPoints.append(trackPoint)
                    lastTrackPointTime = now

                    // Limiter le nombre de points en mémoire pour éviter les crashes
                    // Compacter proactivement à 80% de la limite pour garder de la marge
                    if gpsTrackPoints.count >= compactionThreshold {
                        compactGPSTrackInternal()
                    }
                }
            }
        }

        reverseGeocode(location: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let unavailable = String(localized: "Position indisponible")
        if currentSpotName != unavailable {
            currentSpotName = unavailable
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }
}
