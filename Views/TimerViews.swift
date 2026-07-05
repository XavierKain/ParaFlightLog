//
//  TimerViews.swift
//  ParaFlightLog
//
//  Timer-related views: full-screen chrono, wing picker, flight summary.
//  Used both as a pushed screen from Settings and as a Timer tab when
//  phone-only mode is enabled. Supports a developer simulation mode that
//  drives the whole flow from FlightSimulator.
//  Target: iOS only
//

import SwiftUI
import SwiftData
import CoreLocation

// MARK: - SpotDetectionState

/// State of the automatic takeoff spot detection.
/// Replaces the old magic-string sentinels ("Recherche...", etc.).
enum SpotDetectionState: Equatable {
    case searching
    case unavailable
    case found(String)

    var displayText: String {
        switch self {
        case .searching: return "Locating…"
        case .unavailable: return "Location unavailable"
        case .found(let name): return name
        }
    }

    /// Spot name usable for saving, nil while searching/unavailable
    var resolvedName: String? {
        if case .found(let name) = self { return name }
        return nil
    }
}

// MARK: - TimerView (full-screen chrono)

struct TimerView: View {
    @Environment(DataController.self) private var dataController
    @Environment(LocationService.self) private var locationService
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    @AppStorage(UserDefaultsKeys.varioEnabled) private var varioEnabled = false
    @AppStorage(UserDefaultsKeys.lastFlightType) private var lastFlightTypeRaw = FlightType.soaring.rawValue

    /// True when this instance is driven by the flight simulator (developer mode)
    private let isSimulation: Bool
    @State private var simulator: FlightSimulator?
    @State private var vario = PhoneVarioService()

    @State private var selectedWing: Wing?
    @State private var isFlying = false
    @State private var startDate: Date?
    @State private var elapsedSeconds: Int = 0
    @State private var backgroundTask: Timer?
    @State private var spotState: SpotDetectionState = .searching
    @State private var manualSpotOverride: String? = nil
    @State private var trackPoints: [GPSTrackPoint] = []
    @State private var showingManualSpot = false
    @State private var showingWingPicker = false
    @State private var showingFlightSummary = false
    @State private var completedFlight: Flight?
    @State private var showSaveError = false

    init(simulated: Bool = false) {
        self.isSimulation = simulated
        _simulator = State(initialValue: simulated ? FlightSimulator() : nil)
    }

    /// Flight type selection, backed by the persisted last choice
    private var selectedFlightType: Binding<FlightType> {
        Binding(
            get: { FlightType(rawValue: lastFlightTypeRaw) ?? .soaring },
            set: { lastFlightTypeRaw = $0.rawValue }
        )
    }

    /// Vertical speed currently shown in the running UI
    private var currentVerticalSpeed: Double {
        if isSimulation {
            return simulator?.verticalSpeed ?? 0.0
        }
        return vario.verticalSpeed
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Gradient background
                LinearGradient(
                    colors: isFlying ? [.green.opacity(0.2), .blue.opacity(0.2)] : [.gray.opacity(0.1), .gray.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    if isSimulation {
                        simulationBadge
                    }

                    // Wing selection (compact design)
                    if !isFlying {
                        wingSelectionSection
                    } else {
                        flyingWingHeader
                    }

                    // Flight type chips
                    FlightTypeChipRow(selection: selectedFlightType)

                    // Current spot
                    spotSection

                    Spacer()

                    // Chrono
                    VStack(spacing: 8) {
                        Text("FLIGHT TIME")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .tracking(2)

                        Text(formatElapsedTime(elapsedSeconds))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isFlying ? .green : .primary)

                        if isFlying && (isSimulation || (varioEnabled && vario.isRunning)) {
                            varioReadout
                        }
                    }

                    Spacer()

                    // Start/Stop button
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
                            Text(isFlying ? "STOP FLIGHT" : "START FLIGHT")
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
                    .disabled(!isFlying && !canStartFlight)
                    .opacity((!isFlying && !canStartFlight) ? 0.5 : 1.0)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle(isSimulation ? "Timer (Simulation)" : "Timer")
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
        .onChange(of: scenePhase) { _, newPhase in
            guard isFlying else { return }
            if newPhase == .background || newPhase == .inactive {
                // Timer keeps running conceptually (recomputed from startDate);
                // the vario audio cannot run in background, stop it cleanly.
                vario.stop()
            } else if newPhase == .active {
                if let start = startDate {
                    elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
                if varioEnabled {
                    vario.start(mode: isSimulation ? .manual : .altimeter)
                }
            }
        }
        .onAppear {
            if !isFlying && !isSimulation && manualSpotOverride == nil {
                updateCurrentSpot()
            }
            // Pre-select the wing used for the most recent flight
            if selectedWing == nil,
               let idString = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastUsedWingId),
               let id = UUID(uuidString: idString) {
                selectedWing = wings.first { $0.id == id }
            }
            // Resume the update timer (and vario) if a flight is running
            if isFlying, let start = startDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
                startBackgroundTimer()
                if varioEnabled && !vario.isRunning {
                    vario.start(mode: isSimulation ? .manual : .altimeter)
                }
            }
        }
        .onDisappear {
            // Invalidate timers to avoid leaks; the flight itself keeps
            // running (elapsed time is recomputed from startDate on return)
            backgroundTask?.invalidate()
            backgroundTask = nil
            vario.stop()
        }
        .alert("Save Error", isPresented: $showSaveError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The flight could not be saved. Please try again.")
        }
    }

