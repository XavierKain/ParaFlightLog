//
//  MapboxFlightReplayView.swift
//  ParaFlightLog
//
//  Mapbox-powered 3D flight replay: satellite imagery + 3D terrain
//  (raster-DEM) and — the thing MapKit cannot do — the track drawn as an
//  ELEVATED line at its true GPS altitude, colored by vertical speed
//  (climb green → sink red). Free camera: pinch to zoom, two-finger drag
//  to tilt, rotate to orbit (Mapbox native gestures); a follow mode chases
//  the pilot and any gesture hands the camera back to the user.
//
//  Playback (interpolation, vario, heading, altitude profile) reuses the
//  pure ReplayEngine — this file is only the Mapbox presentation.
//
//  The whole file compiles ONLY when the MapboxMaps SPM package is linked
//  (see MAPBOX_SETUP.md); ReplayLauncherView falls back to the MapKit
//  replay otherwise. `lineZOffset` / elevated lines are experimental
//  Mapbox API (@_spi) — if a future SDK bump breaks them, drop the two
//  lines flagged EXPERIMENTAL below and the replay degrades to a
//  ground-projected gradient line.
//  Target: iOS only
//

#if canImport(MapboxMaps)

import SwiftUI
import CoreLocation
import Combine
import UIKit
@_spi(Experimental) import MapboxMaps

struct MapboxFlightReplayView: View {
    @Environment(\.dismiss) private var dismiss

    private let engine: ReplayEngine
    private let points: [GPSTrackPoint]
    private let hasTrack: Bool

    // Playback
    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var speedIndex = 2               // default 10x
    @State private var lastTickDate: Date?
    @State private var playbackTimer: AnyCancellable?

    // Camera
    @State private var viewport: Viewport
    /// True while the camera chases the pilot. Any user gesture sets the
    /// viewport to .idle — we detect that and flip this off.
    @State private var follow = false
    @State private var didFlyIn = false

    private let playbackSpeeds: [Double] = [1, 4, 10, 30]
    private let tickInterval: TimeInterval = 1.0 / 30.0
    private let followPitch: CGFloat = 62
    private let followZoom: CGFloat = 14.5

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Init

    init(points: [GPSTrackPoint]) {
        // The SDK reads the token once from this global (v11 API).
        MapboxOptions.accessToken = MapboxReplayConfig.accessToken

        let engine = ReplayEngine(points: points)
        self.engine = engine
        self.points = points
        self.hasTrack = engine.rawCoordinates.count >= 2

        _viewport = State(initialValue: .overview(
            geometry: LineString(engine.rawCoordinates),
            geometryPadding: EdgeInsets(top: 80, leading: 40, bottom: 160, trailing: 40)
        ))
    }

