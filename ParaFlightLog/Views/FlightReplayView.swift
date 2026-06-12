//
//  FlightReplayView.swift
//  ParaFlightLog
//
//  Replay 2D / 3D de la trace GPS d'un vol (style Wingman) :
//  carte MapKit avec marqueur animé, trace colorée par Vz,
//  contrôles de lecture (play/pause, vitesse, scrubber) et HUD temps réel.
//  Target: iOS only
//

import SwiftUI
import MapKit
import Combine

// MARK: - ReplayCameraMode (Mode de caméra 2D / 3D)

/// Mode de caméra du replay : vue du dessus classique ou caméra 3D qui suit le pilote
private enum ReplayCameraMode: String, CaseIterable, Identifiable {
    case mode2D
    case mode3D

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mode2D: return "2D"
        case .mode3D: return "3D"
        }
    }
}

// MARK: - ReplaySpeed (Vitesse de lecture)

/// Multiplicateurs de vitesse de lecture du replay
private enum ReplaySpeed: Double, CaseIterable, Identifiable {
    case x1 = 1
    case x10 = 10
    case x30 = 30
    case x60 = 60

    var id: Double { rawValue }

    var label: String { "×\(Int(rawValue))" }
}

// MARK: - ReplaySample (État interpolé au temps courant)

/// Valeurs interpolées de la trace au temps de lecture courant
struct ReplaySample {
    let coordinate: CLLocationCoordinate2D
    let altitude: Double?            // Altitude (m)
    let groundSpeed: Double?         // Vitesse sol (m/s)
    let verticalSpeed: Double?       // Vz lissée (m/s)
    let timestamp: Date              // Heure réelle du point
    let heading: CLLocationDirection // Direction de vol (degrés)
    let segmentIndex: Int            // Index du segment en cours (points[i] → points[i+1])
    let segmentFraction: Double      // Progression dans le segment courant (0…1)
}

// MARK: - ReplayEngine (Précalculs + interpolation)

/// Moteur de replay : précalcule les offsets temporels et les Vz lissées,
/// puis fournit un échantillon interpolé linéairement pour un temps donné.
struct ReplayEngine {
    let points: [GPSTrackPoint]
    let offsets: [TimeInterval]      // Temps écoulé de chaque point depuis le décollage
    let verticalSpeeds: [Double?]    // Vz lissée par point (GPSTraceColorMapper)
    let totalDuration: TimeInterval
    let startDate: Date

    /// Segments colorés par Vz, alignés sur les paires de points (exactement count-1 segments)
    let coloredSegments: [SpeedSegment]

    init?(points: [GPSTrackPoint]) {
        guard points.count >= 2, let start = points.first?.timestamp else { return nil }

        let offsets = points.map { $0.timestamp.timeIntervalSince(start) }
        guard let total = offsets.last, total > 0 else { return nil }

        self.points = points
        self.offsets = offsets
        self.totalDuration = total
        self.startDate = start

        let vz = GPSTraceColorMapper.smoothedVerticalSpeeds(points: points)
        self.verticalSpeeds = vz

        // Construire les segments colorés par Vz en garantissant l'alignement
        // segment i ↔ points[i] → points[i+1] (contrairement au mapper qui peut sauter des points)
        var segments: [SpeedSegment] = []
        segments.reserveCapacity(points.count - 1)
        for i in 1..<points.count {
            let segVz: Double?
            switch (vz[i - 1], vz[i]) {
            case let (a?, b?): segVz = (a + b) / 2
            case let (a?, nil): segVz = a
            case let (nil, b?): segVz = b
            default: segVz = nil
            }
            let color = segVz.map { GPSTraceColorMapper.colorForVerticalSpeed($0) }
                ?? GPSTraceColorMapper.neutralVerticalColor
            segments.append(SpeedSegment(
                startPoint: points[i - 1],
                endPoint: points[i],
                speed: segVz ?? 0,
                color: color
            ))
        }
        self.coloredSegments = segments
    }

