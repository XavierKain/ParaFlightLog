//
//  TrashView.swift
//  ParaFlightLog
//
//  Deleted flights, recoverable for a week.
//
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit

struct TrashView: View {
    @Environment(DataController.self) private var dataController
    @Query(sort: \TrashedFlight.deletedAt, order: .reverse) private var trashed: [TrashedFlight]

    @State private var pendingPurge: TrashedFlight?
    @State private var restoreFailed = false

    var body: some View {
        List {
            if trashed.isEmpty {
                ContentUnavailableView(
                    "Trash is empty",
                    systemImage: "trash",
                    description: Text("Deleted flights land here and stay for 7 days, so an accidental delete can be undone.")
                )
            } else {
                Section {
                    ForEach(trashed) { flight in
                        NavigationLink {
                            TrashedFlightDetailView(trashed: flight)
                        } label: {
                            TrashedFlightRow(trashed: flight)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { pendingPurge = flight }
                            Button("Restore") {
                                if !dataController.restoreFlight(flight) { restoreFailed = true }
                            }
                            .tint(.blue)
                        }
                    }
                } footer: {
                    Text("Flights are removed for good 7 days after deletion.")
                }
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete for good?", isPresented: Binding(
            get: { pendingPurge != nil },
            set: { if !$0 { pendingPurge = nil } }
        ), presenting: pendingPurge) { flight in
            Button("Delete", role: .destructive) {
                dataController.purgeTrashedFlight(flight)
                pendingPurge = nil
            }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: { _ in
            Text("This flight cannot be recovered afterwards.")
        }
        .alert("Could not restore", isPresented: $restoreFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This flight's saved copy could not be read.")
        }
    }
}

// MARK: - Row

/// One trash row. Shows wing and spot alongside the date, because a pilot
/// deciding what to restore out of a full trash has nothing else to tell two
/// Saturday flights apart.
private struct TrashedFlightRow: View {
    let trashed: TrashedFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(trashed.flightDate, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.headline)
                Text(trashed.flightDate, format: .dateTime.hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(TrashFormat.duration(trashed.durationSeconds))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 6) {
                if let wing = trashed.wingName {
                    Label(wing, systemImage: "wind")
                        .lineLimit(1)
                }
                if trashed.wingName != nil && trashed.spotName != nil {
                    Text(verbatim: "•")
                }
                if let spot = trashed.spotName {
                    Label(spot, systemImage: "location.fill")
                        .lineLimit(1)
                }
                if trashed.wingName == nil && trashed.spotName == nil {
                    Text("No wing or spot recorded")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            // Inflection markup only resolves in a literal Text — routed
            // through String(localized:) it renders as raw "^[…](inflect:)".
            Group {
                if trashed.daysLeft == 0 {
                    Text("Removed for good today")
                } else {
                    Text("^[\(trashed.daysLeft) day](inflect: true) left")
                }
            }
            .font(.caption2)
            .foregroundStyle(trashed.daysLeft <= 1 ? .orange : .secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

/// Read-only detail of a deleted flight, decoded from its stored payload.
///
/// The point is identification, not analysis: enough of the flight to be sure
/// it is the one you meant before you restore it (or delete it for good).
struct TrashedFlightDetailView: View {
    @Environment(DataController.self) private var dataController
    @Environment(\.dismiss) private var dismiss
    let trashed: TrashedFlight

    @State private var pendingPurge = false
    @State private var restoreFailed = false

    /// Decoded once at init rather than on every access: the payload carries
    /// the whole GPS track, and the body reads it a dozen times.
    private let backup: BackupFlight?

    init(trashed: TrashedFlight) {
        self.trashed = trashed
        self.backup = DataController.decodeTrashed(trashed)
    }

    var body: some View {
        List {
            if let backup {
                if let track = backup.gpsTrack, track.count >= 2 {
                    Section {
                        trackMap(track)
                            .frame(height: 180)
                            .listRowInsets(EdgeInsets())
                    }
                }

                Section {
                    LabeledContent("Date") {
                        Text(backup.startDate, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    }
                    LabeledContent("Time") {
                        // verbatim: two already-localized clock times joined by
                        // a dash is not a phrase that needs its own catalog key.
                        Text(verbatim: "\(backup.startDate.formatted(date: .omitted, time: .shortened)) – \(backup.endDate.formatted(date: .omitted, time: .shortened))")
                    }
                    LabeledContent("Duration") {
                        Text(TrashFormat.duration(backup.durationSeconds))
                    }
                    if let wing = wingName {
                        LabeledContent("Wing") { Text(wing) }
                    }
                    if let spot = backup.spotName {
                        LabeledContent("Spot") { Text(spot) }
                    }
                    if let type = backup.flightType.flatMap(FlightType.init(rawValue:)) {
                        LabeledContent("Flight type") {
                            Label(type.rawValue, systemImage: type.symbolName)
                        }
                    }
                }

                if hasStats(backup) {
                    Section("Flight statistics") {
                        if let altitude = backup.maxAltitude {
                            LabeledContent("Max altitude") { Text("\(Int(altitude)) m") }
                        }
                        if let altitude = backup.startAltitude {
                            LabeledContent("Takeoff altitude") { Text("\(Int(altitude)) m") }
                        }
                        if let altitude = backup.endAltitude {
                            LabeledContent("Landing altitude") { Text("\(Int(altitude)) m") }
                        }
                        if let distance = backup.totalDistance {
                            LabeledContent("Distance") { Text(formatDistanceText(distance)) }
                        }
                        if let speed = backup.maxSpeed {
                            LabeledContent("Max speed") { Text("\(Int(speed * 3.6)) km/h") }
                        }
                        if let track = backup.gpsTrack, !track.isEmpty {
                            LabeledContent("GPS points") { Text("\(track.count)") }
                        }
                    }
                }

                if hasTakeoffWeather(backup) {
                    Section("Conditions at takeoff") {
                        if let speed = backup.takeoffWindSpeed {
                            LabeledContent("Wind") { Text("\(Int(speed.rounded())) km/h") }
                        }
                        if let gusts = backup.takeoffWindGusts {
                            LabeledContent("Gusts") { Text("\(Int(gusts.rounded())) km/h") }
                        }
                        if let direction = backup.takeoffWindDirection {
                            LabeledContent("Direction") {
                                Text(WeatherService.degreesToCompass(direction))
                            }
                        }
                        if let temperature = backup.takeoffTemperature {
                            LabeledContent("Temperature") { Text("\(Int(temperature.rounded()))°C") }
                        }
                    }
                }

                if let notes = backup.notes, !notes.isEmpty {
                    Section("Notes") {
                        Text(notes).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Label("This flight's saved copy could not be read.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    if dataController.restoreFlight(trashed) {
                        dismiss()
                    } else {
                        restoreFailed = true
                    }
                } label: {
                    Label("Restore this flight", systemImage: "arrow.uturn.backward")
                }
                .disabled(backup == nil)

                Button(role: .destructive) {
                    pendingPurge = true
                } label: {
                    Label("Delete for good", systemImage: "trash")
                }
            } footer: {
                if trashed.daysLeft == 0 {
                    Text("Removed for good today.")
                } else {
                    Text("^[\(trashed.daysLeft) day](inflect: true) left before this flight is removed for good.")
                }
            }
        }
        .navigationTitle("Deleted flight")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete for good?", isPresented: $pendingPurge) {
            Button("Delete", role: .destructive) {
                dataController.purgeTrashedFlight(trashed)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This flight cannot be recovered afterwards.")
        }
        .alert("Could not restore", isPresented: $restoreFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This flight's saved copy could not be read.")
        }
    }

    /// Wing recorded at deletion, falling back to the payload's wing id for
    /// rows trashed before `wingName` existed (nil once that wing is gone too).
    private var wingName: String? {
        if let name = trashed.wingName { return name }
        guard let wingId = backup?.wingId else { return nil }
        return dataController.fetchWings().first { $0.id == wingId }?.name
    }

    private func hasStats(_ backup: BackupFlight) -> Bool {
        backup.startAltitude != nil || backup.maxAltitude != nil || backup.endAltitude != nil
            || backup.totalDistance != nil || backup.maxSpeed != nil
            || backup.gpsTrack?.isEmpty == false
    }

    private func hasTakeoffWeather(_ backup: BackupFlight) -> Bool {
        backup.takeoffWindSpeed != nil || backup.takeoffWindGusts != nil
            || backup.takeoffWindDirection != nil || backup.takeoffTemperature != nil
    }

    private func trackMap(_ track: [GPSTrackPoint]) -> some View {
        let coordinates = track.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        return Map(initialPosition: .region(Self.region(for: coordinates))) {
            MapPolyline(coordinates: coordinates)
                .stroke(.blue, lineWidth: 3)
        }
        .allowsHitTesting(false)
    }

    /// Region framing the whole track, with a floor so a sled ride still
    /// renders at a readable zoom.
    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.01, (maxLat - minLat) * 1.3),
                longitudeDelta: max(0.01, (maxLon - minLon) * 1.3)
            )
        )
    }
}

// MARK: - Formatting

private enum TrashFormat {
    /// "1h23" / "45 min" — matches `Flight.durationFormatted`, which the
    /// trash cannot reuse because it holds decoded payloads, not `Flight`s.
    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(minutes) min"
    }
}
