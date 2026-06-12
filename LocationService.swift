//
//  LocationService.swift
//  ParaFlightLog
//
//  Gestion de CoreLocation + reverse geocoding pour obtenir le spot
//  Inclut le tracking GPS pendant les vols (altitude, distance, vitesse, trace GPS)
//  Target: iOS only
//

import Foundation
import CoreLocation
import MapKit

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()

    // Dernière position connue
    var lastKnownLocation: CLLocation?

    // État de l'autorisation
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // Callbacks pour les requêtes en cours
    private var locationCompletionHandler: ((CLLocation?) -> Void)?
    private var geocodeCompletionHandler: ((String?) -> Void)?

    // MARK: - Flight Tracking Properties

    /// Indique si le tracking de vol est actif
    var isTracking: Bool = false

    /// Altitude de départ (première mesure)
    var startAltitude: Double?

    /// Altitude maximale atteinte
    var maxAltitude: Double?

    /// Altitude actuelle
    var currentAltitude: Double?

    /// Distance totale parcourue (en mètres)
    var totalDistance: Double = 0.0

    /// Vitesse maximale (en m/s)
    var maxSpeed: Double = 0.0

    /// Position précédente pour le calcul de distance
    private var previousLocation: CLLocation?

    /// Trace GPS du vol en cours
    private var gpsTrackPoints: [GPSTrackPoint] = []

    /// Dernier timestamp d'ajout de point GPS
    private var lastTrackPointTime: Date?

    /// Intervalle entre les points GPS (2 secondes pour une bonne précision)
    private let trackPointInterval: TimeInterval = 2.0

    /// Queue pour la thread-safety de la trace GPS
    private let gpsQueue = DispatchQueue(label: "com.soarx.gpstrack", qos: .userInitiated)

    /// Limite de points GPS en mémoire
    private let maxGPSPointsInMemory = 1000
    private let compactionThreshold = 800

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // IMPORTANT: Utiliser kCLDistanceFilterNone pour recevoir TOUTES les mises à jour GPS
        locationManager.distanceFilter = kCLDistanceFilterNone
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Permissions

    /// Demande l'autorisation de localisation (When In Use)
    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Location

    /// Demande la position GPS actuelle
    /// - Parameter completion: callback avec la position (ou nil si erreur)
    func requestLocation(completion: @escaping (CLLocation?) -> Void) {
        // Vérifier les permissions
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logWarning("Location permission not granted", category: .location)
            completion(nil)
            return
        }

        locationCompletionHandler = completion
        locationManager.requestLocation()
    }

    /// Démarre le suivi de position en continu (utile pendant un vol)
    func startUpdatingLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logWarning("Location permission not granted", category: .location)
            return
        }

        locationManager.startUpdatingLocation()
    }

    /// Arrête le suivi de position
    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
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

        // Reset de la trace GPS (thread-safe)
        gpsQueue.sync {
            gpsTrackPoints = []
            lastTrackPointTime = nil
        }

        logInfo("Flight tracking started", category: .location)
    }

    /// Arrête le tracking et retourne l'altitude finale
    func stopFlightTracking() -> Double? {
        isTracking = false
        let endAltitude = currentAltitude
        previousLocation = nil

        // Recalculer la distance totale depuis la trace GPS complète avec filtrage intelligent
        let gpsTrack = getGPSTrack()
        if !gpsTrack.isEmpty {
            let recalculatedDistance = GPSDistanceCalculator.calculateTrackDistance(points: gpsTrack, filterOutliers: true)
            let oldDistance = totalDistance
            totalDistance = recalculatedDistance
            logInfo("Flight tracking stopped - Recalculated distance: \(totalDistance)m (old: \(oldDistance)m), Max Alt: \(maxAltitude ?? 0)m", category: .location)
        } else {
            logInfo("Flight tracking stopped - Distance: \(totalDistance)m, Max Alt: \(maxAltitude ?? 0)m", category: .location)
        }

        return endAltitude
    }

    /// Retourne les données du vol en cours
    func getFlightData() -> (startAlt: Double?, maxAlt: Double?, endAlt: Double?, distance: Double, speed: Double) {
        return (startAltitude, maxAltitude, currentAltitude, totalDistance, maxSpeed)
    }

    /// Retourne la trace GPS du vol (thread-safe)
    func getGPSTrack() -> [GPSTrackPoint] {
        return gpsQueue.sync { gpsTrackPoints }
    }

    /// Compacte la trace GPS pour économiser la mémoire
    /// Stratégie : garder 1 point sur 2 dans la première moitié (anciens points)
    /// et tous les points dans la deuxième moitié (points récents = plus de précision)
    private func compactGPSTrackInternal() {
        let count = gpsTrackPoints.count

        guard count >= compactionThreshold else { return }

        var compacted: [GPSTrackPoint] = []
        compacted.reserveCapacity(count / 2 + count / 4)

        let halfCount = count / 2

        // Première moitié : un point sur 2
        for i in stride(from: 0, to: halfCount, by: 2) {
            compacted.append(gpsTrackPoints[i])
        }

        // Deuxième moitié : tous les points
        for i in halfCount..<count {
            compacted.append(gpsTrackPoints[i])
        }

        gpsTrackPoints = compacted
        logInfo("GPS track compacted: \(count) -> \(compacted.count) points", category: .location)
    }

    // MARK: - Reverse Geocoding

    /// Convertit une position GPS en nom de spot (locality/subLocality)
    /// Utilise MKReverseGeocodingRequest (iOS 26+)
    /// - Parameters:
    ///   - location: position GPS
    ///   - completion: callback avec le nom du spot (ou nil si erreur)
    func reverseGeocode(location: CLLocation, completion: @escaping (String?) -> Void) {
        Task {
            do {
                guard let request = MKReverseGeocodingRequest(location: location) else {
                    logWarning("Could not create geocoding request", category: .location)
                    completion(nil)
                    return
                }
                let mapItems = try await request.mapItems

                guard let mapItem = mapItems.first else {
                    logWarning("No placemark found", category: .location)
                    completion(nil)
                    return
                }

                // iOS 26+ : utiliser addressRepresentations (nouvelle API)
                // Stratégie : cityName > regionName > name
                let spotName: String?
                if let addr = mapItem.addressRepresentations {
                    spotName = addr.cityName ?? addr.regionName ?? mapItem.name
                } else {
                    spotName = mapItem.name
                }

                logDebug("Spot found: \(spotName ?? "Unknown")", category: .location)
                completion(spotName)
            } catch {
                logError("Reverse geocoding error: \(error.localizedDescription)", category: .location)
                completion(nil)
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

                // Temps écoulé depuis la dernière position
                let timeDelta = location.timestamp.timeIntervalSince(previous.timestamp)

                // Filtres pour éviter le bruit GPS (adaptés au parapente) :
                // 1. Distance minimale de 2m (le GPS peut fluctuer de 1-2m à l'arrêt)
                // 2. Distance maximale de 200m entre 2 points (éviter les sauts GPS majeurs)
                // 3. Précision horizontale acceptable (< 50m - en montagne c'est souvent 20-40m)
                // 4. Temps entre 2 points raisonnable (< 30s, sinon c'est un gap)
                let hasAcceptableAccuracy = location.horizontalAccuracy > 0 && location.horizontalAccuracy < 50
                let isValidDistance = distance >= 2 && distance < 200
                let isValidTimeDelta = timeDelta > 0 && timeDelta < 30

                // Calculer la vitesse implicite pour détecter les sauts GPS aberrants
                let implicitSpeed = timeDelta > 0 ? distance / timeDelta : 0
                let isRealisticSpeed = implicitSpeed < 30  // < 108 km/h max réaliste

                if isValidDistance && hasAcceptableAccuracy && isValidTimeDelta && isRealisticSpeed {
                    totalDistance += distance
                }

                // Vitesse max (location.speed est en m/s, -1 si invalide)
                let speed = location.speed
                if speed > 0 && speed < 30 {  // Filtrer les vitesses aberrantes (< 108 km/h)
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
                        speed: location.speed > 0 ? location.speed : nil,
                        accuracy: location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
                    )
                    gpsTrackPoints.append(trackPoint)
                    lastTrackPointTime = now

                    // Compacter si nécessaire pour éviter les crashes mémoire
                    if gpsTrackPoints.count >= compactionThreshold {
                        compactGPSTrackInternal()
                    }
                }
            }
        }

        // Si on a un completion handler en attente, l'appeler
        if let completion = locationCompletionHandler {
            completion(location)
            locationCompletionHandler = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logError("Location error: \(error.localizedDescription)", category: .location)

        // Appeler le completion handler avec nil
        if let completion = locationCompletionHandler {
            completion(nil)
            locationCompletionHandler = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        logInfo("Authorization status changed: \(authorizationStatus.rawValue)", category: .location)

        // Si l'autorisation vient d'être accordée, on peut démarrer la localisation
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            logInfo("Location authorized", category: .location)
        }
    }
}
