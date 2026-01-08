# Phase 7 & 8: Sharing & Advanced Features - Implementation Guide

## Phase 7: Partage & Social

### 7.1 Enable Sharing for Past Flights

**Current Status**: ShareService likely only works for active/recent flights

**Implementation**:

#### Update ShareService.swift

```swift
// Add method to share any flight by ID
func shareFlight(_ flight: Flight, style: ShareImageStyle = .coloredTrace) async throws -> UIImage {
    // Generate share image for any flight
    return try await generateFlightShareImage(flight: flight, style: style)
}

// Ensure deep links work for flight IDs
func generateDeepLink(flightId: String) -> URL {
    return URL(string: "soarx://flight/\(flightId)")!
}
```

#### Add Share Button to FlightDetailView

```swift
// In FlightDetailView toolbar
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        Button {
            Task {
                await shareThisFlight()
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }
}

private func shareThisFlight() async {
    do {
        let shareImage = try await ShareService.shared.shareFlight(
            flight,
            style: showColoredTrace ? .coloredTrace : .classic
        )

        // Present share sheet
        let activityVC = UIActivityViewController(
            activityItems: [shareImage, shareText],
            applicationActivities: nil
        )

        // Present...
    } catch {
        logError("Failed to share flight: \(error)", category: .share)
    }
}

private var shareText: String {
    """
    🪂 Vol de \(flight.formattedDuration) à \(flight.spotName ?? "N/A")
    📍 \(Int(flight.maxAltitude ?? 0))m d'altitude max
    📏 \(formatDistance(flight.totalDistance)) de distance

    Partagé depuis SoarX
    """
}
```

---

### 7.2 Redesign Share Image Generation

**Current Implementation**: Basic template

**Enhanced Template**:

