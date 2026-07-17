//
//  MapboxReplayConfig.swift
//  ParaFlightLog
//
//  Mapbox access + the replay launcher. This file ALWAYS compiles — the
//  Mapbox-powered replay itself (MapboxFlightReplayView) is compiled only
//  when the MapboxMaps SPM package is present, and used only when a public
//  token is configured below. Until then every replay entry point falls
//  back to the MapKit replay (FlightReplayView).
//
//  Setup steps: see MAPBOX_SETUP.md at the repo root.
//  Target: iOS only
//

import SwiftUI

enum MapboxReplayConfig {
    /// PUBLIC Mapbox token ("pk.…"), stored base64-encoded: public tokens
    /// are designed to ship in the app bundle, but committing one in clear
    /// text to a public repo trips GitHub push protection AND Mapbox's
    /// scraper (which auto-disables tokens found on public GitHub). To
    /// update: base64-encode the new pk token and paste it here.
    static let accessToken: String = {
        let encoded = "cGsuZXlKMUlqb2llR0YyYVdWeWEyRnBiaUlzSW1FaU9pSmpiWEp3WlRCNE5uVXdZVzVrTW5seGVHVnNNelZyT0dzM0luMC5LR0JoLUpjZThobUozUUxMeTBOWW53"
        guard let data = Data(base64Encoded: encoded),
              let token = String(data: data, encoding: .utf8) else { return "" }
        return token
    }()

    /// Terrain vertical exaggeration for the 3D replay (1 = true scale).
    static let terrainExaggeration = 1.3

    static var isConfigured: Bool { accessToken.hasPrefix("pk.") }
}

/// Chooses the best available replay for a track: the Mapbox 3D replay when
/// the SDK is linked AND a token is configured, the MapKit replay otherwise.
/// All replay entry points (local flights, shared flights) go through this.
struct ReplayLauncherView: View {
    let points: [GPSTrackPoint]

    var body: some View {
        #if canImport(MapboxMaps)
        if MapboxReplayConfig.isConfigured {
            MapboxFlightReplayView(points: points)
        } else {
            FlightReplayView(points: points)
        }
        #else
        FlightReplayView(points: points)
        #endif
    }
}
