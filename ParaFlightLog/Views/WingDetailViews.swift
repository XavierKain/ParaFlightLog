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

    var flights: [Flight] {
        allFlights.filter { $0.wing?.id == wing.id }
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
