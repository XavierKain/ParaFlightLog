//
//  WatchLocationService.swift
//  ParaFlightLogWatch Watch App
//
//  Service simple de localisation pour Apple Watch
//  Target: Watch only
//

import Foundation
import CoreLocation
import MapKit

@Observable
final class WatchLocationService: NSObject, CLLocationManagerDelegate {
    // CLLocationManager initialisé en background pour éviter le lag
    private var _locationManager: CLLocationManager?
    private var isInitialized = false

    private var locationManager: CLLocationManager {
        if let manager = _locationManager {
            return manager
        }
        // Fallback synchrone si pas encore initialisé
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        _locationManager = manager
        return manager
    }

    var lastKnownLocation: CLLocation?
    var currentSpotName: String = String(localized: "Position...")
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // Données de tracking pour le vol en cours
    var isTracking: Bool = false
    var startAltitude: Double?
    var maxAltitude: Double?
    var currentAltitude: Double?
    var totalDistance: Double = 0.0
    var maxSpeed: Double = 0.0
    private var previousLocation: CLLocation?

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
        manager.allowsBackgroundLocationUpdates = true
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
        previousLocation = nil
    }

    /// Arrête le tracking et retourne l'altitude finale
    func stopFlightTracking() -> Double? {
        isTracking = false
        let endAltitude = currentAltitude
        previousLocation = nil
        return endAltitude
    }

    /// Retourne les données du vol en cours
    func getFlightData() -> (startAlt: Double?, maxAlt: Double?, endAlt: Double?, distance: Double, speed: Double) {
        return (startAltitude, maxAltitude, currentAltitude, totalDistance, maxSpeed)
    }

    // MARK: - Reverse Geocoding avec CLGeocoder

    private var isGeocodingInProgress = false
    private var lastGeocodedSpot: String?

    private func reverseGeocode(location: CLLocation) {
        // Éviter les multiples appels simultanés
        guard !isGeocodingInProgress else { return }
        isGeocodingInProgress = true

        let geocoder = CLGeocoder()

        // Faire le geocoding en background pour ne pas bloquer l'UI
        Task.detached(priority: .utility) { [weak self] in
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                let placemark = placemarks.first

                // Calculer le nom du spot en background
                let unknownSpot = String(localized: "Spot inconnu")
                let spotName = placemark?.locality ??
                               placemark?.subLocality ??
                               placemark?.administrativeArea ??
                               placemark?.name ??
                               unknownSpot

                await MainActor.run {
                    self?.isGeocodingInProgress = false
                    // Ne mettre à jour que si le nom change (évite les re-renders inutiles)
                    if self?.lastGeocodedSpot != spotName {
                        self?.lastGeocodedSpot = spotName
                        self?.currentSpotName = spotName
                    }
                }
            } catch {
                await MainActor.run {
                    self?.isGeocodingInProgress = false
                    let unknownSpot = String(localized: "Spot inconnu")
                    if self?.currentSpotName != unknownSpot {
                        self?.currentSpotName = unknownSpot
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
                if distance > 0 && distance < 100 {  // Filtrer les valeurs aberrantes (> 100m entre 2 points)
                    totalDistance += distance
                }

                // Vitesse (location.speed est en m/s, -1 si invalide)
                let speed = location.speed
                if speed > 0 && speed < 100 {  // Filtrer les vitesses aberrantes (< 360 km/h)
                    if speed > maxSpeed {
                        maxSpeed = speed
                    }
                }
            }

            previousLocation = location
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
