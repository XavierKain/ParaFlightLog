//
//  SpotsViews.swift
//  ParaFlightLog
//
//  Spot management, entity-based:
//  - SpotsManagementView: all spots (name + city + flight count), add/delete.
//  - SpotDetailView: edit name/city/coordinates, and REASSIGN flights to
//    another (or a brand-new) spot — how a geocoded city-spot like "Tarifa"
//    gets split into its real launches (Punta Paloma, La Peña, ...).
//  - SpotMapPicker: coordinate picker with place search.
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit

// MARK: - SpotsManagementView

struct SpotsManagementView: View {
    @Environment(DataController.self) private var dataController
    @Query(sort: \Spot.name) private var spots: [Spot]

    @State private var showingAddSpot = false
    @State private var newSpotName = ""
    @State private var newSpotCity = ""

    private var sortedSpots: [Spot] {
        DataController.popularityOrder(spots)
    }

    var body: some View {
        List {
            if spots.isEmpty {
                ContentUnavailableView(
                    "No Spots",
                    systemImage: "mappin.slash",
                    description: Text("Spots are created automatically from your flights' locations. You can also add one manually.")
                )
            } else {
                Section {
                    ForEach(sortedSpots) { spot in
                        NavigationLink {
                            SpotDetailView(spot: spot)
                        } label: {
                            SpotEntityRow(spot: spot)
                        }
                    }
                } footer: {
                    Text("Tap a spot to rename it, set its city and coordinates, or move flights to another spot (e.g. split a city into its real launches).")
                }
            }
        }
        .navigationTitle("Spots")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newSpotName = ""
                    newSpotCity = ""
                    showingAddSpot = true
                } label: {
                    Label("Add Spot", systemImage: "plus")
                }
            }
        }
        .alert("New Spot", isPresented: $showingAddSpot) {
            TextField("Spot name (e.g. Punta Paloma)", text: $newSpotName)
            TextField("City (e.g. Tarifa)", text: $newSpotCity)
            Button("Create") {
                let name = newSpotName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let city = newSpotCity.trimmingCharacters(in: .whitespacesAndNewlines)
                dataController.findOrCreateSpot(named: name, city: city.isEmpty ? nil : city)
                _ = dataController.saveContext()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Flights can then be moved to this spot from any spot's detail page.")
        }
    }
}

// MARK: - SpotEntityRow

