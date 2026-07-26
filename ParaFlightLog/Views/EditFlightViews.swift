//
//  EditFlightViews.swift
//  ParaFlightLog
//
//  Edit-flight form + map coordinate picker.
//  Split from FlightsViews.swift (Lot C).
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit
import UIKit

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
    @State private var selectedSpot: Spot?
    @State private var showingSpotPicker = false
    @State private var spotMatchMessage: String?
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
        _selectedSpot = State(initialValue: flight.spot)
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
                    // Pick an existing spot (name + city)
                    Button {
                        showingSpotPicker = true
                    } label: {
                        HStack {
                            Label("Existing spot", systemImage: "mappin.circle")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if let spot = selectedSpot {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(spot.name)
                                        .foregroundStyle(.blue)
                                    if let city = spot.city, city.caseInsensitiveCompare(spot.name) != .orderedSame {
                                        Text(city)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("Choose…")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    // Auto-match against existing spots using the coordinates
                    if selectedCoordinate != nil {
                        Button {
                            matchSpotFromGPS()
                        } label: {
                            Label("Match spot from GPS", systemImage: "location.magnifyingglass")
                        }
                    }

                    if let message = spotMatchMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(message.hasPrefix("✅") ? .green : .orange)
                    }

                    // Free-text name (creates/links a spot with that name on save)
                    TextField("Spot name", text: $spotName)
                        .onChange(of: spotName) { _, newValue in
                            // Typing a different name detaches the picked spot
                            if let spot = selectedSpot, spot.name != newValue {
                                selectedSpot = nil
                            }
                        }

                    // Show the coordinates when they exist
                    if let coord = selectedCoordinate {
                        HStack {
                            Text("Coordinates")
                            Spacer()
                            // Dots, not locale decimal commas — see AddFlightView.
                            Text(verbatim: String(format: "%.4f, %.4f", coord.latitude, coord.longitude))
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

                        // Remove the coordinates (staged only; the model is
                        // updated in saveFlight so Cancel leaves it untouched)
                        Button(role: .destructive) {
                            selectedCoordinate = nil
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
            .sheet(isPresented: $showingSpotPicker) {
                SpotPickerSheet(selected: selectedSpot) { spot in
                    selectedSpot = spot
                    if let spot {
                        spotName = spot.name
                        // A flight without coordinates inherits the spot's
                        if selectedCoordinate == nil,
                           let lat = spot.latitude, let lon = spot.longitude {
                            selectedCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        }
                    }
                    spotMatchMessage = nil
                }
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

    /// Nearest existing spot to the flight's coordinates (1.5 km radius).
    private func matchSpotFromGPS() {
        guard let coord = selectedCoordinate else { return }
        if let match = dataController.nearestSpot(to: coord) {
            selectedSpot = match
            spotName = match.name
            spotMatchMessage = "✅ Matched: \(match.name)"
        } else {
            spotMatchMessage = "No existing spot within 1.5 km"
        }
    }

    private func saveFlight() {
        flight.wing = selectedWing
        flight.flightTypeEnum = selectedType
        flight.startDate = startDate
        flight.endDate = endDate
        flight.durationSeconds = calculatedDuration
        flight.notes = notes.isEmpty ? nil : notes
        flight.latitude = selectedCoordinate?.latitude
        flight.longitude = selectedCoordinate?.longitude

        // Spot: picked entity wins; a free-typed name finds-or-creates one;
        // an empty name detaches the flight entirely.
        let trimmedName = spotName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let spot = selectedSpot {
            flight.spot = spot
            flight.spotName = spot.name
        } else if !trimmedName.isEmpty {
            let spot = dataController.findOrCreateSpot(named: trimmedName, coordinate: selectedCoordinate)
            flight.spot = spot
            flight.spotName = spot.name
        } else {
            flight.spot = nil
            flight.spotName = nil
        }

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

                // Stage the coordinates only: the model is updated (and the
                // context saved) in saveFlight, so Cancel discards them.
                selectedCoordinate = location.coordinate
                geocodingMessage = "✅ Coordinates added"
            }
        }
    }
}

// MARK: - SpotPickerSheet (choose an existing spot)

/// Searchable list of existing spots (name + city + flight count).
/// Used by the add/edit flight forms.
struct SpotPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Spot.name) private var spots: [Spot]

    let selected: Spot?
    let onSelect: (Spot?) -> Void

    @State private var searchText = ""

    private var filteredSpots: [Spot] {
        let sorted = spots.sorted { ($0.flights?.count ?? 0) > ($1.flights?.count ?? 0) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.city?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    Label("No spot", systemImage: "mappin.slash")
                        .foregroundStyle(Color.primary)
                }

                ForEach(filteredSpots) { spot in
                    Button {
                        onSelect(spot)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.red)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(spot.name)
                                    .foregroundStyle(Color.primary)
                                if let city = spot.city, city.caseInsensitiveCompare(spot.name) != .orderedSame {
                                    Text(city)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Text("^[\(spot.flights?.count ?? 0) flight](inflect: true)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if spot.id == selected?.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "Spot or city")
            .navigationTitle("Choose a Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
                            // Dots, not locale decimal commas — see AddFlightView.
                            Text(verbatim: String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
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
