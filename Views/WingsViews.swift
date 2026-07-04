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
    @State private var showingAddWing = false

    // Deletion state - handled at parent level to avoid a crash
    @State private var wingToDelete: Wing?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        // Single aggregate pass shared by every row (instead of per-row queries)
        let stats = dataController.computeStats()

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
                        Text("This wing has \(flightCount) recorded flight\(flightCount > 1 ? "s" : ""). Archiving keeps the data, deleting erases it.")
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
                // Title: model name
                Text(wing.name)
                    .font(.headline)

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

// MARK: - AddWingView (Add mode selection)

/// Main add-wing view offering the Library vs Custom choice
struct AddWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    @State private var showingLibrary = false
    @State private var showingCustomForm = false
    @State private var isAddingFromLibrary = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Main icon
                Image(systemName: "wind")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Add a Wing")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Pick a wing from the library or enter its details yourself.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                // Two big buttons
                VStack(spacing: 16) {
                    // Library button
                    Button {
                        showingLibrary = true
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "book.closed.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("From the Library")
                                    .font(.headline)
                                Text("Choose a known model with photo and specs")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isAddingFromLibrary)

                    // Custom button
                    Button {
                        showingCustomForm = true
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Custom Wing")
                                    .font(.headline)
                                Text("Enter the details manually")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.systemGray6))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isAddingFromLibrary)
                }
                .padding(.horizontal, 24)

                if isAddingFromLibrary {
                    ProgressView()
                        .padding()
                }

                Spacer()
            }
            .navigationTitle("New Wing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isAddingFromLibrary)
                }
            }
            .sheet(isPresented: $showingLibrary) {
                WingLibraryView { libraryWing, selectedSize in
                    addWingFromLibrary(libraryWing, size: selectedSize)
                }
            }
            .sheet(isPresented: $showingCustomForm) {
                CustomAddWingView()
            }
        }
    }

    private func addWingFromLibrary(_ libraryWing: LibraryWing, size: String) {
        isAddingFromLibrary = true

        Task {
            // Download the image
            let imageData = try? await WingLibraryService.shared.fetchImage(for: libraryWing)

            // Look up the manufacturer name in the catalog
            let manufacturerName = WingLibraryService.shared.catalog?.manufacturers
                .first { $0.id == libraryWing.manufacturer }?.name

            await MainActor.run {
                // Get the current max displayOrder
                let descriptor = FetchDescriptor<Wing>(
                    predicate: #Predicate { !$0.isArchived },
                    sortBy: [SortDescriptor(\Wing.displayOrder, order: .reverse)]
                )
                let maxDisplayOrder = (try? modelContext.fetch(descriptor).first?.displayOrder) ?? -1

                // name = model only (e.g. "Moustache M1"), brand = manufacturer (e.g. "Flare")
                let wing = Wing(
                    name: libraryWing.model,
                    brand: manufacturerName,
                    size: size,
                    type: libraryWing.type,
                    color: nil,
                    photoData: imageData,
                    displayOrder: maxDisplayOrder + 1
                )

                modelContext.insert(wing)

                do {
                    try modelContext.save()
                    watchManager.sendWingsToWatch()
                    logInfo("Wing added from library: \(wing.name) (\(wing.brand ?? "no brand"))", category: .dataController)
                    dismiss()
                } catch {
                    logError("Failed to save wing: \(error.localizedDescription)", category: .dataController)
                    isAddingFromLibrary = false
                }
            }
        }
    }
}

// MARK: - WingFormView (Shared add/edit form sections)

/// Form sections shared by CustomAddWingView and EditWingView:
/// photo picker, model/brand/size fields, type and color pickers.
struct WingFormView: View {
    @Binding var name: String
    @Binding var brand: String
    @Binding var size: String
    @Binding var type: String
    @Binding var color: String
    @Binding var customColor: String
    @Binding var selectedPhoto: PhotosPickerItem?
    @Binding var photoData: Data?

    /// Show a "Remove Photo" button when a photo is set (used by the edit form)
    var allowsPhotoRemoval: Bool = false

    static let customColorOption = "Other..."
    static let types = ["Soaring", "Cross", "Thermal", "Speedflying", "Acro"]
    static let colors = ["Blue", "Red", "Green", "Yellow", "Orange", "Purple", "Black", "Teal", customColorOption]

    /// Maps legacy stored values (from the previous French UI) to the English options
    static func normalizedColor(_ raw: String) -> String {
        let legacy = [
            "Bleu": "Blue", "Rouge": "Red", "Vert": "Green", "Jaune": "Yellow",
            "Violet": "Purple", "Noir": "Black", "Pétrole": "Teal", "Gris": "Gray"
        ]
        return legacy[raw] ?? raw
    }

    /// Maps legacy stored type values to the English options
    static func normalizedType(_ raw: String) -> String {
        raw == "Thermique" ? "Thermal" : raw
    }

    /// Options for the type picker; includes the current value when it is not
    /// in the standard list (e.g. a type coming from the wing library)
    private var typeOptions: [String] {
        Self.types.contains(type) ? Self.types : Self.types + [type]
    }

