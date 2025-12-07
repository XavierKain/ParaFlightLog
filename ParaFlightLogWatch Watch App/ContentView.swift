//
//  ContentView.swift
//  ParaFlightLogWatch Watch App
//
//  Vue principale de l'app Apple Watch : navigation multi-écrans
//  Target: Watch only
//

import SwiftUI

struct ContentView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService
    @State private var selectedWing: WingDTO?
    @State private var selectedTab: Int = 0
    @State private var isFlying: Bool = false
    @State private var showingActiveFlightView = false
    // Timer data stockée au niveau ContentView
    @State private var flightStartDate: Date?

    var body: some View {
        TabView(selection: $selectedTab) {
            // Écran 1 : Sélection de voile
            WingSelectionView(selectedWing: $selectedWing, selectedTab: $selectedTab)
                .environment(watchManager)
                .tag(0)

            // Écran 2 : Récap voile + bouton Start
            FlightStartView(
                selectedWing: $selectedWing,
                onStartFlight: {
                    startFlight()
                }
            )
            .environment(watchManager)
            .tag(1)
        }
        .tabViewStyle(.page)
        .fullScreenCover(isPresented: $showingActiveFlightView) {
            // Écran 3 : Timer actif (plein écran, impossible de quitter)
            ActiveFlightView(
                wing: selectedWing,
                flightStartDate: $flightStartDate,
                onStopFlight: { duration in
                    stopFlight(duration: duration)
                },
                onDiscardFlight: {
                    discardFlight()
                }
            )
            .environment(watchManager)
            .environment(locationService)
            .interactiveDismissDisabled(true) // Empêche de swipe down pour fermer
        }
        .onAppear {
            // Pré-démarrer la localisation dès le lancement de l'app
            // pour éviter le lag au moment du Start
            Task(priority: .background) {
                locationService.requestAuthorization()
            }
        }
    }
    
    private func startFlight() {
        // IMPORTANT: Définir la date AVANT d'afficher le fullScreenCover
        // pour que le timer puisse démarrer immédiatement
        flightStartDate = Date()
        isFlying = true

        // Démarrer la localisation en arrière-plan (ne bloque pas l'UI)
        Task(priority: .userInitiated) {
            locationService.startUpdatingLocation()
        }

        // Afficher le timer immédiatement
        showingActiveFlightView = true
    }
    
    private func stopFlight(duration: Int) {
        guard let wing = selectedWing, let start = flightStartDate else { return }
        
        let end = Date()
        
        // Créer le FlightDTO
        let flight = FlightDTO(
            wingId: wing.id,
            startDate: start,
            endDate: end,
            durationSeconds: duration
        )
        
        // Envoyer vers l'iPhone
        watchManager.sendFlightToPhone(flight)
        
        // Reset
        isFlying = false
        showingActiveFlightView = false
        flightStartDate = nil
        selectedWing = nil
        selectedTab = 0 // Revenir à la sélection de voile
    }
    
    private func discardFlight() {
        // Annuler le vol sans sauvegarder
        isFlying = false
        showingActiveFlightView = false
        flightStartDate = nil
        selectedWing = nil
        selectedTab = 0
    }
}

// MARK: - WingSelectionView (Écran 1)

