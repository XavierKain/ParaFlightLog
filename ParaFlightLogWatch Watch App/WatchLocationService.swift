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
    var currentSpotName: String = "Searching..."
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

    // Developer flight simulator (fake feed, no real GPS/motion needed)
    private var simTimer: Timer?
    private var simTick: Int = 0
    private(set) var isSimulating: Bool = false

    // Nom du spot verrouillé pendant le vol (pour éviter qu'il change)
    private var lockedSpotName: String?

    // Trace GPS du vol en cours - protégé par gpsQueue pour thread safety
    private var gpsTrackPoints: [GPSTrackPoint] = []
    private var lastTrackPointTime: Date?
    private let trackPointInterval: TimeInterval = 5.0  // Un point toutes les 5 secondes
    private let gpsQueue = DispatchQueue(label: "com.paraflightlog.gpstrack", qos: .userInitiated)

    // GPS point limit and compaction strategy are shared with
    // FlightSessionManager - see GPSTrackCompaction

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
            currentSpotName = "Permission denied"
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

        // Lock the current spot name only if it's a real spot name;
        // otherwise wait for the first real location
        let searchingText = "Searching..."
        let unknownSpot = "Unknown spot"
        let unavailable = "Location unavailable"

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

        // Developer mode: drive the live screen with a fake feed instead of
        // real GPS/motion, so on-watch readability can be judged without moving.
        if WatchSettings.shared.simulateFlightEnabled {
            startSimulatedFeed()
        } else {
            startMotionUpdates()
        }
    }

    /// Arrête le tracking et retourne l'altitude finale
    func stopFlightTracking() -> Double? {
        isTracking = false
        let endAltitude = currentAltitude
        previousLocation = nil
        lockedSpotName = nil  // Déverrouiller le nom du spot
        stopSimulatedFeed()
        stopMotionUpdates()
        return endAltitude
    }

    // MARK: - Flight Simulator (developer tool)

    /// Starts a fake flight feed: altitude climbs and sinks, speed/distance and
    /// G-force change every second, and a GPS track is recorded so the saved
    /// flight can still be replayed/exported. Purely local — no GPS needed.
    private func startSimulatedFeed() {
        stopSimulatedFeed()
        isSimulating = true
        simTick = 0

        // Base takeoff position (a ridge near Annecy) so the recorded track is plausible
        let baseLat = 45.90
        let baseLon = 6.10
        let baseAltitude = 500.0

        currentSpotName = "Simulator"
        lockedSpotName = "Simulator"
        startAltitude = baseAltitude
        maxAltitude = baseAltitude
        currentAltitude = baseAltitude

        simTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.simTick += 1
            let t = Double(self.simTick)

            // Altitude: slow climb/sink between ~500 m and ~1400 m
            let altitude = baseAltitude + 450.0 * (1.0 - cos(t / 18.0))
            self.currentAltitude = altitude
            if altitude > (self.maxAltitude ?? altitude) {
                self.maxAltitude = altitude
            }

            // Ground speed oscillating 8–16 m/s; accumulate distance each second
            let speed = 12.0 + 4.0 * sin(t / 7.0)
            self.totalDistance += speed
            if speed > self.maxSpeed {
                self.maxSpeed = speed
            }

            // G-force gently oscillating around 1.0 (turns/turbulence)
            let gForce = 1.0 + 0.4 * abs(sin(t / 5.0))
            self.currentGForce = gForce
            if gForce > self.maxGForce {
                self.maxGForce = gForce
            }

            // Record a GPS point every 5 s (figure-eight along the ridge)
            if self.simTick % 5 == 0 {
                let lat = baseLat + 0.0025 * sin(t / 12.0)
                let lon = baseLon + 0.0035 * sin(t / 6.0)
                self.gpsQueue.sync {
                    self.gpsTrackPoints.append(GPSTrackPoint(
                        timestamp: Date(),
                        latitude: lat,
                        longitude: lon,
                        altitude: altitude,
                        speed: speed
                    ))
                }
            }
        }
    }

    private func stopSimulatedFeed() {
        simTimer?.invalidate()
        simTimer = nil
        isSimulating = false
    }

    /// Retourne les données du vol en cours
    func getFlightData() -> (startAlt: Double?, maxAlt: Double?, endAlt: Double?, distance: Double, speed: Double, maxGForce: Double) {
        return (startAltitude, maxAltitude, currentAltitude, totalDistance, maxSpeed, maxGForce)
    }

    /// Retourne la trace GPS du vol (thread-safe)
    func getGPSTrack() -> [GPSTrackPoint] {
        return gpsQueue.sync { gpsTrackPoints }
    }

    /// Compacts the GPS track to save memory (internal - called from gpsQueue)
    /// Delegates to the shared GPSTrackCompaction implementation.
    /// WARNING: must be called from within gpsQueue.sync {}
    private func compactGPSTrackInternal() {
        gpsTrackPoints = GPSTrackCompaction.compact(gpsTrackPoints)
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
    // Rate limiting: 1 request every 30 seconds (2 req/min, well under Apple's 50/min limit)
    private let geocodingMinInterval: TimeInterval = 30.0

    private func reverseGeocode(location: CLLocation) {
        // Si un vol est en cours et qu'on a un spot verrouillé, ne pas changer le nom
        if isTracking, let locked = lockedSpotName {
            // Garder le nom verrouillé pendant le vol
            if currentSpotName != locked {
                currentSpotName = locked
            }
            return
        }

        // Rate limiting: avoid Apple throttling (50 req/60s)
        // Minimum 30 seconds between geocoding requests
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

                // watchOS 26+: use addressRepresentations (new API)
                // Strategy: cityName > regionName > name
                let unknownSpot = "Unknown spot"
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
                    // Do not change the spot while a flight is in progress
                    guard !strongSelf.isTracking else { return }
                    let unknownSpot = "Unknown spot"
                    if strongSelf.currentSpotName != unknownSpot {
                        strongSelf.currentSpotName = unknownSpot
                    }
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // While the developer simulator drives the flight, ignore real GPS so it
        // doesn't overwrite the simulated altitude/speed/spot.
        guard !isSimulating else { return }

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

                    // Limit the number of points in memory to avoid crashes
                    // Compact proactively at 80% of the limit to keep headroom
                    if gpsTrackPoints.count >= GPSTrackCompaction.compactionThreshold {
                        compactGPSTrackInternal()
                    }
                }
            }
        }

        reverseGeocode(location: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let unavailable = "Location unavailable"
        if currentSpotName != unavailable {
            currentSpotName = unavailable
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }
}