    var body: some View {
        Group {
            if hasTrack {
                replayContent
            } else {
                emptyState
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Content

    private var replayContent: some View {
        let current = engine.interpolate(at: elapsed)

        return ZStack {
            MapReader { proxy in
                Map(viewport: $viewport) {
                    // Takeoff / landing markers.
                    if let first = engine.rawCoordinates.first {
                        MapViewAnnotation(coordinate: first) {
                            markerBadge(system: "flag.fill", tint: .green)
                        }
                        .allowOverlap(true)
                    }
                    if let last = engine.rawCoordinates.last {
                        MapViewAnnotation(coordinate: last) {
                            markerBadge(system: "flag.checkered", tint: .red)
                        }
                        .allowOverlap(true)
                    }

                    // The pilot.
                    MapViewAnnotation(coordinate: current.coordinate) {
                        pilotBadge(current)
                    }
                    .allowOverlap(true)
                }
                .mapStyle(.standardSatellite)
                .onStyleLoaded { _ in
                    configureStyle(proxy.map)
                }
                .onChange(of: viewport.isIdle) { _, idle in
                    // Any gesture idles the viewport → the user owns the camera.
                    if idle { follow = false }
                }
            }
            .ignoresSafeArea()

            VStack {
                hud(for: current)
                Spacer()
                controls
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
        .sensoryFeedback(.selection, trigger: speedIndex)
        .onChange(of: isPlaying) { _, _ in syncTimer() }
        .onAppear { scheduleFlyIn() }
        .onDisappear { playbackTimer?.cancel() }
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

    // MARK: Style (terrain + elevated vario line)

    private func configureStyle(_ map: MapboxMap?) {
        guard let map else { return }
        do {
            // 3D terrain.
            var dem = RasterDemSource(id: "pfl-dem")
            dem.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
            dem.tileSize = 514
            dem.maxzoom = 14
            try map.addSource(dem)
            var terrain = Terrain(sourceId: "pfl-dem")
            terrain.exaggeration = .constant(MapboxReplayConfig.terrainExaggeration)
            try map.setTerrain(terrain)

            // The full track as ONE line with distance metrics, so both the
            // vario gradient and the altitude offset can ride line-progress.
            var source = GeoJSONSource(id: "pfl-track")
            source.lineMetrics = true
            source.data = .geometry(Geometry.lineString(LineString(engine.rawCoordinates)))
            try map.addSource(source)

            var layer = LineLayer(id: "pfl-track-line", source: "pfl-track")
            layer.lineWidth = .constant(4)
            layer.lineCap = .constant(.round)
            layer.lineJoin = .constant(.round)
            layer.lineEmissiveStrength = .constant(1)
            if let gradient = Self.progressExpression(stops: varioColorStops()) {
                layer.lineGradient = .expression(gradient)
            } else {
                layer.lineColor = .constant(StyleColor(.systemBlue))
            }
            // EXPERIMENTAL: elevate the line to its true GPS altitude (MSL).
            // Remove these two lines to fall back to a ground-projected line.
            if engine.hasAltitude, let altitude = Self.progressExpression(stops: altitudeStops()) {
                layer.lineElevationReference = .constant(.sea)
                layer.lineZOffset = .expression(altitude)
            }
            try map.addLayer(layer)
        } catch {
            logWarning("Mapbox replay style setup failed: \(error)", category: .general)
        }
    }

    /// Per-track stops along line-progress (distance fraction 0…1), sampled
    /// at ≤64 evenly-spaced points: (progress, altitude MSL, vario color).
    private struct ProgressStop {
        let progress: Double
        let value: Any // Double (altitude) or String (rgba color)
    }

    /// Cumulative distance fraction for every raw point.
    private func distanceFractions() -> [Double] {
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(points.count)
        var total: Double = 0
        for index in 1..<points.count {
            let a = CLLocation(latitude: points[index - 1].latitude, longitude: points[index - 1].longitude)
            let b = CLLocation(latitude: points[index].latitude, longitude: points[index].longitude)
            total += b.distance(from: a)
            cumulative.append(total)
        }
        guard total > 0 else { return cumulative.map { _ in 0 } }
        return cumulative.map { $0 / total }
    }

    /// ≤64 sampled indices spread over the whole track.
    private func sampleIndices() -> [Int] {
        let maxStops = 64
        guard points.count > maxStops else { return Array(points.indices) }
        let stride = Double(points.count - 1) / Double(maxStops - 1)
        return (0..<maxStops).map { Int((Double($0) * stride).rounded()) }
    }

    private func altitudeStops() -> [ProgressStop] {
        let fractions = distanceFractions()
        var lastAltitude: Double = 0
        return sampleIndices().map { index in
            if let altitude = points[index].altitude { lastAltitude = altitude }
            return ProgressStop(progress: fractions[index], value: lastAltitude)
        }
    }

    private func varioColorStops() -> [ProgressStop] {
        let fractions = distanceFractions()
        guard let start = points.first?.timestamp else { return [] }
        return sampleIndices().map { index in
            let time = points[index].timestamp.timeIntervalSince(start)
            let vario = engine.interpolate(at: time).verticalSpeed ?? 0
            return ProgressStop(progress: fractions[index], value: Self.rgbaString(VarioPalette.color(vario)))
        }
    }

    /// Builds `["interpolate", ["linear"], ["line-progress"], p0, v0, …]`
    /// from raw stops (strictly increasing progress enforced). Built via
    /// JSON → Expression decoding, which sidesteps the result-builder DSL
    /// for dynamic stop lists. Nil when fewer than 2 valid stops remain.
    private static func progressExpression(stops: [ProgressStop]) -> Exp? {
        var raw: [Any] = ["interpolate", ["linear"], ["line-progress"]]
        var lastProgress = -1.0
        var count = 0
        for stop in stops {
            let progress = min(max(stop.progress, 0), 1)
            guard progress > lastProgress + 0.0001 else { continue }
            lastProgress = progress
            raw.append(progress)
            raw.append(stop.value)
            count += 1
        }
        guard count >= 2,
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let expression = try? JSONDecoder().decode(Exp.self, from: data) else {
            return nil
        }
        return expression
    }

    /// SwiftUI Color → "rgba(r,g,b,a)" string for style expressions.
    private static func rgbaString(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "rgba(%d,%d,%d,%.2f)", Int(red * 255), Int(green * 255), Int(blue * 255), alpha)
    }

    // MARK: Camera

    /// Opening move: overview → dive down to the takeoff after a beat.
    private func scheduleFlyIn() {
        guard !didFlyIn else { return }
        didFlyIn = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            follow = true
            let start = engine.interpolate(at: 0)
            withViewportAnimation(.fly(duration: 2.2)) {
                viewport = followViewport(for: start)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                isPlaying = true
            }
        }
    }

    private func followViewport(for sample: ReplaySample) -> Viewport {
        .camera(
            center: sample.coordinate,
            zoom: followZoom,
            bearing: sample.heading,
            pitch: followPitch
        )
    }

    // MARK: HUD

    private func hud(for sample: ReplaySample) -> some View {
        HStack(spacing: 6) {
            hudChip(icon: "mountain.2.fill",
                    text: sample.altitude.map { "\(Int($0)) m" } ?? "—", width: 78)
            varioChip(sample.verticalSpeed)
            hudChip(icon: "clock",
                    text: Self.clockFormatter.string(from: engine.trackStart.addingTimeInterval(elapsed)),
                    width: 86)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
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
        let vario = verticalSpeed ?? 0
        return HStack(spacing: 3) {
            Image(systemName: vario >= 0 ? "arrow.up" : "arrow.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(VarioPalette.color(vario))
            Text(String(format: "%+.1f m/s", vario))
                .font(.footnote.monospacedDigit()).fontWeight(.semibold)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: 92, height: 34)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Badges

    private func markerBadge(system: String, tint: Color) -> some View {
        Image(systemName: system)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(4)
            .background(.ultraThinMaterial, in: Circle())
    }

    private func pilotBadge(_ sample: ReplaySample) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.35)).frame(width: 44, height: 44)
            Circle()
                .stroke(VarioPalette.color(sample.verticalSpeed ?? 0), lineWidth: 3)
                .frame(width: 44, height: 44)
            Image(systemName: "parachute.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }

    // MARK: Controls (bottom)

    private var controls: some View {
        VStack(spacing: 8) {
            AltitudeProfileScrubber(
                profile: engine.altitudeProfile,
                progress: engine.totalDuration > 0 ? elapsed / engine.totalDuration : 0,
                onScrub: { fraction in
                    isScrubbing = true
                    elapsed = fraction * engine.totalDuration
                },
                onScrubEnd: { isScrubbing = false }
            )
            .frame(height: 56)
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button {
                    if elapsed >= engine.totalDuration { elapsed = 0 }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    speedIndex = (speedIndex + 1) % playbackSpeeds.count
                } label: {
                    Text("\(Int(playbackSpeeds[speedIndex]))×")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .frame(width: 52, height: 34)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                // Camera: recenter/follow toggle + whole-flight overview.
                Button {
                    follow = true
                    withViewportAnimation(.easeOut(duration: 0.8)) {
                        viewport = followViewport(for: engine.interpolate(at: elapsed))
                    }
                } label: {
                    Image(systemName: follow ? "location.fill" : "location")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 34)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(follow ? Color.blue : Color.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Follow the pilot")

                Button {
                    follow = false
                    withViewportAnimation(.easeOut(duration: 0.9)) {
                        viewport = .overview(
                            geometry: LineString(engine.rawCoordinates),
                            geometryPadding: EdgeInsets(top: 80, leading: 40, bottom: 160, trailing: 40)
                        )
                    }
                } label: {
                    Image(systemName: "map")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 34)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Whole flight overview")
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    // MARK: Playback loop

    private func syncTimer() {
        if isPlaying && playbackTimer == nil {
            lastTickDate = Date()
            playbackTimer = Timer.publish(every: tickInterval, on: .main, in: .common)
                .autoconnect()
                .sink { now in tick(now: now) }
        } else if !isPlaying {
            playbackTimer?.cancel()
            playbackTimer = nil
            lastTickDate = nil
        }
    }

    private func tick(now: Date) {
        guard isPlaying, !isScrubbing else { lastTickDate = now; return }
        let dt = lastTickDate.map { now.timeIntervalSince($0) } ?? tickInterval
        lastTickDate = now
        elapsed = min(elapsed + dt * playbackSpeeds[speedIndex], engine.totalDuration)
        if elapsed >= engine.totalDuration {
            isPlaying = false
        }
        if follow {
            viewport = followViewport(for: engine.interpolate(at: elapsed))
        }
    }
}

#endif
