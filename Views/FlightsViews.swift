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

/// Time-period filter for the flights list.
enum FlightPeriodFilter: String, CaseIterable, Identifiable {
    case all = "All Time"
    case thisMonth = "This Month"
    case thisYear = "This Year"
    case lastYear = "Last Year"

    var id: String { rawValue }

    func contains(_ date: Date) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .all:
            return true
        case .thisMonth:
            return calendar.isDate(date, equalTo: Date(), toGranularity: .month)
        case .thisYear:
            return calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        case .lastYear:
            guard let lastYear = calendar.date(byAdding: .year, value: -1, to: Date()) else { return false }
            return calendar.isDate(date, equalTo: lastYear, toGranularity: .year)
        }
    }
}

struct FlightsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]

    @State private var showingFlightDetail: Flight?
    @State private var showingAddFlight = false
    @State private var showingCategorize = false
    @State private var editingFlight: Flight?

    // Optional flight-type filter (nil = all)
    @State private var selectedTypeFilter: FlightType?
    // Time-period filter
    @State private var selectedPeriod: FlightPeriodFilter = .all
    // Free-text search (spot, wing, notes)
    @State private var searchText = ""

    // Pagination: number of flights displayed
    @State private var displayedFlightsCount: Int = 20
    private let pageSize: Int = 15

    // Flights matching type + period + search
    private var filteredFlights: [Flight] {
        var result = flights

        if let filter = selectedTypeFilter {
            result = result.filter { $0.flightTypeEnum == filter }
        }

        if selectedPeriod != .all {
            result = result.filter { selectedPeriod.contains($0.startDate) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { flight in
                (flight.spotName?.localizedCaseInsensitiveContains(query) ?? false)
                    || (flight.wing?.name.localizedCaseInsensitiveContains(query) ?? false)
                    || (flight.notes?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        return result
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
                                    Button {
                                        editingFlight = latest
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
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
                                            Button {
                                                editingFlight = flight
                                            } label: {
                                                Label("Edit", systemImage: "pencil")
                                            }
                                            .tint(.blue)
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
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Spot, wing or notes")
            .refreshable {
                // Ask the Watch to re-deliver any flights still in its outbox
                watchManager.requestWatchOutboxFlush()
                // Small grace period so a re-delivered flight can land visibly
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            .toolbar {
                // Prominent entry point to the iPhone flight tracker
                // (previously buried in Settings ▸ Tracking)
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        LazyView { TimerView() }
                    } label: {
                        Label("Start Flight", systemImage: "play.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(.green)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showingCategorize = true
                    } label: {
                        Label("Categorize Flights", systemImage: "tag")
                    }

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
        .sheet(isPresented: $showingCategorize) {
            CategorizeFlightsView()
        }
        .sheet(item: $editingFlight) { flight in
            EditFlightView(flight: flight)
        }
        .onChange(of: selectedTypeFilter) {
            displayedFlightsCount = 20
        }
        .onChange(of: selectedPeriod) {
            displayedFlightsCount = 20
        }
        .onChange(of: searchText) {
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

            // Time-period filter
            Menu {
                ForEach(FlightPeriodFilter.allCases) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        if period == selectedPeriod {
                            Label(period.rawValue, systemImage: "checkmark")
                        } else {
                            Text(period.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(selectedPeriod.rawValue)
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
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
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
                    // `initialPosition` is applied ONCE, when the Map is first
                    // built. This card keeps its place in the hierarchy when the
                    // featured flight changes, so SwiftUI reuses the same Map and
                    // the camera stays on the previous flight — after deleting
                    // the most recent flight, the card showed the new flight's
                    // details over the deleted one's location. Tying identity to
                    // the flight forces a fresh Map, and a fresh camera, whenever
                    // the featured flight changes.
                    .id(flight.id)
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

