//
//  MapTabView.swift
//  ParaFlightLog
//
//  Hub géographique : carte des vols et spots locaux
//  - My Flights (carte des vols, réutilise ChartsView / FlightsSpotsMapView)
//

import SwiftUI
import MapKit
import SwiftData

struct MapTabView: View {
    var body: some View {
        ZStack {
            // Carte des vols : réutilise ChartsView qui contient déjà FlightsSpotsMapView
            ChartsView()

            // Floating controls en haut à droite
            VStack(alignment: .trailing, spacing: 12) {
                SettingsGearButton()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}

#Preview {
    MapTabView()
}
