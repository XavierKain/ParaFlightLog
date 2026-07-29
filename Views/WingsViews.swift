//
//  WingsViews.swift
//  ParaFlightLog
//
//  Wing-related views: list, detail, add, edit
//  Target: iOS only
//

import SwiftUI
import SwiftData
import PhotosUI

// MARK: - WingsView (Wing list + add)

struct WingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]
    // Reactive source for per-wing hours; also drives the async stats recompute.
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]
    @State private var showingAddWing = false

    // Per-wing hours, computed off the render path (see .task below)
    @State private var stats = FlightStats()

    // Deletion state - handled at parent level to avoid a crash
    @State private var wingToDelete: Wing?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if wings.isEmpty {
                    ContentUnavailableView(
                        "No Wings",
                        systemImage: "wind",
                        description: Text("Add your first wing")
                    )
                } else {
                    ForEach(wings) { wing in
                        WingListRow(
                            wing: wing,
                            hoursFlown: stats.hoursByWing[wing.id],
                            onDeleteTapped: {
                                wingToDelete = wing
                                showingDeleteConfirmation = true
                            }
                        )
                    }
                    .onMove(perform: moveWing)
                }
            }
            .navigationTitle("My Wings")
            .task(id: flights.count) {
                stats = dataController.computeStats(from: flights)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddWing = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddWing) {
                AddWingView()
            }
            .alert(
                wingToDelete.map { "Delete \"\($0.name)\"?" } ?? "Delete?",
                isPresented: $showingDeleteConfirmation
            ) {
                Button("Archive") {
                    if let wing = wingToDelete {
                        withAnimation {
                            dataController.archiveWing(wing)
                        }
                    }
                    wingToDelete = nil
                }
                Button("Delete Permanently", role: .destructive) {
                    if let wing = wingToDelete {
                        withAnimation {
                            modelContext.delete(wing)
                            try? modelContext.save()
                            watchManager.sendWingsToWatch()
                        }
                    }
                    wingToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    wingToDelete = nil
                }
            } message: {
                if let wing = wingToDelete {
                    let flightCount = wing.flights?.count ?? 0
                    if flightCount > 0 {
                        Text("This wing has ^[\(flightCount) flight](inflect: true) recorded. Archiving keeps the data, deleting erases it.")
                    } else {
                        Text("This wing has no recorded flights.")
                    }
                }
            }
        }
    }

    private func moveWing(from source: IndexSet, to destination: Int) {
        var updatedWings = wings.map { $0 }
        updatedWings.move(fromOffsets: source, toOffset: destination)

        // Update displayOrder for every affected wing
        for (index, wing) in updatedWings.enumerated() {
            wing.displayOrder = index
        }

        // Save the context
        do {
            try modelContext.save()
            logInfo("Wings reordered successfully", category: .dataController)

            // Sync with the Apple Watch
            watchManager.syncWingsToWatch(wings: Array(updatedWings))
        } catch {
            logError("Error saving wing order: \(error)", category: .dataController)
        }
    }
}

// MARK: - WingListRow (Row with navigation)

/// List row - deletion is handled by the parent WingsView
struct WingListRow: View {
    let wing: Wing
    let hoursFlown: Double?
    let onDeleteTapped: () -> Void

    var body: some View {
        NavigationLink {
            WingDetailView(wing: wing)
        } label: {
            WingRow(wing: wing, hoursFlown: hoursFlown)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDeleteTapped()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - WingRow

struct WingRow: View {
    let wing: Wing
    /// Total flight hours for this wing, precomputed by the parent (nil = no flights)
    let hoursFlown: Double?
    @Environment(DataController.self) private var dataController

    private let thumbnailSize = CGSize(width: 60, height: 60)

    /// Worst trim status across the wing's deadlines; nil (no schedule set)
    /// or .ok hide the hint entirely.
    private var maintenanceStatus: TrimStatus? {
        WingMaintenance.worstStatus(in: wing.maintenanceSnapshot)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Wing photo with cache, or default icon
            CachedImage(
                data: wing.photoData,
                key: wing.id.uuidString,
                size: thumbnailSize
            ) {
                RoundedRectangle(cornerRadius: 8)
                    .fill((wing.color ?? "Gray").toColor().opacity(0.3))
                    .overlay {
                        Image(systemName: "wind")
                            .font(.title2)
                            .foregroundStyle((wing.color ?? "Gray").toColor())
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                // Title: model name + discreet maintenance hint when a trim
                // deadline is close (orange) or missed (red)
                HStack(spacing: 6) {
                    Text(wing.name)
                        .font(.headline)

                    if let status = maintenanceStatus, status != .ok {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption2)
                            .foregroundStyle(status == .overdue ? Color.red : Color.orange)
                    }
                }

                // Subtitle: size • brand • type
                HStack(spacing: 6) {
                    if let size = wing.size {
                        Text("\(size) m²")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let brand = wing.brand {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(brand)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let type = wing.type {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Stats for this wing
                if let hours = hoursFlown {
                    Text("\(dataController.formatHours(hours)) flown")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