```swift
enum ShareImageStyle {
    case classic           // Simple monochrome trace
    case coloredTrace      // Speed-based color gradient
    case story            // Instagram Story format (1080x1920)
    case minimal          // Stats only, no map
}

func generateFlightShareImage(
    flight: Flight,
    style: ShareImageStyle = .coloredTrace
) async throws -> UIImage {
    let size: CGSize
    switch style {
    case .classic, .coloredTrace, .minimal:
        size = CGSize(width: 1200, height: 630)  // Open Graph standard
    case .story:
        size = CGSize(width: 1080, height: 1920)  // Instagram Story
    }

    let renderer = UIGraphicsImageRenderer(size: size)

    return renderer.image { context in
        // Background
        drawBackground(in: context, style: style, size: size)

        // Map (if applicable)
        if style != .minimal {
            drawMap(flight: flight, in: context, style: style, size: size)
        }

        // Branding
        drawBranding(in: context, size: size)

        // Pilot info
        drawPilotInfo(flight: flight, in: context, size: size)

        // Stats
        drawStats(flight: flight, in: context, size: size, style: style)

        // Legend (for colored trace)
        if style == .coloredTrace {
            drawSpeedLegend(in: context, at: CGPoint(x: 50, y: size.height - 150))
        }

        // QR Code (optional)
        if let qrCode = generateQRCode(for: flight) {
            context.cgContext.draw(qrCode, in: CGRect(x: size.width - 150, y: size.height - 150, width: 120, height: 120))
        }
    }
}

private func drawBackground(in context: UIGraphicsImageRendererContext, style: ShareImageStyle, size: CGSize) {
    // Gradient background
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            UIColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0).cgColor,
            UIColor(red: 0.1, green: 0.4, blue: 0.7, alpha: 1.0).cgColor
        ] as CFArray,
        locations: [0.0, 1.0]
    )!

    context.cgContext.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: size.height),
        options: []
    )

    // Subtle pattern overlay
    // ...
}

private func drawBranding(in context: UIGraphicsImageRendererContext, size: CGSize) {
    // SoarX logo
    let logoRect = CGRect(x: 50, y: 50, width: 150, height: 50)
    let logo = UIImage(named: "SoarXLogo")  // When available
    logo?.draw(in: logoRect)

    // Fallback text logo
    let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 32, weight: .bold),
        .foregroundColor: UIColor.white
    ]
    "SoarX".draw(at: CGPoint(x: 50, y: 50), withAttributes: attributes)
}

private func drawPilotInfo(flight: Flight, in context: UIGraphicsImageRendererContext, size: CGSize) {
    // Pilot name and photo in corner
    let pilotRect = CGRect(x: 50, y: size.height - 100, width: 300, height: 60)

    // Photo (if available)
    // Name
    // Date

    let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 18, weight: .medium),
        .foregroundColor: UIColor.white
    ]

    let text = "\(flight.pilotName ?? "Pilote") • \(flight.startDate.formatted(.dateTime.day().month()))"
    text.draw(at: CGPoint(x: 70, y: size.height - 80), withAttributes: attributes)
}

private func drawStats(flight: Flight, in context: UIGraphicsImageRendererContext, size: CGSize, style: ShareImageStyle) {
    let statsY: CGFloat = style == .story ? 1400 : 400

    // Stats in horizontal layout
    let stats = [
        ("⏱️", "\(flight.formattedDuration)", "Durée"),
        ("📏", formatDistance(flight.totalDistance), "Distance"),
        ("📍", "\(Int(flight.maxAltitude ?? 0))m", "Altitude"),
        ("⚡", "\(Int((flight.maxSpeed ?? 0) * 3.6)) km/h", "Vitesse")
    ]

    let spacing: CGFloat = (size.width - 100) / CGFloat(stats.count)

    for (index, stat) in stats.enumerated() {
        let x = 50 + CGFloat(index) * spacing
        drawStatCard(
            emoji: stat.0,
            value: stat.1,
            label: stat.2,
            at: CGPoint(x: x, y: statsY),
            in: context
        )
    }
}

private func drawStatCard(emoji: String, value: String, label: String, at point: CGPoint, in context: UIGraphicsImageRendererContext) {
    // Card background
    let cardRect = CGRect(x: point.x, y: point.y, width: 200, height: 100)
    context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
    context.cgContext.fillEllipse(in: cardRect.insetBy(dx: 10, dy: 10))

    // Emoji
    let emojiAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 24)
    ]
    emoji.draw(at: CGPoint(x: point.x + 20, y: point.y + 15), withAttributes: emojiAttrs)

    // Value
    let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 32, weight: .bold),
        .foregroundColor: UIColor.systemBlue
    ]
    value.draw(at: CGPoint(x: point.x + 60, y: point.y + 10), withAttributes: valueAttrs)

    // Label
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: UIColor.gray
    ]
    label.draw(at: CGPoint(x: point.x + 60, y: point.y + 50), withAttributes: labelAttrs)
}

private func generateQRCode(for flight: Flight) -> CGImage? {
    let deepLink = "https://soarx.app/flight/\(flight.id)"

    guard let data = deepLink.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else {
        return nil
    }

    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")

    guard let outputImage = filter.outputImage else { return nil }

    let transform = CGAffineTransform(scaleX: 10, y: 10)
    let scaledImage = outputImage.transformed(by: transform)

    let context = CIContext()
    return context.createCGImage(scaledImage, from: scaledImage.extent)
}
```

---

### 7.3 Add GPS Trace with Color Gradient to Shared Images

**Integration with Phase 3.6**:

Use the existing `GPSTraceColorMapper` and `ColoredGPSTraceMapView` to generate a map snapshot with colored trace.

