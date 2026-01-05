//
//  FlightPhotosViews.swift
//  ParaFlightLog
//
//  Composants UI pour afficher et gérer les photos de vol
//  - Galerie de photos
//  - Carousel de photos
//  - Picker de photos
//  - Vue plein écran
//  Target: iOS only
//

import SwiftUI
import PhotosUI

// MARK: - FlightPhotoView

/// Vue qui affiche une photo de vol depuis Appwrite Storage
struct FlightPhotoView: View {
    let fileId: String
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(.systemGray5))
                    .frame(width: size, height: size)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "photo")
                                .font(size > 60 ? .title : .caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .task(id: fileId) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard !fileId.isEmpty else {
            loadedImage = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await FlightSyncService.shared.downloadFlightPhoto(fileId: fileId)
            if let image = UIImage(data: data) {
                await MainActor.run {
                    loadedImage = image
                }
            }
        } catch {
            logError("Failed to load flight photo: \(error.localizedDescription)", category: .sync)
            await MainActor.run {
                loadedImage = nil
            }
        }
    }
}

// MARK: - FlightPhotosCarousel

/// Carousel horizontal pour afficher les photos d'un vol
struct FlightPhotosCarousel: View {
    let photoFileIds: [String]
    let height: CGFloat
    var onPhotoTap: ((Int) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(photoFileIds.enumerated()), id: \.element) { index, fileId in
                    FlightPhotoView(fileId: fileId, size: height, cornerRadius: 12)
                        .onTapGesture {
                            onPhotoTap?(index)
                        }
                }
            }
            .padding(.horizontal)
        }
        .frame(height: height)
    }
}

// MARK: - FlightPhotosGrid

/// Grille de photos pour la vue détaillée
struct FlightPhotosGrid: View {
    let photoFileIds: [String]
    var onPhotoTap: ((Int) -> Void)?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(photoFileIds.enumerated()), id: \.element) { index, fileId in
                FlightPhotoView(fileId: fileId, size: 110, cornerRadius: 8)
                    .aspectRatio(1, contentMode: .fill)
                    .onTapGesture {
                        onPhotoTap?(index)
                    }
            }
        }
    }
}

// MARK: - FlightPhotosBadge

/// Badge indiquant le nombre de photos sur une carte de vol
struct FlightPhotosBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo.fill")
            Text("\(count)")
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
    }
}

// MARK: - FlightPhotosSection

/// Section photos pour la vue détaillée d'un vol
struct FlightPhotosSection: View {
    let flight: PublicFlight
    @State private var selectedPhotoIndex: Int?
    @State private var showingFullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Photos".localized, systemImage: "photo.on.rectangle.angled")
                    .font(.headline)

                Spacer()

                Text("\(flight.photoCount) photo\(flight.photoCount > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if flight.photoFileIds.count <= 3 {
                // Afficher en carousel si peu de photos
                FlightPhotosCarousel(
                    photoFileIds: flight.photoFileIds,
                    height: 180
                ) { index in
                    selectedPhotoIndex = index
                    showingFullScreen = true
                }
            } else {
                // Afficher en grille si plus de photos
                FlightPhotosGrid(
                    photoFileIds: flight.photoFileIds
                ) { index in
                    selectedPhotoIndex = index
                    showingFullScreen = true
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let index = selectedPhotoIndex {
                FlightPhotosFullScreen(
                    photoFileIds: flight.photoFileIds,
                    initialIndex: index
                )
            }
        }
    }
}

// MARK: - FlightPhotosFullScreen

/// Vue plein écran pour visualiser les photos
struct FlightPhotosFullScreen: View {
    let photoFileIds: [String]
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int

    init(photoFileIds: [String], initialIndex: Int) {
        self.photoFileIds = photoFileIds
        self.initialIndex = initialIndex
        self._currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(photoFileIds.enumerated()), id: \.element) { index, fileId in
                    FlightFullScreenPhotoView(fileId: fileId)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            // Bouton fermer
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    .padding()
                }
                Spacer()
            }

            // Indicateur de position
            VStack {
                Spacer()
                Text("\(currentIndex + 1) / \(photoFileIds.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 60)
            }
        }
    }
}

// MARK: - FlightFullScreenPhotoView

