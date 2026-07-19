//
//  WingDetailViews.swift
//  ParaFlightLog
//
//  Wing detail, full-screen photo and archived wings list.
//  Split from WingsViews.swift (Lot C).
//  Target: iOS only
//

import SwiftUI
import SwiftData
import PhotosUI

// MARK: - WingDetailView (Wing detail)

struct WingDetailView: View {
    let wing: Wing
    @Environment(\.dismiss) private var dismiss
    @Environment(DataController.self) private var dataController
    @Query private var allFlights: [Flight]
    @State private var showingEditWing = false
    @State private var selectedFlight: Flight?
    @State private var showingFullScreenPhoto = false
    @State private var showingLogService = false

    var flights: [Flight] {
        allFlights.filter { $0.wing?.id == wing.id }
    }

    /// Maintenance snapshot built from the @Query-driven flight list (not
    /// wing.flights) so the section refreshes when flights change.
    private var maintenanceSnapshot: WingMaintenanceSnapshot {
        WingMaintenanceSnapshot(
            previousHours: wing.previousHours,
            purchaseDate: wing.purchaseDate,
            lastTrimDate: wing.lastTrimDate,
            serviceLog: wing.serviceLog,
            smallTrimIntervalHours: wing.smallTrimIntervalHours,
            fullTrimIntervalHours: wing.fullTrimIntervalHours,
            fullTrimIntervalMonths: wing.fullTrimIntervalMonths,
            flights: flights.map {
                MaintenanceFlight(date: $0.startDate, hours: Double($0.durationSeconds) / 3600.0)
            }
        )
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    // Wing photo (tappable for full screen)
                    if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture {
                                showingFullScreenPhoto = true
                            }
                    } else {
                        // Placeholder when there is no photo
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 150)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.gray.opacity(0.5))
                            }
                    }

                    VStack(spacing: 8) {
                        Text(wing.name)
                            .font(.title)
                            .fontWeight(.bold)

                        HStack(spacing: 16) {
                            if let size = wing.size {
                                Label("\(size) m²", systemImage: "ruler")
                                    .font(.subheadline)
                            }

                            if let brand = wing.brand {
                                Label(brand, systemImage: "building.2")
                                    .font(.subheadline)
                            }

                            if let type = wing.type {
                                Label(type, systemImage: "tag")
                                    .font(.subheadline)
                            }

                            if let color = wing.color {
                                Label(color, systemImage: "paintpalette")
                                    .font(.subheadline)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 16)
            }

            Section("Statistics") {
                let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
                let totalHours = Double(totalSeconds) / 3600.0
                HStack {
                    Text("Flight hours")
                    Spacer()
                    Text(dataController.formatHours(totalHours))
                        .foregroundStyle(.blue)
                }

                HStack {
                    Text("Number of flights")
                    Spacer()
                    Text("\(flights.count)")
                        .foregroundStyle(.blue)
                }
            }

            Section("Maintenance") {
                let snapshot = maintenanceSnapshot
                let states = WingMaintenance.dueStates(in: snapshot)
                let total = WingMaintenance.totalHours(snapshot)

                // Total hours including the pre-app history
                HStack {
                    Text("Total hours")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(dataController.formatHours(total)) total")
                            .foregroundStyle(.blue)
                        if let previous = wing.previousHours, previous > 0 {
                            Text("incl. \(dataController.formatHours(previous)) before the app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let small = states.small {
                    TrimDueRow(title: "Small trim", state: small)
                }
                if let full = states.full {
                    TrimDueRow(title: "Full trim", state: full)
                }
                if states.small == nil && states.full == nil {
                    Text("No trim schedule set — add the intervals in Edit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showingLogService = true
                } label: {
                    Label("Log Service…", systemImage: "wrench.and.screwdriver")
                }
            }

            let serviceLog = wing.serviceLog.sorted { $0.date > $1.date }
            if !serviceLog.isEmpty {
                Section("Service Log") {
                    ForEach(serviceLog) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.type.label)
                                Spacer()
                                Text(event.date, style: .date)
                                    .foregroundStyle(.secondary)
                            }
                            if let hours = event.hoursAtService {
                                Text("at \(dataController.formatHours(hours)) total")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let note = event.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        deleteServiceEvents(at: offsets, from: serviceLog)
                    }
                }
            }

            if !flights.isEmpty {
                Section("Flight History") {
                    ForEach(flights.sorted { $0.startDate > $1.startDate }) { flight in
                        FlightRow(flight: flight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedFlight = flight
                            }
                    }
                }
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingEditWing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showingEditWing) {
            EditWingView(wing: wing)
        }
        .sheet(isPresented: $showingLogService) {
            LogServiceView(wing: wing, totalHours: WingMaintenance.totalHours(maintenanceSnapshot))
        }
        .sheet(item: $selectedFlight) { flight in
            EditFlightView(flight: flight)
                .onAppear {
                    // Immediately check whether the flight was deleted
                    if flight.isDeleted {
                        selectedFlight = nil
                    }
                }
        }
        .onChange(of: allFlights.count) { oldValue, newValue in
            // If a flight gets deleted, close the sheet immediately
            if let selected = selectedFlight {
                if selected.isDeleted || !allFlights.contains(where: { $0.id == selected.id }) {
                    selectedFlight = nil
                }
            }
        }
        .fullScreenCover(isPresented: $showingFullScreenPhoto) {
            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                FullScreenPhotoView(image: uiImage, wingName: wing.name)
            }
        }
    }

    /// Removes the swiped events from the wing's service log. `displayed` is
    /// the date-sorted array the ForEach renders, so the offsets match it.
    private func deleteServiceEvents(at offsets: IndexSet, from displayed: [WingServiceEvent]) {
        let removedIds = Set(offsets.map { displayed[$0].id })
        wing.setServiceLog(wing.serviceLog.filter { !removedIds.contains($0.id) })
        dataController.saveContext()
        dataController.refreshTrimReminders()
    }
}

