//
//  SharedFlightDetailView.swift
//  ParaFlightLog
//
//  Full detail for one community-shared flight, opened from the Explore
//  spot sheet / local spot Community section. Fetches the complete row
//  (stats + the sharer's downsampled GPS track when included) and shows the
//  same kind of page as a local flight: pilot (→ public profile), stat
//  tiles, the speed-coloured track on a map and the 3D replay. Falls back
//  to the plain summary rows when the flight was shared without a track.
//  Presented as a sheet by the callers.
//  Target: iOS only
//

import SwiftUI
import MapKit

struct SharedFlightDetailView: View {
    let flight: SharedFlightSummary
    /// Spot name comes from the caller — `SharedFlightSummary` doesn't carry it.
    let spotName: String

    @Environment(\.dismiss) private var dismiss

    /// Full row (stats + track), fetched once on appear. nil while loading;
    /// on failure the view keeps working from the summary alone.
    @State private var detail: SharedFlightDetail?
    @State private var detailFailed = false
    @State private var showingReplay = false

    private var flightType: FlightType? {
        (detail?.flightType ?? flight.flightType).flatMap(FlightType.init(rawValue:))
    }

    private var track: [GPSTrackPoint]? { detail?.track }

    var body: some View {
        NavigationStack {
            List {
                // Track map + replay (only when the sharer included the track).
                if let track, track.count >= 2 {
                    Section {
                        trackMap(track)
                            .frame(height: 220)
                            .listRowInsets(EdgeInsets())

                        Button {
                            showingReplay = true
                        } label: {
                            Label("Replay in 3D", systemImage: "play.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("Track shared by the pilot (simplified line, colored by speed).")
                    }
                }

                // Stat tiles (only the shared values).
                if let statTiles, !statTiles.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ForEach(statTiles, id: \.label) { tile in
                                VStack(spacing: 4) {
                                    Image(systemName: tile.symbol)
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    Text(tile.value)
                                        .font(.headline.weight(.bold).monospacedDigit())
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    Text(tile.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                }

                Section {
                    // Pilot row → public profile.
                    NavigationLink {
                        PilotProfileView(userId: flight.userId.isEmpty ? nil : flight.userId)
                    } label: {
                        HStack {
                            Label("Pilot", systemImage: "person.fill")
                            Spacer()
                            Text(flight.pilotName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(flight.userId.isEmpty)

                    detailRow("Spot", systemImage: "mappin.circle.fill") {
                        Text(spotName)
                    }
                    detailRow("Date", systemImage: "calendar") {
                        Text(flight.date, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                            .multilineTextAlignment(.trailing)
                    }
                    detailRow("Duration", systemImage: "clock.fill") {
                        Text(durationText)
                    }
                    if let flightType {
                        detailRow("Type", systemImage: flightType.symbolName) {
                            Text(flightType.rawValue)
                        }
                    }
                } footer: {
                    footerText
                }
            }
            .navigationTitle("Shared flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadDetail() }
            .fullScreenCover(isPresented: $showingReplay) {
                if let track {
                    ReplayLauncherView(points: track)
                }
            }
        }
    }

    // MARK: Track map

    /// The shared track coloured by ground speed (green → red between the
    /// 5th and 95th speed percentiles), with takeoff/landing markers.
    private func trackMap(_ track: [GPSTrackPoint]) -> some View {
        Map(initialPosition: .region(Self.region(for: track))) {
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
            if let first = track.first {
                Marker("Takeoff", systemImage: "flag.fill",
                       coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                    .tint(.green)
            }
            if let last = track.last {
                Marker("Landing", systemImage: "flag.checkered",
                       coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                    .tint(.red)
            }
        }
    }

    private static func region(for track: [GPSTrackPoint]) -> MKCoordinateRegion {
        let lats = track.map(\.latitude)
        let lons = track.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.3),
                                   longitudeDelta: max(0.01, (maxLon - minLon) * 1.3))
        )
    }

    private struct TrackSegment {
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    /// Same speed-colouring approach as the local flight detail (chunked
    /// polylines, 5th–95th percentile scaling). Nil without enough speeds.
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
            let end = min(start + chunkSize, track.count - 1)
            let chunk = Array(track[start...end])
            let chunkSpeeds = chunk.compactMap(\.speed)
            let average = chunkSpeeds.isEmpty ? low : chunkSpeeds.reduce(0, +) / Double(chunkSpeeds.count)
            let t = min(max((average - low) / span, 0), 1)
            segments.append(TrackSegment(
                coordinates: chunk.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                color: Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9)
            ))
            start = end
        }
        return segments.isEmpty ? nil : segments
    }

    // MARK: Stats

    private struct StatTile {
        let label: String
        let value: String
        let symbol: String
    }

    /// Tiles for the stats the sharer included; nil while nothing is loaded.
    private var statTiles: [StatTile]? {
        guard let detail else { return nil }
        var tiles: [StatTile] = []
        if let maxAltitude = detail.maxAltitude {
            tiles.append(StatTile(label: "Max altitude", value: "\(Int(maxAltitude.rounded())) m",
                                  symbol: "arrow.up.to.line"))
        }
        if let maxSpeed = detail.maxSpeed {
            tiles.append(StatTile(label: "Max speed", value: "\(Int((maxSpeed * 3.6).rounded())) km/h",
                                  symbol: "speedometer"))
        }
        if let distance = detail.totalDistance, distance > 0 {
            tiles.append(StatTile(label: "Distance", value: String(format: "%.1f km", distance / 1000),
                                  symbol: "point.topleft.down.to.point.bottomright.curvepath"))
        }
        return tiles
    }

    @ViewBuilder
    private var footerText: some View {
        if detail == nil && !detailFailed {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading flight details…")
            }
        } else if track == nil {
            Text("This flight was shared without its GPS track.")
        }
    }

    /// Icon + label on the left, value on the right (Settings-style row).
    private func detailRow<Value: View>(
        _ label: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
            Spacer()
            value()
                .foregroundStyle(.secondary)
        }
    }

    /// "1h05" / "45 min" from the shared duration.
    private var durationText: String {
        let seconds = detail?.durationSeconds ?? flight.durationSeconds
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(hours)h"
        }
        return "\(minutes) min"
    }

    // MARK: Loading

    private func loadDetail() async {
        guard detail == nil else { return }
        do {
            detail = try await CommunityService.shared.sharedFlightDetail(rowId: flight.id)
        } catch {
            detailFailed = true
        }
    }
}