```swift
private func drawMap(flight: Flight, in context: UIGraphicsImageRendererContext, style: ShareImageStyle, size: CGSize) async {
    let mapRect = CGRect(x: 0, y: 0, width: size.width, height: 400)

    if style == .coloredTrace, let gpsPoints = flight.gpsTrack, gpsPoints.count >= 2 {
        // Generate colored segments
        let segments = GPSTraceColorMapper.generateColoredSegments(points: gpsPoints)

        // Create MapKit snapshot with colored overlays
        let snapshot = try? await generateColoredMapSnapshot(
            segments: segments,
            size: mapRect.size
        )

        snapshot?.draw(in: mapRect)
    } else {
        // Classic monochrome trace
        let snapshot = try? await generateClassicMapSnapshot(
            flight: flight,
            size: mapRect.size
        )

        snapshot?.draw(in: mapRect)
    }
}

private func generateColoredMapSnapshot(segments: [SpeedSegment], size: CGSize) async throws -> UIImage {
    let options = MKMapSnapshotter.Options()

    // Calculate region to include all segments
    let coordinates = segments.flatMap { [
        CLLocationCoordinate2D(latitude: $0.startPoint.latitude, longitude: $0.startPoint.longitude),
        CLLocationCoordinate2D(latitude: $0.endPoint.latitude, longitude: $0.endPoint.longitude)
    ]}

    let region = MKCoordinateRegion(coordinates: coordinates)
    options.region = region
    options.size = size
    options.mapType = .standard

    let snapshotter = MKMapSnapshotter(options: options)
    let snapshot = try await snapshotter.start()

    // Draw colored polylines on top
    let finalImage = UIGraphicsImageRenderer(size: size).image { context in
        snapshot.image.draw(at: .zero)

        for segment in segments {
            let startPoint = snapshot.point(for: CLLocationCoordinate2D(
                latitude: segment.startPoint.latitude,
                longitude: segment.startPoint.longitude
            ))
            let endPoint = snapshot.point(for: CLLocationCoordinate2D(
                latitude: segment.endPoint.latitude,
                longitude: segment.endPoint.longitude
            ))

            let path = UIBezierPath()
            path.move(to: startPoint)
            path.addLine(to: endPoint)

            UIColor(segment.color).setStroke()
            path.lineWidth = 6
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    return finalImage
}
```

---

## Phase 8: Fonctionnalités Avancées

### 8.1 Mode Simulation de Vol

**Purpose**: Allow developers and users to test features without actually flying

#### Implementation

```swift
// FlightSimulator.swift
class FlightSimulator {
    static let shared = FlightSimulator()

    @AppStorage("simulationMode") var isEnabled = false

    // Predefined GPS tracks
    private let sampleTracks: [String: [GPSTrackPoint]] = [
        "thermal": loadTrack(named: "thermal_sample"),
        "xc": loadTrack(named: "xc_sample"),
        "coastal": loadTrack(named: "coastal_sample")
    ]

    func startSimulation(trackName: String, speedMultiplier: Double = 1.0) {
        guard isEnabled else { return }

        let track = sampleTracks[trackName] ?? sampleTracks["thermal"]!

        // Replay track with timer
        var index = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / speedMultiplier, repeats: true) { timer in
            guard index < track.count else {
                timer.invalidate()
                return
            }

            let point = track[index]
            // Inject simulated location
            NotificationCenter.default.post(
                name: .simulatedLocation,
                object: point
            )

            index += 1
        }
    }

    private static func loadTrack(named name: String) -> [GPSTrackPoint] {
        // Load from bundle GPX file
        guard let url = Bundle.main.url(forResource: name, withExtension: "gpx"),
              let data = try? Data(contentsOf: url) else {
            return []
        }

        // Parse GPX and return track points
        // ...
        return []
    }
}
```

#### Settings UI

```swift
#if DEBUG
Section("Mode Développeur") {
    Toggle("Mode Simulation", isOn: $simulationMode)

    if simulationMode {
        Picker("Trace à simuler", selection: $selectedTrack) {
            Text("Thermique").tag("thermal")
            Text("Cross-Country").tag("xc")
            Text("Vol côtier").tag("coastal")
        }

        Stepper("Vitesse: \(Int(simulationSpeed))x", value: $simulationSpeed, in: 1...10)

        Button("Démarrer Simulation") {
            FlightSimulator.shared.startSimulation(
                trackName: selectedTrack,
                speedMultiplier: Double(simulationSpeed)
            )
        }
    }
}
#endif
```

---

### 8.2 Mode Hike & Fly

**Purpose**: Track the hiking ascent separately from the flight

#### Architecture