    /// Échantillon interpolé linéairement au temps `elapsed` (clampé à la durée du vol)
    func sample(at elapsed: TimeInterval) -> ReplaySample {
        let t = min(max(elapsed, 0), totalDuration)

        // Recherche binaire de l'index i tel que offsets[i] <= t <= offsets[i+1]
        var lo = 0
        var hi = points.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if offsets[mid] <= t { lo = mid } else { hi = mid }
        }
        let i = lo
        let p0 = points[i]
        let p1 = points[i + 1]
        let dt = offsets[i + 1] - offsets[i]
        let f = dt > 0 ? (t - offsets[i]) / dt : 0

        // Position interpolée
        let lat = p0.latitude + (p1.latitude - p0.latitude) * f
        let lon = p0.longitude + (p1.longitude - p0.longitude) * f

        // Altitude interpolée (gère les vols sans altitude → nil)
        let altitude: Double?
        switch (p0.altitude, p1.altitude) {
        case let (a?, b?): altitude = a + (b - a) * f
        case let (a?, nil): altitude = a
        case let (nil, b?): altitude = b
        default: altitude = nil
        }

        // Vitesse sol : capteur GPS si disponible, sinon distance/temps du segment
        let groundSpeed: Double?
        switch (p0.speed, p1.speed) {
        case let (a?, b?): groundSpeed = a + (b - a) * f
        case let (a?, nil): groundSpeed = a
        case let (nil, b?): groundSpeed = b
        default:
            if dt > 0 {
                let distance = GPSDistanceCalculator.haversineDistance(
                    lat1: p0.latitude, lon1: p0.longitude,
                    lat2: p1.latitude, lon2: p1.longitude
                )
                groundSpeed = distance / dt
            } else {
                groundSpeed = nil
            }
        }

        // Vz lissée interpolée
        let vz: Double?
        switch (verticalSpeeds[i], verticalSpeeds[i + 1]) {
        case let (a?, b?): vz = a + (b - a) * f
        case let (a?, nil): vz = a
        case let (nil, b?): vz = b
        default: vz = nil
        }

        return ReplaySample(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: altitude,
            groundSpeed: groundSpeed,
            verticalSpeed: vz,
            timestamp: startDate.addingTimeInterval(t),
            heading: Self.bearing(from: p0, to: p1),
            segmentIndex: i,
            segmentFraction: f
        )
    }

    /// Cap (degrés 0…360) entre deux points GPS — direction de vol
    static func bearing(from a: GPSTrackPoint, to b: GPSTrackPoint) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - ReplayPilotAnnotation (Annotation du parapente)

/// Annotation déplaçable du pilote — `dynamic` pour que MapKit suive les mises à jour
private final class ReplayPilotAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

// MARK: - ReplayFadedPolyline (Trace complète estompée)

/// Polyline de fond : trace complète affichée en gris estompé
private final class ReplayFadedPolyline: MKPolyline {}

// MARK: - ReplayMapView (Carte MapKit du replay)

/// Carte UIKit du replay : trace estompée + portion parcourue colorée par Vz,
/// marqueur animé et caméra 3D qui suit le pilote.
private struct ReplayMapView: UIViewRepresentable {
    let engine: ReplayEngine
    let sample: ReplaySample
    let cameraMode: ReplayCameraMode