    /// In simulation mode a wing is optional (there may be none in a fresh simulator)
    private var canStartFlight: Bool {
        isSimulation || selectedWing != nil
    }

    // MARK: - Subviews

    private var simulationBadge: some View {
        Label("SIMULATION", systemImage: "wand.and.stars")
            .font(.caption)
            .fontWeight(.bold)
            .tracking(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.orange)
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .padding(.top, 4)
    }

    private var wingSelectionSection: some View {
        VStack(spacing: 12) {
            Text("Wing")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1)

            if wings.isEmpty {
                Text(isSimulation
                     ? "No wing available — the simulated flight will be saved without a wing"
                     : "Add a wing in the Wings tab first")
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
                            // Cached thumbnail
                            CachedImage(
                                data: wing.photoData,
                                key: wing.id.uuidString,
                                size: CGSize(width: 50, height: 50)
                            ) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill((wing.color ?? "Gris").toColor().opacity(0.3))
                                    .overlay {
                                        Image(systemName: "wind")
                                            .foregroundStyle((wing.color ?? "Gris").toColor())
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

                            // White title (matches the Wings page style);
                            // blue is reserved for icons/secondary accents
                            Text("Select a wing")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundStyle(Color.primary)

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
                // .plain: inside a default Button, hierarchical styles (.primary/
                // .secondary) resolve AGAINST THE TINT — everything looked blue.
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var flyingWingHeader: some View {
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

    private var spotSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "location.fill")
                    .foregroundStyle(manualSpotOverride != nil ? .blue : .green)
                Text(displayedSpotName)
                    .font(.headline)
            }

            if !isSimulation {
                Button {
                    showingManualSpot = true
                } label: {
                    Text(manualSpotOverride != nil ? "Change spot" : "Set spot manually")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        .padding(.horizontal)
    }

    private var displayedSpotName: String {
        if isSimulation { return "Simulated Flight" }
        return manualSpotOverride ?? spotState.displayText
    }

    private var varioReadout: some View {
        let speed = currentVerticalSpeed
        let color: Color = speed >= 0.1 ? .green : (speed <= -0.1 ? .red : .secondary)

        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: speed >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                Text(String(format: "%+.1f m/s", speed))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            .font(.title3)
            .foregroundStyle(color)

            if isSimulation, let sim = simulator {
                Text("\(Int(sim.altitude)) m • \(String(format: "%.0f", sim.groundSpeed * 3.6)) km/h")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Timer

    private func startBackgroundTimer() {
        backgroundTask?.invalidate()
        backgroundTask = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = startDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
            timerTick()
        }
    }

    /// Called every second while the timer is displayed and a flight runs
    private func timerTick() {
        guard isFlying else { return }

        if isSimulation {
            // Feed the simulated vertical speed into the vario for beeps
            if let sim = simulator, vario.isRunning {
                vario.ingest(verticalSpeed: sim.verticalSpeed)
            }
        } else {
            // Capture a GPS track point every 5 s (mirrors the Watch cadence)
            if elapsedSeconds > 0 && elapsedSeconds % Int(GPSConstants.trackPointInterval) == 0 {
                captureTrackPoint()
            }
        }
    }

    /// Appends the last known GPS fix to the track (real flights only).
    /// Skips stale fixes so pauses in GPS coverage don't duplicate points.
    private func captureTrackPoint() {
        guard let location = locationService.lastKnownLocation else { return }
        if let lastTimestamp = trackPoints.last?.timestamp,
           location.timestamp <= lastTimestamp {
            return
        }

        trackPoints.append(GPSTrackPoint(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            speed: location.speed >= 0 ? location.speed : nil
        ))
    }

    // MARK: - Flight lifecycle

    private func startFlight() {
        guard canStartFlight else { return }

        // Start the chrono IMMEDIATELY for instant feedback
        startDate = Date()
        elapsedSeconds = 0
        trackPoints = []
        isFlying = true
        startBackgroundTimer()

        if isSimulation {
            simulator?.start()
        } else {
            // Start location updates in the background to keep the UI snappy
            Task {
                locationService.startUpdatingLocation()

                // Only refresh the spot when no manual spot is set
                if manualSpotOverride == nil {
                    updateCurrentSpot()
                }
            }
        }

        if varioEnabled {
            vario.start(mode: isSimulation ? .manual : .altimeter)
        }
    }

    private func stopFlight() {
        guard let start = startDate else { return }

        let end = Date()
        let duration = Int(end.timeIntervalSince(start))
        let wing = selectedWing
        let flightType = selectedFlightType.wrappedValue.rawValue

        backgroundTask?.invalidate()
        backgroundTask = nil
        vario.stop()

        if isSimulation {
            simulator?.stop()
            let points = simulator?.trackPoints ?? []
            let firstPoint = points.first
            saveFlight(
                wing: wing,
                start: start,
                end: end,
                duration: duration,
                spotName: "Simulated Flight",
                latitude: firstPoint?.latitude ?? simulator?.baseCoordinate.latitude,
                longitude: firstPoint?.longitude ?? simulator?.baseCoordinate.longitude,
                flightType: flightType,
                points: points
            )
        } else {
            locationService.stopUpdatingLocation()

            // Manual spot takes priority over the detected one
            let finalSpot = manualSpotOverride ?? spotState.resolvedName
            let points = trackPoints

            // Save IMMEDIATELY with the best location we already have (the
            // track's first point, or the last known GPS fix). The previous
            // code awaited a fresh fix (10s timeout) before saving, leaving
            // the pilot staring at a reset timer screen until the summary
            // finally appeared.
            let knownLocation = points.first.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            } ?? locationService.lastKnownLocation?.coordinate

            saveFlight(
                wing: wing,
                start: start,
                end: end,
                duration: duration,
                spotName: finalSpot,
                latitude: knownLocation?.latitude,
                longitude: knownLocation?.longitude,
                flightType: flightType,
                points: points
            )
        }

        isFlying = false
        elapsedSeconds = 0
        startDate = nil
        // Keep selectedWing: it's the wing just flown — ready for the next flight
        spotState = .searching
        manualSpotOverride = nil
        trackPoints = []
    }

    private func saveFlight(wing: Wing?, start: Date, end: Date, duration: Int,
                            spotName: String?, latitude: Double?, longitude: Double?,
                            flightType: String?, points: [GPSTrackPoint]) {
        let flight = Flight(
            wing: wing,
            startDate: start,
            endDate: end,
            durationSeconds: duration,
            spotName: spotName,
            latitude: latitude,
            longitude: longitude,
            flightType: flightType
        )
        applyTrackData(to: flight, points: points)

        dataController.modelContext.insert(flight)
        dataController.assignSpot(to: flight)
        do {
            try dataController.modelContext.save()
            if let wingId = wing?.id {
                UserDefaults.standard.set(wingId.uuidString, forKey: UserDefaultsKeys.lastUsedWingId)
            }
            completedFlight = flight
            showingFlightSummary = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            logInfo("Timer flight saved: \(flight.durationFormatted), \(points.count) track points", category: .flight)
        } catch {
            logError("Failed to save flight from timer: \(error.localizedDescription)", category: .dataController)
            showSaveError = true
        }
    }

    /// Stores the GPS track and derives basic flight statistics from it.
    private func applyTrackData(to flight: Flight, points: [GPSTrackPoint]) {
        guard !points.isEmpty else { return }

        flight.setGPSTrack(points)
        flight.startAltitude = points.first?.altitude
        flight.endAltitude = points.last?.altitude
        flight.maxAltitude = points.compactMap(\.altitude).max()
        flight.maxSpeed = points.compactMap(\.speed).max()

        var distance: Double = 0
        for (previous, current) in zip(points, points.dropFirst()) {
            let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let to = CLLocation(latitude: current.latitude, longitude: current.longitude)
            distance += to.distance(from: from)
        }
        flight.totalDistance = distance > 0 ? distance : nil
    }

    // MARK: - Spot detection

    private func updateCurrentSpot() {
        spotState = .searching
        locationService.requestLocation { location in
            guard let location = location else {
                DispatchQueue.main.async {
                    spotState = .unavailable
                }
                return
            }

            locationService.reverseGeocode(location: location) { spot in
                DispatchQueue.main.async {
                    if let spot = spot {
                        spotState = .found(spot)
                    } else {
                        spotState = .unavailable
                    }
                }
            }
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

// MARK: - FlightTypeChipRow (compact flight type selection)

struct FlightTypeChipRow: View {
    @Binding var selection: FlightType

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FlightType.allCases) { type in
                    Button {
                        selection = type
                    } label: {
                        Label(type.rawValue, systemImage: type.symbolName)
                            .font(.caption)
                            .fontWeight(selection == type ? .semibold : .regular)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selection == type ? Color.blue : Color(.systemBackground))
                            .foregroundStyle(selection == type ? .white : .primary)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - WingPickerSheet (wing selection sheet)

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
                            // Cached wing photo
                            CachedImage(
                                data: wing.photoData,
                                key: wing.id.uuidString,
                                size: CGSize(width: 50, height: 50)
                            ) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill((wing.color ?? "Gris").toColor().opacity(0.3))
                                    .overlay {
                                        Image(systemName: "wind")
                                            .foregroundStyle((wing.color ?? "Gris").toColor())
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
                    // .plain keeps titles white (hierarchical styles resolve
                    // against the tint inside default buttons → blue titles)
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Choose a Wing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - ManualSpotEditView (manual spot entry)

struct ManualSpotEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var manualSpot: String?
    @State private var tempSpot: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Spot name", text: $tempSpot)
                } header: {
                    Text("Set the spot manually")
                } footer: {
                    Text("This spot takes priority over automatic GPS detection")
                }

                if manualSpot != nil {
                    Section {
                        Button(role: .destructive) {
                            manualSpot = nil
                            dismiss()
                        } label: {
                            Label("Remove and use GPS", systemImage: "location.fill")
                        }
                    }
                }
            }
            .navigationTitle("Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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

// MARK: - FlightSummaryView (post-flight recap)

struct FlightSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let flight: Flight

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Success icon
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)
                    .padding(.top, 40)

                Text("Flight Complete!")
                    .font(.title)
                    .fontWeight(.bold)

                // Flight summary
                VStack(spacing: 16) {
                    // Duration
                    HStack {
                        Image(systemName: "timer")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 30)

                        Text("Duration")
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

                    // Wing
                    if let wingName = flight.wing?.name {
                        HStack {
                            Image(systemName: "wind")
                                .font(.title3)
                                .foregroundStyle(.purple)
                                .frame(width: 30)

                            Text("Wing")
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

                    // Flight statistics
                    if flight.maxAltitude != nil || flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
                        VStack(spacing: 12) {
                            if let maxAlt = flight.maxAltitude {
                                HStack {
                                    Image(systemName: "arrow.up")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                        .frame(width: 30)

                                    Text("Max altitude")
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

                                    Text("Max speed")
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

                                    Text("Max G-force")
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

                    // Date and time
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
                    Text("Done")
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
            .navigationTitle("Summary")
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
