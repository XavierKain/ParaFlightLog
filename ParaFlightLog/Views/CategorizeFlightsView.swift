//
//  CategorizeFlightsView.swift
//  ParaFlightLog
//
//  Bulk flight-type categorization, built for large imported logbooks:
//  - "By spot": one tap types every (untyped) flight of a spot — spots almost
//    always host the same activity (a soaring spot stays a soaring spot).
//  - "Select": multi-select any set of flights (filterable to untyped only)
//    and assign a type to all of them at once.
//  Target: iOS only
//

import SwiftUI
import SwiftData

struct CategorizeFlightsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataController.self) private var dataController
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]

    enum Mode: String, CaseIterable {
        case bySpot = "By Spot"
        case select = "Select"
    }

    @State private var mode: Mode = .bySpot

    // Select mode state
    @State private var selection = Set<UUID>()
    @State private var untypedOnly = true

    // Feedback
    @State private var toastMessage: String?

    private var untypedCount: Int {
        flights.filter { $0.flightTypeEnum == nil }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch mode {
                case .bySpot:
                    SpotCategorizeList(flights: flights) { message in
                        showToast(message)
                    }
                case .select:
                    selectList
                }
            }
            .navigationTitle("Categorize Flights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                statusBar
            }
        }
    }

    // MARK: - Status / toast bar

    private var statusBar: some View {
        VStack(spacing: 6) {
            if let toast = toastMessage {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.9), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Text(untypedCount == 0
                 ? "All flights are categorized 🎉"
                 : "^[\(untypedCount) flight](inflect: true) still without a type")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func showToast(_ message: String) {
        withAnimation(.snappy) { toastMessage = message }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut) { toastMessage = nil }
        }
    }

    // MARK: - Select mode

    private var filteredFlights: [Flight] {
        untypedOnly ? flights.filter { $0.flightTypeEnum == nil } : flights
    }

    private var selectList: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Untyped only", isOn: $untypedOnly)
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                Button(selection.count == filteredFlights.count && !filteredFlights.isEmpty
                       ? "Deselect All" : "Select All") {
                    if selection.count == filteredFlights.count {
                        selection.removeAll()
                    } else {
                        selection = Set(filteredFlights.map(\.id))
                    }
                }
                .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)

            List(selection: $selection) {
                ForEach(filteredFlights) { flight in
                    CategorizeFlightRow(flight: flight)
                        .tag(flight.id)
                }
            }
            .environment(\.editMode, .constant(.active))
            .listStyle(.plain)

            // Assign bar
            if !selection.isEmpty {
                HStack(spacing: 12) {
                    Text("^[\(selection.count) flight](inflect: true) selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Menu {
                        ForEach(FlightType.allCases) { type in
                            Button {
                                assignToSelection(type)
                            } label: {
                                Label(type.rawValue, systemImage: type.symbolName)
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            assignToSelection(nil)
                        } label: {
                            Label("Clear type", systemImage: "xmark.circle")
                        }
                    } label: {
                        Label("Assign Type", systemImage: "tag.fill")
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
        }
        .onChange(of: untypedOnly) {
            selection.removeAll()
        }
    }

    private func assignToSelection(_ type: FlightType?) {
        let targets = flights.filter { selection.contains($0.id) }
        let changed = dataController.setFlightType(type, for: targets)
        selection.removeAll()
        if let type {
            showToast("\(changed) flights set to \(type.rawValue)")
        } else {
            showToast("Type cleared on \(changed) flights")
        }
    }
}

// MARK: - CategorizeFlightRow (compact row for the select list)

private struct CategorizeFlightRow: View {
    let flight: Flight

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(flight.startDate, format: .dateTime.day().month().year())
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(flight.spotName ?? "Unknown spot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                HStack(spacing: 4) {
                    Image(systemName: type.symbolName)
                    Text(type.rawValue)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.indigo)
            } else {
                Text("No type")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - SpotCategorizeList (one-tap typing per spot)

private struct SpotCategorizeList: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    let onApplied: (String) -> Void

    @State private var pendingSpot: SpotGroup?
    @State private var pendingType: FlightType?

    /// Flights grouped per spot with type coverage stats.
    struct SpotGroup: Identifiable {
        let id: String            // spot name
        let name: String
        let flights: [Flight]
        let untyped: [Flight]
        /// Most common existing type at this spot, if any
        let dominantType: FlightType?
    }

    private var groups: [SpotGroup] {
        let bySpot = Dictionary(grouping: flights) { $0.spotName ?? "Unknown spot" }
        return bySpot
            .map { name, spotFlights in
                let untyped = spotFlights.filter { $0.flightTypeEnum == nil }
                let typeCounts = Dictionary(grouping: spotFlights.compactMap(\.flightTypeEnum)) { $0 }
                    .mapValues(\.count)
                let dominant = typeCounts.max { $0.value < $1.value }?.key
                return SpotGroup(
                    id: name,
                    name: name,
                    flights: spotFlights,
                    untyped: untyped,
                    dominantType: dominant
                )
            }
            // Spots with work to do first, then by size
            .sorted {
                if ($0.untyped.isEmpty) != ($1.untyped.isEmpty) {
                    return !$0.untyped.isEmpty
                }
                return $0.flights.count > $1.flights.count
            }
    }

    var body: some View {
        List {
            Section {
                ForEach(groups) { group in
                    row(for: group)
                }
            } footer: {
                Text("Assigning a type to a spot fills its untyped flights. A spot that already has flights of one type shows it as the suggestion — one tap applies it.")
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            pendingDialogTitle,
            isPresented: Binding(
                get: { pendingSpot != nil && pendingType != nil },
                set: { if !$0 { pendingSpot = nil; pendingType = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let group = pendingSpot, let type = pendingType {
                if !group.untyped.isEmpty {
                    Button("Fill \(group.untyped.count) untyped") {
                        apply(type, to: group.untyped, spot: group.name)
                    }
                }
                Button("Overwrite all \(group.flights.count) flights", role: .destructive) {
                    apply(type, to: group.flights, spot: group.name)
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    private var pendingDialogTitle: String {
        guard let group = pendingSpot, let type = pendingType else { return "" }
        return "Set \(group.name) to \(type.rawValue)?"
    }

    private func row(for group: SpotGroup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(group.untyped.isEmpty
                     ? "^[\(group.flights.count) flight](inflect: true) — all typed"
                     : "^[\(group.flights.count) flight](inflect: true) — \(group.untyped.count) untyped")
                    .font(.caption)
                    .foregroundStyle(group.untyped.isEmpty ? Color.secondary : Color.orange)
            }

            Spacer()

            // One-tap suggestion when the spot already leans one way
            if let suggested = group.dominantType, !group.untyped.isEmpty {
                Button {
                    pendingSpot = group
                    pendingType = suggested
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: suggested.symbolName)
                        Text(suggested.rawValue)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            // Full type menu
            Menu {
                ForEach(FlightType.allCases) { type in
                    Button {
                        pendingSpot = group
                        pendingType = type
                    } label: {
                        Label(type.rawValue, systemImage: type.symbolName)
                    }
                }
            } label: {
                Image(systemName: "tag")
                    .font(.body)
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel("Choose a type for \(group.name)")
        }
        .padding(.vertical, 2)
    }

    private func apply(_ type: FlightType, to flights: [Flight], spot: String) {
        let changed = dataController.setFlightType(type, for: flights)
        onApplied("\(spot): \(changed) flights set to \(type.rawValue)")
        pendingSpot = nil
        pendingType = nil
    }
}
