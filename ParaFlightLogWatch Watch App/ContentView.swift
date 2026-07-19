//
//  ContentView.swift
//  ParaFlightLogWatch Watch App
//
//  Main Apple Watch view: multi-screen navigation
//  Flow: wing selection -> start page -> active flight -> stop options -> summary
//  Target: Watch only
//

import SwiftUI

struct ContentView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService
    @State private var selectedWing: WingDTO?
    @State private var activeFlightWing: WingDTO? // Wing captured at start - also triggers the fullScreenCover
    @State private var selectedTab: Int = 1  // open on the middle (wing selection)
    @State private var isFlying: Bool = false
    // Timer data stored at ContentView level
    @State private var flightStartDate: Date?

    // Session recovery alert
    @State private var showingRecoveryAlert: Bool = false
    @State private var recoveredDuration: Int = 0

    // WorkoutManager reference for Water Lock
    private let workoutManager = WorkoutManager.shared
    // FlightSessionManager reference for persistence
    private let sessionManager = FlightSessionManager.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            // Screen 0 (far left): on-watch settings
            // Water Lock, vario, and (developer) cancel-flight + flight simulator.
            WatchSettingsView()
                .tag(0)

            // Screen 1 (middle, opens here): wing selection
            WingSelectionView(selectedWing: $selectedWing, selectedTab: $selectedTab)
                .environment(watchManager)
                .tag(1)

            // Screen 2 (right): wing recap + Start button (the flight)
            FlightStartView(
                selectedWing: $selectedWing,
                onStartFlight: {
                    startFlight()
                }
            )
            .environment(watchManager)
            .tag(2)
        }
        .tabViewStyle(.page)
        // fullScreenCover(item:) so SwiftUI captures the value at presentation time
        .fullScreenCover(item: $activeFlightWing) { wing in
            // Screen 3: active timer (fullscreen, cannot leave)
            ActiveFlightView(
                wing: wing,
                flightStartDate: $flightStartDate,
                onStopFlight: { duration, flightType in
                    stopFlight(duration: duration, flightType: flightType)
                },
                onDiscardFlight: {
                    discardFlight()
                }
            )
            .environment(watchManager)
            .environment(locationService)
            .interactiveDismissDisabled(true) // Prevent swipe-down dismissal
        }
        .onAppear {
            // Check whether there is a session to recover after a crash
            checkForRecoverableSession()
        }
        .alert("Flight recovered", isPresented: $showingRecoveryAlert) {
            Button("Continue flight") {
                continueRecoveredFlight()
            }
            Button("Save & stop") {
                saveRecoveredFlight()
            }
            Button("Discard", role: .destructive) {
                sessionManager.discardSession()
            }
        } message: {
            Text("A flight of \(WatchFormatters.duration(recoveredDuration)) was interrupted. Continue it (keeps ONE session) or save it as it was?")
        }
    }

    /// Continues a crash-recovered flight as the SAME session: re-seeds the
    /// tracking state from the persisted session, restarts sensors/workout and
    /// re-opens the live flight screen. One physical flight = one saved flight.
    private func continueRecoveredFlight() {
        guard let session = sessionManager.activeSession else { return }

        // Rebuild the wing from the persisted session (the wings list may not
        // be synced yet right after a relaunch).
        let wing = WingDTO(id: session.wingId, name: session.wingName, size: session.wingSize)
        WatchImageCache.shared.preloadImageSync(for: wing)

        flightStartDate = session.startDate
        isFlying = true

        sessionManager.resumeSession()

        Task.detached(priority: .high) { [workoutManager] in
            await workoutManager.startWorkoutSession()
        }

        activeFlightWing = wing

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            locationService.startUpdatingLocation()
            locationService.resumeFlightTracking(from: session)
        }

        watchLogInfo("Recovered flight continued as the same session", category: .flight)
    }

    /// Checks whether there is a flight session to recover after a crash
    private func checkForRecoverableSession() {
        guard sessionManager.hasRecoverableSession,
              let duration = sessionManager.recoveredFlightDuration else {
            return
        }

        // Don't show the alert if the user is already flying
        guard !isFlying else { return }

        recoveredDuration = duration
        showingRecoveryAlert = true
    }

    /// Saves the recovered flight through the persistent outbox
    private func saveRecoveredFlight() {
        guard let data = sessionManager.getRecoveredFlightData() else {
            sessionManager.discardSession()
            return
        }

        // endDate/duration are bounded by the last persisted update so the
        // dead time between the crash and the recovery is not counted
        let flight = FlightDTO(
            wingId: data.wingId,
            startDate: data.startDate,
            endDate: data.endDate,
            durationSeconds: recoveredDuration,
            flightType: WatchSettings.shared.lastFlightType.rawValue,
            startAltitude: data.startAltitude,
            maxAltitude: data.maxAltitude,
            endAltitude: data.endAltitude,
            totalDistance: data.totalDistance,
            maxSpeed: data.maxSpeed,
            maxGForce: data.maxGForce > 1.0 ? data.maxGForce : nil,
            gpsTrack: data.gpsTrack.isEmpty ? nil : data.gpsTrack
        )

        // Persist to the outbox FIRST (synchronous), then attempt delivery.
        // Clean up the recovered session ONLY if the outbox write succeeded —
        // otherwise the session stays recoverable and nothing is lost.
        if watchManager.sendFlightToPhone(flight) {
            sessionManager.endSession()
            watchLogInfo("Recovered flight saved: \(recoveredDuration) seconds", category: .flight)
        } else {
            watchLogError("Outbox write failed - keeping recovered session for another attempt", category: .flight)
        }
    }

    private func startFlight() {
        guard let wing = selectedWing else { return }

        // PRELOAD THE IMAGE SYNCHRONOUSLY before showing the flight
        WatchImageCache.shared.preloadImageSync(for: wing)

        // Set the date BEFORE presenting the fullScreenCover
        flightStartDate = Date()
        isFlying = true

        // Start the persistence session for automatic saving
        sessionManager.startSession(wing: wing, spotName: locationService.currentSpotName)

        // Start the workout session IN THE BACKGROUND IMMEDIATELY.
        // A running HKWorkoutSession keeps the app frontmost and the screen
        // ALWAYS ACTIVE for the whole flight (never returns to the watch face),
        // so this runs for every flight — Water Lock is a separate, optional
        // behaviour handled inside the workout session.
        Task.detached(priority: .high) { [workoutManager] in
            await workoutManager.startWorkoutSession()
        }

        // Assigning activeFlightWing automatically triggers fullScreenCover(item:)
        // SwiftUI passes the value straight to the closure, so no timing issue
        activeFlightWing = wing

        // Start the location services after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            locationService.startUpdatingLocation()
            locationService.startFlightTracking()

            // Best-effort live presence signal to the iPhone (Step C2).
            // Simulated flights use a fake feed with fake coordinates and
            // must never post presence.
            if !WatchSettings.shared.simulateFlightEnabled {
                sendFlightStartedSignal()
            }
        }
    }

    /// Sends the ephemeral "flight started" presence signal to the iPhone
    /// with the takeoff coordinates. Uses the same GPS fix the tracking flow
    /// reads (lastKnownLocation); when no fix exists yet, retries ONCE after
    /// ~10 s and then gives up silently — presence is best-effort and must
    /// never interfere with the flight itself.
    private func sendFlightStartedSignal() {
        if let location = locationService.lastKnownLocation {
            watchManager.notifyFlightStarted(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            return
        }

        // Capture the identity of THIS flight before scheduling the retry:
        // if it ended — or a new one started — during the 10 s wait, the
        // signal would post presence for a different flight.
        let scheduledFlightStart = flightStartDate
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard isFlying,
                  flightStartDate == scheduledFlightStart,
                  let location = locationService.lastKnownLocation else { return }
            watchManager.notifyFlightStarted(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        }
    }

    private func stopFlight(duration: Int, flightType: FlightType) {
        // Use activeFlightWing captured at start
        guard let wing = activeFlightWing, let start = flightStartDate else { return }

        let end = Date()

        // Remember the chosen type as the default for the next flight
        WatchSettings.shared.lastFlightType = flightType

        // Grab tracking data and the GPS track BEFORE stopping the tracking
        let gpsTrack = locationService.getGPSTrack()
        let endAltitude = locationService.stopFlightTracking()
        let flightData = locationService.getFlightData()

        // Build the FlightDTO with all data including the GPS track
        let flight = FlightDTO(
            wingId: wing.id,
            startDate: start,
            endDate: end,
            durationSeconds: duration,
            flightType: flightType.rawValue,
            startAltitude: flightData.startAlt,
            maxAltitude: flightData.maxAlt,
            endAltitude: endAltitude,
            totalDistance: flightData.distance,
            maxSpeed: flightData.speed,
            maxGForce: flightData.maxGForce > 1.0 ? flightData.maxGForce : nil,
            gpsTrack: gpsTrack.isEmpty ? nil : gpsTrack
        )

        // Persist to the outbox FIRST (synchronous - the flight can no longer
        // be lost), then attempt delivery to the iPhone.
        // The live tracking session is cleared ONLY when the outbox write
        // succeeded; otherwise it stays recoverable (belt and braces).
        if watchManager.sendFlightToPhone(flight) {
            sessionManager.endSession()
        } else {
            watchLogError("Outbox write failed - keeping session recoverable", category: .flight)
        }

        // Stop the workout session if active
        Task {
            await workoutManager.stopWorkoutSession()
        }

        // Reset - setting activeFlightWing to nil closes the fullScreenCover
        isFlying = false
        flightStartDate = nil
        activeFlightWing = nil
        selectedWing = nil
        selectedTab = 1 // Back to wing selection (middle)
    }

    private func discardFlight() {
        // Cancel the flight without saving (result intentionally ignored)
        _ = locationService.stopFlightTracking()

        // Discard the persistence session
        sessionManager.discardSession()

        // Stop the workout session if active
        Task {
            await workoutManager.stopWorkoutSession()
        }

        // Reset - setting activeFlightWing to nil closes the fullScreenCover
        isFlying = false
        flightStartDate = nil
        activeFlightWing = nil
        selectedWing = nil
        selectedTab = 1 // Back to wing selection (middle)
    }
}