    /// Région englobant toute la trace (mode 2D)
    private var fullRegion: MKCoordinateRegion {
        let lats = engine.points.map { $0.latitude }
        let lons = engine.points.map { $0.longitude }
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.005, (maxLat - minLat) * 1.3),
                longitudeDelta: max(0.005, (maxLon - minLon) * 1.3)
            )
        )
    }

    /// Distance caméra 3D adaptée à l'étendue de la trace
    private var cameraDistance: CLLocationDistance {
        let lats = engine.points.map { $0.latitude }
        let lons = engine.points.map { $0.longitude }
        let diagonal = GPSDistanceCalculator.haversineDistance(
            lat1: lats.min() ?? 0, lon1: lons.min() ?? 0,
            lat2: lats.max() ?? 0, lon2: lons.max() ?? 0
        )
        return min(max(diagonal * 0.6, 900), 6000)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.pointOfInterestFilter = .excludingAll

        // Trace complète estompée en fond
        let coordinates = engine.points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        mapView.addOverlay(ReplayFadedPolyline(coordinates: coordinates, count: coordinates.count))

        // Marqueur du pilote
        let annotation = ReplayPilotAnnotation(coordinate: sample.coordinate)
        context.coordinator.pilotAnnotation = annotation
        mapView.addAnnotation(annotation)

        applyConfiguration(to: mapView, coordinator: context.coordinator, animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Changement de mode 2D / 3D
        if coordinator.lastMode != cameraMode {
            applyConfiguration(to: mapView, coordinator: coordinator, animated: true)
        }

        // Déplacer le marqueur (KVO → animation MapKit fluide)
        coordinator.pilotAnnotation?.coordinate = sample.coordinate

        // Mettre à jour la portion colorée déjà parcourue
        updateProgressOverlays(on: mapView, coordinator: coordinator)

        // Caméra 3D : suit le marqueur avec heading lissé
        if cameraMode == .mode3D {
            let heading = coordinator.smoothedHeading(toward: sample.heading)
            let camera = MKMapCamera(
                lookingAtCenter: sample.coordinate,
                fromDistance: cameraDistance,
                pitch: 60,
                heading: heading
            )
            mapView.camera = camera
        }
    }

    /// Applique la configuration carte + caméra selon le mode
    private func applyConfiguration(to mapView: MKMapView, coordinator: Coordinator, animated: Bool) {
        coordinator.lastMode = cameraMode
        switch cameraMode {
        case .mode2D:
            // Vue du dessus classique sur toute la trace
            mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
            mapView.isPitchEnabled = false
            let camera = MKMapCamera()
            camera.centerCoordinate = fullRegion.center
            camera.pitch = 0
            camera.heading = 0
            mapView.camera = camera
            mapView.setRegion(fullRegion, animated: animated)
        case .mode3D:
            // Imagerie satellite photoréaliste + relief 3D (rendu type Surfr/Wingman),
            // caméra inclinée qui suit le pilote.
            // NB : le simulateur charge ces tuiles en très basse résolution — sur un
            // vrai appareil le rendu est photoréaliste.
            mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            mapView.isPitchEnabled = true
            coordinator.headingValue = sample.heading
            let camera = MKMapCamera(
                lookingAtCenter: sample.coordinate,
                fromDistance: cameraDistance,
                pitch: 60,
                heading: sample.heading
            )
            mapView.setCamera(camera, animated: animated)
        }
    }

    /// Ajoute/retire incrémentalement les segments colorés déjà parcourus
    /// + un segment partiel jusqu'à la position interpolée du pilote.
    private func updateProgressOverlays(on mapView: MKMapView, coordinator: Coordinator) {
        let target = min(sample.segmentIndex, engine.coloredSegments.count)

        // Avancer : ajouter les segments complets nouvellement parcourus
        while coordinator.progressOverlays.count < target {
            let segment = engine.coloredSegments[coordinator.progressOverlays.count]
            let coords = [
                CLLocationCoordinate2D(latitude: segment.startPoint.latitude, longitude: segment.startPoint.longitude),
                CLLocationCoordinate2D(latitude: segment.endPoint.latitude, longitude: segment.endPoint.longitude)
            ]
            let polyline = ColoredPolyline(coordinates: coords, count: 2)
            polyline.color = UIColor(segment.color)
            coordinator.progressOverlays.append(polyline)
            mapView.addOverlay(polyline, level: .aboveRoads)
        }

        // Reculer (scrub arrière) : retirer les segments en trop
        while coordinator.progressOverlays.count > target {
            if let last = coordinator.progressOverlays.popLast() {
                mapView.removeOverlay(last)
            }
        }

        // Segment partiel : du début du segment courant jusqu'au pilote
        if let partial = coordinator.partialOverlay {
            mapView.removeOverlay(partial)
            coordinator.partialOverlay = nil
        }
        if sample.segmentIndex < engine.coloredSegments.count, sample.segmentFraction > 0 {
            let segment = engine.coloredSegments[sample.segmentIndex]
            let coords = [
                CLLocationCoordinate2D(latitude: segment.startPoint.latitude, longitude: segment.startPoint.longitude),
                sample.coordinate
            ]
            let polyline = ColoredPolyline(coordinates: coords, count: 2)
            polyline.color = UIColor(segment.color)
            coordinator.partialOverlay = polyline
            mapView.addOverlay(polyline, level: .aboveRoads)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var pilotAnnotation: ReplayPilotAnnotation?
        var progressOverlays: [ColoredPolyline] = []
        var partialOverlay: ColoredPolyline?
        var lastMode: ReplayCameraMode?
        var headingValue: CLLocationDirection = 0
        private var pilotImage: UIImage?

        /// Lissage exponentiel du heading (gère le passage 359° → 0°)
        func smoothedHeading(toward target: CLLocationDirection) -> CLLocationDirection {
            var delta = (target - headingValue).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            headingValue = (headingValue + delta * 0.12 + 360).truncatingRemainder(dividingBy: 360)
            return headingValue
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let faded = overlay as? ReplayFadedPolyline {
                let renderer = MKPolylineRenderer(polyline: faded)
                renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.45)
                renderer.lineWidth = 3
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let polyline = overlay as? ColoredPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.color
                renderer.lineWidth = 4.5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is ReplayPilotAnnotation else { return nil }

            let identifier = "replayPilot"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.image = makePilotImage()
            view.zPriority = .max
            view.collisionMode = .none
            view.canShowCallout = false
            return view
        }

        /// Image du marqueur : pastille blanche avec le symbole parapente orange (mise en cache)
        private func makePilotImage() -> UIImage {
            if let cached = pilotImage { return cached }

            let size = CGSize(width: 38, height: 38)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { _ in
                let circleRect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
                UIColor.systemBackground.withAlphaComponent(0.95).setFill()
                UIBezierPath(ovalIn: circleRect).fill()
                UIColor.systemOrange.setStroke()
                let stroke = UIBezierPath(ovalIn: circleRect)
                stroke.lineWidth = 2.5
                stroke.stroke()

                let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
                if let symbol = UIImage(systemName: "figure.paragliding", withConfiguration: config)?
                    .withTintColor(.systemOrange, renderingMode: .alwaysOriginal) {
                    let symbolRect = CGRect(
                        x: (size.width - symbol.size.width) / 2,
                        y: (size.height - symbol.size.height) / 2,
                        width: symbol.size.width,
                        height: symbol.size.height
                    )
                    symbol.draw(in: symbolRect)
                }
            }
            pilotImage = image
            return image
        }
    }
}

// MARK: - FlightReplayView (Replay plein écran d'un vol)

/// Vue plein écran qui rejoue la trace GPS d'un vol en 2D ou 3D,
/// avec contrôles de lecture et HUD temps réel (altitude, vitesse, Vz).
struct FlightReplayView: View {
    @Environment(\.dismiss) private var dismiss
    let flight: Flight

    private let engine: ReplayEngine?

    // État de lecture
    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var speed: ReplaySpeed = .x10
    @State private var cameraMode: ReplayCameraMode = .mode3D
    @State private var lastTick: Date?

    /// Ticker d'affichage ~30 fps pour une animation fluide
    private let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    init(flight: Flight) {
        self.flight = flight
        self.engine = ReplayEngine(points: flight.gpsTrack ?? [])
    }

    var body: some View {
        ZStack {
            if let engine {
                replayContent(engine: engine)
            } else {
                noTrackContent
            }
        }
        .background(Color(.systemBackground))
        .onReceive(ticker) { now in
            advancePlayback(now: now)
        }
    }

    // MARK: - Contenu principal

    @ViewBuilder
    private func replayContent(engine: ReplayEngine) -> some View {
        let sample = engine.sample(at: elapsed)

        ZStack {
            ReplayMapView(engine: engine, sample: sample, cameraMode: cameraMode)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                hud(sample: sample)
                Spacer()
                playbackControls(engine: engine)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    /// Barre supérieure : fermer + toggle 2D/3D
    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .accessibilityLabel(String(localized: "Fermer"))

            Spacer()

            Picker(String(localized: "Mode caméra"), selection: $cameraMode) {
                ForEach(ReplayCameraMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// HUD temps réel : heure, altitude, vitesse sol, Vz colorée
    private func hud(sample: ReplaySample) -> some View {
        HStack(spacing: 0) {
            hudItem(
                title: String(localized: "Heure"),
                value: sample.timestamp.formatted(date: .omitted, time: .shortened),
                color: .primary
            )
            Divider().frame(height: 30)
            hudItem(
                title: String(localized: "Altitude"),
                value: sample.altitude.map { "\(Int($0)) m" } ?? "—",
                color: .blue
            )
            Divider().frame(height: 30)
            hudItem(
                title: String(localized: "Vitesse"),
                value: sample.groundSpeed.map { "\(Int($0 * 3.6)) km/h" } ?? "—",
                color: .purple
            )
            Divider().frame(height: 30)
            hudItem(
                title: "Vz",
                value: sample.verticalSpeed.map { String(format: "%+.1f m/s", $0) } ?? "—",
                color: sample.verticalSpeed.map {
                    GPSTraceColorMapper.colorForVerticalSpeed($0)
                } ?? .secondary
            )
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func hudItem(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    /// Contrôles de lecture : scrubber, temps, play/pause, vitesses
    private func playbackControls(engine: ReplayEngine) -> some View {
        VStack(spacing: 10) {
            // Scrubber sur la durée du vol
            Slider(
                value: $elapsed,
                in: 0...engine.totalDuration
            ) { editing in
                // Pause pendant le scrub pour un contrôle précis
                if editing { isPlaying = false }
            }
            .tint(.orange)

            // Temps écoulé / restant
            HStack {
                Text(formatTime(elapsed))
                Spacer()
                Text("-" + formatTime(engine.totalDuration - elapsed))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                // Play / pause (relance depuis le début si le vol est terminé)
                Button {
                    if !isPlaying && elapsed >= engine.totalDuration {
                        elapsed = 0
                    }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                }
                .accessibilityLabel(isPlaying ? String(localized: "Pause") : String(localized: "Lecture"))

                Spacer()

                // Vitesses de lecture ×1 ×10 ×30 ×60
                ForEach(ReplaySpeed.allCases) { value in
                    Button {
                        speed = value
                    } label: {
                        Text(value.label)
                            .font(.subheadline.weight(speed == value ? .bold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                speed == value ? Color.orange.opacity(0.25) : Color.clear,
                                in: Capsule()
                            )
                            .foregroundStyle(speed == value ? .orange : .secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Message affiché si la trace est insuffisante (< 2 points ou durée nulle)
    private var noTrackContent: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                String(localized: "Replay indisponible"),
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                description: Text(String(localized: "Ce vol ne contient pas assez de points GPS pour être rejoué."))
            )
            Button(String(localized: "Fermer")) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Lecture

    /// Avance la lecture au rythme réel × multiplicateur (appelé ~30 fps)
    private func advancePlayback(now: Date) {
        guard let engine else { return }

        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now

        guard isPlaying, dt > 0 else { return }

        let next = elapsed + dt * speed.rawValue
        if next >= engine.totalDuration {
            elapsed = engine.totalDuration
            isPlaying = false
        } else {
            elapsed = next
        }
    }

    /// Formate une durée en h:mm:ss ou mm:ss
    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
