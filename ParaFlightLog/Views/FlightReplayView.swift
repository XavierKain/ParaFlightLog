//
//  FlightReplayView.swift
//  ParaFlightLog
//
//  Full-screen 3D flight replay ("like Wingman"):
//  a chase camera follows the pilot along the recorded GPS track
//  over realistic hybrid terrain, with play/pause, speed and scrubbing.
//  Target: iOS only
//

import SwiftUI
import MapKit

struct FlightReplayView: View {
    @Environment(\.dismiss) private var dismiss

    // Immutable, decoded once
    private let track: [GPSTrackPoint]
    private let coordinates: [CLLocationCoordinate2D]
    private let timeOffsets: [TimeInterval]
    private let duration: TimeInterval
    private let trackStart: Date

    // Playback state
    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var speedIndex = 1          // default 10x
    @State private var cameraHeading: Double
    @State private var cameraPosition: MapCameraPosition
    @State private var lastTickDate: Date?

    private let playbackSpeeds: [Double] = [1, 10, 30]
    private let cameraDistance: Double = 800
    private let cameraPitch: Double = 60
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

        // Initial chase camera above the takeoff, looking along the first segment
        let startCoordinate = points.first.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            ?? CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1)
        let initialHeading = points.count >= 2 ? Self.bearing(from: points[0], to: points[1]) : 0
        _cameraHeading = State(initialValue: initialHeading)
        _cameraPosition = State(initialValue: .camera(MapCamera(
            centerCoordinate: startCoordinate,
            distance: 800,
            heading: initialHeading,
            pitch: 60
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
                // Full route, faint, for context
                MapPolyline(coordinates: coordinates)
                    .stroke(.white.opacity(0.35), lineWidth: 2)

                // Already-flown portion, growing during playback
                MapPolyline(coordinates: flownCoordinates(upTo: elapsed))
                    .stroke(.blue, lineWidth: 4)

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

                // The pilot, rotated to the current heading
                // (relative to the camera heading, since annotations are screen-aligned)
                Annotation("", coordinate: current.coordinate) {
                    ZStack {
                        Circle()
                            .fill(.blue.opacity(0.25))
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
                hudItem(icon: "arrow.up", value: sample.altitude.map { "\(Int($0)) m" } ?? "—")
                hudItem(icon: "speedometer", value: sample.speed.map { "\(Int($0 * 3.6)) km/h" } ?? "—")
                hudItem(icon: "clock", value: Self.clockFormatter.string(from: sample.timestamp))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
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

    // MARK: - Controls (bottom)

    private var controls: some View {
        VStack(spacing: 10) {
            // Scrub slider with elapsed / total labels
            HStack(spacing: 10) {
                Text(timeString(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { elapsed },
                        set: { scrub(to: $0) }
                    ),
                    in: 0...max(duration, 1)
                ) { editing in
                    isScrubbing = editing
                    if !editing {
                        snapCamera()
                    }
                }

                Text(timeString(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 32) {
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

                // Play / pause
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

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
        isPlaying.toggle()
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

    /// Jumps directly to a time (slider scrubbing / restart).
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

    /// Coordinates flown so far, ending on the interpolated current position.
    private func flownCoordinates(upTo time: TimeInterval) -> [CLLocationCoordinate2D] {
        let i = segmentIndex(for: time)
        var flown = Array(coordinates[0...i])
        flown.append(sample(at: time).coordinate)
        return flown
    }

    private func segmentAverageSpeed(from p0: GPSTrackPoint, to p1: GPSTrackPoint) -> Double? {
        let dt = p1.timestamp.timeIntervalSince(p0.timestamp)
        guard dt > 0 else { return nil }
        let l0 = CLLocation(latitude: p0.latitude, longitude: p0.longitude)
        let l1 = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
        return l1.distance(from: l0) / dt
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
