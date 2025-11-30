//
//  LocationService.swift
//  ParaFlightLog
//
//  Gestion de CoreLocation + reverse geocoding pour obtenir le spot
//  Target: iOS only
//

import Foundation
import CoreLocation

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()

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
            print("⚠️ Location permission not granted")
            completion(nil)
            return
        }

        locationCompletionHandler = completion
        locationManager.requestLocation()
    }

    /// Démarre le suivi de position en continu (utile pendant un vol)
    func startUpdatingLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            print("⚠️ Location permission not granted")
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
    /// - Parameters:
    ///   - location: position GPS
    ///   - completion: callback avec le nom du spot (ou nil si erreur)
    func reverseGeocode(location: CLLocation, completion: @escaping (String?) -> Void) {
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            if let error = error {
                print("❌ Reverse geocoding error: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let placemark = placemarks?.first else {
                print("⚠️ No placemark found")
                completion(nil)
                return
            }

            // Stratégie : locality > subLocality > administrativeArea
            let spotName = self?.extractSpotName(from: placemark)
            print("✅ Spot found: \(spotName ?? "Unknown")")
            completion(spotName)
        }
    }

    /// Extrait le meilleur nom de spot depuis un placemark
    private func extractSpotName(from placemark: CLPlacemark) -> String? {
        // Priorité 1 : locality (ville/village)
        if let locality = placemark.locality, !locality.isEmpty {
            return locality
        }

        // Priorité 2 : subLocality (quartier)
        if let subLocality = placemark.subLocality, !subLocality.isEmpty {
            return subLocality
        }

        // Priorité 3 : administrativeArea (région/état)
        if let admin = placemark.administrativeArea, !admin.isEmpty {
            return admin
        }

        // Fallback : name générique
        return placemark.name
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        lastKnownLocation = location
        print("📍 Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")

        // Si on a un completion handler en attente, l'appeler
        if let completion = locationCompletionHandler {
            completion(location)
            locationCompletionHandler = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Location error: \(error.localizedDescription)")

        // Appeler le completion handler avec nil
        if let completion = locationCompletionHandler {
            completion(nil)
            locationCompletionHandler = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        print("🔐 Authorization status changed: \(authorizationStatus.rawValue)")

        // Si l'autorisation vient d'être accordée, on peut démarrer la localisation
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            print("✅ Location authorized")
        }
    }
}
