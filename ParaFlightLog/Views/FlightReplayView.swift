//
//  FlightReplayView.swift
//  ParaFlightLog
//
//  Full-screen 3D flight replay (Wingman/Surfr-style):
//  - Chase camera with adjustable zoom & tilt (pinch / two-finger drag), or a
//    fully free camera the pilot moves by hand.
//  - Fading comet trail (the last ~10 viewed seconds) so circling in lift
//    doesn't build up into an unreadable blob; the whole vario-colored track
//    is shown in overview mode instead.
//  - Continuous vario color gradient (red sink → cyan neutral → green climb).
//  - Altitude-profile timeline scrubber, auto-play, HUD with live vario.
//  Target: iOS only
//

import SwiftUI
import MapKit
import Combine

struct FlightReplayView: View {
    @Environment(\.dismiss) private var dismiss

    // Immutable, decoded once
    private let track: [GPSTrackPoint]
    private let coordinates: [CLLocationCoordinate2D]
    private let timeOffsets: [TimeInterval]
    private let duration: TimeInterval
    private let trackStart: Date
    /// Full track split into runs of similar vertical speed, pre-colored
    /// (used in overview mode, where the whole flight is visible).
    private let varioSegments: [VarioSegment]
    /// Altitude samples normalized for the profile scrubber (0...1 by time).
    private let altitudeProfile: [CGPoint]

    // Playback state
    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var isOverview = false
    /// true = chase camera follows the pilot; false = free camera (manual)
    @State private var followMode = true
    @State private var speedIndex = 2          // default 10x
    @State private var cameraHeading: Double
    @State private var cameraPosition: MapCameraPosition
    @State private var lastTickDate: Date?
    /// Set whenever the code (not the user) moves the camera, so the transition
    /// animation's intermediate frames aren't captured as the pilot's framing.
    /// Initialized to "now": the initial camera setup counts as programmatic.
    @State private var lastProgrammaticCameraChange = Date()
    /// Drives playback at ~30 Hz; only alive while actually playing.
    @State private var playbackTimer: AnyCancellable?

    // Adjustable chase-camera framing: pinch to zoom and two-finger drag to
    // tilt keep working in follow mode — the values are captured from the map
    // and fed back into every camera update.
    @State private var cameraDistance: Double = 900
    @State private var cameraPitch: Double = 62

    private let playbackSpeeds: [Double] = [1, 5, 10, 30]
    private let tickInterval: TimeInterval = 1.0 / 30.0

    /// Trail window in flight-seconds: roughly the last 10 *viewed* seconds,
    /// whatever the playback speed.
    private var trailWindow: TimeInterval {
        max(20, 10 * playbackSpeeds[speedIndex])
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(flight: Flight) {
        // Sort by timestamp so interpolation is always monotonic
        let points = (flight.gpsTrack ?? []).sorted { $0.timestamp < $1.timestamp }
        self.track = points
        self.coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        let start = points.first?.timestamp ?? Date()
        self.trackStart = start
        let offsets = points.map { $0.timestamp.timeIntervalSince(start) }
        self.timeOffsets = offsets
        self.duration = offsets.last ?? 0

        self.varioSegments = Self.makeVarioSegments(points: points)
        self.altitudeProfile = Self.makeAltitudeProfile(points: points, offsets: offsets)

        // Initial chase camera above the takeoff, looking along the first segment
        let startCoordinate = points.first.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            ?? CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1)
        let initialHeading = points.count >= 2 ? Self.bearing(from: points[0], to: points[1]) : 0
        _cameraHeading = State(initialValue: initialHeading)
        _cameraPosition = State(initialValue: .camera(MapCamera(
            centerCoordinate: startCoordinate,
            distance: 900,
            heading: initialHeading,
            pitch: 62
        )))
    }

    var body: some View {
        Group {
            if track.count >= 2 {
                replayContent
            } else {
                emptyState
            }
        }
    }

    // MARK: - Content

    /// Gestures: free camera = everything; follow mode keeps zoom + pitch so
    /// the pilot can adjust the chase framing even during playback.
    private var interactionModes: MapInteractionModes {
        if !followMode || isOverview || !isPlaying {
            return .all
        }
        return [.zoom, .pitch]
    }

