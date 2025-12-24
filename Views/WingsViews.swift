//
//  WingsViews.swift
//  ParaFlightLog
//
//  Vues liées aux voiles : liste, détail, ajout, édition
//  Target: iOS only
//

import SwiftUI
import SwiftData
import PhotosUI

// MARK: - WingsView (Liste + ajout de voiles)

struct WingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.displayOrder) private var wings: [Wing]
    @State private var showingAddWing = false
    @State private var wingToAction: Wing?
    @State private var showingActionSheet = false

    var body: some View {
        NavigationStack {
            List {
                if wings.isEmpty {
                    ContentUnavailableView(
                        "Aucune voile",
                        systemImage: "wind",
                        description: Text("Ajoutez votre première voile")
                    )
                } else {
                    ForEach(wings) { wing in
                        NavigationLink {
                            WingDetailView(wing: wing)
                        } label: {
                            WingRow(wing: wing)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                wingToAction = wing
                                showingActionSheet = true
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveWing)
                }
            }
            .navigationTitle(String(localized: "Mes voiles"))
            .id(localizationManager.currentLanguage) // Force re-render quand la langue change
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddWing = true
                    } label: {
                        Label("Ajouter", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddWing) {
                AddWingView()
            }
            .confirmationDialog("Que voulez-vous faire ?", isPresented: $showingActionSheet, presenting: wingToAction) { wing in
                Button("Archiver") {
                    dataController.archiveWing(wing)
                }
                Button("Supprimer définitivement", role: .destructive) {
                    let flightCount = wing.flights?.count ?? 0
                    if flightCount > 0 {
                        // Si la voile a des vols, forcer l'archivage
                        dataController.archiveWing(wing)
                    } else {
                        // Si pas de vols, suppression directe
                        dataController.deleteWing(wing)
                    }
                }
                Button("Annuler", role: .cancel) { }
            } message: { wing in
                let flightCount = wing.flights?.count ?? 0
                if flightCount > 0 {
                    Text("Cette voile a \(flightCount) vol\(flightCount > 1 ? "s" : "") enregistré\(flightCount > 1 ? "s" : ""). L'archivage conservera les données, la suppression les effacera.")
                } else {
                    Text("Cette voile n'a aucun vol enregistré.")
                }
            }
        }
    }

    private func moveWing(from source: IndexSet, to destination: Int) {
        var updatedWings = wings.map { $0 }
        updatedWings.move(fromOffsets: source, toOffset: destination)

        // Mettre à jour displayOrder pour toutes les voiles affectées
        for (index, wing) in updatedWings.enumerated() {
            wing.displayOrder = index
        }

        // Sauvegarder le contexte
        do {
            try modelContext.save()
            logInfo("Wings reordered successfully", category: .dataController)

            // Synchroniser avec Apple Watch
            watchManager.syncWingsToWatch(wings: Array(updatedWings))
        } catch {
            logError("Error saving wing order: \(error)", category: .dataController)
        }
    }
}

// MARK: - WingRow

struct WingRow: View {
    let wing: Wing
    @Environment(DataController.self) private var dataController

    private let thumbnailSize = CGSize(width: 60, height: 60)

