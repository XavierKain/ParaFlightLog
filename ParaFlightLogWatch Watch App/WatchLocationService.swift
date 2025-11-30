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

    // MARK: - Reverse Geocoding avec MapKit

    private func reverseGeocode(location: CLLocation) {
        Task {
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = "current location"
                request.region = MKCoordinateRegion(
                    center: location.coordinate,
                    latitudinalMeters: 1000,
                    longitudinalMeters: 1000
                )

                // Utiliser MKLocalPointsOfInterestRequest pour obtenir le nom du lieu
                let placemarkRequest = CLGeocoder()

                // Fallback: utiliser les coordonnées pour afficher
                // On va simplement faire une recherche locale pour trouver le nom
                let search = MKLocalSearch(request: request)
                let response = try await search.start()

                if let firstItem = response.mapItems.first {
                    let spotName = firstItem.placemark.locality ??
                                   firstItem.placemark.subLocality ??
                                   firstItem.placemark.administrativeArea ??
                                   "Spot inconnu"
                    await MainActor.run {
                        self.currentSpotName = spotName
                        print("✅ Watch spot: \(spotName)")
                    }
                } else {
                    await MainActor.run {
                        self.currentSpotName = "Spot inconnu"
                    }
                }
            } catch {
                print("❌ Watch geocoding error: \(error.localizedDescription)")
                await MainActor.run {
                    self.currentSpotName = "Spot inconnu"
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
