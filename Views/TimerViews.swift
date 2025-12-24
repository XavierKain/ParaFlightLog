//
//  TimerViews.swift
//  ParaFlightLog
//
//  Vues liées au chronomètre : timer, sélection voile, résumé vol
//  Target: iOS only
//

import SwiftUI
import SwiftData
import CoreLocation

// MARK: - TimerView (Chrono redesigné)

struct TimerView: View {
    @Environment(DataController.self) private var dataController
    @Environment(LocationService.self) private var locationService
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    @State private var selectedWing: Wing?
    @State private var isFlying = false
    @State private var startDate: Date?
    @State private var elapsedSeconds: Int = 0
    @State private var backgroundTask: Timer?
    @State private var currentSpot: String = "Recherche..."
    @State private var manualSpotOverride: String? = nil
    @State private var showingManualSpot = false
    @State private var showingWingPicker = false
    @State private var showingFlightSummary = false
    @State private var completedFlight: Flight?

    var body: some View {
        NavigationStack {
            ZStack {
                // Fond dégradé
                LinearGradient(
                    colors: isFlying ? [.green.opacity(0.2), .blue.opacity(0.2)] : [.gray.opacity(0.1), .gray.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 24) {
                    // Sélection de la voile (design compact)
                    if !isFlying {
                        VStack(spacing: 12) {
                            Text("Voile")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(1)

                            if wings.isEmpty {
                                Text("Ajoutez d'abord une voile dans l'onglet Voiles")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding()
                            } else {
                                Button {
                                    showingWingPicker = true
                                } label: {
                                    HStack(spacing: 12) {
                                        if let wing = selectedWing {
                                            // Photo miniature avec cache
                                            CachedImage(
                                                data: wing.photoData,
                                                key: wing.id.uuidString,
                                                size: CGSize(width: 50, height: 50)
                                            ) {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                                                    .overlay {
                                                        Image(systemName: "wind")
                                                            .foregroundStyle(colorFromString(wing.color ?? "Gris"))
                                                    }
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 8))

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(wing.name)
                                                    .font(.headline)
                                                    .foregroundStyle(.primary)
                                                if let size = wing.size {
                                                    Text("\(size) m²")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }

                                            Spacer()

                                            Image(systemName: "chevron.down")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        } else {
                                            Image(systemName: "wind")
                                                .font(.title2)
                                                .foregroundStyle(.blue)

                                            Text("Sélectionner une voile")
                                                .font(.body)
                                                .foregroundStyle(.blue)

                                            Spacer()

                                            Image(systemName: "chevron.down")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding()
                                    .background(
                                        LinearGradient(
                                            colors: selectedWing == nil ? [.blue.opacity(0.1), .blue.opacity(0.05)] : [Color(.systemBackground)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedWing == nil ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 2)
                                    )
                                    .cornerRadius(12)
                                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                                }
                                .padding(.horizontal)
                            }
                        }
                    } else {
                        // Afficher la voile sélectionnée pendant le vol
                        if let wing = selectedWing {
                            VStack(spacing: 8) {
                                CachedImage(
                                    data: wing.photoData,
                                    key: wing.id.uuidString,
                                    size: CGSize(width: 80, height: 80)
                                ) {
                                    Circle()
                                        .fill(.blue.opacity(0.2))
                                        .overlay {
                                            Image(systemName: "wind")
                                                .font(.largeTitle)
                                                .foregroundStyle(.blue)
                                        }
                                }
                                .clipShape(Circle())

                                Text(wing.name)
                                    .font(.title2)
                                    .fontWeight(.bold)

                                if let size = wing.size {
                                    Text("\(size) m²")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Spot actuel
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "location.fill")
                                .foregroundStyle(manualSpotOverride != nil ? .blue : .green)
                            Text(manualSpotOverride ?? currentSpot)
                                .font(.headline)
                        }

                        Button {
                            showingManualSpot = true
                        } label: {
                            Text(manualSpotOverride != nil ? "Changer le spot" : "Définir le spot manuellement")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding(.horizontal)

                    Spacer()

                    // Chrono
                    VStack(spacing: 8) {
                        Text("TEMPS DE VOL")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .tracking(2)

                        Text(formatElapsedTime(elapsedSeconds))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isFlying ? .green : .primary)
                    }

                    Spacer()

                    // Bouton Start/Stop (redesigné)
                    Button {
                        if isFlying {
                            stopFlight()
                        } else {
                            startFlight()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isFlying ? "stop.fill" : "play.fill")
                                .font(.title2)
                            Text(isFlying ? "ARRÊTER LE VOL" : "DÉMARRER LE VOL")
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(isFlying ? Color.red : Color.green)
                        .foregroundStyle(.white)
                        .cornerRadius(16)
                        .shadow(color: (isFlying ? Color.red : Color.green).opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    .disabled(!isFlying && selectedWing == nil)
                    .opacity((!isFlying && selectedWing == nil) ? 0.5 : 1.0)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Chrono")
            .sheet(isPresented: $showingManualSpot) {
                ManualSpotEditView(manualSpot: $manualSpotOverride)
            }
            .sheet(isPresented: $showingWingPicker) {
                WingPickerSheet(wings: wings, selectedWing: $selectedWing)
            }
            .sheet(isPresented: $showingFlightSummary) {
                if let flight = completedFlight {
                    FlightSummaryView(flight: flight)
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Gérer le timer en arrière-plan
            if isFlying {
                if newPhase == .background || newPhase == .inactive {
                    // Continuer le timer en background
                } else if newPhase == .active, let start = startDate {
                    // Recalculer le temps écoulé quand on revient au premier plan
                    elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        }
        .onAppear {
            if !isFlying && manualSpotOverride == nil {
                updateCurrentSpot()
            }
            // Démarrer le timer de mise à jour si un vol est en cours
            if isFlying, let start = startDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
                startBackgroundTimer()
            }
        }
    }

    private func startBackgroundTimer() {
        backgroundTask?.invalidate()
        backgroundTask = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = startDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func startFlight() {
        guard selectedWing != nil else { return }

        // Démarrer le timer IMMÉDIATEMENT pour une réponse instantanée
        startDate = Date()
        elapsedSeconds = 0
        isFlying = true
        startBackgroundTimer()

        // Démarrer la localisation en arrière-plan pour ne pas bloquer l'UI
        Task {
            locationService.startUpdatingLocation()

            // Ne mettre à jour le spot que si aucun spot manuel n'est défini
            if manualSpotOverride == nil {
                updateCurrentSpot()
            }
        }
    }

    private func stopFlight() {
        guard let wing = selectedWing, let start = startDate else { return }

        let end = Date()
        let duration = Int(end.timeIntervalSince(start))

        backgroundTask?.invalidate()
        backgroundTask = nil

        locationService.stopUpdatingLocation()

        // Utiliser le spot manuel en priorité, sinon le spot automatique
        let finalSpot: String?
        if let manual = manualSpotOverride {
            finalSpot = manual
        } else if currentSpot != "Recherche..." && currentSpot != "Position indisponible" {
            finalSpot = currentSpot
        } else {
            finalSpot = nil
        }

        locationService.requestLocation { [self] location in
            DispatchQueue.main.async {
                let flight = Flight(
                    wing: wing,
                    startDate: start,
                    endDate: end,
                    durationSeconds: duration,
                    spotName: finalSpot,
                    latitude: location?.coordinate.latitude,
                    longitude: location?.coordinate.longitude
                )

                dataController.modelContext.insert(flight)
                try? dataController.modelContext.save()

                // Afficher le récapitulatif
                completedFlight = flight
                showingFlightSummary = true
            }
        }

        isFlying = false
        elapsedSeconds = 0
        startDate = nil
        selectedWing = nil
        currentSpot = "Recherche..."
        manualSpotOverride = nil
    }

    private func updateCurrentSpot() {
        locationService.requestLocation { location in
            guard let location = location else {
                DispatchQueue.main.async {
                    currentSpot = "Position indisponible"
                }
                return
            }

            locationService.reverseGeocode(location: location) { spot in
                DispatchQueue.main.async {
                    currentSpot = spot ?? "Spot inconnu"
                }
            }
        }
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge": return .red
        case "bleu": return .blue
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        default: return .gray
        }
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

// MARK: - WingPickerSheet (Sélection de voile en sheet)

struct WingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let wings: [Wing]
    @Binding var selectedWing: Wing?

    var body: some View {
        NavigationStack {
            List {
                ForEach(wings) { wing in
                    Button {
                        selectedWing = wing
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            // Photo de la voile avec cache
                            CachedImage(
                                data: wing.photoData,
                                key: wing.id.uuidString,
                                size: CGSize(width: 50, height: 50)
                            ) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                                    .overlay {
                                        Image(systemName: "wind")
                                            .foregroundStyle(colorFromString(wing.color ?? "Gris"))
                                    }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(wing.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 8) {
                                    if let size = wing.size {
                                        Text("\(size) m²")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let type = wing.type {
                                        Text(type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            if selectedWing?.id == wing.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Choisir une voile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge": return .red
        case "bleu": return .blue
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        default: return .gray
        }
    }
}

// MARK: - ManualSpotEditView (Saisie manuelle du spot)

struct ManualSpotEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var manualSpot: String?
    @State private var tempSpot: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du spot", text: $tempSpot)
                } header: {
                    Text("Définir le spot manuellement")
                } footer: {
                    Text("Ce spot sera utilisé en priorité sur la détection GPS automatique")
                }

                if manualSpot != nil {
                    Section {
                        Button(role: .destructive) {
                            manualSpot = nil
                            dismiss()
                        } label: {
                            Label("Supprimer et utiliser le GPS", systemImage: "location.fill")
                        }
                    }
                }
            }
            .navigationTitle("Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        if !tempSpot.isEmpty {
                            manualSpot = tempSpot
                        }
                        dismiss()
                    }
                    .disabled(tempSpot.isEmpty)
                }
            }
            .onAppear {
                tempSpot = manualSpot ?? ""
            }
        }
    }
}

// MARK: - FlightSummaryView (Récapitulatif de vol)

struct FlightSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let flight: Flight

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Icône de succès
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)
                    .padding(.top, 40)

                Text("Vol terminé !")
                    .font(.title)
                    .fontWeight(.bold)

                // Résumé du vol
                VStack(spacing: 16) {
                    // Durée
                    HStack {
                        Image(systemName: "timer")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 30)

                        Text("Durée")
                            .font(.headline)

                        Spacer()

                        Text(flight.durationFormatted)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Voile
                    if let wingName = flight.wing?.name {
                        HStack {
                            Image(systemName: "wind")
                                .font(.title3)
                                .foregroundStyle(.purple)
                                .frame(width: 30)

                            Text("Voile")
                                .font(.headline)

                            Spacer()

                            Text(wingName)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Spot
                    if let spot = flight.spotName {
                        HStack {
                            Image(systemName: "location.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                                .frame(width: 30)

                            Text("Spot")
                                .font(.headline)

                            Spacer()

                            Text(spot)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Statistiques de vol
                    if flight.maxAltitude != nil || flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
                        VStack(spacing: 12) {
                            if let maxAlt = flight.maxAltitude {
                                HStack {
                                    Image(systemName: "arrow.up")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                        .frame(width: 30)

                                    Text("Altitude max")
                                        .font(.headline)

                                    Spacer()

                                    Text("\(Int(maxAlt)) m")
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                }
                            }

                            if let distance = flight.totalDistance {
                                HStack {
                                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                        .font(.title3)
                                        .foregroundStyle(.cyan)
                                        .frame(width: 30)

                                    Text("Distance")
                                        .font(.headline)

                                    Spacer()

                                    Text(formatDistance(distance))
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.cyan)
                                }
                            }

                            if let speed = flight.maxSpeed {
                                HStack {
                                    Image(systemName: "speedometer")
                                        .font(.title3)
                                        .foregroundStyle(.purple)
                                        .frame(width: 30)

                                    Text("Vitesse max")
                                        .font(.headline)

                                    Spacer()

                                    Text("\(Int(speed * 3.6)) km/h")
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.purple)
                                }
                            }

                            if let gForce = flight.maxGForce {
                                HStack {
                                    Image(systemName: "waveform.path.ecg")
                                        .font(.title3)
                                        .foregroundStyle(.green)
                                        .frame(width: 30)

                                    Text("G-Force max")
                                        .font(.headline)

                                    Spacer()

                                    Text(String(format: "%.1f G", gForce))
                                        .font(.body)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Date et heure
                    HStack {
                        Image(systemName: "calendar")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 30)

                        Text("Date")
                            .font(.headline)

                        Spacer()

                        Text(flight.dateFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Terminer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .navigationTitle("Récapitulatif")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func formatDistance(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1f km", distance / 1000)
        } else {
            return "\(Int(distance)) m"
        }
    }
}
