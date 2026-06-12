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

    // État pour la suppression - géré au niveau parent pour éviter le crash
    @State private var wingToDelete: Wing?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        List {
            if wings.isEmpty {
                ContentUnavailableView(
                    "Aucune voile",
                    systemImage: "wind",
                    description: Text("Ajoutez votre première voile")
                )
            } else {
                ForEach(wings) { wing in
                    WingListRow(wing: wing, onDeleteTapped: {
                        wingToDelete = wing
                        showingDeleteConfirmation = true
                    })
                }
                .onMove(perform: moveWing)
            }
        }
        .navigationTitle(String(localized: "Mes voiles"))
        .id(localizationManager.currentLanguage)
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
            AddWingChoiceView()
        }
        .alert(
                wingToDelete.map { "Supprimer \"\($0.name)\" ?" } ?? "Supprimer ?",
                isPresented: $showingDeleteConfirmation
            ) {
                Button("Archiver") {
                    if let wing = wingToDelete {
                        withAnimation {
                            dataController.archiveWing(wing)
                        }
                    }
                    wingToDelete = nil
                }
                Button("Supprimer définitivement", role: .destructive) {
                    if let wing = wingToDelete {
                        withAnimation {
                            modelContext.delete(wing)
                            try? modelContext.save()
                            dataController.statsCache.invalidate()
                            watchManager.sendWingsToWatch()
                        }
                    }
                    wingToDelete = nil
                }
                Button("Annuler", role: .cancel) {
                    wingToDelete = nil
                }
        } message: {
            if let wing = wingToDelete {
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

// MARK: - WingListRow (Row avec navigation)

/// Row de la liste - la suppression est gérée par le parent WingsView
struct WingListRow: View {
    let wing: Wing
    let onDeleteTapped: () -> Void

    var body: some View {
        NavigationLink {
            WingDetailView(wing: wing)
        } label: {
            WingRow(wing: wing)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDeleteTapped()
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }
}

// MARK: - WingRow

struct WingRow: View {
    let wing: Wing
    @Environment(DataController.self) private var dataController
    @State private var photoData: Data?
    @State private var isLoadingPhoto = true

    private let thumbnailSize = CGSize(width: 60, height: 60)

    var body: some View {
        HStack(spacing: 12) {
            // Photo de la voile avec cache ou icône par défaut
            if isLoadingPhoto {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
            } else if let data = photoData {
                CachedImage(
                    data: data,
                    key: wing.id.uuidString,
                    size: thumbnailSize
                ) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill((wing.color ?? "Gris").toColor().opacity(0.3))
                        .overlay {
                            Image(systemName: "wind")
                                .font(.title2)
                                .foregroundStyle((wing.color ?? "Gris").toColor())
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill((wing.color ?? "Gris").toColor().opacity(0.3))
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .overlay {
                        Image(systemName: "wind")
                            .font(.title2)
                            .foregroundStyle((wing.color ?? "Gris").toColor())
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                // Titre : nom du modèle + pastille "Empruntée" + alerte révision
                HStack(spacing: 6) {
                    Text(wing.name)
                        .font(.headline)

                    if !wing.isOwned {
                        Text("Empruntée")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.gray.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }

                    if wing.isMaintenanceDue {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Sous-titre : taille • marque • type
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
        .task {
            // Charger photoData sur un thread background
            let data = await Task.detached(priority: .userInitiated) { [wing] in
                return wing.photoData
            }.value
            photoData = data
            isLoadingPhoto = false
        }
    }
}

// MARK: - AddWingChoiceView (Choix du mode d'ajout)

/// Données pré-remplies depuis la bibliothèque pour le formulaire manuel
/// (la photo est le PNG détouré téléchargé depuis GitHub)
struct LibraryWingPrefill: Identifiable {
    let id = UUID()
    let name: String
    let brand: String?
    let size: String?
    let type: String?
    let photoData: Data?
}

/// Vue principale d'ajout de voile : « Depuis la bibliothèque » vs « Saisie manuelle »
/// La sélection bibliothèque pré-remplit le formulaire manuel (infos + photo détourée)
/// pour que l'utilisateur puisse régler propriété/maintenance avant de sauver.
struct AddWingChoiceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showingLibrary = false
    @State private var showingManualForm = false
    @State private var libraryPrefill: LibraryWingPrefill?
    @State private var isPreparingLibraryWing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Icône principale
                Image(systemName: "wind")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text(String(localized: "addWing.title"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(String(localized: "addWing.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                // Deux gros boutons
                VStack(spacing: 16) {
                    // Bouton Bibliothèque
                    Button {
                        showingLibrary = true
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "book.closed.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "addWing.fromLibrary"))
                                    .font(.headline)
                                Text(String(localized: "addWing.fromLibraryDesc"))
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
                    .disabled(isPreparingLibraryWing)
                    // Sheet attaché au bouton (plusieurs sheets sur la même vue = conflit)
                    .sheet(isPresented: $showingLibrary) {
                        WingLibraryView { libraryWing, selectedSize in
                            prepareLibraryWing(libraryWing, size: selectedSize)
                        }
                    }

                    // Bouton Saisie manuelle
                    Button {
                        showingManualForm = true
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "addWing.custom"))
                                    .font(.headline)
                                Text(String(localized: "addWing.customDesc"))
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
                    .disabled(isPreparingLibraryWing)
                    .sheet(isPresented: $showingManualForm) {
                        AddWingView(onSaved: { dismiss() })
                    }
                }
                .padding(.horizontal, 24)

                if isPreparingLibraryWing {
                    ProgressView()
                        .padding()
                }

                Spacer()
            }
            .navigationTitle(String(localized: "addWing.navTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                    .disabled(isPreparingLibraryWing)
                }
            }
            // Formulaire pré-rempli depuis la bibliothèque
            .sheet(item: $libraryPrefill) { prefill in
                AddWingView(prefill: prefill, onSaved: { dismiss() })
            }
        }
    }

    /// Télécharge la photo détourée puis ouvre le formulaire manuel pré-rempli
    /// (l'utilisateur peut ajuster propriété/maintenance avant de sauver)
    private func prepareLibraryWing(_ libraryWing: LibraryWing, size: String) {
        isPreparingLibraryWing = true

        Task {
            // Télécharger l'image PNG détourée (cache mémoire/disque sinon GitHub)
            let imageData = await WingLibraryService.shared.image(for: libraryWing)

            // Nom du fabricant depuis le catalogue
            let manufacturerName = WingLibraryService.shared.manufacturerName(for: libraryWing)

            // Laisser la sheet bibliothèque finir de se fermer avant d'en présenter une autre
            try? await Task.sleep(nanoseconds: 350_000_000)

            await MainActor.run {
                // name = modèle seul (ex: "Moustache M1"), brand = marque (ex: "Flare")
                libraryPrefill = LibraryWingPrefill(
                    name: libraryWing.model,
                    brand: manufacturerName,
                    size: size,
                    type: libraryWing.type,
                    photoData: imageData
                )
                isPreparingLibraryWing = false
            }
        }
    }
}

// MARK: - AddWingView (Formulaire manuel)

/// Formulaire d'ajout manuel d'une voile (éventuellement pré-rempli depuis la bibliothèque)
struct AddWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    /// Callback appelé après une sauvegarde réussie (permet de fermer la vue parente)
    private let onSaved: (() -> Void)?

    @State private var name: String = ""
    @State private var brand: String = ""
    @State private var size: String = ""
    @State private var type: String = "Soaring"
    @State private var color: String = "Bleu"
    @State private var customColor: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showSaveError: Bool = false

    // Propriété & maintenance
    @State private var isOwned: Bool = true
    @State private var hasPurchaseDate: Bool = false
    @State private var purchaseDate: Date = Date()
    @State private var initialHoursText: String = ""
    @State private var maintenanceIntervalText: String = ""

    let types = ["Soaring", "Cross", "Thermique", "Speedflying", "Acro"]
    let colors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir", "Pétrole", "Autre..."]

    /// - Parameters:
    ///   - prefill: infos + photo détourée venant de la bibliothèque (nil = saisie vierge)
    ///   - onSaved: appelé après une sauvegarde réussie (ferme la vue de choix parente)
    init(prefill: LibraryWingPrefill? = nil, onSaved: (() -> Void)? = nil) {
        self.onSaved = onSaved

        if let prefill {
            _name = State(initialValue: prefill.name)
            _brand = State(initialValue: prefill.brand ?? "")
            _size = State(initialValue: prefill.size ?? "")
            if let prefillType = prefill.type, types.contains(prefillType) {
                _type = State(initialValue: prefillType)
            }
            _photoData = State(initialValue: prefill.photoData)
            // Couleur inconnue depuis la bibliothèque : champ libre vide → nil si non renseigné
            _color = State(initialValue: "Autre...")
        }
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
                        Label("Choisir une photo", systemImage: "photo.on.rectangle.angled")
                    }
                }

                Section("Informations") {
                    TextField("Modèle", text: $name)
                    TextField("Marque", text: $brand)
                    HStack {
                        TextField("Taille", text: $size)
                            .keyboardType(.decimalPad)
                            .onChange(of: size) { _, newValue in
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

                Section {
                    Toggle("C'est ma voile", isOn: $isOwned)

                    if isOwned {
                        Toggle("Date d'achat connue", isOn: $hasPurchaseDate)
                        if hasPurchaseDate {
                            DatePicker("Date d'achat", selection: $purchaseDate, displayedComponents: .date)
                        }

                        HStack {
                            Text("Heures à l'achat")
                            Spacer()
                            TextField("0", text: $initialHoursText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: initialHoursText) { _, newValue in
                                    let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                                    if filtered != newValue {
                                        initialHoursText = filtered
                                    }
                                }
                            Text("h")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Intervalle de révision")
                            Spacer()
                            TextField("—", text: $maintenanceIntervalText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: maintenanceIntervalText) { _, newValue in
                                    let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                                    if filtered != newValue {
                                        maintenanceIntervalText = filtered
                                    }
                                }
                            Text("h")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Propriété")
                } footer: {
                    if isOwned {
                        Text("Intervalle de révision suggéré : 100 h ou 1 an. Laissez vide pour désactiver le suivi.")
                    } else {
                        Text("Voile empruntée ou testée : les heures comptent pour votre expérience, pas de suivi matériel.")
                    }
                }
            }
            .navigationTitle(String(localized: "addWing.navTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.add")) {
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
            .alert("Erreur de sauvegarde", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Impossible de sauvegarder la voile. Veuillez réessayer.")
            }
        }
    }

    private func addWing() {
        let descriptor = FetchDescriptor<Wing>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\Wing.displayOrder, order: .reverse)]
        )
        let maxDisplayOrder = (try? modelContext.fetch(descriptor).first?.displayOrder) ?? -1

        let finalColor = color == "Autre..." ? customColor : color

        let wing = Wing(
            name: name,
            brand: brand.isEmpty ? nil : brand,
            size: size.isEmpty ? nil : size,
            type: type,
            color: finalColor.isEmpty ? nil : finalColor,
            photoData: photoData,
            displayOrder: maxDisplayOrder + 1
        )

        // Propriété & maintenance
        wing.isOwned = isOwned
        if isOwned {
            wing.purchaseDate = hasPurchaseDate ? purchaseDate : nil
            wing.initialHours = Self.parseHours(initialHoursText) ?? 0
            wing.maintenanceIntervalHours = Self.parseHours(maintenanceIntervalText)
        }

        modelContext.insert(wing)

        Task { @MainActor in
            do {
                try modelContext.save()
                watchManager.sendWingsToWatch()
                dismiss()
                // Ferme aussi la vue de choix parente (bibliothèque vs manuel)
                onSaved?()
            } catch {
                logError("Failed to save wing: \(error.localizedDescription)", category: .dataController)
                showSaveError = true
            }
        }
    }

    /// Convertit un texte saisi ("12,5" ou "12.5") en heures, nil si vide ou invalide
    static func parseHours(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, let value = Double(normalized), value >= 0 else { return nil }
        return value
    }
}

// MARK: - EditWingView (Modifier une voile)

struct EditWingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var watchManager

    let wing: Wing
    private let wingId: UUID

    @State private var name: String
    @State private var brand: String
    @State private var size: String
    @State private var type: String
    @State private var color: String
    @State private var customColor: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var isLoadingPhoto: Bool = true
    @State private var showSaveError: Bool = false

    // Propriété & maintenance
    @State private var isOwned: Bool
    @State private var hasPurchaseDate: Bool
    @State private var purchaseDate: Date
    @State private var initialHoursText: String
    @State private var maintenanceIntervalText: String
    @State private var isSold: Bool
    @State private var soldDate: Date

    let types = ["Soaring", "Cross", "Thermique", "Speedflying", "Acro"]
    let colors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir", "Pétrole", "Autre..."]

    /// Formatte des heures en texte de champ ("12" ou "12.5"), vide si nil ou 0
    private static func hoursFieldText(_ value: Double?) -> String {
        guard let value, value > 0 else { return "" }
        return value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    init(wing: Wing) {
        self.wing = wing
        self.wingId = wing.id
        _name = State(initialValue: wing.name)
        _brand = State(initialValue: wing.brand ?? "")
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
        // Ne pas accéder à photoData dans l'init - sera chargé dans .task
        _photoData = State(initialValue: nil)
        _isLoadingPhoto = State(initialValue: true)

        // Propriété & maintenance
        _isOwned = State(initialValue: wing.isOwned)
        _hasPurchaseDate = State(initialValue: wing.purchaseDate != nil)
        _purchaseDate = State(initialValue: wing.purchaseDate ?? Date())
        _initialHoursText = State(initialValue: Self.hoursFieldText(wing.initialHours))
        _maintenanceIntervalText = State(initialValue: Self.hoursFieldText(wing.maintenanceIntervalHours))
        _isSold = State(initialValue: wing.soldDate != nil)
        _soldDate = State(initialValue: wing.soldDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    HStack {
                        Spacer()
                        if isLoadingPhoto {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 120, height: 120)
                                .overlay {
                                    ProgressView()
                                }
                        } else if let photoData = photoData, let uiImage = UIImage(data: photoData) {
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
                    TextField("Modèle", text: $name)
                    TextField("Marque", text: $brand)
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

                Section {
                    Toggle("C'est ma voile", isOn: $isOwned)

                    if isOwned {
                        Toggle("Date d'achat connue", isOn: $hasPurchaseDate)
                        if hasPurchaseDate {
                            DatePicker("Date d'achat", selection: $purchaseDate, displayedComponents: .date)
                        }

                        HStack {
                            Text("Heures à l'achat")
                            Spacer()
                            TextField("0", text: $initialHoursText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: initialHoursText) { _, newValue in
                                    let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                                    if filtered != newValue {
                                        initialHoursText = filtered
                                    }
                                }
                            Text("h")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Intervalle de révision")
                            Spacer()
                            TextField("—", text: $maintenanceIntervalText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: maintenanceIntervalText) { _, newValue in
                                    let filtered = newValue.filter { $0.isNumber || $0 == "." || $0 == "," }
                                    if filtered != newValue {
                                        maintenanceIntervalText = filtered
                                    }
                                }
                            Text("h")
                                .foregroundStyle(.secondary)
                        }

                        Toggle("Vendue", isOn: $isSold)
                        if isSold {
                            DatePicker("Date de revente", selection: $soldDate, displayedComponents: .date)
                        }
                    }
                } header: {
                    Text("Propriété")
                } footer: {
                    if isOwned {
                        Text("Intervalle de révision suggéré : 100 h ou 1 an. Laissez vide pour désactiver le suivi.")
                    } else {
                        Text("Voile empruntée ou testée : les heures comptent pour votre expérience, pas de suivi matériel.")
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
            .task {
                // Charger la photo sur un thread background pour éviter le freeze
                // L'accès à wing.photoData peut déclencher un chargement SwiftData synchrone
                let loadedData = await Task.detached(priority: .userInitiated) { [wing] in
                    return wing.photoData
                }.value
                photoData = loadedData
                isLoadingPhoto = false
            }
            .onChange(of: selectedPhoto) { _, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        photoData = data
                    }
                }
            }
            .alert("Erreur de sauvegarde", isPresented: $showSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Impossible de sauvegarder les modifications. Veuillez réessayer.")
            }
        }
    }

    private func saveWing() {
        // Utiliser la couleur personnalisée si "Autre..." est sélectionné
        let finalColor = color == "Autre..." ? customColor : color

        wing.name = name
        wing.brand = brand.isEmpty ? nil : brand
        wing.size = size.isEmpty ? nil : size
        wing.type = type
        wing.color = finalColor.isEmpty ? nil : finalColor
        wing.photoData = photoData

        // Propriété & maintenance
        wing.isOwned = isOwned
        if isOwned {
            wing.purchaseDate = hasPurchaseDate ? purchaseDate : nil
            wing.initialHours = AddWingView.parseHours(initialHoursText) ?? 0
            wing.maintenanceIntervalHours = AddWingView.parseHours(maintenanceIntervalText)
            wing.soldDate = isSold ? soldDate : nil
        }
        // Si la voile n'est plus possédée, on conserve les données existantes
        // (jamais de suppression silencieuse) — isMaintenanceDue est déjà
        // neutralisé par le guard isOwned du modèle.

        // Invalider le cache d'image si la photo a changé
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

// MARK: - WingDetailView (Détail d'une voile)

struct WingDetailView: View {
    let wing: Wing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DataController.self) private var dataController
    @State private var showingEditWing = false
    @State private var selectedFlight: Flight?
    @State private var showingFullScreenPhoto = false
    @State private var photoImage: UIImage?
    @State private var isLoadingPhoto = true
    @State private var showingMaintenanceConfirmation = false

    /// Utilise la relation inverse wing.flights au lieu de @Query pour éviter de charger tous les vols
    var flights: [Flight] {
        wing.flights ?? []
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    // Photo de la voile (tappable pour afficher en plein écran)
                    if isLoadingPhoto {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 150)
                            .overlay {
                                ProgressView()
                            }
                    } else if let uiImage = photoImage {
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

            // Bandeau voile vendue
            if wing.isOwned, let soldDate = wing.soldDate {
                Section {
                    Label("Vendue le \(soldDate.formatted(date: .long, time: .omitted))", systemImage: "tag.slash")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                }
            }

            // Compteur matériel (voiles possédées uniquement)
            if wing.isOwned {
                Section("Compteur matériel") {
                    HStack {
                        Text("Heures totales")
                        Spacer()
                        Text(dataController.formatHours(wing.totalAirframeHours))
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                    }

                    // Détail : heures à l'achat + heures enregistrées
                    HStack {
                        Text("Détail")
                        Spacer()
                        Text("\(dataController.formatHours(wing.initialHours)) à l'achat + \(dataController.formatHours(wing.loggedHours)) enregistrées")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Depuis dernière révision")
                        Spacer()
                        Text(dataController.formatHours(wing.hoursSinceMaintenance))
                            .foregroundStyle(wing.isMaintenanceDue ? .orange : .secondary)
                    }

                    if let lastDate = wing.lastMaintenanceDate {
                        HStack {
                            Text("Dernière révision")
                            Spacer()
                            Text(lastDate.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Progression vers l'intervalle de révision
                    if let interval = wing.maintenanceIntervalHours, interval > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: min(wing.hoursSinceMaintenance, interval), total: interval)
                                .tint(wing.isMaintenanceDue ? .orange : .blue)

                            HStack {
                                Text("\(dataController.formatHours(wing.hoursSinceMaintenance)) / \(dataController.formatHours(interval))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                if wing.isMaintenanceDue {
                                    Label("Révision à prévoir", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if wing.soldDate == nil {
                        Button {
                            showingMaintenanceConfirmation = true
                        } label: {
                            Label("Révision effectuée", systemImage: "wrench.and.screwdriver")
                        }
                    }
                }
            } else {
                // Voile empruntée : pas de suivi matériel
                Section {
                    Label("Voile empruntée — pas de suivi matériel, les heures comptent pour ton expérience", systemImage: "person.2")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
        .confirmationDialog(
            "Marquer la révision comme effectuée ?",
            isPresented: $showingMaintenanceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Révision effectuée") {
                markMaintenanceDone()
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Le compteur de révision repartira de \(dataController.formatHours(wing.totalAirframeHours)) (compteur total actuel).")
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
        .fullScreenCover(isPresented: $showingFullScreenPhoto) {
            if let uiImage = photoImage {
                FullScreenPhotoView(image: uiImage, wingName: wing.name)
            }
        }
        .task {
            // Charger la photo sur un thread background pour éviter le freeze
            let loadedImage = await Task.detached(priority: .userInitiated) { [wing] in
                guard let data = wing.photoData else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            photoImage = loadedImage
            isLoadingPhoto = false
        }
    }

    /// Enregistre une révision : le compteur de maintenance repart du compteur total actuel
    private func markMaintenanceDone() {
        wing.lastMaintenanceHours = wing.totalAirframeHours
        wing.lastMaintenanceDate = Date()
        do {
            try modelContext.save()
            logInfo("Maintenance recorded for wing \(wing.name)", category: .dataController)
        } catch {
            logError("Failed to save maintenance: \(error.localizedDescription)", category: .dataController)
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
                                    .fill((wing.color ?? "Gris").toColor().opacity(0.3))
                                    .frame(width: 50, height: 50)
                                    .overlay {
                                        Image(systemName: "wind")
                                            .foregroundStyle((wing.color ?? "Gris").toColor())
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
                    // Utiliser le modelContext de la vue pour que @Query soit mis à jour
                    modelContext.delete(wing)
                    try? modelContext.save()
                    // Invalider le cache de stats
                    dataController.statsCache.invalidate()
                }
            }
        } message: {
            if let wing = wingToDelete {
                let flightCount = wing.flights?.count ?? 0
                Text("⚠️ Cette action est irréversible ! La voile \"\(wing.name)\" et ses \(flightCount) vol\(flightCount > 1 ? "s" : "") seront définitivement supprimés.")
            }
        }
    }
}
