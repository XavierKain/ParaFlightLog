//
//  LogbookView.swift
//  ParaFlightLog
//
//  Hub consolidé : Flights + Stats + Charts
//  Utilise un segmented control pour basculer entre Timeline, Stats et Maps
//

import SwiftUI

struct LogbookView: View {
    @State private var selectedSegment = 0
    @Environment(FlightService.self) private var flightService

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Contenu temporaire - sera implémenté en Phase 2
                Text("Logbook View")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text("Fusion de Flights, Stats et Charts")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding()
            }
            .navigationTitle("Logbook")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsGearButton()
                }
            }
        }
    }
}

#Preview {
    LogbookView()
        .environment(FlightService.shared)
}
