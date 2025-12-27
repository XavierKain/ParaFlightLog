//
//  WingLibraryView.swift
//  ParaFlightLog
//
//  Vue de sélection d'une voile depuis la bibliothèque en ligne
//  Target: iOS only
//

import SwiftUI

/// Vue principale de la bibliothèque de voiles
struct WingLibraryView: View {
    @Environment(\.dismiss) private var dismiss

    /// Callback quand une voile est sélectionnée avec une taille
    let onWingSelected: (LibraryWing, String) -> Void

    // State
    @State private var catalog: WingCatalog?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedManufacturer: WingManufacturer?
    @State private var selectedWing: LibraryWing?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else if let catalog = catalog {
                    catalogContent(catalog)
                }
            }
            .navigationTitle(String(localized: "wingLibrary.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refreshCatalog() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .sheet(item: $selectedWing) { wing in
                SizeSelectionSheet(wing: wing) { size in
                    onWingSelected(wing, size)
                    dismiss()
                }
            }
        }
        .task {
            await loadCatalog()
        }
    }

    // MARK: - Views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(String(localized: "wingLibrary.loading"))
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(String(localized: "wingLibrary.retry")) {
                Task { await loadCatalog() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func catalogContent(_ catalog: WingCatalog) -> some View {
        List {
            // Offline mode indicator
            if WingLibraryService.shared.isOfflineMode {
                Section {
                    HStack {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(.orange)
                        Text(String(localized: "wingLibrary.offlineMode"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Manufacturers
            Section(header: Text(String(localized: "wingLibrary.manufacturers"))) {
                ForEach(catalog.manufacturers) { manufacturer in
                    let wingCount = catalog.wings.filter { $0.manufacturer == manufacturer.id }.count
                    NavigationLink {
                        WingListView(
                            manufacturer: manufacturer,
                            wings: catalog.wings.filter { $0.manufacturer == manufacturer.id },
                            onWingSelected: { wing in
                                selectedWing = wing
                            }
                        )
                    } label: {
                        HStack {
                            Text(manufacturer.name)
                            Spacer()
                            Text("\(wingCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // All wings
            Section(header: Text(String(localized: "wingLibrary.allWings"))) {
                ForEach(catalog.wings) { wing in
                    let manufacturerName = catalog.manufacturers.first { $0.id == wing.manufacturer }?.name
                    WingRowView(wing: wing, manufacturerName: manufacturerName) {
                        selectedWing = wing
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func loadCatalog() async {
        isLoading = true
        errorMessage = nil

        // Clear cache on first load to always get fresh data
        WingLibraryService.shared.clearCache()

        do {
            catalog = try await WingLibraryService.shared.fetchCatalog(forceRefresh: true)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func refreshCatalog() async {
        isLoading = true
        errorMessage = nil

        // Force refresh clears image cache too
        WingLibraryService.shared.clearCache()

        do {
            catalog = try await WingLibraryService.shared.fetchCatalog(forceRefresh: true)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Wing List View

/// Liste des voiles d'un fabricant
private struct WingListView: View {
    let manufacturer: WingManufacturer
    let wings: [LibraryWing]
    let onWingSelected: (LibraryWing) -> Void

    var body: some View {
        List {
            ForEach(wings) { wing in
                WingRowView(wing: wing, manufacturerName: manufacturer.name) {
                    onWingSelected(wing)
                }
            }
        }
        .navigationTitle(manufacturer.name)
    }
}

// MARK: - Wing Row View

/// Ligne affichant une voile dans la liste
private struct WingRowView: View {
    let wing: LibraryWing
    let manufacturerName: String?
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var isLoadingImage = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Image - affichée directement sans fond (images déjà détourées)
                Group {
                    if let image = image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else if isLoadingImage {
                        ProgressView()
                    } else {
                        Image(systemName: "wind")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                }
                .frame(width: 50, height: 50)

                // Info - Titre: modèle, Sous-titre: marque • type • année
                VStack(alignment: .leading, spacing: 4) {
                    Text(wing.fullName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        if let brand = manufacturerName {
                            Text(brand)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("•")
                                .foregroundStyle(.secondary)
                        }
                        Text(wing.type)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let year = wing.year {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text("\(year)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Sizes
                    Text(wing.sizes.map { "\($0)m²" }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard wing.imageUrl != nil else { return }

        isLoadingImage = true
        defer { isLoadingImage = false }

        do {
            let data = try await WingLibraryService.shared.fetchImage(for: wing)
            if let uiImage = UIImage(data: data) {
                image = uiImage
            }
        } catch {
            // Silently fail - placeholder will be shown
        }
    }
}

// MARK: - Size Selection Sheet

/// Sheet pour sélectionner la taille de la voile
private struct SizeSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let wing: LibraryWing
    let onSizeSelected: (String) -> Void

    @State private var image: UIImage?

    /// Récupère le nom du fabricant depuis le catalogue en cache
    private var manufacturerName: String? {
        WingLibraryService.shared.catalog?.manufacturers.first { $0.id == wing.manufacturer }?.name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Wing image
                    Group {
                        if let image = image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: "wind")
                                .font(.system(size: 60))
                                .foregroundStyle(.blue)
                        }
                    }
                    .frame(height: 150)
                    .padding()

                    // Wing info - Titre: modèle, Sous-titre: marque • type
                    VStack(spacing: 8) {
                        Text(wing.fullName)
                            .font(.title2)
                            .fontWeight(.semibold)

                        HStack(spacing: 8) {
                            if let brand = manufacturerName {
                                Text(brand)
                                Text("•")
                            }
                            Text(wing.type)
                        }
                        .foregroundStyle(.secondary)
                    }

                    // Size buttons
                    VStack(spacing: 12) {
                        Text(String(localized: "wingLibrary.selectSize"))
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 70), spacing: 12)
                        ], spacing: 12) {
                            ForEach(wing.sizes, id: \.self) { size in
                                Button {
                                    onSizeSelected(size)
                                } label: {
                                    Text("\(size)m")
                                        .font(.headline)
                                        .frame(minWidth: 60)
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 8)
                                        .background(Color.blue)
                                        .foregroundStyle(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                    .padding()
                }
                .padding(.vertical)
            }
            .navigationTitle(String(localized: "wingLibrary.selectSize"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            loadImage()
        }
    }

    private func loadImage() {
        guard wing.imageUrl != nil else { return }

        Task {
            do {
                let data = try await WingLibraryService.shared.fetchImage(for: wing)
                await MainActor.run {
                    if let uiImage = UIImage(data: data) {
                        image = uiImage
                    }
                }
            } catch {
                // Silently fail
            }
        }
    }
}

#Preview {
    WingLibraryView { wing, size in
        print("Selected: \(wing.fullName) \(size)m")
    }
}