    private var replayContent: some View {
        let current = sample(at: elapsed)

        return ZStack {
            Map(position: $cameraPosition, interactionModes: interactionModes) {
                if isOverview {
                    // Whole flight, vario-colored (readable from high up)
                    ForEach(varioSegments) { segment in
                        MapPolyline(coordinates: segment.coordinates)
                            .stroke(segment.color, lineWidth: 3.5)
                    }
                } else {
                    // Faint full route for context only
                    MapPolyline(coordinates: coordinates)
                        .stroke(.white.opacity(0.18), lineWidth: 1.5)

                    // Comet trail: last ~10 viewed seconds, fading with age
                    ForEach(trailChunks(at: elapsed)) { chunk in
                        MapPolyline(coordinates: chunk.coordinates)
                            .stroke(chunk.color, lineWidth: 4)
                    }
                }

                // Takeoff and landing markers
                if let first = coordinates.first {
                    Annotation("Takeoff", coordinate: first) {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                if let last = coordinates.last {
                    Annotation("Landing", coordinate: last) {
                        Image(systemName: "flag.checkered")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }

                // The pilot, rotated to the current heading, ringed with the
                // live vario color (annotations are screen-aligned, hence the
                // camera-heading compensation)
                Annotation("", coordinate: current.coordinate) {
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.35))
                            .frame(width: 46, height: 46)
                        Circle()
                            .stroke(Self.varioColor(current.verticalSpeed ?? 0), lineWidth: 3)
                            .frame(width: 46, height: 46)
                        Image(systemName: "parachute.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .rotationEffect(.degrees(current.heading - cameraHeading))
                    }
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .onMapCameraChange(frequency: .continuous) { context in
                // Capture pinch-zoom / tilt so follow mode keeps the pilot's
                // framing on the next tick (values from our own per-tick chase
                // updates simply echo back unchanged). Skip right after a
                // programmatic transition (snap / overview / initial setup):
                // its animation reports intermediate distances up to 6000 m
                // that would corrupt the saved framing.
                guard followMode, !isOverview,
                      Date().timeIntervalSince(lastProgrammaticCameraChange) >= 0.8 else { return }
                cameraDistance = min(max(context.camera.distance, 250), 6000)
                cameraPitch = min(max(context.camera.pitch, 0), 75)
            }
            .ignoresSafeArea()

            // HUD + controls overlays
            VStack {
                hud(for: current)
                Spacer()
                controls
            }
        }
        .onChange(of: isPlaying) { _, playing in
            // The 30 Hz timer only lives while playing — no wasted wakeups
            // while paused or parked in overview.
            if playing {
                startPlaybackTimer()
            } else {
                stopPlaybackTimer()
            }
        }
        .onAppear {
            // Auto-start the flyover after the map settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if !isPlaying && elapsed == 0 {
                    isPlaying = true
                }
            }
        }
        .onDisappear {
            stopPlaybackTimer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            ContentUnavailableView(
                "No GPS Track",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                description: Text("This flight has no recorded track to replay.")
            )
            Button("Done") {
                dismiss()
            }
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
                hudItem(icon: "clock", value: Self.clockFormatter.string(from: sample.timestamp))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close replay")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func hudItem(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .fontWeight(.semibold)
        }
    }

    /// Vario readout: signed m/s, tinted like a variometer.
    private func varioHudItem(_ verticalSpeed: Double?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: (verticalSpeed ?? 0) >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Self.varioColor(verticalSpeed ?? 0))
            Text(verticalSpeed.map { String(format: "%+.1f", $0) } ?? "—")
                .font(.subheadline.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(Self.varioColor(verticalSpeed ?? 0))
        }
    }

    // MARK: - Controls (bottom)