struct WingSelectionView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Binding var selectedWing: WingDTO?
    @Binding var selectedTab: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("Sélection")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, -4)

            if watchManager.wings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wind.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.red)

                    Text("Aucune voile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Ajoutez-en depuis l'iPhone")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(watchManager.wings) { wing in
                            WingButton(
                                wing: wing,
                                isSelected: selectedWing?.id == wing.id,
                                onTap: {
                                    // Sélectionner immédiatement pour voir la surbrillance
                                    selectedWing = wing
                                    // Petit délai pour voir l'effet de sélection avant le scroll
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        withAnimation {
                                            selectedTab = 1
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}

/// Bouton de sélection de voile optimisé et moderne
struct WingButton: View {
    let wing: WingDTO
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Indicateur visuel de sélection (barre latérale)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.green : Color.clear)
                    .frame(width: 3)

                // Contenu principal - nom et taille empilés
                VStack(alignment: .leading, spacing: 2) {
                    Text(wing.shortName)
                        .font(.system(.body, design: .rounded))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let size = wing.size {
                        Text("\(size) m²")
                            .font(.system(.caption2, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                    }
                }

                Spacer(minLength: 0)

                // Icône de sélection
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.green.opacity(0.12) : Color.gray.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
    }
}

// MARK: - FlightStartView (Écran 2 - Récap + Start)

struct FlightStartView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService
    @Binding var selectedWing: WingDTO?
    let onStartFlight: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Voile sélectionnée
            if let wing = selectedWing {
                VStack(spacing: 4) {
                    Text(wing.shortName)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    
                    if let size = wing.size {
                        Text("\(size) m²")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Localisation actuelle
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(locationService.currentSpotName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
                
                Spacer()
                
                // Bouton Start
                Button {
                    onStartFlight()
                } label: {
                    Label("Start", systemImage: "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                
                Spacer()
                
            } else {
                // Pas de voile sélectionnée
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    
                    Text("Choisir une voile")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Text("Swipez vers la gauche")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // Supprimé: onAppear qui démarrait la localisation et causait du lag
    }
}

// MARK: - ActiveFlightView (Écran 3 - Timer plein écran)

struct ActiveFlightView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService
    
    let wing: WingDTO?
    @Binding var flightStartDate: Date?
    let onStopFlight: (Int) -> Void
    let onDiscardFlight: () -> Void
    
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var showingStopOptions = false
    @State private var showingSummary = false
    @State private var finalDuration: Int = 0

    var body: some View {
        VStack(spacing: 6) {
            // Indicateur vol en cours
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("VOL EN COURS")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fontWeight(.bold)
            }
            
            // Voile + taille
            if let wing = wing {
                HStack(spacing: 4) {
                    Text(wing.shortName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let size = wing.size {
                        Text("• \(size)m²")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
            
            // Spot
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text(locationService.currentSpotName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            
            // TIMER principal
            Text(formatElapsedTime(elapsedSeconds))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)
            
            Spacer()

            // Bouton Stop
            Button {
                showingStopOptions = true
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .navigationBarBackButtonHidden(true) // Cacher le bouton retour
        .toolbar(.hidden, for: .navigationBar) // Cacher la barre de navigation
        .sheet(isPresented: $showingStopOptions) {
            // Fenêtre de choix : Sauvegarder ou Annuler
            StopFlightOptionsView(
                duration: elapsedSeconds,
                onSave: {
                    finalDuration = elapsedSeconds
                    stopTimer()
                    locationService.stopUpdatingLocation()
                    showingStopOptions = false
                    showingSummary = true
                },
                onDiscard: {
                    stopTimer()
                    locationService.stopUpdatingLocation()
                    showingStopOptions = false
                    onDiscardFlight()
                }
            )
        }
        .sheet(isPresented: $showingSummary) {
            FlightSummaryView(
                duration: finalDuration,
                wing: wing ?? WingDTO(id: UUID(), name: "Inconnue", size: nil, type: nil, color: nil, photoData: nil, displayOrder: 0)
            ) {
                onStopFlight(finalDuration)
            }
        }
        .onAppear {
            // Démarrer le timer immédiatement sans délai
            startTimerImmediately()
        }
        .onDisappear {
            stopTimer()
        }
    }
    
    private func startTimerImmediately() {
        // Calculer immédiatement le temps écoulé
        if let start = flightStartDate {
            elapsedSeconds = Int(Date().timeIntervalSince(start))
        } else {
            elapsedSeconds = 0
        }
        
        // Démarrer le timer sur le RunLoop principal
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = flightStartDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func formatElapsedTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}

// MARK: - StopFlightOptionsView (Choix sauvegarder/annuler)

struct StopFlightOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    let duration: Int
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Titre en haut
            Text("Terminer le vol ?")
                .font(.headline)

            // Durée
            Text(formatDuration(duration))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.blue)

            Spacer()

            // Bouton Sauvegarder (vert)
            Button {
                onSave()
            } label: {
                Label("Sauvegarder", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            // Bouton Annuler (rouge)
            Button(role: .destructive) {
                onDiscard()
            } label: {
                Text("Annuler le vol")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .navigationBarHidden(true)
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }
}

// MARK: - FlightSummaryView (Résumé après vol - compact)

struct FlightSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let duration: Int
    let wing: WingDTO
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Icône centrée au-dessus
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)

            // Titre
            Text("Vol terminé !")
                .font(.headline)

            // Durée
            Text(formatDuration(duration))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.blue)

            // Voile + taille
            HStack(spacing: 4) {
                Text(wing.shortName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let size = wing.size {
                    Text("• \(size) m²")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            Spacer()

            // Bouton fermer
            Button {
                dismiss()
                onDismiss()
            } label: {
                Text("OK")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }
}

#Preview {
    ContentView()
        .environment(WatchConnectivityManager.shared)
}