private struct SpotEntityRow: View {
    let spot: Spot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: spot.latitude != nil ? "mappin.circle.fill" : "mappin.slash.circle")
                .font(.title3)
                .foregroundStyle(spot.latitude != nil ? .red : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name)
                    .font(.headline)
                    .lineLimit(1)
                // City shown only when it differs from the spot name
                if let city = spot.city, city.caseInsensitiveCompare(spot.name) != .orderedSame {
                    Text(city)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("^[\(spot.flights?.count ?? 0) flight](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SpotDetailView (edit + flight reassignment)

struct SpotDetailView: View {
    @Environment(DataController.self) private var dataController
    @Environment(\.dismiss) private var dismiss
    @Bindable var spot: Spot

    @State private var editedName: String = ""
    @State private var editedCity: String = ""
    @State private var showingMapPicker = false

    // Reassignment state
    @State private var selection = Set<UUID>()
    @State private var showingNewSpotPrompt = false
    @State private var newSpotName = ""
    @State private var newSpotCity = ""

    @State private var showingDeleteConfirm = false

    // Set before dismiss() when the spot was deleted (delete button or a split
    // that emptied it): the onDisappear commitEdits() must not touch the
    // now-deleted @Model.
    @State private var didDelete = false

    // Split-by-GPS state
    @State private var splitClusterSizes: [Int] = []
    @State private var showingSplitConfirm = false
    @State private var splitInfoMessage: String?

    private var spotFlights: [Flight] {
        (spot.flights ?? []).sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        List(selection: $selection) {
            // Identity
            Section("Spot") {
                LabeledContent("Name") {
                    TextField("Spot name", text: $editedName)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitEdits() }
                }
                LabeledContent("City") {
                    TextField("City", text: $editedCity)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitEdits() }
                }

                Button {
                    showingMapPicker = true
                } label: {
                    HStack {
                        Label("Coordinates", systemImage: "map")
                        Spacer()
                        if let lat = spot.latitude, let lon = spot.longitude {
                            Text("\(lat, specifier: "%.4f"), \(lon, specifier: "%.4f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Set on map")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }

            // Flights, selectable for reassignment
            Section {
                if spotFlights.isEmpty {
                    Text("No flights at this spot.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(spotFlights) { flight in
                        SpotFlightRow(flight: flight)
                            .tag(flight.id)
                    }
                }
            } header: {
                HStack {
                    Text("^[\(spotFlights.count) flight](inflect: true)")
                    Spacer()
                    if !spotFlights.isEmpty {
                        Button(selection.count == spotFlights.count ? "Deselect All" : "Select All") {
                            if selection.count == spotFlights.count {
                                selection.removeAll()
                            } else {
                                selection = Set(spotFlights.map(\.id))
                            }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            } footer: {
                if !spotFlights.isEmpty {
                    Text("Select flights to move them to another spot — e.g. split \"\(spot.name)\" into its real launches.")
                }
            }

            // Tools
            Section {
                Button {
                    prepareSplit()
                } label: {
                    Label("Split by GPS location", systemImage: "arrow.triangle.branch")
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Groups this spot's flights by takeoff position (within 1 km = same spot) and creates \"\(spot.name) 1\", \"\(spot.name) 2\", … — open each one afterwards to rename it to the real launch.")
            }

            // Danger zone
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Spot", systemImage: "trash")
                }
            } footer: {
                Text("Flights keep their spot name but lose the link; they can be reassigned later.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(spot.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                moveBar
            }
        }
        .onAppear {
            editedName = spot.name
            editedCity = spot.city ?? ""
        }
        .onDisappear {
            commitEdits()
        }
        .sheet(isPresented: $showingMapPicker) {
            SpotMapPicker(
                title: spot.name,
                initialCoordinate: spot.latitude.flatMap { lat in
                    spot.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) }
                },
                searchSeed: spot.city ?? spot.name
            ) { coordinate in
                dataController.updateSpot(spot, name: editedName.isEmpty ? spot.name : editedName,
                                          city: editedCity, coordinate: coordinate)
            }
        }
        .alert("New Spot", isPresented: $showingNewSpotPrompt) {
            TextField("Spot name (e.g. Punta Paloma)", text: $newSpotName)
            TextField("City", text: $newSpotCity)
            Button("Create & Move") {
                moveSelectionToNewSpot()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("^[\(selection.count) flight](inflect: true) will be moved to this new spot.")
        }
        .confirmationDialog(
            "Delete \"\(spot.name)\"?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                didDelete = true
                dataController.deleteSpot(spot)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog(
            splitConfirmTitle,
            isPresented: $showingSplitConfirm,
            titleVisibility: .visible
        ) {
            Button("Split into \(splitClusterSizes.count) spots") {
                performSplit()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Flight groups found: \(splitClusterSizes.map(String.init).joined(separator: ", ")). Each becomes \"\(spot.name) 1\", \"\(spot.name) 2\", … that you can rename.")
        }
        .alert("Split by GPS", isPresented: Binding(
            get: { splitInfoMessage != nil },
            set: { if !$0 { splitInfoMessage = nil } }
        )) {
            Button("OK") { splitInfoMessage = nil }
        } message: {
            Text(splitInfoMessage ?? "")
        }
    }

    private var splitConfirmTitle: String {
        "Split \"\(spot.name)\" into \(splitClusterSizes.count) spots?"
    }

    // MARK: - Split by GPS

    private func prepareSplit() {
        let clusters = dataController.clusterFlightsByLocation(spotFlights)
        let locatedCount = clusters.reduce(0) { $0 + $1.count }

        if locatedCount == 0 {
            splitInfoMessage = "None of these flights have GPS coordinates, so they can't be grouped by position."
            return
        }
        if clusters.count < 2 {
            splitInfoMessage = "All located flights are within 1 km of each other — this already looks like a single spot."
            return
        }

        splitClusterSizes = clusters.map(\.count)
        showingSplitConfirm = true
    }

    private func performSplit() {
        guard let result = dataController.splitSpotByLocation(spot) else {
            splitInfoMessage = "Nothing to split."
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if result.originalDeleted {
            // The spot this screen shows no longer exists
            didDelete = true
            dismiss()
        } else {
            splitInfoMessage = "Created \(result.createdNames.joined(separator: ", ")) (\(result.movedFlights) flights moved). \(result.keptWithoutLocation) flights without GPS stayed here."
        }
    }

    // MARK: - Move bar

    private var moveBar: some View {
        HStack(spacing: 12) {
            Text("^[\(selection.count) flight](inflect: true) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Button {
                    newSpotName = ""
                    newSpotCity = spot.city ?? ""
                    showingNewSpotPrompt = true
                } label: {
                    Label("New Spot…", systemImage: "plus.circle")
                }

                Divider()

                ForEach(otherSpots) { target in
                    Button {
                        moveSelection(to: target)
                    } label: {
                        if let city = target.city, city.caseInsensitiveCompare(target.name) != .orderedSame {
                            Text("\(target.name) — \(city)")
                        } else {
                            Text(target.name)
                        }
                    }
                }
            } label: {
                Label("Move To", systemImage: "arrow.turn.up.right")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var otherSpots: [Spot] {
        dataController.fetchSpots().filter { $0.id != spot.id }
    }

    // MARK: - Actions

    private func commitEdits() {
        // The spot was deleted on this screen: any access to it would touch a
        // deleted @Model (onDisappear fires after the deleting dismiss()).
        guard !didDelete else { return }
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = editedCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if name != spot.name || city != (spot.city ?? "") {
            dataController.updateSpot(spot, name: name, city: city, coordinate: nil)
        }
    }

    private func moveSelection(to target: Spot) {
        let flights = spotFlights.filter { selection.contains($0.id) }
        dataController.reassignFlights(flights, to: target)
        selection.removeAll()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func moveSelectionToNewSpot() {
        let name = newSpotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let city = newSpotCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = dataController.findOrCreateSpot(named: name, city: city.isEmpty ? nil : city)
        moveSelection(to: target)
    }
}

// MARK: - SpotFlightRow (compact flight row for reassignment lists)

private struct SpotFlightRow: View {
    let flight: Flight

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(flight.startDate, format: .dateTime.day().month().year())
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(flight.durationFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let wing = flight.wing {
                        Text("• \(wing.name)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if let type = flight.flightTypeEnum {
                Image(systemName: type.symbolName)
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
        }
    }
}

// MARK: - SpotMapPicker (coordinate picker with place search)

struct SpotMapPicker: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: (CLLocationCoordinate2D) -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var markerCoordinate: CLLocationCoordinate2D?
    @State private var searchText: String
    @State private var isSearching = false

    init(title: String,
         initialCoordinate: CLLocationCoordinate2D?,
         searchSeed: String,
         onSave: @escaping (CLLocationCoordinate2D) -> Void) {
        self.title = title
        self.onSave = onSave

        if let coord = initialCoordinate {
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )))
            _markerCoordinate = State(initialValue: coord)
        } else {
            _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 45.9, longitude: 6.1),
                span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
            )))
        }
        _searchText = State(initialValue: searchSeed)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MapReader { proxy in
                    Map(position: $cameraPosition) {
                        if let coord = markerCoordinate {
                            Marker(title, coordinate: coord)
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
                                .accessibilityLabel("Search")
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
            .navigationTitle(title)
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
