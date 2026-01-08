//
//  MapTabView.swift
//  ParaFlightLog
//
//  Hub géographique : consolidation de toutes les fonctionnalités map
//  - My Flights (heatmap)
//  - Spots (annotations)
//  - Live Pilots (pilotes en vol)
//  - NOTAM Zones (restrictions)
//

import SwiftUI
import MapKit

struct MapTabView: View {
    @State private var selectedMode: MapMode = .myFlights
    @State private var showNOTAM = false

    enum MapMode {
        case myFlights      // Heatmap de mes vols
        case spots          // Annotations des spots
        case livePilots     // Pilotes en vol actuellement
        case notamZones     // Zones NOTAM/restrictions
    }

    var body: some View {
        ZStack {
            // Contenu temporaire - sera implémenté en Phase 3
            VStack {
                Spacer()
                Text("Map Tab View")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text("Consolidation géographique")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding()
                Spacer()
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 12) {
                // Settings gear icon
                SettingsGearButton()
                    .padding()
            }
        }
    }
}

#Preview {
    MapTabView()
}