    var body: some View {
        Group {
            Section("Photo") {
                HStack {
                    Spacer()
                    if let photoData = photoData, let uiImage = UIImage(data: photoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 120, height: 120)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(.gray)
                            }
                    }
                    Spacer()
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(photoData == nil ? "Choose a Photo" : "Change Photo", systemImage: "photo.on.rectangle.angled")
                }
                .onChange(of: selectedPhoto) { _, newValue in
                    Task {
                        if let data = try? await newValue?.loadTransferable(type: Data.self) {
                            photoData = data
                        }
                    }
                }

                if allowsPhotoRemoval && photoData != nil {
                    Button(role: .destructive) {
                        photoData = nil
                    } label: {
                        Label("Remove Photo", systemImage: "trash")
                    }
                }
            }

            Section("Details") {
                TextField("Model", text: $name)
                TextField("Brand", text: $brand)
                HStack {
                    TextField("Size", text: $size)
                        .keyboardType(.decimalPad)
                        .onChange(of: size) { _, newValue in
                            // Keep only digits and the decimal separator
                            let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                            if filtered != newValue {
                                size = filtered
                            }
                        }
                    Text("m²")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Attributes") {
                Picker("Type", selection: $type) {
                    ForEach(typeOptions, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }

                Picker("Color", selection: $color) {
                    ForEach(Self.colors, id: \.self) { color in
                        Text(color).tag(color)
                    }
                }

                if color == Self.customColorOption {
                    TextField("Custom color", text: $customColor)
                }
            }
        }
    }
}

// MARK: - CustomAddWingView (Manual form)

/// Manual wing creation form
struct CustomAddWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    @State private var name: String = ""
    @State private var brand: String = ""
    @State private var size: String = ""
    @State private var type: String = "Soaring"
    @State private var color: String = "Blue"
    @State private var customColor: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showSaveError: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                WingFormView(
                    name: $name,
                    brand: $brand,
                    size: $size,
                    type: $type,
                    color: $color,
                    customColor: $customColor,
                    selectedPhoto: $selectedPhoto,
                    photoData: $photoData
                )
            }
            .navigationTitle("Custom Wing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addWing()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .alert("Save Error", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Could not save the wing. Please try again.")
            }
        }
    }

    private func addWing() {
        let descriptor = FetchDescriptor<Wing>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\Wing.displayOrder, order: .reverse)]
        )
        let maxDisplayOrder = (try? modelContext.fetch(descriptor).first?.displayOrder) ?? -1

        let finalColor = color == WingFormView.customColorOption ? customColor : color

        let wing = Wing(
            name: name,
            brand: brand.isEmpty ? nil : brand,
            size: size.isEmpty ? nil : size,
            type: type,
            color: finalColor.isEmpty ? nil : finalColor,
            photoData: photoData,
            displayOrder: maxDisplayOrder + 1
        )

        modelContext.insert(wing)

        Task { @MainActor in
            do {
                try modelContext.save()
                watchManager.sendWingsToWatch()
                dismiss()
            } catch {
                logError("Failed to save wing: \(error.localizedDescription)", category: .dataController)
                showSaveError = true
            }
        }
    }
}

// MARK: - EditWingView (Edit a wing)

struct EditWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    let wing: Wing

    @State private var name: String
    @State private var brand: String
    @State private var size: String
    @State private var type: String
    @State private var color: String
    @State private var customColor: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showSaveError: Bool = false

    init(wing: Wing) {
        self.wing = wing
        _name = State(initialValue: wing.name)
        _brand = State(initialValue: wing.brand ?? "")
        _size = State(initialValue: wing.size ?? "")
        _type = State(initialValue: WingFormView.normalizedType(wing.type ?? "Soaring"))
        // If the current color is not in the list, use "Other..."
        let existingColor = WingFormView.normalizedColor(wing.color ?? "Blue")
        if WingFormView.colors.contains(existingColor) && existingColor != WingFormView.customColorOption {
            _color = State(initialValue: existingColor)
            _customColor = State(initialValue: "")
        } else {
            _color = State(initialValue: WingFormView.customColorOption)
            _customColor = State(initialValue: existingColor)
        }
        _photoData = State(initialValue: wing.photoData)
    }

    var body: some View {
        NavigationStack {
            Form {
                WingFormView(
                    name: $name,
                    brand: $brand,
                    size: $size,
                    type: $type,
                    color: $color,
                    customColor: $customColor,
                    selectedPhoto: $selectedPhoto,
                    photoData: $photoData,
                    allowsPhotoRemoval: true
                )
            }
            .navigationTitle("Edit Wing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveWing()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .alert("Save Error", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Could not save the changes. Please try again.")
            }
        }
    }

    private func saveWing() {
        // Use the custom color when "Other..." is selected
        let finalColor = color == WingFormView.customColorOption ? customColor : color

        wing.name = name
        wing.brand = brand.isEmpty ? nil : brand
        wing.size = size.isEmpty ? nil : size
        wing.type = type
        wing.color = finalColor.isEmpty ? nil : finalColor
        wing.photoData = photoData

        // Invalidate the image cache in case the photo changed
        ImageCacheManager.shared.invalidate(key: wing.id.uuidString)

        Task { @MainActor in
            do {
                try modelContext.save()
                watchManager.sendWingsToWatch()
                dismiss()
            } catch {
                logError("Failed to save wing changes: \(error.localizedDescription)", category: .dataController)
                showSaveError = true
            }
        }
    }
}

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
