//
//  MapTabView.swift
//  ParaFlightLog
//
//  Hub géographique : consolidation de toutes les fonctionnalités map
//  - My Flights (carte des vols)
//  - Live Pilots (pilotes en vol)
//  - NOTAM Zones (restrictions aériennes)
//

import SwiftUI
import MapKit
import SwiftData

struct MapTabView: View {
    @State private var selectedMode: MapMode = .myFlights
    @Query private var flights: [Flight]

    enum MapMode: String, CaseIterable {
        case myFlights
        case livePilots
        case notamZones

        var displayName: String {
            switch self {
            case .myFlights: return String(localized: "Mes vols")
            case .livePilots: return String(localized: "En direct")
            case .notamZones: return String(localized: "NOTAM")
            }
        }

        var icon: String {
            switch self {
            case .myFlights: return "map"
            case .livePilots: return "airplane.circle"
            case .notamZones: return "exclamationmark.triangle"
            }
        }
    }

    var body: some View {
        ZStack {
            // Contenu de la carte selon le mode sélectionné
            Group {
                switch selectedMode {
                case .myFlights:
                    // Réutiliser ChartsView qui contient déjà FlightsSpotsMapView
                    ChartsView()
                case .livePilots:
                    LiveFlightsMapView()
                case .notamZones:
                    NOTAMMapView()
                }
            }
            .ignoresSafeArea(edges: .top)

            // Mode selector en bas
            VStack {
                Spacer()

                MapModePicker(selectedMode: $selectedMode)
                    .padding()
            }

            // Floating controls en haut à droite
            VStack(alignment: .trailing, spacing: 12) {
                SettingsGearButton()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}

// MARK: - MapModePicker

struct MapModePicker: View {
    @Binding var selectedMode: MapTabView.MapMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MapTabView.MapMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        selectedMode = mode
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 14, weight: .semibold))

                        if selectedMode == mode {
                            Text(mode.displayName)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .foregroundStyle(selectedMode == mode ? .white : .primary)
                    .padding(.horizontal, selectedMode == mode ? 16 : 12)
                    .padding(.vertical, 10)
                    .background {
                        if selectedMode == mode {
                            Color.blue
                        } else {
                            Color(.systemBackground)
                        }
                    }
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .cornerRadius(25)
    }
}

#Preview {
    MapTabView()
}
