//
//  FlightReplayView.swift
//  ParaFlightLog
//
//  Full-screen 3D flight replay (Wingman-style):
//  a chase camera follows the pilot over realistic 3D terrain, the track is
//  colored by climb/sink (vario), and the timeline is an altitude-profile
//  scrubber. Playback auto-starts; an overview mode frames the whole flight.
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
    /// Track split into consecutive runs of similar vertical speed, pre-colored
    /// (green = climb, red = sink) so the 3D line reads like a vario trace.
    private let varioSegments: [VarioSegment]
    /// Altitude samples normalized for the profile scrubber (0...1 by time).
    private let altitudeProfile: [CGPoint]

    // Playback state
    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var isOverview = false
    @State private var speedIndex = 1          // default 10x
    @State private var cameraHeading: Double
    @State private var cameraPosition: MapCameraPosition
    @State private var lastTickDate: Date?

    private let playbackSpeeds: [Double] = [1, 5, 10, 30]
    private let cameraDistance: Double = 900
    private let cameraPitch: Double = 62
    private let tickInterval: TimeInterval = 1.0 / 30.0
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

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

    private var replayContent: some View {
        let current = sample(at: elapsed)

        return ZStack {
            Map(position: $cameraPosition, interactionModes: isPlaying ? [] : .all) {
                // Vario-colored track: green while climbing, red while sinking
                ForEach(varioSegments) { segment in
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(segment.color, lineWidth: 3.5)
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
                // current vario color (relative to camera heading: annotations
                // are screen-aligned)
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
            .ignoresSafeArea()

            // HUD + controls overlays
            VStack {
                hud(for: current)
                Spacer()
                controls
            }
        }
        .onReceive(timer) { now in
            tick(now)
        }
        .onAppear {
            // Auto-start the flyover (Wingman-style) after the map settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if !isPlaying && elapsed == 0 {
                    isPlaying = true
                }
            }
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
            // Altitude-profile scrubber (replaces the plain slider)
            AltitudeProfileScrubber(
                profile: altitudeProfile,
                progress: duration > 0 ? elapsed / duration : 0,
                onScrub: { fraction in
                    isScrubbing = true
                    scrub(to: fraction * duration)
                },
                onScrubEnd: {
                    isScrubbing = false
                    snapCamera()
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

            HStack(spacing: 24) {
                // Playback speed cycle
                Button {
                    speedIndex = (speedIndex + 1) % playbackSpeeds.count
                } label: {
                    Text("\(Int(playbackSpeeds[speedIndex]))x")
                        .font(.headline.monospacedDigit())
                        .frame(width: 52, height: 36)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Playback speed")

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

                // Chase / overview camera toggle
                Button {
                    toggleOverview()
                } label: {
                    Image(systemName: isOverview ? "location.fill.viewfinder" : "map")
                        .font(.headline)
                        .frame(width: 52, height: 36)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOverview ? "Back to chase camera" : "Overview of the whole flight")

                // Restart
                Button {
                    scrub(to: 0)
                    snapCamera()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(width: 52, height: 36)
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
        if !isPlaying && elapsed >= duration {
            // Replay from the start when finished
            elapsed = 0
            snapCamera()
        }
        if isOverview {
            isOverview = false
            snapCamera()
        }
        isPlaying.toggle()
    }

    /// Frames the whole flight from above (paused), or returns to the chase cam.
    private func toggleOverview() {
        isOverview.toggle()
        if isOverview {
            isPlaying = false
            withAnimation(.easeInOut(duration: 0.6)) {
                cameraPosition = .automatic
            }
        } else {
            snapCamera()
        }
    }

    /// Advances playback on every timer tick and moves the chase camera.
    private func tick(_ now: Date) {
        defer { lastTickDate = now }
        guard isPlaying, !isScrubbing, let last = lastTickDate else { return }

        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return }

        var newElapsed = elapsed + dt * playbackSpeeds[speedIndex]
        if newElapsed >= duration {
            newElapsed = duration
            isPlaying = false
        }
        elapsed = newElapsed

        // Chase camera: center on the pilot, lerp the heading so turns stay smooth
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

    // MARK: - Vario Coloring

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

    /// Variometer color scale: strong climb → green, neutral → cyan, sink → orange/red.
    private static func varioColor(_ verticalSpeed: Double) -> Color {
        switch verticalSpeed {
        case 1.5...:            return .green
        case 0.3..<1.5:         return Color(red: 0.55, green: 0.85, blue: 0.35)
        case -0.8..<0.3:        return .cyan
        case -2.5..<(-0.8):     return .orange
        default:                return .red
        }
    }

    /// Groups consecutive points into runs of the same vario color so the
    /// track renders as a handful of polylines instead of one per segment.
    private static func makeVarioSegments(points: [GPSTrackPoint]) -> [VarioSegment] {
        guard points.count >= 2 else { return [] }

        var segments: [VarioSegment] = []
        var runCoords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: points[0].latitude, longitude: points[0].longitude)
        ]
        var runColor = varioColor(segmentVerticalSpeed(from: points[0], to: points[1]) ?? 0)

        for i in 1..<points.count {
            let coord = CLLocationCoordinate2D(latitude: points[i].latitude, longitude: points[i].longitude)
            let color: Color
            if i < points.count - 1 {
                color = varioColor(segmentVerticalSpeed(from: points[i], to: points[i + 1]) ?? 0)
            } else {
                color = runColor
            }

            runCoords.append(coord)

            if color != runColor {
                segments.append(VarioSegment(id: segments.count, coordinates: runCoords, color: runColor))
                // Start the next run from the current point so lines connect
                runCoords = [coord]
                runColor = color
            }
        }

        if runCoords.count >= 2 {
            segments.append(VarioSegment(id: segments.count, coordinates: runCoords, color: runColor))
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
