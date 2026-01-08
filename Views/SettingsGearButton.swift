//
//  SettingsGearButton.swift
//  ParaFlightLog
//
//  Composant réutilisable : bouton engrenage qui ouvre les Settings en modal
//  Accessible depuis tous les onglets de l'app
//

import SwiftUI

struct SettingsGearButton: View {
    @State private var showSettings = false

    var body: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .sheet(isPresented: $showSettings) {
            SettingsTabView()
        }
    }
}

#Preview {
    SettingsGearButton()
}
