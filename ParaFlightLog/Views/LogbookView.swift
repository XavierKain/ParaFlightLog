//
//  LogbookView.swift
//  ParaFlightLog
//
//  Hub consolidé : Flights + Stats + Charts
//  Utilise un segmented control pour basculer entre Timeline, Stats et Maps
//

import SwiftUI
import SwiftData

struct LogbookView: View {
    @State private var selectedSegment = 0
    @Environment(DataController.self) private var dataController

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented control pour choisir la vue
                Picker("View", selection: $selectedSegment) {
                    Label("Timeline", systemImage: "list.bullet").tag(0)
                    Label("Stats", systemImage: "chart.bar").tag(1)
                    Label("Maps", systemImage: "map").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                // Contenu basé sur le segment sélectionné
                // Note: On utilise un switch au lieu de TabView(.page) pour éviter
                // le conflit entre le swipe horizontal et le swipe-to-delete des vols
                Group {
                    switch selectedSegment {
                    case 0:
                        FlightsView()
                    case 1:
                        StatsView()
                    case 2:
                        ChartsView()
                    default:
                        FlightsView()
                    }
                }
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
}