    var body: some View {
        HStack(spacing: 12) {
            // Photo de la voile avec cache ou icône par défaut
            CachedImage(
                data: wing.photoData,
                key: wing.id.uuidString,
                size: thumbnailSize
            ) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                    .overlay {
                        Image(systemName: "wind")
                            .font(.title2)
                            .foregroundStyle(colorFromString(wing.color ?? "Gris"))
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

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

                // Stats de cette voile
                let stats = dataController.totalHoursByWing()
                if let hours = stats[wing.id] {
                    Text("\(dataController.formatHours(hours)) de vol")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge": return .red
        case "bleu": return .blue
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        default: return .gray
        }
    }
}

// MARK: - AddWingView (Formulaire d'ajout avec photo)

struct AddWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    @State private var name: String = ""
    @State private var size: String = ""
    @State private var type: String = "Soaring"
    @State private var color: String = "Bleu"
    @State private var customColor: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?

    let types = ["Soaring", "Cross", "Thermique", "Speedflying", "Acro"]
    let colors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir", "Pétrole", "Autre..."]

    var body: some View {
        NavigationStack {
            Form {
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
                        Label("Choisir une photo", systemImage: "photo.on.rectangle.angled")
                    }
                }

                Section("Informations") {
                    TextField("Nom", text: $name)
                    HStack {
                        TextField("Taille", text: $size)
                            .keyboardType(.decimalPad)
                            .onChange(of: size) { _, newValue in
                                // Filtrer pour ne garder que les chiffres et le point/virgule
                                let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                                if filtered != newValue {
                                    size = filtered
                                }
                            }
                        Text("m²")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Caractéristiques") {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }

                    Picker("Couleur", selection: $color) {
                        ForEach(colors, id: \.self) { color in
                            Text(color).tag(color)
                        }
                    }

                    if color == "Autre..." {
                        TextField("Couleur personnalisée", text: $customColor)
                    }
                }
            }
            .navigationTitle("Nouvelle voile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        addWing()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onChange(of: selectedPhoto) { _, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        photoData = data
                    }
                }
            }
        }
    }

    private func addWing() {
        // Récupérer le displayOrder max actuel pour ajouter la nouvelle voile à la fin
        let descriptor = FetchDescriptor<Wing>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\Wing.displayOrder, order: .reverse)]
        )
        let maxDisplayOrder = (try? modelContext.fetch(descriptor).first?.displayOrder) ?? -1

        // Utiliser la couleur personnalisée si "Autre..." est sélectionné
        let finalColor = color == "Autre..." ? customColor : color

        let wing = Wing(
            name: name,
            size: size.isEmpty ? nil : size,
            type: type,
            color: finalColor.isEmpty ? nil : finalColor,
            photoData: photoData,
            displayOrder: maxDisplayOrder + 1
        )

        modelContext.insert(wing)

        Task { @MainActor in
            try? modelContext.save()
            watchManager.sendWingsToWatch()
        }

        dismiss()
    }
}

// MARK: - EditWingView (Modifier une voile)

struct EditWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    let wing: Wing

    @State private var name: String
    @State private var size: String
    @State private var type: String
    @State private var color: String
    @State private var customColor: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?

    let types = ["Soaring", "Cross", "Thermique", "Speedflying", "Acro"]
    let colors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir", "Pétrole", "Autre..."]

    init(wing: Wing) {
        self.wing = wing
        _name = State(initialValue: wing.name)
        _size = State(initialValue: wing.size ?? "")
        _type = State(initialValue: wing.type ?? "Soaring")
        // Si la couleur actuelle n'est pas dans la liste, utiliser "Autre..."
        let existingColor = wing.color ?? "Bleu"
        let standardColors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir", "Pétrole"]
        if standardColors.contains(existingColor) {
            _color = State(initialValue: existingColor)
            _customColor = State(initialValue: "")
        } else {
            _color = State(initialValue: "Autre...")
            _customColor = State(initialValue: existingColor)
        }
        _photoData = State(initialValue: wing.photoData)
    }

    var body: some View {
        NavigationStack {
            Form {
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
                        Label("Changer la photo", systemImage: "photo.on.rectangle.angled")
                    }

                    if photoData != nil {
                        Button(role: .destructive) {
                            photoData = nil
                        } label: {
                            Label("Supprimer la photo", systemImage: "trash")
                        }
                    }
                }

                Section("Informations") {
                    TextField("Nom", text: $name)
                    HStack {
                        TextField("Taille", text: $size)
                            .keyboardType(.decimalPad)
                            .onChange(of: size) { _, newValue in
                                // Filtrer pour ne garder que les chiffres et le point/virgule
                                let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                                if filtered != newValue {
                                    size = filtered
                                }
                            }
                        Text("m²")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Caractéristiques") {
                    Picker("Type", selection: $type) {
                        ForEach(types, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }

                    Picker("Couleur", selection: $color) {
                        ForEach(colors, id: \.self) { color in
                            Text(color).tag(color)
                        }
                    }

                    if color == "Autre..." {
                        TextField("Couleur personnalisée", text: $customColor)
                    }
                }
            }
            .navigationTitle("Modifier la voile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saveWing()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onChange(of: selectedPhoto) { _, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        photoData = data
                    }
                }
            }
        }
    }

    private func saveWing() {
        // Utiliser la couleur personnalisée si "Autre..." est sélectionné
        let finalColor = color == "Autre..." ? customColor : color

        wing.name = name
        wing.size = size.isEmpty ? nil : size
        wing.type = type
        wing.color = finalColor.isEmpty ? nil : finalColor
        wing.photoData = photoData

        // Invalider le cache d'image si la photo a changé
        ImageCacheManager.shared.invalidate(key: wing.id.uuidString)

        Task { @MainActor in
            try? modelContext.save()
            watchManager.sendWingsToWatch()
        }

        dismiss()
    }
}

