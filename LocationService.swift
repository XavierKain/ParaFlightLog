//
//  LocationService.swift
//  ParaFlightLog
//
//  CoreLocation + reverse geocoding to resolve the flying spot name.
//  Target: iOS only
//

import Foundation
import CoreLocation
import MapKit

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()

    /// Maximum time to wait for a GPS fix before delivering nil to the caller.
    /// Guarantees callers never hang waiting for a location.
    private let locationRequestTimeout: TimeInterval = 10.0

    // Last known position
    var lastKnownLocation: CLLocation?

    // Authorization state
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // Pending request callback + generation counter so a late fix or the
    // timeout can never fire the same completion twice.
    private var locationCompletionHandler: ((CLLocation?) -> Void)?
    private var locationRequestGeneration: Int = 0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Permissions

    /// Requests location authorization (When In Use)
    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Location

    /// Requests the current GPS position.
    /// The completion is always called exactly once, with nil after
    /// `locationRequestTimeout` seconds if no fix was obtained.
    /// - Parameter completion: callback with the position (or nil)
    func requestLocation(completion: @escaping (CLLocation?) -> Void) {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logWarning("Location permission not granted", category: .location)
            completion(nil)
            return
        }

        // If a previous request is still pending, resolve it with nil first
        if let previous = locationCompletionHandler {
            previous(nil)
        }

        locationRequestGeneration += 1
        let generation = locationRequestGeneration
        locationCompletionHandler = completion
        locationManager.requestLocation()

        // Timeout: never leave the caller hanging
        DispatchQueue.main.asyncAfter(deadline: .now() + locationRequestTimeout) { [weak self] in
            guard let self = self,
                  self.locationRequestGeneration == generation,
                  let pending = self.locationCompletionHandler else { return }

            logWarning("Location request timed out after \(Int(self.locationRequestTimeout))s", category: .location)
            self.locationCompletionHandler = nil
            pending(nil)
        }
    }

    /// Starts continuous location updates (useful during a flight)
    func startUpdatingLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logWarning("Location permission not granted", category: .location)
            return
        }

        locationManager.startUpdatingLocation()
    }

    /// Stops location updates
    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - Reverse Geocoding

    /// Converts a GPS position into a spot name (locality/subLocality).
    /// Uses MKReverseGeocodingRequest.
    /// - Parameters:
    ///   - location: GPS position
    ///   - completion: callback with the spot name (or nil on failure)
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

                // Strategy: cityName > regionName > name
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

        if let completion = locationCompletionHandler {
            locationCompletionHandler = nil
            completion(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logError("Location error: \(error.localizedDescription)", category: .location)

        if let completion = locationCompletionHandler {
            locationCompletionHandler = nil
            completion(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        logInfo("Authorization status changed: \(authorizationStatus.rawValue)", category: .location)
    }
}