// MARK: - WingSelectionView (Screen 1)

struct WingSelectionView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Binding var selectedWing: WingDTO?
    @Binding var selectedTab: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Selection")
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

                    Text("No wings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Add one from the iPhone")
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
                                    // Select immediately to show the highlight
                                    selectedWing = wing
                                    // Short delay so the selection effect is visible before the scroll
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        withAnimation {
                                            selectedTab = 2  // go to the flight/start screen
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

/// Optimized, modern wing selection button
struct WingButton: View {
    let wing: WingDTO
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Visual selection indicator (side bar)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Color.green : Color.clear)
                    .frame(width: 3)

                // Wing thumbnail (40x40) with matching background
                CachedWingImage(wing: wing, size: 40, isSelected: isSelected)

                // Main content - name and size stacked
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

                // Selection icon
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

// MARK: - FlightStartView (Screen 2 - Recap + Start)

struct FlightStartView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService
    @Binding var selectedWing: WingDTO?
    let onStartFlight: () -> Void

    // Flight type is chosen here, before launch. Written to lastFlightType so the
    // whole active-flight / stop flow is pre-filled with it (still editable on stop).
    @Bindable private var settings = WatchSettings.shared
    @State private var showingTypePicker = false

    var body: some View {
        VStack(spacing: 8) {
            if let wing = selectedWing {
                // Wing: image, then name + size on ONE line
                CachedWingImage(wing: wing, size: 30, showBackground: false)

                HStack(spacing: 6) {
                    Text(wing.shortName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let size = wing.size {
                        Text("\(size) m²")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }

                // Current location
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(locationService.currentSpotName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                // Flight type — roomier card that opens the full picker screen
                Button {
                    showingTypePicker = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: settings.lastFlightType.symbolName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        Text(settings.lastFlightType.rawValue)
                            .font(.body)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                // Start button — breathing room from the bottom edge
                Button {
                    onStartFlight()
                } label: {
                    Label("Start", systemImage: "play.circle.fill")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.bottom, 6)

            } else {
                // No wing selected
                Spacer()
                Image(systemName: "arrow.left")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Pick a wing first")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 6)
        .sheet(isPresented: $showingTypePicker) {
            FlightTypePickerView(selected: settings.lastFlightType) { type in
                settings.lastFlightType = type
            }
        }
    }
}

// MARK: - FlightTypePickerView (dedicated screen, like wing selection)

/// Full-screen flight-type picker: one labelled row per type (icon + name +
/// short description) so it's obvious what each icon means.
struct FlightTypePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let selected: FlightType
    let onSelect: (FlightType) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Flight Type")
                    .font(.headline)
                    .padding(.top, 4)

                ForEach(FlightType.allCases) { type in
                    Button {
                        onSelect(type)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: type.symbolName)
                                .font(.system(size: 22))
                                .foregroundStyle(type == selected ? Color.green : Color.blue)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(type.rawValue)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(type.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            if type == selected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(type == selected ? Color.green.opacity(0.18) : Color.gray.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - ActiveFlightView (Screen 3 - Fullscreen timer)

struct ActiveFlightView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService

    let wing: WingDTO  // Non-optional: fullScreenCover(item:) guarantees a value
    @Binding var flightStartDate: Date?
    let onStopFlight: (Int, FlightType) -> Void
    let onDiscardFlight: () -> Void

    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var showingStopSheet: Bool = false
    @State private var finalDuration: Int = 0
    @State private var finalFlightType: FlightType = WatchSettings.shared.lastFlightType
    @State private var timerUpdateCounter: Int = 0

    // Observed singletons (Observation tracks accesses made in body)
    private let vario = VarioService.shared
    private let settings = WatchSettings.shared

    var body: some View {
        VStack(spacing: 2) {
            // Flight-in-progress indicator (pinned at the top)
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                // verbatim: bypasses the string catalog (a leftover fr entry
                // translated "Flying" to "En vol" on French devices)
                Text(verbatim: "In flight")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fontWeight(.bold)
            }
            .padding(.top, -4) // Push even higher

            // Wing + size with image
            HStack(spacing: 6) {
                CachedWingImage(wing: wing, size: 22, showBackground: false)
                Text(wing.shortName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let size = wing.size {
                    Text("• \(size)m²")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
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

            // Live flight metrics - three big tiles (altitude / speed / G-force).
            // Units live in the label so the NUMBER itself can be as large as possible.
            HStack(spacing: 4) {
                MetricTile(value: WatchFormatters.altitudeValue(locationService.currentAltitude),
                           label: "Alt m",
                           color: .orange)

                MetricTile(value: WatchFormatters.speedKmh(locationService.maxSpeed),
                           label: "Max km/h",   // it's the MAX speed, not the current one
                           color: .purple)

                MetricTile(value: WatchFormatters.gForce(locationService.currentGForce),
                           label: "G",
                           color: .green)
            }
            .padding(.vertical, 2)

            // Vario readout (only when the feature is on and available)
            if VarioService.isAvailable && settings.varioEnabled {
                HStack(spacing: 3) {
                    Image(systemName: vario.verticalSpeed >= 0 ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                    Text(WatchFormatters.verticalSpeed(vario.verticalSpeed))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .foregroundStyle(varioColor)
            }

            Spacer()
                .frame(maxHeight: 2)

            // Main TIMER
            Text(WatchFormatters.elapsedTime(elapsedSeconds))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.green)

            Spacer()
                .frame(maxHeight: 4)

            // Stop button
            Button {
                showingStopSheet = true
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.body)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color.black) // Opaque black background
        .overlay(alignment: .topTrailing) {
            // Vario toggle (hidden when the device has no barometer)
            if VarioService.isAvailable {
                Button {
                    toggleVario()
                } label: {
                    Image(systemName: settings.varioEnabled ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(settings.varioEnabled ? .green : .gray)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.varioEnabled ? "Turn vario off" : "Turn vario on")
                .padding(.trailing, 2)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingStopSheet) {
            // Container view handling the internal transition without a flash
            StopFlightContainerView(
                duration: elapsedSeconds,
                wing: wing,
                startAltitude: locationService.startAltitude,
                maxAltitude: locationService.maxAltitude,
                endAltitude: locationService.currentAltitude,
                totalDistance: locationService.totalDistance,
                maxSpeed: locationService.maxSpeed,
                maxGForce: locationService.maxGForce,
                onSave: { duration, flightType in
                    finalDuration = duration
                    finalFlightType = flightType
                    stopTimer()
                    VarioService.shared.stop()
                    locationService.stopUpdatingLocation()
                },
                onDiscard: {
                    stopTimer()
                    VarioService.shared.stop()
                    locationService.stopUpdatingLocation()
                    showingStopSheet = false
                    onDiscardFlight()
                },
                onDismiss: {
                    // Close the fullScreenCover first - the sheet goes away with it
                    // Don't set showingStopSheet = false, or the flight screen would flash
                    onStopFlight(finalDuration, finalFlightType)
                }
            )
            .presentationBackground(.black)
        }
        .onAppear {
            // Start the timer immediately, no delay
            startTimerImmediately()
            // Start the vario if enabled
            if settings.varioEnabled {
                VarioService.shared.start()
            }
        }
        .onDisappear {
            stopTimer()
            // Safety net: never leave the altimeter running after a flight
            VarioService.shared.stop()
        }
    }

    private var varioColor: Color {
        if vario.verticalSpeed > 0.1 {
            return .green
        } else if vario.verticalSpeed < -0.1 {
            return .red
        } else {
            return .secondary
        }
    }

    private func toggleVario() {
        settings.varioEnabled.toggle()
        if settings.varioEnabled {
            VarioService.shared.start()
        } else {
            VarioService.shared.stop()
        }
    }

    private func startTimerImmediately() {
        // Compute the elapsed time immediately
        if let start = flightStartDate {
            elapsedSeconds = Int(Date().timeIntervalSince(start))
        } else {
            elapsedSeconds = 0
        }

        // Start the timer on the main RunLoop
        // Note: no weak self needed, SwiftUI Views are structs
        // The timer is stored in @State and invalidated in onDisappear
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] _ in
            if let start = flightStartDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }

            // Update the sessionManager data every 10 seconds
            timerUpdateCounter += 1
            if timerUpdateCounter >= 10 {
                timerUpdateCounter = 0
                updateSessionData()
            }
        }
    }

    /// Updates the flight data in the FlightSessionManager
    private func updateSessionData() {
        FlightSessionManager.shared.updateSession(
            startAltitude: locationService.startAltitude,
            maxAltitude: locationService.maxAltitude,
            currentAltitude: locationService.currentAltitude,
            totalDistance: locationService.totalDistance,
            maxSpeed: locationService.maxSpeed,
            maxGForce: locationService.maxGForce,
            gpsTrackPoints: locationService.getGPSTrack()
        )
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// One metric tile of the active flight screen.
/// Flexible width + scaling so long values fit on 40-45mm watches.
private struct MetricTile: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - WatchSettingsView (on-watch settings, leftmost page)

/// Settings the pilot can change directly on the Watch, without reaching for the
/// iPhone. Public: Water Lock + Vario. Developer: cancel-flight + flight simulator.
/// Big card-style toggles; any change is pushed back to the iPhone (two-way sync).
struct WatchSettingsView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Bindable private var settings = WatchSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.blue)
                    Text("Settings")
                        .font(.headline)
                }
                .padding(.top, 4)

                settingCard(icon: "drop.fill", tint: .cyan,
                            title: "Water Lock",
                            subtitle: "Locks the screen during a flight",
                            isOn: $settings.autoWaterLockEnabled)

                settingCard(icon: "waveform.path.ecg", tint: .green,
                            title: "Vario",
                            subtitle: "Climb/sink haptics during a flight",
                            isOn: $settings.varioEnabled)

                if settings.developerModeEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "hammer.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Developer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 2)

                    settingCard(icon: "xmark.circle", tint: .orange,
                                title: "Allow cancel flight",
                                subtitle: "Lets you discard a flight in progress",
                                isOn: $settings.allowSessionDismiss)

                    settingCard(icon: "play.circle", tint: .blue,
                                title: "Simulate flight",
                                subtitle: "Next flight runs on a fake feed",
                                isOn: $settings.simulateFlightEnabled)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        // Any change made here is pushed back to the iPhone (two-way sync).
        .onChange(of: settings.autoWaterLockEnabled) { _, _ in watchManager.sendSettingsToPhone() }
        .onChange(of: settings.varioEnabled) { _, _ in watchManager.sendSettingsToPhone() }
        .onChange(of: settings.allowSessionDismiss) { _, _ in watchManager.sendSettingsToPhone() }
        .onChange(of: settings.simulateFlightEnabled) { _, _ in watchManager.sendSettingsToPhone() }
    }

    /// Big, readable toggle card (matches the previous on-watch settings style).
    @ViewBuilder
    private func settingCard(icon: String, tint: Color, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.body)
                }
            }
            .tint(tint)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - StopFlightOptionsView (Save/discard choice + flight type)

struct StopFlightOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    let duration: Int
    let onSave: (FlightType) -> Void
    let onDiscard: () -> Void

    // Default to the last used type
    @State private var selectedType: FlightType = WatchSettings.shared.lastFlightType

    // Check whether discarding is allowed
    private var canDismiss: Bool {
        WatchSettings.shared.allowSessionDismiss
    }

    var body: some View {
        // Plain VStack (no ScrollView): everything fits on one screen,
        // including the Discard button.
        VStack(spacing: 4) {
            Text("End flight?")
                .font(.subheadline)
                .fontWeight(.semibold)

            // Duration + flight type recap on one compact block
            Text(WatchFormatters.duration(duration))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.blue)

            HStack(spacing: 5) {
                Image(systemName: selectedType.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(selectedType.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            // Save button (green)
            Button {
                onSave(selectedType)
            } label: {
                Label("Save", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            // Discard button (red) - only if allowed
            if canDismiss {
                Button(role: .destructive) {
                    onDiscard()
                } label: {
                    Text("Discard flight")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .navigationBarHidden(true)
    }
}

// MARK: - StopFlightContainerView (Container for the flash-free transition)

/// Container view handling the options -> summary transition without closing the sheet
struct StopFlightContainerView: View {
    let duration: Int
    let wing: WingDTO
    let startAltitude: Double?
    let maxAltitude: Double?
    let endAltitude: Double?
    let totalDistance: Double
    let maxSpeed: Double
    let maxGForce: Double
    let onSave: (Int, FlightType) -> Void
    let onDiscard: () -> Void
    let onDismiss: () -> Void

    @State private var showingSummary: Bool = false
    @State private var savedDuration: Int = 0
    @State private var savedFlightType: FlightType = WatchSettings.shared.lastFlightType

    var body: some View {
        ZStack {
            if !showingSummary {
                StopFlightOptionsView(
                    duration: duration,
                    onSave: { flightType in
                        savedDuration = duration
                        savedFlightType = flightType
                        onSave(duration, flightType)
                        // Fade + move-from-bottom transition (like a sheet)
                        withAnimation(.easeOut(duration: 0.3)) {
                            showingSummary = true
                        }
                    },
                    onDiscard: onDiscard
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if showingSummary {
                FlightSummaryView(
                    duration: savedDuration,
                    flightType: savedFlightType,
                    wing: wing,
                    startAltitude: startAltitude,
                    maxAltitude: maxAltitude,
                    endAltitude: endAltitude,
                    totalDistance: totalDistance,
                    maxSpeed: maxSpeed,
                    maxGForce: maxGForce,
                    onDismiss: onDismiss
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

// MARK: - FlightSummaryView (Post-flight summary with statistics)

struct FlightSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let duration: Int
    let flightType: FlightType
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
                // Icon + title on one line to save space
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    Text("Flight saved!")
                        .font(.headline)
                }
                .padding(.top, -8) // Push toward the top

                // Duration
                Text(WatchFormatters.duration(duration))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.blue)

                // Wing + size with image
                HStack(spacing: 6) {
                    CachedWingImage(wing: wing, size: 20, showBackground: false)
                    Text(wing.shortName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let size = wing.size {
                        Text("• \(size) m²")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }

                // Flight type
                HStack(spacing: 4) {
                    Image(systemName: flightType.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(flightType.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Flight statistics
                VStack(spacing: 6) {
                    // Altitudes
                    if startAltitude != nil || maxAltitude != nil || endAltitude != nil {
                        HStack(spacing: 8) {
                            StatBox(label: "Takeoff", value: WatchFormatters.altitudeValue(startAltitude), unit: "m", color: .orange)
                            StatBox(label: "Max", value: WatchFormatters.altitudeValue(maxAltitude), unit: "m", color: .red)
                            StatBox(label: "Landing", value: WatchFormatters.altitudeValue(endAltitude), unit: "m", color: .orange)
                        }
                    }

                    // Distance and speed
                    HStack(spacing: 8) {
                        if totalDistance > 0 {
                            StatBox(label: "Distance", value: WatchFormatters.distance(totalDistance), unit: "", color: .cyan)
                        }
                        if maxSpeed > 0 {
                            StatBox(label: "Max speed", value: WatchFormatters.speedKmh(maxSpeed), unit: "km/h", color: .purple)
                        }
                    }

                    // Max G-Force
                    if maxGForce > 1.0 {
                        HStack(spacing: 8) {
                            StatBox(label: "G-Force max", value: WatchFormatters.gForce(maxGForce), unit: "G", color: .green)
                        }
                    }
                }

                // Close button
                Button {
                    // Don't call dismiss() - onDismiss closes the fullScreenCover,
                    // which makes the sheet disappear automatically
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
}

// MARK: - StatBox (Single statistic component)

struct StatBox: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
        .environment(WatchLocationService())
}
