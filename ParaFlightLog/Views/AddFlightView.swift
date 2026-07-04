//
//  AddFlightView.swift
//  ParaFlightLog
//
//  Manual flight entry: date, duration wheels, wing, flight type,
//  spot (with geocoding / map pick) and notes.
//  Target: iOS only
//

import SwiftUI
import SwiftData
import MapKit

struct AddFlightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataController.self) private var dataController
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]

    @State private var startDate = Date()
    @State private var durationHours = 0
    @State private var durationMinutes = 30
    @State private var selectedWing: Wing?
    @State private var selectedType: FlightType?
    @State private var spotName = ""
    @State private var notes = ""

    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var showingMapPicker = false
    @State private var isGeocodingSpot = false
    @State private var geocodingMessage: String?
    @State private var isSaving = false
    @State private var hasAppeared = false

    private var durationSeconds: Int {
        durationHours * 3600 + durationMinutes * 60
    }

    private var endDate: Date {
        startDate.addingTimeInterval(TimeInterval(durationSeconds))
    }

    private var canSave: Bool {
        selectedWing != nil && durationSeconds > 0 && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date & Duration") {
                    DatePicker("Flight start", selection: $startDate)

                    HStack(spacing: 0) {
                        Picker("Hours", selection: $durationHours) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text("\(hour) h").tag(hour)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()

                        Picker("Minutes", selection: $durationMinutes) {
                            ForEach(0..<60, id: \.self) { minute in
                                Text("\(minute) min").tag(minute)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                    .frame(height: 120)

                    HStack {
                        Text("Flight end")
                        Spacer()
                        Text(endDate, format: .dateTime.day().month().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if durationSeconds == 0 {
                        Text("Set a duration of at least one minute.")
                    }
                }

                Section("Wing") {
                    if wings.isEmpty {
                        Text("Add a wing in the Wings tab first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Wing", selection: $selectedWing) {
                            ForEach(wings) { wing in
                                Text(wing.name).tag(wing as Wing?)
                            }
                        }
                    }
                }

                Section("Flight Type") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FlightType.allCases) { type in
                                FlightTypeChip(type: type, isSelected: selectedType == type) {
                                    withAnimation(.snappy) {
                                        selectedType = (selectedType == type) ? nil : type
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Spot") {
                    TextField("Spot name", text: $spotName)

                    if let coord = selectedCoordinate {
                        HStack {
                            Text("Coordinates")
                            Spacer()
                            Text("\(coord.latitude, specifier: "%.4f"), \(coord.longitude, specifier: "%.4f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            showingMapPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "map")
                                Text("Adjust on the map")
                            }
                        }

                        Button(role: .destructive) {
                            selectedCoordinate = nil
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Remove coordinates")
                            }
                        }
                    } else {
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
            }
            .navigationTitle("New Flight")
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
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingMapPicker) {
                MapCoordinatePicker(
                    selectedCoordinate: $selectedCoordinate,
                    spotName: spotName
                )
            }
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true

                selectedWing = wings.first

                // Pre-select the last flight type picked by the pilot
                if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastFlightType),
                   let type = FlightType(rawValue: raw) {
                    selectedType = type
                }
            }
        }
    }

    // MARK: - Saving

    private func saveFlight() {
        guard let wing = selectedWing else { return }
        isSaving = true

        let trimmedSpot = spotName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Geocode on save when a spot name was typed but no coordinates were picked
        if selectedCoordinate == nil && !trimmedSpot.isEmpty {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmedSpot
            MKLocalSearch(request: request).start { response, _ in
                DispatchQueue.main.async {
                    let location = response?.mapItems.first?.location
                    finalizeSave(wing: wing, spotName: trimmedSpot, location: location)
                }
            }
        } else {
            let location = selectedCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            finalizeSave(wing: wing, spotName: trimmedSpot, location: location)
        }
    }

    private func finalizeSave(wing: Wing, spotName: String, location: CLLocation?) {
        dataController.addFlight(
            wing: wing,
            startDate: startDate,
            endDate: endDate,
            durationSeconds: durationSeconds,
            location: location,
            spotName: spotName.isEmpty ? nil : spotName,
            flightType: selectedType?.rawValue,
            notes: notes.isEmpty ? nil : notes
        )

        // Remember the last flight type picked by the pilot
        if let type = selectedType {
            UserDefaults.standard.set(type.rawValue, forKey: UserDefaultsKeys.lastFlightType)
        }

        dismiss()
    }

    // MARK: - Geocoding

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

                selectedCoordinate = mapItem.location.coordinate
                geocodingMessage = "✅ Coordinates added"
            }
        }
    }
}

// MARK: - FlightTypeChip (tappable capsule with symbol + name)

private struct FlightTypeChip: View {
    let type: FlightType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: type.symbolName)
                Text(type.rawValue)
            }
            .font(.subheadline)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue : Color(.tertiarySystemFill))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