// MARK: - WingDetailView (Détail d'une voile)

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
                    // Photo de la voile (tappable pour afficher en plein écran)
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
                        // Placeholder quand pas de photo
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

                        HStack(spacing: 20) {
                            if let size = wing.size {
                                Label("\(size) m²", systemImage: "ruler")
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

            Section("Statistiques") {
                let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
                let totalHours = Double(totalSeconds) / 3600.0
                HStack {
                    Text("Heures de vol")
                    Spacer()
                    Text(dataController.formatHours(totalHours))
                        .foregroundStyle(.blue)
                }

                HStack {
                    Text("Nombre de vols")
                    Spacer()
                    Text("\(flights.count)")
                        .foregroundStyle(.blue)
                }
            }

            if !flights.isEmpty {
                Section("Historique des vols") {
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
        .navigationTitle("Détails")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingEditWing = true
                } label: {
                    Label("Modifier", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showingEditWing) {
            EditWingView(wing: wing)
        }
        .sheet(item: $selectedFlight) { flight in
            EditFlightView(flight: flight)
                .onAppear {
                    // Vérifier immédiatement si le vol a été supprimé
                    if flight.isDeleted {
                        selectedFlight = nil
                    }
                }
        }
        .onChange(of: allFlights.count) { oldValue, newValue in
            // Si un vol est supprimé, fermer immédiatement la sheet
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
                            // Limiter le zoom entre 1x et 4x
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
                    // Double-tap pour réinitialiser le zoom
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

// MARK: - ArchivedWingsView (Liste des voiles archivées)

struct ArchivedWingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Wing> { $0.isArchived }, sort: \Wing.createdAt, order: .reverse) private var archivedWings: [Wing]
    @State private var selectedWing: Wing?
    @State private var showingDeleteAlert = false
    @State private var wingToDelete: Wing?

    var body: some View {
        List {
            if archivedWings.isEmpty {
                ContentUnavailableView(
                    "Aucune voile archivée",
                    systemImage: "archivebox",
                    description: Text("Les voiles archivées apparaîtront ici")
                )
            } else {
                ForEach(archivedWings) { wing in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            // Photo de la voile ou icône par défaut
                            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                                    .frame(width: 50, height: 50)
                                    .overlay {
                                        Image(systemName: "wind")
                                            .foregroundStyle(colorFromString(wing.color ?? "Gris"))
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

                                // Nombre de vols
                                let flightCount = wing.flights?.count ?? 0
                                if flightCount > 0 {
                                    Text("\(flightCount) vol\(flightCount > 1 ? "s" : "")")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }

                        // Boutons d'action
                        HStack(spacing: 12) {
                            Button {
                                dataController.unarchiveWing(wing)
                            } label: {
                                Label("Restaurer", systemImage: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                wingToDelete = wing
                                showingDeleteAlert = true
                            } label: {
                                Label("Supprimer", systemImage: "trash")
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
        .navigationTitle("Voiles archivées")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Supprimer définitivement ?", isPresented: $showingDeleteAlert) {
            Button("Annuler", role: .cancel) { }
            Button("Supprimer", role: .destructive) {
                if let wing = wingToDelete {
                    dataController.permanentlyDeleteWing(wing)
                }
            }
        } message: {
            if let wing = wingToDelete {
                let flightCount = wing.flights?.count ?? 0
                Text("⚠️ Cette action est irréversible ! La voile \"\(wing.name)\" et ses \(flightCount) vol\(flightCount > 1 ? "s" : "") seront définitivement supprimés.")
            }
        }
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge": return .red
        case "bleu": return .blue
        case "vert": return .green
        case "jaune": return .yellow
        case "orange": return .orange
        case "violet": return .purple
        case "noir": return .black
        default: return .gray
        }
    }
}
