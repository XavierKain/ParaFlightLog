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
//  Camera — the orbit rig (Wingman "hybrid" model)
//  -----------------------------------------------
//  Wingman's replay camera offers three behaviours (automatic / hybrid / free).
//  The heart of the good ones is a *rig* that orbits the moving pilot: the user
//  adjusts three rig parameters and they PERSIST while the camera keeps
//  tracking. We model that directly:
//
//      rig = (distance, pitch, headingOffset)          // depth / height / yaw
//      camera = rig applied to the live pilot anchor:
//          center   = pilot position
//          distance = rig.distance                     ← pinch
//          pitch    = rig.pitch                        ← two-finger vertical drag
//          heading  = trackHeading + rig.headingOffset ← rotate
//
//  Gestures are read from the Map itself (interaction modes = `.all`). A
//  `.simultaneousGesture` touch-sentinel tells us when a finger is down: while
//  it is, we NEVER drive the camera (no fighting / juddering). When the user
//  lets go we let the map settle, snapshot its framing, decompose it back into
//  the rig, and resume driving from exactly where they left off. The four modes
//  — Chase, Orbit, Top-down, Overview — are just different ways of applying (or
//  ignoring) the rig each frame.
//
//  Preserved fix history (see inline notes): programmatic-camera capture
//  suppression, clamped dt, timer gated so it sleeps when fully idle,
//  pause-doesn't-exit-the-current-camera, whole-track overview fly-in.
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