    private var controls: some View {
        VStack(spacing: 10) {
            // Altitude-profile scrubber (the timeline IS the altitude curve)
            AltitudeProfileScrubber(
                profile: altitudeProfile,
                progress: duration > 0 ? elapsed / duration : 0,
                onScrub: { fraction in
                    isScrubbing = true
                    scrub(to: fraction * duration)
                },
                onScrubEnd: {
                    isScrubbing = false
                    if followMode { snapCamera() }
                }
            )
            .frame(height: 56)

            HStack(spacing: 10) {
                Text(timeString(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeString(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                // Playback speed cycle
                Button {
                    speedIndex = (speedIndex + 1) % playbackSpeeds.count
                } label: {
                    Text("\(Int(playbackSpeeds[speedIndex]))x")
                        .font(.headline.monospacedDigit())
                        .frame(width: 50, height: 36)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Playback speed")

                // Camera: follow the pilot, or free (move it by hand)
                Button {
                    toggleFollow()
                } label: {
                    Image(systemName: followMode ? "video.fill" : "hand.draw.fill")
                        .font(.headline)
                        .frame(width: 50, height: 36)
                        .background(
                            followMode ? Color.blue.opacity(0.25) : Color(.tertiarySystemFill),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(followMode ? "Camera follows the pilot — tap for free camera" : "Free camera — tap to follow the pilot")

                // Play / pause
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                // Whole-flight overview
                Button {
                    toggleOverview()
                } label: {
                    Image(systemName: isOverview ? "location.fill.viewfinder" : "map")
                        .font(.headline)
                        .frame(width: 50, height: 36)
                        .background(
                            isOverview ? Color.blue.opacity(0.25) : Color(.tertiarySystemFill),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOverview ? "Back to the pilot" : "Overview of the whole flight")

                // Restart
                Button {
                    scrub(to: 0)
                    if followMode { snapCamera() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(width: 50, height: 36)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restart replay")
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Playback Engine

    private func togglePlayback() {
        if !isPlaying {
            // Starting playback (pause leaves the overview state alone)
            if elapsed >= duration {
                // Replay from the start when finished
                elapsed = 0
                if followMode { snapCamera() }
            }
            if isOverview {
                isOverview = false
                if followMode { snapCamera() }
            }
        }
        isPlaying.toggle()
    }

    /// Runs `tick` at ~30 Hz while playing. Started on play, invalidated on
    /// pause and on disappear (via onChange(of: isPlaying) / onDisappear).
    private func startPlaybackTimer() {
        guard playbackTimer == nil else { return }
        lastTickDate = Date()
        playbackTimer = Timer.publish(every: tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { now in
                tick(now)
            }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.cancel()
        playbackTimer = nil
        lastTickDate = nil
    }

    /// Chase camera on/off. Free camera keeps playing — the pilot marker moves
    /// while the camera stays wherever the user put it.
    private func toggleFollow() {
        followMode.toggle()
        if followMode {
            isOverview = false
            snapCamera()
        }
    }

    /// Frames the whole flight from above, or returns to the previous camera.
    private func toggleOverview() {
        isOverview.toggle()
        lastProgrammaticCameraChange = Date()
        if isOverview {
            withAnimation(.easeInOut(duration: 0.6)) {
                cameraPosition = .automatic
            }
        } else if followMode {
            snapCamera()
        }
    }

    /// Advances playback on every timer tick; moves the camera in follow mode.
    private func tick(_ now: Date) {
        defer { lastTickDate = now }
        guard isPlaying, !isScrubbing, let last = lastTickDate else { return }

        // Clamp: after a main-thread stall or backgrounding, one tick must not
        // apply the whole gap × playback speed.
        let dt = min(now.timeIntervalSince(last), 0.5)
        guard dt > 0 else { return }

        var newElapsed = elapsed + dt * playbackSpeeds[speedIndex]
        if newElapsed >= duration {
            newElapsed = duration
            isPlaying = false
        }
        elapsed = newElapsed

        // Chase camera: center on the pilot with the user-adjusted zoom/tilt,
        // lerping the heading so turns stay smooth. Free camera: hands off.
        guard followMode, !isOverview else { return }
        let current = sample(at: elapsed)
        cameraHeading = Self.lerpAngle(from: cameraHeading, to: current.heading, factor: 0.08)
        withAnimation(.linear(duration: tickInterval)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: current.coordinate,
                distance: cameraDistance,
                heading: cameraHeading,
                pitch: cameraPitch
            ))
        }
    }

    /// Jumps directly to a time (scrubbing / restart).
    private func scrub(to time: TimeInterval) {
        elapsed = min(max(0, time), duration)
    }

    /// Re-centers the camera instantly on the current point (no heading lerp).
    private func snapCamera() {
        lastProgrammaticCameraChange = Date()
        let current = sample(at: elapsed)
        cameraHeading = current.heading
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .camera(MapCamera(
                centerCoordinate: current.coordinate,
                distance: cameraDistance,
                heading: cameraHeading,
                pitch: cameraPitch
            ))
        }
    }

    // MARK: - Track Sampling & Interpolation

    private struct ReplaySample {
        var coordinate: CLLocationCoordinate2D
        var altitude: Double?
        var speed: Double?          // m/s
        var verticalSpeed: Double?  // m/s, vario
        var heading: Double         // degrees, 0 = north
        var timestamp: Date
    }

    /// Interpolated state of the pilot at a given time offset.
    private func sample(at time: TimeInterval) -> ReplaySample {
        let i = segmentIndex(for: time)
        let p0 = track[i]
        let p1 = track[i + 1]
        let t0 = timeOffsets[i]
        let t1 = timeOffsets[i + 1]
        let fraction = t1 > t0 ? min(max((time - t0) / (t1 - t0), 0), 1) : 0

        let coordinate = CLLocationCoordinate2D(
            latitude: p0.latitude + (p1.latitude - p0.latitude) * fraction,
            longitude: p0.longitude + (p1.longitude - p0.longitude) * fraction
        )

        // Altitude: lerp when both points have one, otherwise whichever exists
        let altitude: Double?
        switch (p0.altitude, p1.altitude) {
        case let (a0?, a1?): altitude = a0 + (a1 - a0) * fraction
        case let (a0?, nil): altitude = a0
        case let (nil, a1?): altitude = a1
        default: altitude = nil
        }

        // Speed: lerp recorded speeds, fall back to the segment's average speed
        let speed: Double?
        switch (p0.speed, p1.speed) {
        case let (s0?, s1?): speed = s0 + (s1 - s0) * fraction
        case let (s0?, nil): speed = s0
        case let (nil, s1?): speed = s1
        default: speed = segmentAverageSpeed(from: p0, to: p1)
        }

        return ReplaySample(
            coordinate: coordinate,
            altitude: altitude,
            speed: speed,
            verticalSpeed: Self.segmentVerticalSpeed(from: p0, to: p1),
            heading: Self.bearing(from: p0, to: p1),
            timestamp: trackStart.addingTimeInterval(time)
        )
    }

    /// Largest segment index i such that timeOffsets[i] <= time (binary search).
    private func segmentIndex(for time: TimeInterval) -> Int {
        var low = 0
        var high = timeOffsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if timeOffsets[mid] <= time {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return min(low, track.count - 2)
    }

    private func segmentAverageSpeed(from p0: GPSTrackPoint, to p1: GPSTrackPoint) -> Double? {
        let dt = p1.timestamp.timeIntervalSince(p0.timestamp)
        guard dt > 0 else { return nil }
        let l0 = CLLocation(latitude: p0.latitude, longitude: p0.longitude)
        let l1 = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
        return l1.distance(from: l0) / dt
    }

    // MARK: - Comet Trail

    private struct TrailChunk: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    /// The last `trailWindow` flight-seconds as a handful of slices, colored by
    /// vario and fading out with age (oldest almost transparent). Keeps the
    /// screen readable when the pilot circles in the same spot for minutes.
    private func trailChunks(at time: TimeInterval) -> [TrailChunk] {
        let window = trailWindow
        let start = max(0, time - window)
        guard time > start else { return [] }

        let sliceCount = 8
        let sliceDuration = (time - start) / Double(sliceCount)
        guard sliceDuration > 0 else { return [] }

        var chunks: [TrailChunk] = []
        chunks.reserveCapacity(sliceCount)

        for k in 0..<sliceCount {
            let t0 = start + sliceDuration * Double(k)
            let t1 = start + sliceDuration * Double(k + 1)

            // Slice coordinates: interpolated ends + the raw points in between
            var coords: [CLLocationCoordinate2D] = [sample(at: t0).coordinate]
            let i0 = segmentIndex(for: t0)
            let i1 = segmentIndex(for: t1)
            if i1 > i0 {
                coords.append(contentsOf: coordinates[(i0 + 1)...i1])
            }
            coords.append(sample(at: t1).coordinate)
            guard coords.count >= 2 else { continue }

            // Age fade: newest slice fully opaque, oldest nearly gone
            let ageFactor = Double(k + 1) / Double(sliceCount)
            let opacity = 0.12 + 0.88 * ageFactor
            let vario = sample(at: (t0 + t1) / 2).verticalSpeed ?? 0

            chunks.append(TrailChunk(
                id: k,
                coordinates: coords,
                color: Self.varioColor(vario).opacity(opacity)
            ))
        }
        return chunks
    }

    // MARK: - Vario Coloring (continuous gradient)

    private struct VarioSegment: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    /// Vertical speed (m/s) over one segment, nil without altitude data.
    private static func segmentVerticalSpeed(from p0: GPSTrackPoint, to p1: GPSTrackPoint) -> Double? {
        guard let a0 = p0.altitude, let a1 = p1.altitude else { return nil }
        let dt = p1.timestamp.timeIntervalSince(p0.timestamp)
        guard dt > 0 else { return nil }
        return (a1 - a0) / dt
    }

    /// Continuous variometer gradient: strong sink → red, weak sink → orange,
    /// neutral → cyan, weak climb → light green, strong climb → green.
    /// Piecewise-linear RGB interpolation between the stops.
    private static func varioColor(_ verticalSpeed: Double) -> Color {
        // (vario m/s, r, g, b)
        let stops: [(Double, Double, Double, Double)] = [
            (-4.0, 0.95, 0.15, 0.15),   // strong sink: red
            (-1.5, 1.00, 0.55, 0.10),   // sink: orange
            ( 0.0, 0.25, 0.80, 0.95),   // neutral: cyan
            ( 1.5, 0.55, 0.90, 0.30),   // climb: light green
            ( 4.0, 0.10, 0.85, 0.25)    // strong climb: green
        ]

        let v = min(max(verticalSpeed, stops.first!.0), stops.last!.0)
        for i in 0..<(stops.count - 1) {
            let (v0, r0, g0, b0) = stops[i]
            let (v1, r1, g1, b1) = stops[i + 1]
            if v <= v1 {
                let f = v1 > v0 ? (v - v0) / (v1 - v0) : 0
                return Color(
                    red: r0 + (r1 - r0) * f,
                    green: g0 + (g1 - g0) * f,
                    blue: b0 + (b1 - b0) * f
                )
            }
        }
        return Color(red: stops.last!.1, green: stops.last!.2, blue: stops.last!.3)
    }

    /// Quantized color id used to group consecutive points into polyline runs
    /// (full-track overview rendering).
    private static func varioBucket(_ verticalSpeed: Double) -> Int {
        Int((min(max(verticalSpeed, -4), 4) * 2).rounded())   // 0.5 m/s buckets
    }

    /// Groups consecutive points into runs of similar vario so the full track
    /// renders as a limited number of polylines with a smooth-looking gradient.
    /// The raw per-point vario is smoothed with a short moving average and
    /// sub-3-point runs are merged into their neighbor: otherwise noisy tracks
    /// flip 0.5 m/s buckets constantly and produce thousands of polylines.
    private static func makeVarioSegments(points: [GPSTrackPoint]) -> [VarioSegment] {
        guard points.count >= 2 else { return [] }

        let coords = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        // Per-point vertical speed: point i carries the vario of segment i→i+1
        // (the last point repeats its predecessor's value).
        var varios = [Double](repeating: 0, count: points.count)
        for i in 0..<(points.count - 1) {
            varios[i] = segmentVerticalSpeed(from: points[i], to: points[i + 1]) ?? 0
        }
        varios[points.count - 1] = varios[points.count - 2]

        // Centered moving average over 5 points tames GPS altitude noise.
        let radius = 2
        let smoothed = varios.indices.map { i -> Double in
            let lo = max(0, i - radius)
            let hi = min(varios.count - 1, i + radius)
            return varios[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }

        // Runs of consecutive points sharing a bucket.
        var runs: [(bucket: Int, range: ClosedRange<Int>)] = []
        var runStart = 0
        var runBucket = varioBucket(smoothed[0])
        for i in 1..<smoothed.count where varioBucket(smoothed[i]) != runBucket {
            runs.append((runBucket, runStart...(i - 1)))
            runStart = i
            runBucket = varioBucket(smoothed[i])
        }
        runs.append((runBucket, runStart...(smoothed.count - 1)))

        // Merge runs shorter than 3 points into the previous run (coalescing
        // same-bucket neighbors that touch as a result).
        let minRunLength = 3
        var merged: [(bucket: Int, range: ClosedRange<Int>)] = []
        for run in runs {
            if let last = merged.last, run.range.count < minRunLength || last.bucket == run.bucket {
                merged[merged.count - 1] = (last.bucket, last.range.lowerBound...run.range.upperBound)
            } else {
                merged.append(run)
            }
        }
        // A short leading run has no previous neighbor: fold it forward.
        if merged.count >= 2, merged[0].range.count < minRunLength {
            merged[1] = (merged[1].bucket, merged[0].range.lowerBound...merged[1].range.upperBound)
            merged.removeFirst()
        }

        // One polyline per run, extended by one point so consecutive runs
        // connect, colored by the run's mean smoothed vario.
        var segments: [VarioSegment] = []
        segments.reserveCapacity(merged.count)
        for run in merged {
            let last = min(run.range.upperBound + 1, coords.count - 1)
            let runCoords = Array(coords[run.range.lowerBound...last])
            guard runCoords.count >= 2 else { continue }
            let meanVario = smoothed[run.range].reduce(0, +) / Double(run.range.count)
            segments.append(VarioSegment(id: segments.count, coordinates: runCoords, color: varioColor(meanVario)))
        }
        return segments
    }

    /// Altitude curve normalized to 0...1 in both axes (x = time, y = altitude).
    private static func makeAltitudeProfile(points: [GPSTrackPoint], offsets: [TimeInterval]) -> [CGPoint] {
        let altitudes = points.compactMap(\.altitude)
        guard let minAlt = altitudes.min(), let maxAlt = altitudes.max(),
              let totalTime = offsets.last, totalTime > 0 else { return [] }
        let span = max(maxAlt - minAlt, 1)

        var profile: [CGPoint] = []
        profile.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            guard let alt = point.altitude else { continue }
            profile.append(CGPoint(
                x: offsets[index] / totalTime,
                y: (alt - minAlt) / span
            ))
        }
        return profile
    }

    // MARK: - Math Helpers

    /// Initial great-circle bearing between two points, in degrees (0..360, 0 = north).
    private static func bearing(from a: GPSTrackPoint, to b: GPSTrackPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180

        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let radians = atan2(y, x)
        return (radians * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Lerps between two angles along the shortest arc (avoids the 359° -> 1° spin).
    private static func lerpAngle(from: Double, to: Double, factor: Double) -> Double {
        let delta = (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
        return (from + delta * factor + 360).truncatingRemainder(dividingBy: 360)
    }

    /// "m:ss" or "h:mm:ss"
    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - AltitudeProfileScrubber

/// Timeline scrubber drawn as the flight's altitude profile: the flown part is
/// filled, a playhead marks the current position, and dragging scrubs time.
private struct AltitudeProfileScrubber: View {
    /// Normalized altitude curve (x = time 0...1, y = altitude 0...1).
    let profile: [CGPoint]
    /// Current playback progress, 0...1.
    let progress: Double
    let onScrub: (Double) -> Void
    let onScrubEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .leading) {
                // Full profile, faint
                profilePath(in: size, closed: true)
                    .fill(Color.white.opacity(0.12))
                profilePath(in: size, closed: false)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1.5)

                // Flown part, highlighted
                profilePath(in: size, closed: true)
                    .fill(Color.blue.opacity(0.45))
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: size.width * progress)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                // Playhead
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: 2)
                    .offset(x: size.width * progress - 1)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / size.width, 0), 1)
                        onScrub(fraction)
                    }
                    .onEnded { _ in
                        onScrubEnd()
                    }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("Flight timeline")
        .accessibilityHint("Drag to move through the flight")
    }

    /// Altitude curve path; `closed` adds the baseline for a fillable area.
    private func profilePath(in size: CGSize, closed: Bool) -> Path {
        Path { path in
            guard profile.count >= 2 else {
                // Flat line when there is no altitude data
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                if closed {
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.closeSubpath()
                }
                return
            }

            // Leave a little headroom so peaks don't touch the edge
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * size.width,
                        y: size.height - (p.y * (size.height - 10) + 5))
            }

            path.move(to: point(profile[0]))
            for p in profile.dropFirst() {
                path.addLine(to: point(p))
            }
            if closed {
                path.addLine(to: CGPoint(x: profile.last.map { $0.x * size.width } ?? size.width, y: size.height))
                path.addLine(to: CGPoint(x: profile.first.map { $0.x * size.width } ?? 0, y: size.height))
                path.closeSubpath()
            }
        }
    }
}