/// Vue pour une photo de vol individuelle en plein écran avec zoom
struct FlightFullScreenPhotoView: View {
    let fileId: String

    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    scale = lastScale * value.magnification
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    // Reset if zoomed out too much
                                    if scale < 1.0 {
                                        withAnimation {
                                            scale = 1.0
                                            lastScale = 1.0
                                        }
                                    }
                                    // Limit max zoom
                                    if scale > 4.0 {
                                        withAnimation {
                                            scale = 4.0
                                            lastScale = 4.0
                                        }
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation {
                                if scale > 1.0 {
                                    scale = 1.0
                                    lastScale = 1.0
                                } else {
                                    scale = 2.0
                                    lastScale = 2.0
                                }
                            }
                        }
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 60))
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await FlightSyncService.shared.downloadFlightPhoto(fileId: fileId)
            if let image = UIImage(data: data) {
                await MainActor.run {
                    loadedImage = image
                }
            }
        } catch {
            logError("Failed to load full screen photo: \(error.localizedDescription)", category: .sync)
        }
    }
}

// MARK: - FlightPhotoPicker

/// Picker pour sélectionner et uploader des photos
struct FlightPhotoPicker: View {
    let flightId: String
    @Binding var isPresented: Bool
    var onPhotosUploaded: (([String]) -> Void)?

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if selectedImages.isEmpty {
                    // Picker state
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)

                        Text("Ajouter des photos".localized)
                            .font(.headline)

                        Text("Sélectionnez jusqu'à 10 photos pour ce vol".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        PhotosPicker(
                            selection: $selectedItems,
                            maxSelectionCount: 10,
                            matching: .images
                        ) {
                            Label("Choisir des photos".localized, systemImage: "photo.badge.plus")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding()
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                } else {
                    // Preview state
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 110)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Button {
                                        selectedImages.remove(at: index)
                                        if index < selectedItems.count {
                                            selectedItems.remove(at: index)
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, .red)
                                    }
                                    .padding(4)
                                }
                            }
                        }
                        .padding()
                    }

                    if isUploading {
                        VStack(spacing: 8) {
                            ProgressView(value: uploadProgress)
                                .progressViewStyle(.linear)
                            Text("Upload en cours...".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    Button {
                        Task {
                            await uploadPhotos()
                        }
                    } label: {
                        Label(
                            "Uploader \(selectedImages.count) photo\(selectedImages.count > 1 ? "s" : "")".localized,
                            systemImage: "arrow.up.circle.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isUploading ? Color.gray : Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isUploading)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("Photos du vol".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler".localized) {
                        isPresented = false
                    }
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await loadSelectedImages(from: newItems)
                }
            }
        }
    }

    private func loadSelectedImages(from items: [PhotosPickerItem]) async {
        var images: [UIImage] = []

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }

        await MainActor.run {
            selectedImages = images
        }
    }

    private func uploadPhotos() async {
        guard !selectedImages.isEmpty else { return }

        await MainActor.run {
            isUploading = true
            uploadProgress = 0
            errorMessage = nil
        }

        do {
            let fileIds = try await FlightSyncService.shared.uploadFlightPhotos(
                flightId: flightId,
                images: selectedImages
            )

            await MainActor.run {
                isUploading = false
                onPhotosUploaded?(fileIds)
                isPresented = false
            }
        } catch {
            await MainActor.run {
                isUploading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - FlightPhotosThumbnail

/// Miniature pour les cartes de vol avec indication du nombre de photos
struct FlightPhotosThumbnail: View {
    let photoFileIds: [String]
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let firstPhotoId = photoFileIds.first {
                FlightPhotoView(fileId: firstPhotoId, size: size, cornerRadius: 8)
            }

            if photoFileIds.count > 1 {
                FlightPhotosBadge(count: photoFileIds.count)
                    .padding(4)
            }
        }
    }
}

// MARK: - Previews

#Preview("Photo Carousel") {
    FlightPhotosCarousel(
        photoFileIds: ["photo1", "photo2", "photo3"],
        height: 180
    )
}

#Preview("Photo Grid") {
    FlightPhotosGrid(
        photoFileIds: ["photo1", "photo2", "photo3", "photo4", "photo5", "photo6"]
    )
    .padding()
}

#Preview("Photo Badge") {
    FlightPhotosBadge(count: 5)
}