/// The user-controlled orbit rig. Persisted across frames and modes so the
/// pilot keeps the framing they dialled in while the camera tracks the flight.
///   • `distance`      — depth (pinch)
///   • `pitch`         — height / look-down angle (two-finger vertical drag)
///   • `headingOffset` — yaw *relative to the flight direction* (rotate)
nonisolated struct CameraRig {
    var distance: Double
    var pitch: Double
    var headingOffset: Double

    static let `default` = CameraRig(distance: 900, pitch: 62, headingOffset: 0)

    static func clampDistance(_ d: Double) -> Double { min(max(d, 150), 12000) }
    static func clampPitch(_ p: Double) -> Double { min(max(p, 0), 80) }
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

    /// The user's orbit framing — captured from map gestures and re-applied to
    /// the moving pilot every tick.
    @State private var rig: CameraRig = .default

    /// Last framing the map reported (updated continuously). The snapshot we
    /// decompose into the rig when a gesture ends, and the seamless start point
    /// for the resumed follow.
    @State private var lastObserved: CamState?

    /// True while the user has a finger on the map. While set we never drive the
    /// camera — the map owns it — so there is zero fighting between our follow
    /// loop and the live pinch / tilt / rotate.
    @State private var userInteracting = false
    /// Pending "gesture settled" capture, so we read the *final* framing after
    /// pan deceleration rather than mid-fling.
    @State private var captureWork: DispatchWorkItem?

    /// One-time camera-gesture hint (pinch / tilt / rotate), dismissed on the
    /// first map touch or after a few seconds.
    @State private var showGestureHint = true

    // Timer
    @State private var lastTickDate: Date?
    @State private var playbackTimer: AnyCancellable?

    private let playbackSpeeds: [Double] = [1, 4, 10, 30]
    private let tickInterval: TimeInterval = 1.0 / 30.0
    /// Comet-trail length in real flight-seconds (independent of playback speed).
    private let cometWindow: TimeInterval = 14
    /// Orbit rotation rate, degrees per real second (advances only while playing).
    private let orbitRate: Double = 10
    /// After a gesture ends, wait this long for the map to settle before we
    /// snapshot its framing into the rig and resume driving.
    private let settleDelay: TimeInterval = 0.28

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Init

    init(flight: Flight) {
        self.init(points: flight.gpsTrack ?? [])
    }

    /// Replay from raw track points — used for community-shared flights,
    /// which have no local Flight model.
    init(points: [GPSTrackPoint]) {
        let engine = ReplayEngine(points: points)
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

    private var replayContent: some View {
        let current = engine.interpolate(at: elapsed)

        return ZStack {
            // Full gesture set enabled in every mode: pinch = depth, two-finger
            // vertical drag = pitch, rotate = heading offset. We arbitrate with
            // the map (not against it) via `userInteracting`.
            Map(position: $cameraPosition, interactionModes: .all) {
                mapContent(current: current)
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .onMapCameraChange(frequency: .continuous) { context in
                // Just track what the map is showing. The rig is captured only
                // when a gesture *ends* (below), never from our own programmatic
                // writes — so following can't corrupt the saved framing.
                lastObserved = CamState(center: context.camera.centerCoordinate,
                                        distance: context.camera.distance,
                                        pitch: context.camera.pitch,
                                        heading: context.camera.heading)
            }
            // Touch-sentinel: a zero-distance drag that recognises *alongside*
            // the map's own gestures. It never steals the touch — it only tells
            // us a finger is down, which is enough to stop driving the camera.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginUserInteraction() }
                    .onEnded { _ in endUserInteraction() }
            )
            .ignoresSafeArea()

            VStack {
                hud(for: current)
                Spacer()

                // One-time gesture hint: the camera is fully free (pinch =
                // zoom, two-finger vertical drag = tilt 3D, two-finger rotate
                // = heading) but nothing hinted at it. Fades out on first
                // touch or after a few seconds.
                if showGestureHint {
                    Label("Pinch to zoom · two-finger drag to tilt in 3D · rotate to orbit",
                          systemImage: "hand.draw")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }

                controls
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
        .sensoryFeedback(.selection, trigger: mode)
        .sensoryFeedback(.selection, trigger: speedIndex)
        .onChange(of: isPlaying) { _, _ in syncTimer() }
        .onChange(of: cameraAnimating) { _, _ in syncTimer() }
        .onChange(of: userInteracting) { _, interacting in
            // First touch on the map: the pilot found the gestures.
            if interacting { withAnimation(.easeOut(duration: 0.4)) { showGestureHint = false } }
        }
        .onAppear {
            scheduleOpeningFlyIn()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                withAnimation(.easeOut(duration: 0.8)) { showGestureHint = false }
            }
        }
        .onDisappear { stopTimer() }
    }

    /// Render mode (feedback #2 — no overlapping traces):
    ///   • Overview  → the whole flight as a vario-gradient track (readable from
    ///     high up, the one place the full colour story belongs).
    ///   • Following → a single faint context line for the whole route + a
    ///     bright comet tail over the recent seconds. Nothing else, so no two
    ///     layers ever fight for the same pixels.
    @MapContentBuilder
    private func mapContent(current: ReplaySample) -> some MapContent {
        if mode == .overview {
            ForEach(engine.varioRuns) { run in
                MapPolyline(coordinates: run.coordinates)
                    .stroke(VarioPalette.color(run.meanVario), lineWidth: 3.5)
            }
        } else {
            // Faint full route — thin, single, high-transparency context line.
            MapPolyline(coordinates: engine.rawCoordinates)
                .stroke(.white.opacity(0.16), lineWidth: 1.5)
            // Bright comet tail over the last few real seconds, faded by age.
            ForEach(engine.trailSlices(endingAt: elapsed, window: cometWindow, sliceCount: 8)) { slice in
                MapPolyline(coordinates: slice.coordinates)
                    .stroke(VarioPalette.color(slice.meanVario).opacity(0.2 + 0.8 * slice.ageFactor),
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

    /// One compact line that never wraps on a 393 pt iPhone (feedback #1):
    /// three fixed-width, monospaced chips — altitude, vario, time — plus Done.
    /// Speed lives in the bottom bar, not up here. Fixed widths +
    /// `minimumScaleFactor` keep a 4-digit altitude and a negative vario on a
    /// single line.
    private func hud(for sample: ReplaySample) -> some View {
        HStack(spacing: 8) {
            hudChip(icon: "mountain.2.fill",
                    text: sample.altitude.map { "\(Int($0)) m" } ?? "—",
                    width: 76)
            varioChip(sample.verticalSpeed)
            hudChip(icon: "clock",
                    text: Self.clockFormatter.string(from: engine.trackStart.addingTimeInterval(sample.time)),
                    width: 88)

            Spacer(minLength: 6)

            Button { dismiss() } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close replay")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func hudChip(icon: String, text: String, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(text)
                .font(.footnote.monospacedDigit()).fontWeight(.semibold)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: width, height: 34)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func varioChip(_ verticalSpeed: Double?) -> some View {
        let v = verticalSpeed ?? 0
        return HStack(spacing: 3) {
            Image(systemName: v >= 0 ? "arrow.up" : "arrow.down")
                .font(.caption2.weight(.bold))
            Text(verticalSpeed.map { String(format: "%+.1f", $0) } ?? "—")
                .font(.footnote.monospacedDigit()).fontWeight(.semibold)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(VarioPalette.color(v))
        .frame(width: 56, height: 34)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("Vario \(verticalSpeed.map { String(format: "%+.1f meters per second", $0) } ?? "unknown")")
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

    // MARK: - User camera gestures (the rig)

    /// A finger went down on the map. Hand the camera to the user: cancel any
    /// pending settle, drop any in-flight programmatic transition, and stop
    /// driving until they let go.
    private func beginUserInteraction() {
        hasUserInteracted = true
        captureWork?.cancel()
        captureWork = nil
        transition = nil
        if !userInteracting { userInteracting = true }
    }

    /// The finger lifted. The map may still be decelerating, so wait a beat,
    /// then snapshot its final framing into the rig and resume driving from
    /// exactly there. Overview is free-pan and owns no rig.
    private func endUserInteraction() {
        guard mode != .overview else { userInteracting = false; return }
        captureWork?.cancel()
        let work = DispatchWorkItem {
            captureRigFromMap()
            userInteracting = false
            cameraAnimating = true          // wake the tick so follow eases in
            captureWork = nil
        }
        captureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    /// Decompose the map's current framing back into rig parameters. Heading is
    /// stored *relative to the flight direction* so the offset persists as the
    /// pilot turns (the drone-rig behaviour). Each mode keeps only the rig
    /// parameters it actually honours, so a tilt in Top-down (say) doesn't stick.
    private func captureRigFromMap() {
        guard let o = lastObserved else { return }
        let trackHeading = engine.interpolate(at: elapsed).heading
        switch mode {
        case .chase:
            rig.distance = CameraRig.clampDistance(o.distance)
            rig.pitch = CameraRig.clampPitch(o.pitch)
            rig.headingOffset = ReplayEngine.angleDelta(trackHeading, o.heading)
        case .orbit:
            rig.distance = CameraRig.clampDistance(o.distance)
            rig.pitch = CameraRig.clampPitch(o.pitch)
            orbitAngle = o.heading          // keep spinning from where they left it
        case .topDown:
            rig.distance = CameraRig.clampDistance(o.distance)
        case .overview:
            break
        }
        cam = o                             // seamless: follow eases on from here
    }

    // MARK: - Camera driver

    /// Starts an eased transition from the current on-screen framing to a mode.
    private func beginTransition(to newMode: CameraMode, duration: TimeInterval = 1.0) {
        let from = lastObserved ?? cam
        cam = from
        if newMode == .orbit {                          // start aligned to the rig
            orbitAngle = engine.interpolate(at: elapsed).heading + rig.headingOffset
        }
        mode = newMode
        transition = CameraTransition(from: from, start: Date(), duration: duration)
        cameraAnimating = true                          // wakes the timer
    }

    /// The framing the camera wants *right now* — the rig applied to the live
    /// pilot anchor. Each mode is just a different application of the rig.
    private func cameraTarget(_ s: ReplaySample) -> CamState {
        switch mode {
        case .chase:
            return CamState(center: s.coordinate,
                            distance: rig.distance,
                            pitch: rig.pitch,
                            heading: (s.heading + rig.headingOffset).truncatingRemainder(dividingBy: 360))
        case .orbit:
            return CamState(center: s.coordinate,
                            distance: max(rig.distance, 600),
                            pitch: min(max(rig.pitch, 35), 75),
                            heading: orbitAngle)
        case .topDown:
            return CamState(center: s.coordinate,
                            distance: max(rig.distance, 500),
                            pitch: 0,
                            heading: s.heading)
        case .overview:
            return CamState(center: engine.centerCoordinate,
                            distance: engine.overviewDistance,
                            pitch: 0, heading: 0)
        }
    }

    /// One camera step: while the user is touching, do nothing (they own it);
    /// otherwise run an active transition, hand control to the user in overview,
    /// or ease the live camera toward the follow target.
    private func stepCamera(dt: Double, now: Date) {
        if userInteracting { return }               // never fight a live gesture
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

    /// Exponential ease of the live framing toward the target. Center lags
    /// slightly (reads as cinematic); heading follows the shortest arc; distance
    /// and pitch ease too. Because the rig is captured only on gesture-end (not
    /// from `onMapCameraChange`), easing these can no longer feed back and
    /// corrupt the saved framing.
    private func follow(_ c: CamState, toward t: CamState, dt: Double) -> CamState {
        let kCenter = 1 - exp(-dt / 0.18)
        let kHeading = 1 - exp(-dt / 0.30)
        let kZoom = 1 - exp(-dt / 0.25)
        return CamState(
            center: CLLocationCoordinate2D(
                latitude: c.center.latitude + (t.center.latitude - c.center.latitude) * kCenter,
                longitude: c.center.longitude + (t.center.longitude - c.center.longitude) * kCenter),
            distance: c.distance + (t.distance - c.distance) * kZoom,
            pitch: c.pitch + (t.pitch - c.pitch) * kZoom,
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
            if mode == .orbit && !userInteracting {
                orbitAngle = (orbitAngle + orbitRate * dt).truncatingRemainder(dividingBy: 360)
            }
        }

        if !isScrubbing { stepCamera(dt: dt, now: now) }

        // Let the tick sleep once we're paused, settled, and not mid-gesture.
        if !isPlaying && !userInteracting && transition == nil && cameraConverged() {
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