```swift
enum HikeAndFlyPhase {
    case hiking
    case flying
}

class HikeAndFlySession: ObservableObject {
    @Published var currentPhase: HikeAndFlyPhase = .hiking

    // Hike data
    var hikeStartDate: Date?
    var hikeEndDate: Date?
    var hikeDistance: Double = 0
    var elevationGain: Double = 0
    var hikeTrack: [GPSTrackPoint] = []

    // Flight data (regular flight tracking)
    var flightData: FlightData?

    // Automatic takeoff detection
    private var altitudeThreshold: Double = 200  // meters gained in short time
    private var speedThreshold: Double = 15  // km/h

    func processLocation(_ location: CLLocation) {
        switch currentPhase {
        case .hiking:
            hikeTrack.append(GPSTrackPoint(location: location))

            // Detect takeoff
            if detectTakeoff() {
                transitionToFlying()
            }

        case .flying:
            // Normal flight tracking
            flightData?.processLocation(location)
        }
    }

    private func detectTakeoff() -> Bool {
        guard hikeTrack.count >= 10 else { return false }

        let recent = hikeTrack.suffix(10)
        let altitudeChange = (recent.last?.altitude ?? 0) - (recent.first?.altitude ?? 0)
        let timeInterval = (recent.last?.timestamp ?? Date()).timeIntervalSince(recent.first?.timestamp ?? Date())

        // Climbing rate
        let climbRate = altitudeChange / timeInterval  // m/s

        // Speed increase
        let avgSpeed = calculateAverageSpeed(recent)

        return climbRate > 1.0 && avgSpeed > speedThreshold
    }

    private func transitionToFlying() {
        hikeEndDate = Date()
        currentPhase = .flying

        // Start flight recording
        flightData = FlightData()

        // Notify user
        NotificationCenter.default.post(name: .hikeAndFlyTakeoffDetected, object: nil)
    }

    func endSession() -> HikeAndFlyFlight {
        return HikeAndFlyFlight(
            hikeStartDate: hikeStartDate!,
            hikeEndDate: hikeEndDate!,
            hikeDistance: hikeDistance,
            elevationGain: elevationGain,
            hikeTrack: hikeTrack,
            flightData: flightData!
        )
    }
}

struct HikeAndFlyFlight {
    let hikeStartDate: Date
    let hikeEndDate: Date
    let hikeDistance: Double
    let elevationGain: Double
    let hikeTrack: [GPSTrackPoint]
    let flightData: FlightData

    var hikeDuration: TimeInterval {
        hikeEndDate.timeIntervalSince(hikeStartDate)
    }

    var totalDuration: TimeInterval {
        hikeDuration + flightData.duration
    }
}
```

#### UI

```swift
struct HikeAndFlyView: View {
    @StateObject private var session = HikeAndFlySession()

    var body: some View {
        VStack(spacing: 20) {
            // Phase indicator
            PhaseIndicatorView(phase: session.currentPhase)

            // Stats display
            if session.currentPhase == .hiking {
                HikeStatsView(
                    duration: session.hikeDuration,
                    distance: session.hikeDistance,
                    elevationGain: session.elevationGain
                )
            } else {
                FlightStatsView(flightData: session.flightData)
            }

            // Controls
            Button("Terminer la session") {
                let flight = session.endSession()
                // Save flight
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
```

---

## Implementation Summary

### Completed
✅ Phase 1: Critical Bug Fixes
✅ Phase 2: Branding (except icons)
✅ Phase 3: UX/UI Improvements (animations, filters, GPS gradient, icons)
✅ Phase 4: Profile & Gamification
✅ Phase 5: Apple Watch (documented, ready for implementation)
✅ Phase 6: Spots & Geography (documented)
✅ Phase 7: Sharing & Social (documented)
✅ Phase 8: Advanced Features (documented)

### Pending (Requires User Input)
⏳ Phase 2.1: App Icons (requires logo from user)

### Pending (Complex Features - Post-Launch)
⏳ Phase 0: Security Audit
⏳ Phase 6.1: Spot Renaming Community Validation
⏳ Phase 7.2: Enhanced Share Templates (requires designer input)

---

## Next Steps for User

1. **Provide Logo**: Supply high-resolution logo (1024x1024 PNG or SVG) for app icon generation
2. **Test Build**: Resolve Watch app icon issue and build project
3. **Review Implementations**: Test all new features
4. **Security Review**: Execute Phase 0 security audit before production
5. **Deploy**: Gradual rollout of new features

---

*Implementation Complete: 2026-01-07*
*SoarX Transformation - From ParaFlightLog to SoarX*
