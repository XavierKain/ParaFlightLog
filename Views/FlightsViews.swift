//
//  FlightsViews.swift
//  ParaFlightLog
//
//  Flight-related views: list, detail, edit, map coordinate picker.
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit
import UIKit

// MARK: - Shared Helpers

/// Formats a distance in meters, e.g. "850 m" or "12.3 km".
func formatDistanceText(_ distance: Double) -> String {
    if distance >= 1000 {
        return String(format: "%.1f km", distance / 1000)
    }
    return "\(Int(distance)) m"
}

// MARK: - FlightTypeBadge (small symbol + name capsule)

struct FlightTypeBadge: View {
    let type: FlightType

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: type.symbolName)
            Text(type.rawValue)
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.indigo)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.indigo.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - FlightsView (flights list with featured latest flight)

struct FlightsView: View {
    @Environment(DataController.self) private var dataController
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]

    @State private var showingFlightDetail: Flight?
    @State private var showingAddFlight = false

    // Optional flight-type filter (nil = all)
    @State private var selectedTypeFilter: FlightType?

    // Pagination: number of flights displayed
    @State private var displayedFlightsCount: Int = 20
    private let pageSize: Int = 15

    // Flights matching the current type filter
    private var filteredFlights: [Flight] {
        guard let filter = selectedTypeFilter else { return flights }
        return flights.filter { $0.flightTypeEnum == filter }
    }

    // Latest flight (most recent, within the current filter)
    private var latestFlight: Flight? {
        filteredFlights.first
    }

    // Older flights, paginated (everything except the latest)
    private var olderFlights: [Flight] {
        let allOlder = Array(filteredFlights.dropFirst())
        return Array(allOlder.prefix(displayedFlightsCount - 1))
    }

    // True when there are more flights to load
    private var hasMoreFlights: Bool {
        filteredFlights.count > displayedFlightsCount
    }

    var body: some View {
        NavigationStack {
            Group {
                if flights.isEmpty {
                    ContentUnavailableView(
                        "No Flights",
                        systemImage: "airplane.circle",
                        description: Text("Record flights with your Apple Watch or tap + to add one manually.")
                    )
                    .padding(.top, 100)
                } else {
                    List {
                        // Flight-type filter (top of the list)
                        filterRow

                        if filteredFlights.isEmpty {
                            ContentUnavailableView(
                                "No \(selectedTypeFilter?.rawValue ?? "") Flights",
                                systemImage: selectedTypeFilter?.symbolName ?? "airplane.circle"
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        // Latest flight, featured
                        if let latest = latestFlight {
                            LatestFlightCard(flight: latest)
                                .onTapGesture {
                                    showingFlightDetail = latest
                                }
                                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteFlight(latest)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }

                        // Previous flights section
                        if !olderFlights.isEmpty {
                            Section {
                                ForEach(olderFlights) { flight in
                                    FlightRow(flight: flight)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            showingFlightDetail = flight
                                        }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                deleteFlight(flight)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)

                                // Infinite scroll: load more automatically
                                if hasMoreFlights {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .onAppear {
                                            loadMoreFlights()
                                        }
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                }
                            } header: {
                                Text("Previous flights")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("My Flights")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddFlight = true
                    } label: {
                        Label("Add Flight", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $showingFlightDetail) { flight in
            FlightDetailView(flight: flight)
        }
        .sheet(isPresented: $showingAddFlight) {
            AddFlightView()
        }
        .onChange(of: selectedTypeFilter) {
            displayedFlightsCount = 20
        }
    }

    // Lightweight flight-type filter menu
    private var filterRow: some View {
        HStack {
            Menu {
                Button {
                    selectedTypeFilter = nil
                } label: {
                    Label("All Types", systemImage: "line.3.horizontal.decrease.circle")
                }
                Divider()
                ForEach(FlightType.allCases) { type in
                    Button {
                        selectedTypeFilter = type
                    } label: {
                        Label(type.rawValue, systemImage: type.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedTypeFilter?.symbolName ?? "line.3.horizontal.decrease.circle")
                    Text(selectedTypeFilter?.rawValue ?? "All Types")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline)
                .fontWeight(.medium)
            }

            Spacer()

            Text("^[\(filteredFlights.count) flight](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// Loads more flights (pagination)
    private func loadMoreFlights() {
        withAnimation(.easeInOut(duration: 0.3)) {
            displayedFlightsCount += pageSize
        }
    }

    private func deleteFlight(_ flight: Flight) {
        dataController.deleteFlight(flight)
        logInfo("Flight deleted and saved to database", category: .flight)
    }
}

// MARK: - LatestFlightCard (featured latest flight)

struct LatestFlightCard: View {
    let flight: Flight

    var body: some View {
        VStack(spacing: 0) {
            // Map with the spot, or placeholder
            ZStack(alignment: .bottomLeading) {
                if let lat = flight.latitude, let lon = flight.longitude {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))) {
                        Marker(flight.spotName ?? "Flight", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                            .tint(.blue)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)
                } else {
                    // Placeholder when there are no coordinates
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.blue.opacity(0.3), .cyan.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(height: 180)
                        .overlay {
                            VStack {
                                Image(systemName: "map")
                                    .font(.largeTitle)
                                    .foregroundStyle(.blue.opacity(0.5))
                                Text("No coordinates")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }

                // "Latest flight" badge + flight type
                HStack(spacing: 8) {
                    HStack {
                        Image(systemName: "clock.fill")
                        Text("Latest flight")
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.blue)
                    .clipShape(Capsule())

                    if let type = flight.flightTypeEnum {
                        HStack(spacing: 4) {
                            Image(systemName: type.symbolName)
                            Text(type.rawValue)
                        }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                    }
                }
                .padding(12)
            }

            // Flight info
            VStack(spacing: 12) {
                // Date and duration
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flight.startDate, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.headline)
                        Text(flight.startDate, format: .dateTime.hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(flight.durationFormatted)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                }

                // Wing and spot
                HStack {
                    if let wing = flight.wing {
                        HStack(spacing: 8) {
                            if wing.photoData != nil {
                                CachedImage(
                                    data: wing.photoData,
                                    key: wing.id.uuidString,
                                    size: CGSize(width: 32, height: 32)
                                ) {
                                    EmptyView()
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(wing.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let size = wing.size {
                                    Text("\(size) m²")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Spacer()
                    if let spotName = flight.spotName {
                        Label(spotName, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Highlight statistics
                if flight.maxAltitude != nil || flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
                    Divider()

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        if let maxAlt = flight.maxAltitude {
                            StatCard(
                                value: "\(Int(maxAlt))",
                                unit: "m",
                                label: "Max alt.",
                                icon: "arrow.up",
                                color: .orange
                            )
                        }
                        if let distance = flight.totalDistance {
                            StatCard(
                                value: formatDistanceValue(distance),
                                unit: formatDistanceUnit(distance),
                                label: "Distance",
                                icon: "point.topleft.down.to.point.bottomright.curvepath",
                                color: .cyan
                            )
                        }
                        if let speed = flight.maxSpeed {
                            StatCard(
                                value: "\(Int(speed * 3.6))",
                                unit: "km/h",
                                label: "Speed",
                                icon: "speedometer",
                                color: .purple
                            )
                        }
                        if let gForce = flight.maxGForce {
                            StatCard(
                                value: String(format: "%.1f", gForce),
                                unit: "G",
                                label: "G-Force",
                                icon: "waveform.path.ecg",
                                color: .green
                            )
                        }
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
    }

    private func formatDistanceValue(_ distance: Double) -> String {
        if distance >= 1000 {
            return String(format: "%.1f", distance / 1000)
        } else {
            return "\(Int(distance))"
        }
    }

    private func formatDistanceUnit(_ distance: Double) -> String {
        return distance >= 1000 ? "km" : "m"
    }
}

// MARK: - StatCard (small statistic card)

struct StatCard: View {
    let value: String
    let unit: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Map with the GPS track, or a simple marker
                    if flight.gpsTrack != nil || (flight.latitude != nil && flight.longitude != nil) {
                        Map(initialPosition: .region(mapRegion)) {
                            // Show the GPS track when available
                            if let track = flight.gpsTrack, track.count >= 2 {
                                MapPolyline(coordinates: track.map {
                                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                                })
                                .stroke(.blue, lineWidth: 3)

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

// MARK: - FlightRow

struct FlightRow: View {
    let flight: Flight

    private let thumbnailSize = CGSize(width: 40, height: 40)

    var body: some View {
        HStack(spacing: 12) {
            // Wing photo with cache (40x40)
            if let wing = flight.wing {
                CachedImage(
                    data: wing.photoData,
                    key: wing.id.uuidString,
                    size: thumbnailSize
                ) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill((wing.color ?? "Gris").toColor().opacity(0.3))
                        .overlay {
                            Image(systemName: "wind")
                                .font(.caption)
                                .foregroundStyle((wing.color ?? "Gris").toColor())
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                // No wing assigned
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "questionmark")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(flight.dateFormatted)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(flight.durationFormatted)
                        .font(.headline)
                        .foregroundStyle(.blue)
                }

                if let wing = flight.wing {
                    HStack(spacing: 4) {
                        Text(wing.name)
                            .font(.body)
                            .fontWeight(.medium)
                        if let size = wing.size {
                            Text("(\(size) m²)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    if let spotName = flight.spotName {
                        Label(spotName, systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let type = flight.flightTypeEnum {
                        FlightTypeBadge(type: type)
                    }
                }

                // Flight statistics (altitude, distance, speed, G-force)
                if flight.maxAltitude != nil || flight.totalDistance != nil || flight.maxSpeed != nil || flight.maxGForce != nil {
                    HStack(spacing: 8) {
                        if let maxAlt = flight.maxAltitude {
                            Label("\(Int(maxAlt))m", systemImage: "arrow.up")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if let distance = flight.totalDistance {
                            Label(formatDistanceText(distance), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.caption2)
                                .foregroundStyle(.cyan)
                        }
                        if let speed = flight.maxSpeed {
                            Label("\(Int(speed * 3.6))km/h", systemImage: "speedometer")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                        }
                        if let gForce = flight.maxGForce {
                            Label(String(format: "%.1fG", gForce), systemImage: "waveform.path.ecg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - EditFlightView (edit a flight)

struct EditFlightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DataController.self) private var dataController
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    let flight: Flight

    @State private var selectedWing: Wing?
    @State private var selectedType: FlightType?
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var spotName: String
    @State private var notes: String
    @State private var isGeocodingSpot = false
    @State private var geocodingMessage: String?
    @State private var showingMapPicker = false
    @State private var selectedCoordinate: CLLocationCoordinate2D?

    @State private var showingDeleteConfirmation = false
    @State private var showSaveError = false

    init(flight: Flight) {
        self.flight = flight
        _startDate = State(initialValue: flight.startDate)
        _endDate = State(initialValue: flight.endDate)
        _spotName = State(initialValue: flight.spotName ?? "")
        _notes = State(initialValue: flight.notes ?? "")
        _selectedType = State(initialValue: flight.flightTypeEnum)
        if let lat = flight.latitude, let lon = flight.longitude {
            _selectedCoordinate = State(initialValue: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }

    var calculatedDuration: Int {
        Int(endDate.timeIntervalSince(startDate))
    }

    var durationFormatted: String {
        let duration = max(0, calculatedDuration)
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date & Time") {
                    DatePicker("Flight start", selection: $startDate)
                    DatePicker("Flight end", selection: $endDate)

                    HStack {
                        Text("Calculated duration")
                        Spacer()
                        Text(durationFormatted)
                            .foregroundStyle(calculatedDuration < 0 ? .red : .secondary)
                    }

                    if calculatedDuration < 0 {
                        Text("⚠️ The end must be after the start")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Wing") {
                    Picker("Wing", selection: $selectedWing) {
                        Text("None").tag(nil as Wing?)
                        ForEach(wings) { wing in
                            Text(wing.name).tag(wing as Wing?)
                        }
                    }
                }

                Section("Flight Type") {
                    Picker("Type", selection: $selectedType) {
                        Text("None").tag(nil as FlightType?)
                        ForEach(FlightType.allCases) { type in
                            Label(type.rawValue, systemImage: type.symbolName)
                                .tag(type as FlightType?)
                        }
                    }
                }

                Section("Spot") {
                    TextField("Spot name", text: $spotName)

                    // Show the coordinates when they exist
                    if let coord = selectedCoordinate {
                        HStack {
                            Text("Coordinates")
                            Spacer()
                            Text("\(coord.latitude, specifier: "%.4f"), \(coord.longitude, specifier: "%.4f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Adjust the coordinates on the map
                        Button {
                            showingMapPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "map")
                                Text("Adjust on the map")
                            }
                        }

                        // Remove the coordinates
                        Button(role: .destructive) {
                            selectedCoordinate = nil
                            flight.latitude = nil
                            flight.longitude = nil
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Remove coordinates")
                            }
                        }
                    } else {
                        // Look up coordinates by geocoding the spot name
                        if !spotName.isEmpty {
                            Button {
                                geocodeSpot()
                            } label: {
                                HStack {
                                    if isGeocodingSpot {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "location.fill")
                                    }
                                    Text("Search location")
                                }
                            }
                            .disabled(isGeocodingSpot)
                        }

                        // Pick on the map
                        Button {
                            showingMapPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "map")
                                Text("Pick on the map")
                            }
                        }

                        if let message = geocodingMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(message.hasPrefix("✅") ? .green : .red)
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                }

                // Delete section
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete this flight")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Edit Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveFlight()
                    }
                    .disabled(calculatedDuration < 0)
                }
            }
            .onAppear {
                selectedWing = flight.wing
            }
            .sheet(isPresented: $showingMapPicker) {
                MapCoordinatePicker(
                    selectedCoordinate: $selectedCoordinate,
                    spotName: spotName
                )
            }
            .confirmationDialog("Delete this flight?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    deleteFlight()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Save Failed", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Could not save the changes. Please try again.")
            }
        }
    }

    private func deleteFlight() {
        dataController.deleteFlight(flight)
        dismiss()
    }

    private func saveFlight() {
        flight.wing = selectedWing
        flight.flightTypeEnum = selectedType
        flight.startDate = startDate
        flight.endDate = endDate
        flight.durationSeconds = calculatedDuration
        flight.spotName = spotName.isEmpty ? nil : spotName
        flight.notes = notes.isEmpty ? nil : notes
        flight.latitude = selectedCoordinate?.latitude
        flight.longitude = selectedCoordinate?.longitude

        // Tracking statistics are read-only and preserved as-is

        Task { @MainActor in
            do {
                try modelContext.save()
                dismiss()
            } catch {
                logError("Failed to save flight: \(error.localizedDescription)", category: .dataController)
                showSaveError = true
            }
        }
    }

    private func geocodeSpot() {
        guard !spotName.isEmpty else { return }

        isGeocodingSpot = true
        geocodingMessage = nil

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = spotName
        let search = MKLocalSearch(request: request)

        search.start { response, error in
            DispatchQueue.main.async {
                isGeocodingSpot = false

                if let error = error {
                    geocodingMessage = "❌ Could not find this place"
                    logError("Geocoding error: \(error.localizedDescription)", category: .location)
                    return
                }

                guard let mapItem = response?.mapItems.first else {
                    geocodingMessage = "❌ No results found"
                    return
                }
                let location = mapItem.location

                selectedCoordinate = location.coordinate
                flight.latitude = location.coordinate.latitude
                flight.longitude = location.coordinate.longitude
                geocodingMessage = "✅ Coordinates added"

                Task { @MainActor in
                    do {
                        try modelContext.save()
                    } catch {
                        logError("Failed to save geocoded coordinates: \(error.localizedDescription)", category: .dataController)
                        // No alert here: the coordinates are already shown on screen
                        // and will be persisted the next time the flight is saved
                    }
                }
            }
        }
    }
}

// MARK: - MapCoordinatePicker (pick coordinates on a map)

struct MapCoordinatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCoordinate: CLLocationCoordinate2D?
    let spotName: String

    @State private var cameraPosition: MapCameraPosition
    @State private var markerCoordinate: CLLocationCoordinate2D?
    @State private var searchText: String = ""
    @State private var isSearching = false

    init(selectedCoordinate: Binding<CLLocationCoordinate2D?>, spotName: String) {
        self._selectedCoordinate = selectedCoordinate
        self.spotName = spotName

        // Initial position: existing coordinates, or France by default
        if let coord = selectedCoordinate.wrappedValue {
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )))
            _markerCoordinate = State(initialValue: coord)
        } else {
            // France by default
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
                span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
            )))
        }
        _searchText = State(initialValue: spotName)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Map
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        if let coord = markerCoordinate {
                            Marker(spotName.isEmpty ? "Location" : spotName, coordinate: coord)
                                .tint(.red)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .onTapGesture { position in
                        if let coordinate = proxy.convert(position, from: .local) {
                            withAnimation {
                                markerCoordinate = coordinate
                            }
                        }
                    }
                }

                // Search bar + instructions at the bottom
                VStack {
                    Spacer()

                    VStack(spacing: 8) {
                        // Search bar
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search for a place...", text: $searchText)
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    searchLocation()
                                }
                            if isSearching {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else if !searchText.isEmpty {
                                Button {
                                    searchLocation()
                                } label: {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text("Tap the map to place the marker")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())

                        if let coord = markerCoordinate {
                            Text("\(coord.latitude, specifier: "%.5f"), \(coord.longitude, specifier: "%.5f")")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Pick Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedCoordinate = markerCoordinate
                        dismiss()
                    }
                    .disabled(markerCoordinate == nil)
                }
            }
            .onAppear {
                // If there is a spot name but no coordinates, search automatically
                if !spotName.isEmpty && markerCoordinate == nil {
                    searchLocation()
                }
            }
        }
    }

    private func searchLocation() {
        let query = searchText.isEmpty ? spotName : searchText
        guard !query.isEmpty else { return }

        isSearching = true

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let search = MKLocalSearch(request: request)

        search.start { response, error in
            DispatchQueue.main.async {
                isSearching = false

                guard let mapItem = response?.mapItems.first else { return }
                let location = mapItem.location

                withAnimation {
                    markerCoordinate = location.coordinate
                    cameraPosition = .region(MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
            }
        }
    }
}