// MARK: - TrimDueRow + TrimStatusBadge

/// One maintenance deadline row: title, remaining hours / due date detail,
/// and a colored status badge.
struct TrimDueRow: View {
    let title: String
    let state: TrimDueState
    @Environment(DataController.self) private var dataController

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TrimStatusBadge(status: state.status)
        }
    }

    /// e.g. "8h left or until 12 Mar 2027", "overdue by 3h", "was due 1 Jan 2026"
    private var detailText: String {
        var parts: [String] = []
        if let hours = state.hoursRemaining {
            parts.append(hours > 0
                ? "\(dataController.formatHours(hours)) left"
                : "overdue by \(dataController.formatHours(-hours))")
        }
        if let dueDate = state.dueDate {
            let dateText = dueDate.formatted(date: .abbreviated, time: .omitted)
            parts.append(dueDate > Date() ? "until \(dateText)" : "was due \(dateText)")
        }
        return parts.joined(separator: " or ")
    }
}

/// Colored capsule: green OK / orange Due soon / red Overdue
struct TrimStatusBadge: View {
    let status: TrimStatus

    var body: some View {
        Text(label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .ok: return "OK"
        case .dueSoon: return "Due soon"
        case .overdue: return "Overdue"
        }
    }

    private var color: Color {
        switch status {
        case .ok: return .green
        case .dueSoon: return .orange
        case .overdue: return .red
        }
    }
}

// MARK: - LogServiceView (Log a service event)

/// Sheet recording one service event (type, date, note) into the wing's
/// maintenance log. The wing's current total hours are stamped on the event
/// so the trim counters reset by hours, not only by date.
struct LogServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataController.self) private var dataController

    let wing: Wing
    /// Total hours on the wing right now (previousHours + logged flights)
    let totalHours: Double

    @State private var type: WingServiceType = .fullTrim
    @State private var date: Date = Date()
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(WingServiceType.allCases, id: \.self) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note (optional)", text: $note, axis: .vertical)
                } footer: {
                    Text("Recorded at \(dataController.formatHours(totalHours)) total on this wing.")
                }
            }
            .navigationTitle("Log Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEvent()
                    }
                }
            }
        }
    }

    private func saveEvent() {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        wing.addServiceEvent(WingServiceEvent(
            date: date,
            type: type,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            hoursAtService: totalHours
        ))
        dataController.saveContext()
        dataController.refreshTrimReminders()
        dismiss()
    }
}

// MARK: - FullScreenPhotoView

struct FullScreenPhotoView: View {
    let image: UIImage
    let wingName: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = lastScale * value
                        }
                        .onEnded { _ in
                            lastScale = scale
                            // Clamp the zoom between 1x and 4x
                            if scale < 1.0 {
                                withAnimation {
                                    scale = 1.0
                                    lastScale = 1.0
                                }
                            } else if scale > 4.0 {
                                withAnimation {
                                    scale = 4.0
                                    lastScale = 4.0
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    // Double-tap to reset the zoom
                    withAnimation {
                        scale = 1.0
                        lastScale = 1.0
                    }
                }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .background(Circle().fill(Color.black.opacity(0.5)).padding(-8))
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}

// MARK: - ArchivedWingsView (Archived wings list)

struct ArchivedWingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Wing> { $0.isArchived }, sort: \Wing.createdAt, order: .reverse) private var archivedWings: [Wing]
    @State private var selectedWing: Wing?
    @State private var showingDeleteAlert = false
    @State private var wingToDelete: Wing?

    var body: some View {
        List {
            if archivedWings.isEmpty {
                ContentUnavailableView(
                    "No Archived Wings",
                    systemImage: "archivebox",
                    description: Text("Archived wings will appear here")
                )
            } else {
                ForEach(archivedWings) { wing in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            // Wing photo or default icon
                            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill((wing.color ?? "Gray").toColor().opacity(0.3))
                                    .frame(width: 50, height: 50)
                                    .overlay {
                                        Image(systemName: "wind")
                                            .foregroundStyle((wing.color ?? "Gray").toColor())
                                    }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(wing.name)
                                    .font(.headline)

                                HStack(spacing: 12) {
                                    if let size = wing.size {
                                        Text("\(size) m²")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let type = wing.type {
                                        Text(type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                // Flight count
                                let flightCount = wing.flights?.count ?? 0
                                if flightCount > 0 {
                                    Text("\(flightCount) flight\(flightCount > 1 ? "s" : "")")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }

                        // Action buttons
                        HStack(spacing: 12) {
                            Button {
                                dataController.unarchiveWing(wing)
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                wingToDelete = wing
                                showingDeleteAlert = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Archived Wings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete permanently?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let wing = wingToDelete {
                    // Use the view's modelContext so @Query picks up the change
                    modelContext.delete(wing)
                    try? modelContext.save()
                }
            }
        } message: {
            if let wing = wingToDelete {
                let flightCount = wing.flights?.count ?? 0
                Text("⚠️ This action is irreversible! The wing \"\(wing.name)\" and its \(flightCount) flight\(flightCount > 1 ? "s" : "") will be permanently deleted.")
            }
        }
    }
}
