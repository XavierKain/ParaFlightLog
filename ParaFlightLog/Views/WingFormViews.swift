//
//  WingFormViews.swift
//  ParaFlightLog
//
//  Wing add/edit forms (library or manual) + shared form sections.
//  Split from WingsViews.swift (Lot C).
//  Target: iOS only
//

import SwiftUI
import SwiftData
import PhotosUI

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
                    // Same duplicate-on-retry hazard as CustomAddWingView:
                    // drop the failed insert before the user tries again.
                    modelContext.delete(wing)
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
                // Remove the failed insert from the context: tapping "Add"
                // again inserts a fresh wing, so leaving this one behind
                // would create a duplicate on a successful retry.
                modelContext.delete(wing)
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

