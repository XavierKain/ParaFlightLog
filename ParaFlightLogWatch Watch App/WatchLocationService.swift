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
    private let locationManager = CLLocationManager()

    var lastKnownLocation: CLLocation?
    var currentSpotName: String = "Recherche..."
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = locationManager.authorizationStatus
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdatingLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            print("⚠️ Location permission not granted on Watch")
            currentSpotName = "Permission refusée"
            return
        }

        locationManager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - Reverse Geocoding avec CLGeocoder

    private var isGeocodingInProgress = false

    private func reverseGeocode(location: CLLocation) {
        // Éviter les multiples appels simultanés
        guard !isGeocodingInProgress else { return }
        isGeocodingInProgress = true

        // CLGeocoder fonctionne sur watchOS pour le reverse geocoding
        let geocoder = CLGeocoder()

        // Faire le geocoding en background pour ne pas bloquer l'UI
        Task.detached(priority: .background) { [weak self] in
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)

                await MainActor.run {
                    self?.isGeocodingInProgress = false

                    guard let placemark = placemarks.first else {
                        self?.currentSpotName = "Spot inconnu"
                        return
                    }

                    // Priorité : locality (ville) > subLocality > administrativeArea
                    let spotName = placemark.locality ??
                                   placemark.subLocality ??
                                   placemark.administrativeArea ??
                                   placemark.name ??
                                   "Spot inconnu"

                    self?.currentSpotName = spotName
                    print("✅ Watch spot: \(spotName)")
                }
            } catch {
                await MainActor.run {
                    self?.isGeocodingInProgress = false
                    print("❌ Watch geocoding error: \(error.localizedDescription)")
                    self?.currentSpotName = "Spot inconnu"
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        lastKnownLocation = location
        print("📍 Watch location: \(location.coordinate.latitude), \(location.coordinate.longitude)")

        // Reverse geocoding avec MapKit
        reverseGeocode(location: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Watch location error: \(error.localizedDescription)")
        currentSpotName = "Position indisponible"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        print("🔐 Watch authorization status: \(authorizationStatus.rawValue)")
    }
}
