//
//  WatchLocationService.swift
//  ParaFlightLogWatch Watch App
//
//  Service simple de localisation pour Apple Watch
//  Target: Watch only
//

import Foundation
import CoreLocation

@Observable
final class WatchLocationService: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()

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

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        lastKnownLocation = location
        print("📍 Watch location: \(location.coordinate.latitude), \(location.coordinate.longitude)")

        // Reverse geocoding
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            if let error = error {
                print("❌ Watch geocoding error: \(error.localizedDescription)")
                self?.currentSpotName = "Spot inconnu"
                return
            }

            guard let placemark = placemarks?.first else {
                self?.currentSpotName = "Spot inconnu"
                return
            }

            let spotName = placemark.locality ?? placemark.subLocality ?? placemark.administrativeArea ?? "Spot inconnu"
            DispatchQueue.main.async {
                self?.currentSpotName = spotName
                print("✅ Watch spot: \(spotName)")
            }
        }
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
