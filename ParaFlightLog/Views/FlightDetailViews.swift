//
//  FlightDetailViews.swift
//  ParaFlightLog
//
//  Flight detail sheet + GPX/IGC share + detail stat cards.
//  Split from FlightsViews.swift (Lot C).
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit
import UIKit

// MARK: - FlightDetailView (flight detail)

struct FlightDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let flight: Flight

    @State private var showingEditSheet = false
    @State private var showingReplay = false
    @State private var exportedFile: ExportedTrackFile?
    @State private var exportErrorMessage: String?

    private enum TrackExportFormat {
        case gpx, igc
    }

    // Region showing the whole GPS track
    private var mapRegion: MKCoordinateRegion {
        if let track = flight.gpsTrack, !track.isEmpty {
            let lats = track.map { $0.latitude }
            let lons = track.map { $0.longitude }
            let minLat = lats.min() ?? 0
            let maxLat = lats.max() ?? 0
            let minLon = lons.min() ?? 0
            let maxLon = lons.max() ?? 0

            let centerLat = (minLat + maxLat) / 2
            let centerLon = (minLon + maxLon) / 2
            let spanLat = max(0.01, (maxLat - minLat) * 1.3)
            let spanLon = max(0.01, (maxLon - minLon) * 1.3)

            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            )
        } else if let lat = flight.latitude, let lon = flight.longitude {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
            span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
        )
    }

    /// One speed-coloured chunk of the GPS track.
    private struct TrackSegment {
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    /// Splits the track into ~120 chunks coloured by their average ground
    /// speed (green = slow … red = fast, scaled between the track's 5th and
    /// 95th speed percentiles so outliers don't flatten the gradient).
    /// Returns nil when too few points carry a speed — the caller then draws
    /// the classic single blue line.
    private static func speedSegments(_ track: [GPSTrackPoint], maxSegments: Int = 120) -> [TrackSegment]? {
        let speeds = track.compactMap(\.speed)
        guard track.count >= 4, speeds.count >= track.count / 2 else { return nil }

        let sorted = speeds.sorted()
        let low = sorted[Int(Double(sorted.count - 1) * 0.05)]
        let high = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let span = max(high - low, 0.1)

        let chunkSize = max(2, track.count / maxSegments)
        var segments: [TrackSegment] = []
        var start = 0
        while start < track.count - 1 {
            // Overlap by one point so consecutive segments join seamlessly.
            let end = min(start + chunkSize, track.count - 1)
            let chunk = Array(track[start...end])
            let chunkSpeeds = chunk.compactMap(\.speed)
            let average = chunkSpeeds.isEmpty
                ? low
                : chunkSpeeds.reduce(0, +) / Double(chunkSpeeds.count)
            let t = min(max((average - low) / span, 0), 1)
            // Hue 0.33 (green) → 0.0 (red).
            let color = Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9)
            segments.append(TrackSegment(
                coordinates: chunk.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                color: color
            ))
            start = end
        }
        return segments.isEmpty ? nil : segments
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Map with the GPS track, or a simple marker
                    if flight.gpsTrack != nil || (flight.latitude != nil && flight.longitude != nil) {
                        Map(initialPosition: .region(mapRegion)) {
                            // Show the GPS track when available, coloured by
                            // ground speed (green → yellow → red). Falls back
                            // to a single blue line when no speeds were logged.
                            if let track = flight.gpsTrack, track.count >= 2 {
                                if let segments = Self.speedSegments(track) {
                                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                        MapPolyline(coordinates: segment.coordinates)
                                            .stroke(segment.color, lineWidth: 3)
                                    }
                                } else {
                                    MapPolyline(coordinates: track.map {
                                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                    })
                                    .stroke(.blue, lineWidth: 3)
                                }

                                // Takeoff marker (green)
                                if let first = track.first {
                                    Marker("Takeoff", systemImage: "flag.fill", coordinate:
                                        CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                                        .tint(.green)
                                }

                                // Landing marker (red)
                                if let last = track.last {
                                    Marker("Landing", systemImage: "flag.checkered", coordinate:
                                        CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                                        .tint(.red)
                                }
                            } else if let lat = flight.latitude, let lon = flight.longitude {
                                Marker(flight.spotName ?? "Flight", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                                    .tint(.blue)
                            }
                        }
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)

                        // GPS track info + replay
                        if let track = flight.gpsTrack, !track.isEmpty {
                            HStack {
                                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                    .foregroundStyle(.blue)
                                Text("\(track.count) GPS points recorded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)

                            if track.count >= 2 {
                                Button {
                                    showingReplay = true
                                } label: {
                                    Label("Replay Flight", systemImage: "play.circle.fill")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(.horizontal)
                            }
                        }
                    }

                    // Main info
                    VStack(spacing: 16) {
                        // Duration, large
                        VStack(spacing: 4) {
                            Text("Flight duration")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(flight.durationFormatted)
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(.blue)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        // Flight statistics (right below the duration)
                        if flight.startAltitude != nil || flight.maxAltitude != nil || flight.endAltitude != nil ||
                           flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Flight statistics")
                                    .font(.headline)

                                VStack(spacing: 8) {
                                    // Altitudes
                                    if flight.startAltitude != nil || flight.maxAltitude != nil || flight.endAltitude != nil {
                                        HStack(spacing: 8) {
                                            if let alt = flight.startAltitude {
                                                DetailStatCard(title: "Takeoff alt.", value: "\(Int(alt)) m", color: .orange, icon: "arrow.up.circle")
                                            }
                                            if let alt = flight.maxAltitude {
                                                DetailStatCard(title: "Max alt.", value: "\(Int(alt)) m", color: .red, icon: "arrow.up")
                                            }
                                            if let alt = flight.endAltitude {
                                                DetailStatCard(title: "Landing alt.", value: "\(Int(alt)) m", color: .orange, icon: "arrow.down.circle")
                                            }
                                        }
                                    }

                                    // Distance and speed
                                    HStack(spacing: 8) {
                                        if let distance = flight.totalDistance {
                                            DetailStatCard(
                                                title: "Distance",
                                                value: formatDistanceText(distance),
                                                color: .cyan,
                                                icon: "point.topleft.down.to.point.bottomright.curvepath"
                                            )
                                        }
                                        if let speed = flight.maxSpeed {
                                            DetailStatCard(
                                                title: "Max speed",
                                                value: "\(Int(speed * 3.6)) km/h",
                                                color: .purple,
                                                icon: "speedometer"
                                            )
                                        }
                                        if let gForce = flight.maxGForce {
                                            DetailStatCard(
                                                title: "Max G-Force",
                                                value: String(format: "%.1f G", gForce),
                                                color: .green,
                                                icon: "waveform.path.ecg"
                                            )
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // Date and time
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Start", systemImage: "play.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(flight.startDate, format: .dateTime.weekday(.abbreviated).day().month().year())
                                    .font(.subheadline)
                                Text(flight.startDate, format: .dateTime.hour().minute())
                                    .font(.headline)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Label("End", systemImage: "stop.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(flight.endDate, format: .dateTime.weekday(.abbreviated).day().month().year())
                                    .font(.subheadline)
                                Text(flight.endDate, format: .dateTime.hour().minute())
                                    .font(.headline)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    // Wing, flight type and spot
                    VStack(spacing: 12) {
                        if let wing = flight.wing {
                            HStack(spacing: 12) {
                                CachedImage(
                                    data: wing.photoData,
                                    key: wing.id.uuidString,
                                    size: CGSize(width: 50, height: 50)
                                ) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.blue.opacity(0.2))
                                        .overlay {
                                            Image(systemName: "wind")
                                                .foregroundStyle(.blue)
                                        }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Wing")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(wing.name)
                                        .font(.headline)
                                    if let size = wing.size {
                                        Text("\(size) m²")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        if let type = flight.flightTypeEnum {
                            HStack {
                                Image(systemName: type.symbolName)
                                    .foregroundStyle(.indigo)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Flight type")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(type.rawValue)
                                        .font(.headline)
                                }
                                Spacer()
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        if let spotName = flight.spotName {
                            HStack {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.blue)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Spot")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(spotName)
                                        .font(.headline)
                                }
                                Spacer()
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        // Weather snapshot at takeoff (best-effort, may be absent)
                        if hasTakeoffWeather {
                            takeoffConditionsCard
                        }
                    }
                    .padding(.horizontal)

                    // Notes
                    if let notes = flight.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes")
                                .font(.headline)
                            Text(notes)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 40)
                }
            }
            .navigationTitle("Flight Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if flight.gpsTrack?.isEmpty == false {
                        Menu {
                            Button {
                                export(.gpx)
                            } label: {
                                Label("GPX", systemImage: "map")
                            }
                            Button {
                                export(.igc)
                            } label: {
                                Label("IGC", systemImage: "doc.text")
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }

                    Button {
                        showingEditSheet = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
            .sheet(isPresented: $showingEditSheet) {
                EditFlightView(flight: flight)
            }
            .fullScreenCover(isPresented: $showingReplay) {
                FlightReplayView(flight: flight)
            }
            .sheet(item: $exportedFile) { file in
                TrackShareSheet(url: file.url)
                    .presentationDetents([.medium, .large])
            }
            .alert("Export Failed", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "Unknown error.")
            }
        }
    }

    // MARK: - Conditions at takeoff

    private var hasTakeoffWeather: Bool {
        flight.takeoffWindSpeed != nil || flight.takeoffWindGusts != nil ||
        flight.takeoffWindDirection != nil || flight.takeoffTemperature != nil
    }

    /// Compact "Conditions at takeoff" card: wind speed + gusts + direction
    /// arrow/compass + temperature (whatever the snapshot managed to record).
    private var takeoffConditionsCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "wind")
                .foregroundStyle(.teal)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Conditions at takeoff")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let speed = flight.takeoffWindSpeed {
                        Text("\(Int(speed.rounded())) km/h")
                            .font(.headline)
                    }
                    if let gusts = flight.takeoffWindGusts {
                        Text("gusts \(Int(gusts.rounded()))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let direction = flight.takeoffWindDirection {
                        HStack(spacing: 3) {
                            // Wind comes FROM `direction`; arrow shows the flow.
                            Image(systemName: "location.north.fill")
                                .font(.caption)
                                .foregroundStyle(.teal)
                                .rotationEffect(.degrees(direction + 180))
                            Text(WeatherService.degreesToCompass(direction))
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
            }

            Spacer()

            if let temperature = flight.takeoffTemperature {
                Text("\(Int(temperature.rounded()))°C")
                    .font(.title3.weight(.medium))
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func export(_ format: TrackExportFormat) {
        do {
            let url: URL
            switch format {
            case .gpx:
                url = try TrackExporter.gpxFile(for: flight)
            case .igc:
                url = try TrackExporter.igcFile(for: flight)
            }
            exportedFile = ExportedTrackFile(url: url)
        } catch {
            logError("Track export failed: \(error.localizedDescription)", category: .flight)
            exportErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - ExportedTrackFile + TrackShareSheet

/// Identifiable wrapper so the share sheet can be driven by .sheet(item:)
struct ExportedTrackFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController wrapper for sharing an exported track file
/// (named to avoid clashing with the backup ShareSheet in SettingsViews)
struct TrackShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - DetailStatCard (stat card for the detail view)

struct DetailStatCard: View {
    let title: String
    let value: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

