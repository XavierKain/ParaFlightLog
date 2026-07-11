//
//  FlightReplayView.swift
//  ParaFlightLog
//
//  Full-screen cinematic 3D flight replay (Wingman/Surfr-class).
//
//  Architecture
//  ------------
//  All motion math lives in `ReplayEngine` (a pure, nonisolated struct built
//  once in `init`): Catmull-Rom-smoothed, resampled path + heading/vario
//  smoothing. This view is a thin driver — it advances a clock and eases a
//  camera toward a per-mode target. Every frame is an O(1) engine lookup, not
//  per-tick spline math.
//
//  Camera
//  ------
//  Four modes — Chase, Orbit, Top-down, Overview — expressed as a single
//  target `CamState` (center / distance / pitch / heading). A unified per-tick
//  driver eases the live camera toward that target, so mode switches animate
//  with an ease-in-out over ~1s and following stays silky. On open it holds a
//  2s whole-track overview, then dives to the start and autoplays in Chase.
//
//  Preserved fix history (see inline notes): programmatic-camera capture
//  suppression, clamped dt, timer gated so it sleeps when fully idle,
//  pause-doesn't-exit-the-current-camera.
//
//  Target: iOS only
//

import SwiftUI
import MapKit
import Combine

// MARK: - Camera model

/// The four cinematic camera modes, cycled by the camera button.
enum CameraMode: CaseIterable {
    case chase, orbit, topDown, overview

    var next: CameraMode {
        let all = CameraMode.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    var iconName: String {
        switch self {
        case .chase: return "video.fill"
        case .orbit: return "rotate.3d"
        case .topDown: return "chevron.up.chevron.down"
        case .overview: return "map.fill"
        }
    }

    var label: String {
        switch self {
        case .chase: return "Chase"
        case .orbit: return "Orbit"
        case .topDown: return "Top"
        case .overview: return "Overview"
        }
    }
}

/// A fully-specified camera framing. The driver eases the live value toward a
/// per-mode target of this shape.
nonisolated struct CamState {
    var center: CLLocationCoordinate2D
    var distance: Double
    var pitch: Double
    var heading: Double
}

/// An in-flight ease-in-out between two framings (mode switch, snap, dive-in).
private struct CameraTransition {
    let from: CamState
    let start: Date
    let duration: TimeInterval
}

// MARK: - FlightReplayView

struct FlightReplayView: View {
    @Environment(\.dismiss) private var dismiss

    /// Pure motion engine, precomputed once from the track.
    private let engine: ReplayEngine
    private let hasTrack: Bool

    // Playback
    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var speedIndex = 2               // default 10x
    @State private var hasUserInteracted = false

    // Camera
    @State private var mode: CameraMode = .overview
    @State private var cam: CamState
    @State private var cameraPosition: MapCameraPosition
    @State private var transition: CameraTransition?
    @State private var orbitAngle: Double = 0
    /// True while a transition or a not-yet-settled follow is animating. Keeps
    /// the tick alive past `isPlaying` so mode switches finish smoothly, then
    /// lets it sleep again once the camera has settled (no wasted wakeups).
    @State private var cameraAnimating = false

    /// User-chosen chase framing, captured from pinch-zoom / two-finger tilt
    /// and reused across ticks so the pilot keeps their framing.
    @State private var userDistance: Double = 900
    @State private var userPitch: Double = 62

    /// Last framing the map reported — the true starting point for the next
    /// transition (the user may have panned freely in overview / while paused).
    @State private var lastObserved: CamState?
    /// Set whenever *we* move the camera, so the transition's intermediate
    /// frames aren't captured as the pilot's framing.
    @State private var lastProgrammaticCameraChange = Date()

    // Timer
    @State private var lastTickDate: Date?
    @State private var playbackTimer: AnyCancellable?

    private let playbackSpeeds: [Double] = [1, 4, 10, 30]
    private let tickInterval: TimeInterval = 1.0 / 30.0
    private let transitionDuration: TimeInterval = 1.0
    /// Comet-trail length in real flight-seconds (independent of playback speed).
    private let cometWindow: TimeInterval = 14
    /// Orbit rotation rate, degrees per real second (advances only while playing).
    private let orbitRate: Double = 10

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Init

    init(flight: Flight) {
        let engine = ReplayEngine(points: flight.gpsTrack ?? [])
        self.engine = engine
        self.hasTrack = engine.rawCoordinates.count >= 2

        // Open on the whole-flight overview, then dive to the start (onAppear).
        let overview = CamState(center: engine.centerCoordinate,
                                distance: engine.overviewDistance,
                                pitch: 0, heading: 0)
        _cam = State(initialValue: overview)
        _cameraPosition = State(initialValue: .camera(MapCamera(
            centerCoordinate: overview.center,
            distance: overview.distance,
            heading: overview.heading,
            pitch: overview.pitch
        )))
    }

