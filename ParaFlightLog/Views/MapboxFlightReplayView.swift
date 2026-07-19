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

    /// Style handle captured on load, to drive the live overlays (pilot
    /// symbol + fading comet) from the playback tick.
    @State private var styleMap: MapboxMap?

    /// Tick counter: the pilot symbol moves every tick, the comet geometry /
    /// gradient (heavier) refreshes every 3rd tick (~10 Hz).
    @State private var overlayTick = 0

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

                }
                .mapStyle(.standardSatellite)
                .onStyleLoaded { _ in
                    styleMap = proxy.map
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

            // EXPERIMENTAL elevated-line expression, shared by both layers so
            // the gray context and the colored reveal sit at the SAME altitude.
            // Remove the two lineElevationReference/lineZOffset blocks to fall
            // back to ground-projected lines.
            let altitudeExpression = engine.hasAltitude
                ? Self.progressExpression(stops: altitudeStops())
                : nil

            // 1. Context layer: the WHOLE flight as a faint gray line — in
            //    soaring you criss-cross the same ridge dozens of times; a
            //    fully-colored track becomes unreadable. The context only
            //    hints at where the flight goes.
            var context = LineLayer(id: "pfl-track-context", source: "pfl-track")
            context.lineWidth = .constant(2.5)
            context.lineCap = .constant(.round)
            context.lineJoin = .constant(.round)
            context.lineColor = .constant(StyleColor(UIColor.white.withAlphaComponent(0.28)))
            context.lineEmissiveStrength = .constant(1)
            if let altitudeExpression {
                context.lineElevationReference = .constant(.sea)
                context.lineZOffset = .expression(altitudeExpression)
            }
            try map.addLayer(context)

            // 2. Comet layer: only the LAST ~30 s of flight, vario-colored and
            //    fading out toward its tail — after hours of laps the screen
            //    stays readable (geometry + gradient refreshed from the tick).
            var comet = GeoJSONSource(id: "pfl-comet-src")
            comet.lineMetrics = true
            comet.data = .geometry(Geometry.lineString(LineString([])))
            try map.addSource(comet)

            var cometLayer = LineLayer(id: "pfl-comet", source: "pfl-comet-src")
            cometLayer.lineWidth = .constant(4.5)
            cometLayer.lineCap = .constant(.round)
            cometLayer.lineJoin = .constant(.round)
            cometLayer.lineEmissiveStrength = .constant(1)
            if engine.hasAltitude {
                cometLayer.lineElevationReference = .constant(.sea)
            }
            try map.addLayer(cometLayer)

            // 3. Pilot symbol: a real 3D layer (symbol-z-offset at the GPS
            //    altitude) so the marker rides ON the elevated line instead of
            //    sitting on the ground under it like a view annotation would.
            try map.addImage(Self.pilotIcon(color: .systemGreen), id: "pfl-pilot-climb")
            try map.addImage(Self.pilotIcon(color: .systemRed), id: "pfl-pilot-sink")
            try map.addImage(Self.pilotIcon(color: .systemBlue), id: "pfl-pilot-level")

            var pilotSource = GeoJSONSource(id: "pfl-pilot-src")
            pilotSource.data = .geometry(Geometry.point(Point(engine.rawCoordinates[0])))
            try map.addSource(pilotSource)

            var pilot = SymbolLayer(id: "pfl-pilot", source: "pfl-pilot-src")
            pilot.iconImage = .constant(.name("pfl-pilot-level"))
            pilot.iconAllowOverlap = .constant(true)
            pilot.iconIgnorePlacement = .constant(true)
            if engine.hasAltitude {
                pilot.symbolElevationReference = .constant(.sea)
                pilot.symbolZOffset = .constant(0)
            }
            try map.addLayer(pilot)

            // Seed the overlays at the current playback position.
            updateLiveOverlays(map: map, force: true)
        } catch {
            logWarning("Mapbox replay style setup failed: \(error)", category: .general)
        }
    }

    /// Real flight-seconds of trail kept behind the pilot.
    private let cometWindow: TimeInterval = 30

    /// Moves the pilot symbol (position + altitude + climb/sink icon) and
    /// refreshes the fading comet. The pilot moves every call; the comet
    /// geometry/gradient (heavier: two expressions rebuilt) refreshes every
    /// 3rd tick unless `force`.
    private func updateLiveOverlays(map: MapboxMap?, force: Bool = false) {
        guard let map else { return }
        let sample = engine.interpolate(at: elapsed)

        // Pilot: position, true altitude, vario icon.
        try? map.updateGeoJSONSource(
            withId: "pfl-pilot-src",
            geoJSON: .geometry(Geometry.point(Point(sample.coordinate)))
        )
        if engine.hasAltitude, let altitude = sample.altitude {
            try? map.setLayerProperty(for: "pfl-pilot", property: "symbol-z-offset", value: altitude)
        }
        let vario = sample.verticalSpeed ?? 0
        let icon = vario > 0.3 ? "pfl-pilot-climb" : (vario < -0.3 ? "pfl-pilot-sink" : "pfl-pilot-level")
        try? map.setLayerProperty(for: "pfl-pilot", property: "icon-image", value: icon)

        // Comet (throttled).
        overlayTick += 1
        guard force || overlayTick % 3 == 0 else { return }

        let tailStart = max(0, elapsed - cometWindow)
        guard let trackStart = points.first?.timestamp else { return }
        var window = points.filter {
            let t = $0.timestamp.timeIntervalSince(trackStart)
            return t >= tailStart && t <= elapsed
        }
        // Head of the comet = the interpolated live position.
        window.append(GPSTrackPoint(
            timestamp: trackStart.addingTimeInterval(elapsed),
            latitude: sample.coordinate.latitude,
            longitude: sample.coordinate.longitude,
            altitude: sample.altitude,
            speed: sample.speed
        ))
        guard window.count >= 2 else {
            try? map.updateGeoJSONSource(
                withId: "pfl-comet-src",
                geoJSON: .geometry(Geometry.lineString(LineString([])))
            )
            return
        }

        let coordinates = window.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        try? map.updateGeoJSONSource(
            withId: "pfl-comet-src",
            geoJSON: .geometry(Geometry.lineString(LineString(coordinates)))
        )

        // Per-window gradient (vario color, alpha fading toward the tail) and
        // altitude stops, both over line-progress 0…1.
        let span = max(elapsed - tailStart, 0.001)
        var colorStops: [ProgressStop] = []
        var zStops: [ProgressStop] = []
        var lastAltitude = window.first?.altitude ?? 0
        for point in window {
            let t = point.timestamp.timeIntervalSince(trackStart)
            let fraction = min(max((t - tailStart) / span, 0), 1)
            let pointVario = engine.interpolate(at: t).verticalSpeed ?? 0
            let alpha = 0.08 + 0.92 * fraction
            colorStops.append(ProgressStop(
                progress: fraction,
                value: Self.rgbaString(VarioPalette.color(pointVario), alpha: alpha)
            ))
            if let altitude = point.altitude { lastAltitude = altitude }
            zStops.append(ProgressStop(progress: fraction, value: lastAltitude))
        }
        if let gradient = Self.progressExpression(stops: colorStops),
           let raw = try? JSONEncoder().encode(gradient),
           let json = try? JSONSerialization.jsonObject(with: raw) {
            try? map.setLayerProperty(for: "pfl-comet", property: "line-gradient", value: json)
        }
        if engine.hasAltitude,
           let zExpression = Self.progressExpression(stops: zStops),
           let raw = try? JSONEncoder().encode(zExpression),
           let json = try? JSONSerialization.jsonObject(with: raw) {
            try? map.setLayerProperty(for: "pfl-comet", property: "line-z-offset", value: json)
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
    /// `alpha` overrides the color's own opacity (comet tail fade).
    private static func rgbaString(_ color: Color, alpha: Double? = nil) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, colorAlpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &colorAlpha)
        let a = alpha ?? Double(colorAlpha)
        return String(format: "rgba(%d,%d,%d,%.2f)", Int(red * 255), Int(green * 255), Int(blue * 255), a)
    }

    /// Pilot marker bitmap: white-ringed vario-colored dot with a paraglider
    /// glyph — rendered once per tint and registered as a style image so the
    /// 3D symbol layer can display it at true altitude.
    private static func pilotIcon(color: UIColor) -> UIImage {
        let side: CGFloat = 26
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: side - 4, height: side - 4)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            if let glyph = UIImage(systemName: "parachute.fill", withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(in: CGRect(x: 6.5, y: 6.5, width: 13, height: 13))
            }
        }
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

    // MARK: Controls (bottom)

    private var controls: some View {
        VStack(spacing: 8) {
            AltitudeProfileScrubber(
                profile: engine.altitudeProfile,
                progress: engine.totalDuration > 0 ? elapsed / engine.totalDuration : 0,
                onScrub: { fraction in
                    isScrubbing = true
                    elapsed = fraction * engine.totalDuration
                    updateLiveOverlays(map: styleMap, force: true)
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
        updateLiveOverlays(map: styleMap)
        if follow {
            viewport = followViewport(for: engine.interpolate(at: elapsed))
        }
    }
}

#endif
