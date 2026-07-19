//
//  TrimFlightView.swift
//  ParaFlightLog
//
//  Video-editor-style trim for a recorded flight: drag the start/end
//  sliders to cut away the part where you forgot to stop the tracker (the
//  drive home, the packing time…). Applying rewrites the GPS track, the
//  dates/duration and the track-derived stats, then re-shares the flight so
//  the community copy (idempotent upsert) matches the trimmed one.
//  Target: iOS only
//

import SwiftUI
import MapKit
import CoreLocation

struct TrimFlightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataController.self) private var dataController

    let flight: Flight

    /// Kept window, as offsets in seconds from the first track point.
    @State private var startOffset: Double = 0
    @State private var endOffset: Double = 0

    /// Full track, loaded once (decoding it per render would be wasteful).
    @State private var track: [GPSTrackPoint] = []
    @State private var totalSeconds: Double = 0

    private var keptSeconds: Double { max(0, endOffset - startOffset) }

    /// Points inside the kept window.
    private var keptTrack: [GPSTrackPoint] {
        guard let start = track.first?.timestamp else { return [] }
        let from = start.addingTimeInterval(startOffset)
        let to = start.addingTimeInterval(endOffset)
        return track.filter { $0.timestamp >= from && $0.timestamp <= to }
    }

    private var canApply: Bool {
        keptTrack.count >= 2 && keptSeconds >= 60
            && (startOffset > 0.5 || endOffset < totalSeconds - 0.5)
    }

    var body: some View {
        NavigationStack {
            Group {
                if track.count >= 2 {
                    content
                } else {
                    ContentUnavailableView(
                        "No track to trim",
                        systemImage: "scissors",
                        description: Text("This flight has no GPS track.")
                    )
                }
            }
            .navigationTitle("Trim flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(!canApply)
                }
            }
            .onAppear {
                guard track.isEmpty, let points = flight.gpsTrack, points.count >= 2,
                      let first = points.first, let last = points.last else { return }
                track = points
                totalSeconds = last.timestamp.timeIntervalSince(first.timestamp)
                endOffset = totalSeconds
            }
        }
    }

    private var content: some View {
        Form {
            Section {
                map
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Blue: the part you keep. Gray: what gets cut.")
            }

            Section("Start") {
                slider(value: $startOffset, range: 0...max(0, endOffset - 60))
                LabeledContent("Cut from the start") {
                    Text(durationText(startOffset))
                        .monospacedDigit()
                }
            }

            Section("End") {
                slider(value: $endOffset, range: min(totalSeconds, startOffset + 60)...totalSeconds)
                LabeledContent("Cut from the end") {
                    Text(durationText(totalSeconds - endOffset))
                        .monospacedDigit()
                }
            }

            Section {
                LabeledContent("Flight duration after trim") {
                    Text(durationText(keptSeconds))
                        .font(.headline.monospacedDigit())
                }
            } footer: {
                Text("Applying rewrites the flight's track, duration and stats (max altitude, max speed, distance). This cannot be undone.")
            }
        }
    }

    private func slider(value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Slider(value: value, in: range)
    }

    /// Kept window in blue over the cut parts in gray.
    private var map: some View {
        let kept = keptTrack
        return Map(initialPosition: .region(region)) {
            MapPolyline(coordinates: track.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
            .stroke(Color(.systemGray3), lineWidth: 3)

            if kept.count >= 2 {
                MapPolyline(coordinates: kept.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(.blue, lineWidth: 3)

                if let first = kept.first {
                    Marker("Start", systemImage: "flag.fill",
                           coordinate: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude))
                        .tint(.green)
                }
                if let last = kept.last {
                    Marker("End", systemImage: "flag.checkered",
                           coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
                        .tint(.red)
                }
            }
        }
    }

    private var region: MKCoordinateRegion {
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

    /// "1h05" / "12 min" / "45 s".
    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    // MARK: Apply

    private func apply() {
        let kept = keptTrack
        guard kept.count >= 2, let first = kept.first, let last = kept.last else { return }

        flight.setGPSTrack(kept)
        flight.startDate = first.timestamp
        flight.endDate = last.timestamp
        flight.durationSeconds = Int(last.timestamp.timeIntervalSince(first.timestamp).rounded())

        // Track-derived stats, recomputed from the kept window. maxGForce is
        // NOT touched — it comes from the motion sensors, not the GPS track.
        let altitudes = kept.compactMap(\.altitude)
        flight.maxAltitude = altitudes.max()
        flight.startAltitude = first.altitude
        flight.endAltitude = last.altitude
        flight.maxSpeed = kept.compactMap(\.speed).max()

        var distance: Double = 0
        for index in 1..<kept.count {
            let a = CLLocation(latitude: kept[index - 1].latitude, longitude: kept[index - 1].longitude)
            let b = CLLocation(latitude: kept[index].latitude, longitude: kept[index].longitude)
            distance += b.distance(from: a)
        }
        flight.totalDistance = distance

        dataController.saveContext()
        // Idempotent upsert (row ID = flight UUID): the community copy —
        // including the shared track — is replaced by the trimmed one.
        CommunityService.shared.shareFlightIfEnabled(flight, dataController: dataController)
        // Trimming can change the flight duration — refresh the trim reminders.
        dataController.refreshTrimReminders()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
