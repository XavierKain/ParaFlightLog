//
//  SpotsViews.swift
//  ParaFlightLog
//
//  Spot management: list, row, map picker.
//  Split from SettingsViews.swift (Lot C).
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit

// MARK: - SpotsManagementView

/// View to manage the spots detected in flights
struct SpotsManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]

    @State private var selectedSpot: SpotInfo?
    @State private var showingMapPicker = false

    /// Groups the info of a single spot
    struct SpotInfo: Identifiable, Hashable {
        let id = UUID()
        let name: String
        var latitude: Double?
        var longitude: Double?
        var flightCount: Int

        var hasCoordinates: Bool {
            latitude != nil && longitude != nil
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
        }

        static func == (lhs: SpotInfo, rhs: SpotInfo) -> Bool {
            lhs.name == rhs.name
        }
    }

    /// Extracts all unique spots from the flights
    var spots: [SpotInfo] {
        var spotDict: [String: SpotInfo] = [:]

        for flight in flights {
            guard let spotName = flight.spotName, !spotName.isEmpty else { continue }

            if var existing = spotDict[spotName] {
                existing.flightCount += 1
                // Update the coordinates if this flight has some
                if existing.latitude == nil, let lat = flight.latitude, let lon = flight.longitude {
                    existing.latitude = lat
                    existing.longitude = lon
                }
                spotDict[spotName] = existing
            } else {
                spotDict[spotName] = SpotInfo(
                    name: spotName,
                    latitude: flight.latitude,
                    longitude: flight.longitude,
                    flightCount: 1
                )
            }
        }

        return spotDict.values.sorted { $0.flightCount > $1.flightCount }
    }

    var body: some View {
        List {
            if spots.isEmpty {
                ContentUnavailableView(
                    "No Spots",
                    systemImage: "mappin.slash",
                    description: Text("Spots will appear here once you have recorded flights")
                )
            } else {
                Section {
                    ForEach(spots) { spot in
                        SpotRowView(spot: spot) {
                            selectedSpot = spot
                            showingMapPicker = true
                        }
                    }
                } header: {
                    Text(spotsCountText(spots.count))
                } footer: {
                    Text("Add GPS coordinates to a spot to apply them automatically to all associated flights")
                }
            }
        }
        .navigationTitle("Spots")
        .sheet(isPresented: $showingMapPicker) {
            if let spot = selectedSpot {
                SpotMapPicker(spot: spot) { coordinate in
                    updateSpotCoordinates(spotName: spot.name, coordinate: coordinate)
                }
            }
        }
    }

    /// Updates the coordinates of all flights with this spot name
    private func updateSpotCoordinates(spotName: String, coordinate: CLLocationCoordinate2D) {
        var updatedCount = 0

        for flight in flights {
            if flight.spotName == spotName {
                flight.latitude = coordinate.latitude
                flight.longitude = coordinate.longitude
                updatedCount += 1
            }
        }

        Task { @MainActor in
            do {
                try modelContext.save()
                logInfo("Updated \(updatedCount) flights with coordinates for spot: \(spotName)", category: .location)
            } catch {
                logError("Failed to save spot coordinates: \(error.localizedDescription)", category: .dataController)
            }
        }
    }

    /// Correctly pluralized spot count text
    private func spotsCountText(_ count: Int) -> String {
        count == 1 ? "1 spot detected" : "\(count) spots detected"
    }
}

/// Row displaying a spot
struct SpotRowView: View {
    let spot: SpotsManagementView.SpotInfo
    let onMapTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(spot.hasCoordinates ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: spot.hasCoordinates ? "mappin.circle.fill" : "mappin.slash")
                    .font(.title3)
                    .foregroundStyle(spot.hasCoordinates ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(spot.name)
                    .font(.headline)

                HStack(spacing: 8) {
                    Label(flightsCountText(spot.flightCount), systemImage: "airplane")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if spot.hasCoordinates {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text("GPS ✓")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            // Add/edit coordinates button
            Button {
                onMapTap()
            } label: {
                Image(systemName: spot.hasCoordinates ? "map" : "map.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    /// Correctly pluralized flight count text
    private func flightsCountText(_ count: Int) -> String {
        count == 1 ? "1 flight" : "\(count) flights"
    }
}

/// Correctly pluralized "flights will be updated" text
private func flightsWillBeUpdatedText(_ count: Int) -> String {
    count == 1 ? "📍 1 flight will be updated" : "📍 \(count) flights will be updated"
}

/// Map picker for a spot
struct SpotMapPicker: View {
    @Environment(\.dismiss) private var dismiss
    let spot: SpotsManagementView.SpotInfo
    let onSave: (CLLocationCoordinate2D) -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var markerCoordinate: CLLocationCoordinate2D?
    @State private var searchText: String = ""
    @State private var isSearching = false

    init(spot: SpotsManagementView.SpotInfo, onSave: @escaping (CLLocationCoordinate2D) -> Void) {
        self.spot = spot
        self.onSave = onSave

        // Initial position
        if let lat = spot.latitude, let lon = spot.longitude {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
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
        _searchText = State(initialValue: spot.name)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        if let coord = markerCoordinate {
                            Marker(spot.name, coordinate: coord)
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

                        // How many flights will be updated
                        Text(flightsWillBeUpdatedText(spot.flightCount))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding()
                }
            }
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let coord = markerCoordinate {
                            onSave(coord)
                        }
                        dismiss()
                    }
                    .disabled(markerCoordinate == nil)
                }
            }
            .onAppear {
                // Search automatically when there are no coordinates yet
                if markerCoordinate == nil {
                    searchLocation()
                }
            }
        }
    }

    private func searchLocation() {
        guard !searchText.isEmpty else { return }

        isSearching = true

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
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

