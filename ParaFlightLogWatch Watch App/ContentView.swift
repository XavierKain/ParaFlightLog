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
    @State private var selectedWing: WingDTO?
    @State private var selectedTab: Int = 0
    @State private var isFlying: Bool = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // Écran 1 : Sélection de voile
            WingSelectionView(selectedWing: $selectedWing, selectedTab: $selectedTab, isFlying: isFlying)
                .environment(watchManager)
                .tag(0)

            // Écran 2 : Timer et contrôle du vol
            FlightTimerView(selectedWing: $selectedWing, selectedTab: $selectedTab, isFlying: $isFlying)
                .environment(watchManager)
                .tag(1)
        }
        .tabViewStyle(.page)
        // Empêcher le changement de tab pendant le vol via onChange
        .onChange(of: selectedTab) { oldValue, newValue in
            if isFlying && newValue != 1 {
                // Forcer le retour à l'écran du chrono si un vol est en cours
                selectedTab = 1
            }
        }
    }
}

// MARK: - WingSelectionView (Écran 1)

struct WingSelectionView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Binding var selectedWing: WingDTO?
    @Binding var selectedTab: Int
    var isFlying: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            Text("Sélection")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

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
                    VStack(spacing: 4) {
                        ForEach(watchManager.wings) { wing in
                            Button {
                                selectedWing = wing
                                // Auto-navigation vers l'écran timer avec animation
                                withAnimation {
                                    selectedTab = 1
                                }
                            } label: {
                                HStack {
                                    // Photo ou icône de la voile
                                    if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 30, height: 30)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        Image(systemName: "wind")
                                            .font(.title3)
                                            .foregroundStyle(.blue)
                                            .frame(width: 30, height: 30)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(wing.name)
                                            .font(.headline)
                                        if let size = wing.size {
                                            Text("\(size) m²")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    if selectedWing?.id == wing.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedWing?.id == wing.id ? Color.green.opacity(0.15) : Color.gray.opacity(0.2))
                            )
                            .disabled(isFlying) // Désactiver pendant le vol
                            .opacity(isFlying ? 0.5 : 1.0)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}

// MARK: - FlightTimerView (Écran 2)

struct FlightTimerView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService
    @Environment(\.scenePhase) private var scenePhase
    @Binding var selectedWing: WingDTO?
    @Binding var selectedTab: Int
    @Binding var isFlying: Bool
    @State private var startDate: Date?
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var showingFlightSummary = false
    @State private var completedFlightData: (duration: Int, wing: WingDTO)?

    var body: some View {
        VStack(spacing: 8) {
            // Voile sélectionnée
            if let wing = selectedWing {
                HStack(spacing: 6) {
                    // Photo ou icône de la voile
                    if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 35, height: 35)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "wind")
                            .font(.headline)
                            .foregroundStyle(.blue)
                            .frame(width: 35, height: 35)
                    }

                    VStack(spacing: 2) {
                        Text(wing.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let size = wing.size {
                            Text("\(size) m²")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text("Choisir une voile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            // Spot (si vol en cours)
            if isFlying {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(locationService.currentSpotName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
            }

            // Chrono
            Text(formatElapsedTime(elapsedSeconds))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isFlying ? .green : .primary)

            // Bouton Start/Stop
            Button {
                if isFlying {
                    stopFlight()
                } else {
                    startFlight()
                }
            } label: {
                Label(isFlying ? "Stop" : "Start", systemImage: isFlying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .tint(isFlying ? .red : .green)
            .disabled(!isFlying && selectedWing == nil)
        }
        .sheet(isPresented: $showingFlightSummary) {
            if let data = completedFlightData {
                FlightSummaryView(duration: data.duration, wing: data.wing)
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active && isFlying, let start = startDate {
                // Recalculer le temps écoulé depuis le début du vol
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    // MARK: - Flight Control

    private func startFlight() {
        guard selectedWing != nil else { return }

        startDate = Date()
        elapsedSeconds = 0
        isFlying = true

        // Démarrer la localisation
        locationService.startUpdatingLocation()

        // Démarrer le timer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            elapsedSeconds += 1
        }
    }

    private func stopFlight() {
        guard let wing = selectedWing, let start = startDate else { return }

        let end = Date()
        let duration = Int(end.timeIntervalSince(start))

        // Arrêter le timer et le GPS
        timer?.invalidate()
        timer = nil
        locationService.stopUpdatingLocation()

        // Créer le FlightDTO
        let flight = FlightDTO(
            wingId: wing.id,
            startDate: start,
            endDate: end,
            durationSeconds: duration
        )

        // Envoyer vers l'iPhone
        watchManager.sendFlightToPhone(flight)

        // Sauvegarder les données pour le résumé
        completedFlightData = (duration: duration, wing: wing)

        // Reset l'interface
        isFlying = false
        elapsedSeconds = 0
        startDate = nil
        selectedWing = nil

        // Afficher le résumé
        showingFlightSummary = true
    }

    // MARK: - Helpers

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

// MARK: - FlightSummaryView (Résumé après vol)

struct FlightSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let duration: Int
    let wing: WingDTO

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 6) {
                    // Icône de succès
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 35))
                        .foregroundStyle(.green)

                    Text("Vol terminé !")
                        .font(.caption)
                        .fontWeight(.semibold)

                    // Durée
                    VStack(spacing: 1) {
                        Text(formatDuration(duration))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                        Text("durée")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    // Voile
                    VStack(spacing: 3) {
                        // Photo de la voile si disponible
                        if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 35, height: 35)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        Text(wing.name)
                            .font(.caption)
                            .fontWeight(.semibold)
                        if let size = wing.size {
                            Text("\(size) m²")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Bouton fermer
                    Button {
                        dismiss()
                    } label: {
                        Text("Terminer")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }
        }
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

