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
    @State private var activeFlightWing: WingDTO? // Voile capturée au démarrage du vol
    @State private var selectedTab: Int = 0
    @State private var isFlying: Bool = false
    @State private var showingActiveFlightView = false
    // Timer data stockée au niveau ContentView
    @State private var flightStartDate: Date?

    // Référence au WorkoutManager pour le Water Lock
    private let workoutManager = WorkoutManager.shared

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
            // Utiliser activeFlightWing qui a été capturé au démarrage du vol
            ActiveFlightView(
                wing: activeFlightWing,
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
                // Demander l'autorisation HealthKit au lancement
                await workoutManager.requestAuthorization()
            }
        }
    }
    
    private func startFlight() {
        // IMPORTANT: Capturer la voile AVANT tout le reste
        // pour qu'elle soit disponible dans le fullScreenCover
        activeFlightWing = selectedWing

        // Définir la date AVANT d'afficher le fullScreenCover
        // pour que le timer puisse démarrer immédiatement
        flightStartDate = Date()
        isFlying = true

        // Démarrer la localisation et le tracking en arrière-plan
        Task(priority: .userInitiated) {
            locationService.startUpdatingLocation()
            locationService.startFlightTracking()

            // Démarrer la session workout pour permettre le Water Lock
            // Le WorkoutManager s'occupe d'activer le Water Lock si le setting est activé
            if WatchSettings.shared.autoWaterLockEnabled {
                print("🔍 Starting workout session for Water Lock...")
                await workoutManager.startWorkoutSession()
            }
        }

        // Afficher le timer immédiatement
        showingActiveFlightView = true
    }

    private func stopFlight(duration: Int) {
        // Utiliser activeFlightWing qui a été capturé au démarrage
        guard let wing = activeFlightWing, let start = flightStartDate else { return }

        let end = Date()

        // Récupérer les données de tracking et la trace GPS AVANT d'arrêter le tracking
        let gpsTrack = locationService.getGPSTrack()
        let endAltitude = locationService.stopFlightTracking()
        let flightData = locationService.getFlightData()

        // Créer le FlightDTO avec toutes les données y compris la trace GPS
        let flight = FlightDTO(
            wingId: wing.id,
            startDate: start,
            endDate: end,
            durationSeconds: duration,
            startAltitude: flightData.startAlt,
            maxAltitude: flightData.maxAlt,
            endAltitude: endAltitude,
            totalDistance: flightData.distance,
            maxSpeed: flightData.speed,
            maxGForce: flightData.maxGForce > 1.0 ? flightData.maxGForce : nil,
            gpsTrack: gpsTrack.isEmpty ? nil : gpsTrack
        )

        // Envoyer vers l'iPhone
        watchManager.sendFlightToPhone(flight)

        // Arrêter la session workout si active
        Task {
            await workoutManager.stopWorkoutSession()
        }

        // Reset
        isFlying = false
        showingActiveFlightView = false
        flightStartDate = nil
        activeFlightWing = nil
        selectedWing = nil
        selectedTab = 0 // Revenir à la sélection de voile
    }

    private func discardFlight() {
        // Annuler le vol sans sauvegarder
        locationService.stopFlightTracking()

        // Arrêter la session workout si active
        Task {
            await workoutManager.stopWorkoutSession()
        }

        isFlying = false
        showingActiveFlightView = false
        flightStartDate = nil
        activeFlightWing = nil
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
        VStack(alignment: .leading, spacing: 2) {
            Text("Sélection")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 8)
                .padding(.top, -8)

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
            HStack(spacing: 6) {
                // Indicateur visuel de sélection (barre latérale)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.green : Color.clear)
                    .frame(width: 3)

                // Miniature de la voile (40x40) avec fond adapté
                CachedWingImage(wing: wing, size: 40, isSelected: isSelected)

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
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
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
                    // Image de la voile
                    CachedWingImage(wing: wing, size: 36, showBackground: false)

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

/// État de la sheet (options ou résumé)
private enum FlightSheetState: Identifiable {
    case stopOptions
    case summary

    var id: Int {
        switch self {
        case .stopOptions: return 0
        case .summary: return 1
        }
    }
}

struct ActiveFlightView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService

    let wing: WingDTO?
    @Binding var flightStartDate: Date?
    let onStopFlight: (Int) -> Void
    let onDiscardFlight: () -> Void

    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var sheetState: FlightSheetState?
    @State private var finalDuration: Int = 0

    var body: some View {
        VStack(spacing: 2) {
            // Indicateur vol en cours (collé en haut)
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Flying")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fontWeight(.bold)
            }
            .padding(.top, -4) // Remonter encore plus haut

            // Voile + taille avec image
            HStack(spacing: 6) {
                if let wing = wing {
                    CachedWingImage(wing: wing, size: 22, showBackground: false)
                    Text(wing.shortName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let size = wing.size {
                        Text("• \(size)m²")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                    }
                } else {
                    // Placeholder invisible pour maintenir le layout
                    Color.clear.frame(height: 22)
                }
            }

            // Spot
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                Text(locationService.currentSpotName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Données de vol en temps réel (taille augmentée: 20 pour valeurs, 12 pour labels)
            HStack(spacing: 10) {
                // Altitude
                VStack(spacing: 0) {
                    Text("\(formatAltitude(locationService.currentAltitude))m")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange)
                    Text(String(localized: "Alt"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Distance
                VStack(spacing: 0) {
                    Text(formatDistance(locationService.totalDistance))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.cyan)
                    Text(String(localized: "Dist"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Vitesse max
                VStack(spacing: 0) {
                    Text("\(formatSpeed(locationService.maxSpeed))")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.purple)
                    Text(String(localized: "Max"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // G-force actuel
                VStack(spacing: 0) {
                    Text(String(format: "%.1f", locationService.currentGForce))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.green)
                    Text("G")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            Spacer()
                .frame(maxHeight: 2)

            // TIMER principal
            Text(formatElapsedTime(elapsedSeconds))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)

            Spacer()
                .frame(maxHeight: 4)

            // Bouton Stop
            Button {
                sheetState = .stopOptions
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.body)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color.black) // Fond noir opaque
        .navigationBarBackButtonHidden(true) // Cacher le bouton retour
        .toolbar(.hidden, for: .navigationBar) // Cacher la barre de navigation
        .sheet(item: $sheetState) { state in
            // Une seule sheet avec contenu dynamique pour éviter le flash
            Group {
                switch state {
                case .stopOptions:
                    StopFlightOptionsView(
                        duration: elapsedSeconds,
                        onSave: {
                            finalDuration = elapsedSeconds
                            stopTimer()
                            locationService.stopUpdatingLocation()
                            // Transition directe vers le summary sans fermer la sheet
                            sheetState = .summary
                        },
                        onDiscard: {
                            stopTimer()
                            locationService.stopUpdatingLocation()
                            sheetState = nil
                            onDiscardFlight()
                        }
                    )
                case .summary:
                    FlightSummaryView(
                        duration: finalDuration,
                        wing: wing ?? WingDTO(id: UUID(), name: "Inconnue", size: nil, type: nil, color: nil, photoData: nil, displayOrder: 0),
                        startAltitude: locationService.startAltitude,
                        maxAltitude: locationService.maxAltitude,
                        endAltitude: locationService.currentAltitude,
                        totalDistance: locationService.totalDistance,
                        maxSpeed: locationService.maxSpeed,
                        maxGForce: locationService.maxGForce
                    ) {
                        sheetState = nil
                        onStopFlight(finalDuration)
                    }
                }
            }
            .presentationBackground(.black)
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

    private func formatAltitude(_ altitude: Double?) -> String {
        guard let alt = altitude else { return "--" }
        return "\(Int(alt))"
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1fkm", distance / 1000)
        } else {
            return "\(Int(distance))m"
        }
    }

    private func formatSpeed(_ speed: Double) -> String {
        let kmh = speed * 3.6  // Convertir m/s en km/h
        return "\(Int(kmh))km/h"
    }
}

// MARK: - StopFlightOptionsView (Choix sauvegarder/annuler)

struct StopFlightOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    let duration: Int
    let onSave: () -> Void
    let onDiscard: () -> Void

    // Vérifier si l'annulation est autorisée
    private var canDismiss: Bool {
        WatchSettings.shared.allowSessionDismiss
    }

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

            // Bouton Annuler (rouge) - seulement si autorisé
            if canDismiss {
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

// MARK: - FlightSummaryView (Résumé après vol avec statistiques)

struct FlightSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let duration: Int
    let wing: WingDTO
    let startAltitude: Double?
    let maxAltitude: Double?
    let endAltitude: Double?
    let totalDistance: Double
    let maxSpeed: Double
    let maxGForce: Double
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                // Icône + titre sur une ligne pour gagner de l'espace
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    Text("Vol terminé !")
                        .font(.headline)
                }
                .padding(.top, -8) // Remonter vers le haut

                // Durée
                Text(formatDuration(duration))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)

                // Voile + taille avec image
                HStack(spacing: 6) {
                    CachedWingImage(wing: wing, size: 20, showBackground: false)
                    Text(wing.shortName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let size = wing.size {
                        Text("• \(size) m²")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }

                // Statistiques de vol
                VStack(spacing: 6) {
                    // Altitudes
                    if startAltitude != nil || maxAltitude != nil || endAltitude != nil {
                        HStack(spacing: 8) {
                            StatBox(label: String(localized: "Départ"), value: formatAlt(startAltitude), unit: "m", color: .orange)
                            StatBox(label: String(localized: "Max"), value: formatAlt(maxAltitude), unit: "m", color: .red)
                            StatBox(label: String(localized: "Arrivée"), value: formatAlt(endAltitude), unit: "m", color: .orange)
                        }
                    }

                    // Distance et vitesse
                    HStack(spacing: 8) {
                        if totalDistance > 0 {
                            StatBox(label: String(localized: "Distance"), value: formatDist(totalDistance), unit: "", color: .cyan)
                        }
                        if maxSpeed > 0 {
                            StatBox(label: String(localized: "Vitesse max"), value: formatSpeed(maxSpeed), unit: "km/h", color: .purple)
                        }
                    }

                    // G-Force max
                    if maxGForce > 1.0 {
                        HStack(spacing: 8) {
                            StatBox(label: "G-Force max", value: String(format: "%.1f", maxGForce), unit: "G", color: .green)
                        }
                    }
                }

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
                .padding(.top, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
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

    private func formatAlt(_ alt: Double?) -> String {
        guard let altitude = alt else { return "--" }
        return "\(Int(altitude))"
    }

    private func formatDist(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1f km", distance / 1000)
        } else {
            return "\(Int(distance)) m"
        }
    }

    private func formatSpeed(_ speed: Double) -> String {
        return "\(Int(speed * 3.6))"
    }
}

// MARK: - StatBox (Composant pour afficher une statistique)

struct StatBox: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ContentView()
        .environment(WatchConnectivityManager.shared)
}