    var body: some View {
        Group {
            if hasTrack {
                replayContent
            } else {
                emptyState
            }
        }
    }

    // MARK: - Content

    /// Interaction: overview & paused-idle are fully free; the active modes keep
    /// zoom (and pitch for chase/orbit) so the pilot can adjust framing.
    private var interactionModes: MapInteractionModes {
        if mode == .overview { return .all }
        if !isPlaying && !cameraAnimating && transition == nil { return .all }
        switch mode {
        case .chase, .orbit: return [.zoom, .pitch]
        case .topDown: return [.zoom]
        case .overview: return .all
        }
    }

    private var replayContent: some View {
        let current = engine.interpolate(at: elapsed)

        return ZStack {
            Map(position: $cameraPosition, interactionModes: interactionModes) {
                mapContent(current: current)
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .onMapCameraChange(frequency: .continuous) { context in
                lastObserved = CamState(center: context.camera.centerCoordinate,
                                        distance: context.camera.distance,
                                        pitch: context.camera.pitch,
                                        heading: context.camera.heading)
                // Capture the pilot's chase framing only — never during a
                // programmatic transition (its eased intermediate distances up
                // to overview scale would corrupt the saved framing), and only
                // in Chase (Orbit/Top drive pitch/heading themselves).
                guard mode == .chase, transition == nil,
                      Date().timeIntervalSince(lastProgrammaticCameraChange) >= 0.5 else { return }
                userDistance = min(max(context.camera.distance, 200), 8000)
                userPitch = min(max(context.camera.pitch, 0), 80)
            }
            .ignoresSafeArea()

            VStack {
                hud(for: current)
                Spacer()
                controls
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
        .sensoryFeedback(.selection, trigger: mode)
        .sensoryFeedback(.selection, trigger: speedIndex)
        .onChange(of: isPlaying) { _, _ in syncTimer() }
        .onChange(of: cameraAnimating) { _, _ in syncTimer() }
        .onAppear { scheduleOpeningFlyIn() }
        .onDisappear { stopTimer() }
    }

    @MapContentBuilder
    private func mapContent(current: ReplaySample) -> some MapContent {
        if mode == .overview {
            // Whole flight, vario-colored — readable from high up.
            ForEach(engine.varioRuns) { run in
                MapPolyline(coordinates: run.coordinates)
                    .stroke(VarioPalette.color(run.meanVario), lineWidth: 3.5)
            }
        } else {
            // Progressive track: faint unflown remainder…
            let remainder = engine.remainderCoordinates(from: elapsed)
            if remainder.count >= 2 {
                MapPolyline(coordinates: remainder)
                    .stroke(.white.opacity(0.18), lineWidth: 2)
            }
            // …flown part in the vario gradient…
            ForEach(engine.flownRuns(upTo: elapsed)) { run in
                MapPolyline(coordinates: run.coordinates)
                    .stroke(VarioPalette.color(run.meanVario).opacity(0.55), lineWidth: 3)
            }
            // …and a brighter comet tail over the last few real seconds.
            ForEach(engine.trailSlices(endingAt: elapsed, window: cometWindow, sliceCount: 8)) { slice in
                MapPolyline(coordinates: slice.coordinates)
                    .stroke(VarioPalette.color(slice.meanVario).opacity(0.15 + 0.85 * slice.ageFactor),
                            lineWidth: 4.5)
            }
        }

        if let first = engine.rawCoordinates.first {
            Annotation("Takeoff", coordinate: first) {
                markerBadge(system: "flag.fill", tint: .green)
            }
        }
        if let last = engine.rawCoordinates.last {
            Annotation("Landing", coordinate: last) {
                markerBadge(system: "flag.checkered", tint: .red)
            }
        }

        // Pilot, rotated to the flight heading (annotations are screen-aligned,
        // hence the camera-heading compensation).
        Annotation("", coordinate: current.coordinate) {
            ZStack {
                Circle().fill(.black.opacity(0.35)).frame(width: 46, height: 46)
                Circle()
                    .stroke(VarioPalette.color(current.verticalSpeed ?? 0), lineWidth: 3)
                    .frame(width: 46, height: 46)
                Image(systemName: "parachute.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .rotationEffect(.degrees(current.heading - cam.heading))
            }
        }
    }

    private func markerBadge(system: String, tint: Color) -> some View {
        Image(systemName: system)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(4)
            .background(.ultraThinMaterial, in: Circle())
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            ContentUnavailableView(
                "No GPS Track",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                description: Text("This flight has no recorded track to replay.")
            )
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - HUD (top)

    private func hud(for sample: ReplaySample) -> some View {
        HStack(alignment: .top) {
            HStack(spacing: 14) {
                hudItem(icon: "mountain.2.fill", value: sample.altitude.map { "\(Int($0)) m" } ?? "—")
                hudItem(icon: "speedometer", value: sample.speed.map { "\(Int($0 * 3.6)) km/h" } ?? "—")
                varioHudItem(sample.verticalSpeed)
                hudItem(icon: "clock",
                        value: Self.clockFormatter.string(from: engine.trackStart.addingTimeInterval(sample.time)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer()

            Button { dismiss() } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close replay")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func hudItem(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospacedDigit()).fontWeight(.semibold)
        }
    }

    private func varioHudItem(_ verticalSpeed: Double?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: (verticalSpeed ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(VarioPalette.color(verticalSpeed ?? 0))
            Text(verticalSpeed.map { String(format: "%+.1f", $0) } ?? "—")
                .font(.subheadline.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(VarioPalette.color(verticalSpeed ?? 0))
        }
    }

    // MARK: - Controls (bottom)

    private var controls: some View {
        VStack(spacing: 10) {
            AltitudeProfileScrubber(
                profile: engine.altitudeProfile,
                progress: engine.totalDuration > 0 ? elapsed / engine.totalDuration : 0,
                onScrub: { fraction in
                    isScrubbing = true
                    hasUserInteracted = true
                    elapsed = min(max(fraction, 0), 1) * engine.totalDuration
                },
                onScrubEnd: {
                    isScrubbing = false
                    if mode != .overview { beginTransition(to: mode, duration: 0.4) }
                }
            )
            .frame(height: 64)

            HStack {
                Text(timeString(elapsed))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(timeString(engine.totalDuration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                speedButton
                cameraModeButton
                playButton
                restartButton
            }
        }
        .padding()
        .frame(maxWidth: 640)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var speedButton: some View {
        Button {
            hasUserInteracted = true
            speedIndex = (speedIndex + 1) % playbackSpeeds.count
        } label: {
            Text("\(Int(playbackSpeeds[speedIndex]))x")
                .font(.headline.monospacedDigit())
                .frame(width: 54, height: 40)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed \(Int(playbackSpeeds[speedIndex]))x")
    }

    private var cameraModeButton: some View {
        Button {
            cycleCameraMode()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: mode.iconName).font(.headline)
                Text(mode.label).font(.system(size: 9, weight: .semibold))
            }
            .frame(width: 60, height: 40)
            .background(Color.blue.opacity(0.25), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera mode: \(mode.label). Tap to change.")
    }

    private var playButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private var restartButton: some View {
        Button {
            restart()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.headline)
                .frame(width: 54, height: 40)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restart replay")
    }

    // MARK: - Playback control

    private func togglePlayback() {
        hasUserInteracted = true
        if !isPlaying {
            if elapsed >= engine.totalDuration { elapsed = 0 }
            if mode == .overview {
                beginTransition(to: .chase)          // leave overview, dive to pilot
            } else {
                beginTransition(to: mode, duration: 0.4)   // re-center after a free pan
            }
        }
        isPlaying.toggle()
    }

    private func restart() {
        hasUserInteracted = true
        elapsed = 0
        if mode != .overview { beginTransition(to: mode, duration: 0.6) }
    }

    private func cycleCameraMode() {
        hasUserInteracted = true
        beginTransition(to: mode.next)
    }

    /// Opening cinematic: hold the whole-track overview ~2s, then dive to the
    /// start and autoplay in Chase — unless the pilot already took over.
    private func scheduleOpeningFlyIn() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard !hasUserInteracted, elapsed == 0, mode == .overview else { return }
            beginTransition(to: .chase)
            isPlaying = true
        }
    }

    // MARK: - Camera driver

    /// Starts an eased transition from the current on-screen framing to a mode.
    private func beginTransition(to newMode: CameraMode, duration: TimeInterval = 1.0) {
        let from = lastObserved ?? cam
        cam = from
        if newMode == .orbit { orbitAngle = from.heading }   // start aligned, then rotate
        mode = newMode
        transition = CameraTransition(from: from, start: Date(), duration: duration)
        lastProgrammaticCameraChange = Date()
        cameraAnimating = true                                // wakes the timer
    }

    /// The framing the camera wants *right now* for the current pilot sample.
    private func cameraTarget(_ s: ReplaySample) -> CamState {
        switch mode {
        case .chase:
            return CamState(center: s.coordinate, distance: userDistance, pitch: userPitch, heading: s.heading)
        case .orbit:
            return CamState(center: s.coordinate, distance: max(userDistance, 700) * 1.1, pitch: 58, heading: orbitAngle)
        case .topDown:
            return CamState(center: s.coordinate, distance: max(userDistance, 600) * 1.25, pitch: 0, heading: s.heading)
        case .overview:
            return CamState(center: engine.centerCoordinate, distance: engine.overviewDistance, pitch: 0, heading: 0)
        }
    }

    /// One camera step: run an active transition, hand control to the user in
    /// overview, otherwise ease the live camera toward the follow target.
    private func stepCamera(dt: Double, now: Date) {
        let target = cameraTarget(engine.interpolate(at: elapsed))
        if let tr = transition {
            let p = tr.duration > 0 ? min(now.timeIntervalSince(tr.start) / tr.duration, 1) : 1
            cam = mix(tr.from, target, easeInOut(p))
            if p >= 1 { transition = nil }
            writeCamera()
        } else if mode == .overview {
            return                                   // user explores freely
        } else {
            cam = follow(cam, toward: target, dt: dt)
            writeCamera()
        }
    }

    private func writeCamera() {
        withAnimation(.linear(duration: tickInterval)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: cam.center,
                distance: cam.distance,
                heading: cam.heading,
                pitch: cam.pitch
            ))
        }
    }

    /// Exponential ease of the live framing toward the target (slight center
    /// lag reads as cinematic; heading follows the shortest arc).
    private func follow(_ c: CamState, toward t: CamState, dt: Double) -> CamState {
        let kCenter = 1 - exp(-dt / 0.22)
        let kHeading = 1 - exp(-dt / 0.30)
        let kFraming = 1 - exp(-dt / 0.20)
        return CamState(
            center: CLLocationCoordinate2D(
                latitude: c.center.latitude + (t.center.latitude - c.center.latitude) * kCenter,
                longitude: c.center.longitude + (t.center.longitude - c.center.longitude) * kCenter),
            distance: c.distance + (t.distance - c.distance) * kFraming,
            pitch: c.pitch + (t.pitch - c.pitch) * kFraming,
            heading: ReplayEngine.lerpAngle(from: c.heading, to: t.heading, factor: kHeading)
        )
    }

    private func mix(_ a: CamState, _ b: CamState, _ e: Double) -> CamState {
        CamState(
            center: CLLocationCoordinate2D(
                latitude: a.center.latitude + (b.center.latitude - a.center.latitude) * e,
                longitude: a.center.longitude + (b.center.longitude - a.center.longitude) * e),
            distance: a.distance + (b.distance - a.distance) * e,
            pitch: a.pitch + (b.pitch - a.pitch) * e,
            heading: ReplayEngine.lerpAngle(from: a.heading, to: b.heading, factor: e)
        )
    }

    private func easeInOut(_ p: Double) -> Double {
        p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
    }

    private func cameraConverged() -> Bool {
        let t = cameraTarget(engine.interpolate(at: elapsed))
        return abs(cam.center.latitude - t.center.latitude) < 1e-6
            && abs(cam.center.longitude - t.center.longitude) < 1e-6
            && abs(cam.distance - t.distance) < 2
            && abs(cam.pitch - t.pitch) < 0.5
            && abs(ReplayEngine.angleDelta(cam.heading, t.heading)) < 0.5
    }

    // MARK: - Timer

    /// The 30 Hz tick lives only while playing OR while the camera is still
    /// animating (a transition / not-yet-settled follow). Once fully idle it
    /// sleeps — no wasted wakeups while parked.
    private func syncTimer() {
        let shouldRun = isPlaying || cameraAnimating
        if shouldRun {
            guard playbackTimer == nil else { return }
            lastTickDate = Date()
            playbackTimer = Timer.publish(every: tickInterval, on: .main, in: .common)
                .autoconnect()
                .sink { now in tick(now) }
        } else {
            stopTimer()
        }
    }

    private func stopTimer() {
        playbackTimer?.cancel()
        playbackTimer = nil
        lastTickDate = nil
    }

    private func tick(_ now: Date) {
        defer { lastTickDate = now }
        guard let last = lastTickDate else { return }
        // Clamp: after a stall / backgrounding one tick must not apply the
        // whole gap × playback speed.
        let dt = min(now.timeIntervalSince(last), 0.5)
        guard dt > 0 else { return }

        if isPlaying && !isScrubbing {
            var next = elapsed + dt * playbackSpeeds[speedIndex]
            if next >= engine.totalDuration {
                next = engine.totalDuration
                isPlaying = false
                cameraAnimating = true          // let the camera settle at the end
            }
            elapsed = next
            if mode == .orbit {
                orbitAngle = (orbitAngle + orbitRate * dt).truncatingRemainder(dividingBy: 360)
            }
        }

        if !isScrubbing { stepCamera(dt: dt, now: now) }

        // Let the tick sleep once we're paused and fully settled.
        if !isPlaying && transition == nil && cameraConverged() {
            if cameraAnimating { cameraAnimating = false }
        }
    }

    // MARK: - Formatting

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
