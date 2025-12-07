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

    override init() {
        super.init()
        // Pré-initialiser le CLLocationManager en background dès la création
        // Cela évite le freeze au premier appel de startUpdatingLocation
        Task.detached(priority: .utility) { [weak self] in
            await self?.initializeLocationManager()
        }
    }

    /// Initialise le CLLocationManager en background
    @MainActor
    private func initializeLocationManager() {
        guard !isInitialized else { return }
        isInitialized = true

        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
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
