//
//  LocationService.swift
//  ParaFlightLog
//
//  Gestion de CoreLocation + reverse geocoding pour obtenir le spot
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

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
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
        logDebug("Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)", category: .location)

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
