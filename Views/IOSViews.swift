//
//  IOSViews.swift
//  ParaFlightLog
//
//  Toutes les vues SwiftUI pour l'app iOS
//  Target: iOS only
//

import SwiftUI
import SwiftData
import Charts
import PhotosUI

// MARK: - ContentView (TabView principale)

struct ContentView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager

    var body: some View {
        TabView {
            WingsView()
                .tabItem {
                    Label("Voiles", systemImage: "wind")
                }

            FlightsView()
                .tabItem {
                    Label("Vols", systemImage: "airplane")
                }

            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar")
                }

            TimerView()
                .tabItem {
                    Label("Chrono", systemImage: "timer")
                }

            SettingsView()
                .tabItem {
                    Label("Réglages", systemImage: "gearshape")
                }
        }
    }
}

// MARK: - FlightsView (Liste des vols avec édition)

struct FlightsView: View {
    @Environment(DataController.self) private var dataController
    @Query(sort: \Flight.startDate, order: .reverse) private var flights: [Flight]
    @State private var selectedFlight: Flight?

    var body: some View {
        NavigationStack {
            List {
                if flights.isEmpty {
                    ContentUnavailableView(
                        "Aucun vol",
                        systemImage: "airplane.circle",
                        description: Text("Commencez un vol depuis la Watch ou l'onglet Chrono")
                    )
                } else {
                    ForEach(flights) { flight in
                        FlightRow(flight: flight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedFlight = flight
                            }
                    }
                    .onDelete(perform: deleteFlights)
                }
            }
            .navigationTitle("Mes vols")
            .sheet(item: $selectedFlight) { flight in
                EditFlightView(flight: flight)
            }
        }
    }

    private func deleteFlights(at offsets: IndexSet) {
        for index in offsets {
            dataController.deleteFlight(flights[index])
        }
    }
}

struct FlightRow: View {
    let flight: Flight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(flight.dateFormatted)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(flight.durationFormatted)
                    .font(.headline)
                    .foregroundStyle(.blue)
            }

            if let wingName = flight.wing?.name {
                Text(wingName)
                    .font(.body)
                    .fontWeight(.medium)
            }

            if let spotName = flight.spotName {
                Label(spotName, systemImage: "location.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - EditFlightView (Éditer un vol)

struct EditFlightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.createdAt, order: .reverse) private var wings: [Wing]

    let flight: Flight

    @State private var selectedWing: Wing?
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var spotName: String
    @State private var notes: String

    init(flight: Flight) {
        self.flight = flight
        _startDate = State(initialValue: flight.startDate)
        _endDate = State(initialValue: flight.endDate)
        _spotName = State(initialValue: flight.spotName ?? "")
        _notes = State(initialValue: flight.notes ?? "")
    }

    var calculatedDuration: Int {
        Int(endDate.timeIntervalSince(startDate))
    }

    var durationFormatted: String {
        let duration = max(0, calculatedDuration)
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date et heure") {
                    DatePicker("Début du vol", selection: $startDate)
                    DatePicker("Fin du vol", selection: $endDate)

                    HStack {
                        Text("Durée calculée")
                        Spacer()
                        Text(durationFormatted)
                            .foregroundStyle(calculatedDuration < 0 ? .red : .secondary)
                    }

                    if calculatedDuration < 0 {
                        Text("⚠️ La fin doit être après le début")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Voile utilisée") {
                    Picker("Voile", selection: $selectedWing) {
                        Text("Aucune").tag(nil as Wing?)
                        ForEach(wings) { wing in
                            Text(wing.name).tag(wing as Wing?)
                        }
                    }
                }

                Section("Spot") {
                    TextField("Nom du spot", text: $spotName)

                    if let lat = flight.latitude, let lon = flight.longitude {
                        HStack {
                            Text("Coordonnées")
                            Spacer()
                            Text("\(lat, specifier: "%.4f"), \(lon, specifier: "%.4f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle("Modifier le vol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        saveFlight()
                    }
                    .disabled(calculatedDuration < 0)
                }
            }
            .onAppear {
                selectedWing = flight.wing
            }
        }
    }

    private func saveFlight() {
        flight.wing = selectedWing
        flight.startDate = startDate
        flight.endDate = endDate
        flight.durationSeconds = calculatedDuration
        flight.spotName = spotName.isEmpty ? nil : spotName
        flight.notes = notes.isEmpty ? nil : notes

        Task { @MainActor in
            try? modelContext.save()
        }

        dismiss()
    }
}

// MARK: - WingsView (Liste + ajout de voiles)

struct WingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.createdAt, order: .reverse) private var wings: [Wing]
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
                }
            }
            .navigationTitle("Mes voiles")
            .toolbar {
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
}

struct WingRow: View {
    let wing: Wing
    @Environment(DataController.self) private var dataController

    var body: some View {
        HStack(spacing: 12) {
            // Photo de la voile ou icône par défaut
            if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorFromString(wing.color ?? "Gris").opacity(0.3))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "wind")
                            .font(.title2)
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
        case "rouge", "red": return .red
        case "bleu", "blue": return .blue
        case "vert", "green": return .green
        case "jaune", "yellow": return .yellow
        case "orange": return .orange
        case "violet", "purple": return .purple
        case "noir", "black": return .black
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
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?

    let types = ["Soaring", "Cross", "Acro", "Débutant"]
    let colors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir"]

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
                    TextField("Taille (ex: 22 m²)", text: $size)
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
        let wing = Wing(
            name: name,
            size: size.isEmpty ? nil : size,
            type: type,
            color: color,
            photoData: photoData
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
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?

    let types = ["Soaring", "Cross", "Acro", "Débutant"]
    let colors = ["Bleu", "Rouge", "Vert", "Jaune", "Orange", "Violet", "Noir"]

    init(wing: Wing) {
        self.wing = wing
        _name = State(initialValue: wing.name)
        _size = State(initialValue: wing.size ?? "")
        _type = State(initialValue: wing.type ?? "Soaring")
        _color = State(initialValue: wing.color ?? "Bleu")
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
                    TextField("Taille (ex: 22 m²)", text: $size)
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
        wing.name = name
        wing.size = size.isEmpty ? nil : size
        wing.type = type
        wing.color = color
        wing.photoData = photoData

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

    var flights: [Flight] {
        allFlights.filter { $0.wing?.id == wing.id }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    // Photo de la voile
                    if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                    .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .padding(.bottom, 8)
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
        }
    }
}

// MARK: - StatsView (Statistiques améliorées)

struct StatsView: View {
    @Environment(DataController.self) private var dataController
    @Query private var flights: [Flight]
    @Query(filter: #Predicate<Wing> { !$0.isArchived }) private var wings: [Wing]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Carte totale
                    TotalStatsCard(flights: flights)

                    // Tableau et graphique par voile
                    StatsByWingSection(flights: flights, wings: wings)

                    // Tableau et graphique par spot
                    StatsBySpotSection(flights: flights)
                }
                .padding()
            }
            .navigationTitle("Statistiques")
            .background(Color(.systemGroupedBackground))
        }
    }
}

// MARK: - TotalStatsCard

struct TotalStatsCard: View {
    let flights: [Flight]

    var body: some View {
        VStack(spacing: 16) {
            Text("Total")
                .font(.title2)
                .fontWeight(.bold)

            let totalSeconds = flights.reduce(0) { $0 + $1.durationSeconds }
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60

            HStack(spacing: 40) {
                VStack(spacing: 4) {
                    Text("\(flights.count)")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.blue)
                    Text("session\(flights.count > 1 ? "s" : "")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(hours)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.green)
                        Text("h")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("\(minutes)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.green)
                        Text("min")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("temps de vol")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

// MARK: - StatsByWingSection

struct StatsByWingSection: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    let wings: [Wing]
    @State private var selectedWing: Wing?
    @State private var showingDetail = false

    var wingStats: [(wing: Wing, sessions: Int, hours: Int, minutes: Int)] {
        wings.compactMap { wing in
            let wingFlights = flights.filter { $0.wing?.id == wing.id }
            guard !wingFlights.isEmpty else { return nil }

            let totalSeconds = wingFlights.reduce(0) { $0 + $1.durationSeconds }
            return (
                wing: wing,
                sessions: wingFlights.count,
                hours: totalSeconds / 3600,
                minutes: (totalSeconds % 3600) / 60
            )
        }
        .sorted { $0.hours * 60 + $0.minutes > $1.hours * 60 + $1.minutes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Par voile")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if wingStats.isEmpty {
                Text("Aucune donnée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                // Tableau
                VStack(spacing: 0) {
                    // En-tête
                    HStack {
                        Text("Voile")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Sessions")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("Temps")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    // Lignes
                    ForEach(wingStats, id: \.wing.id) { stat in
                        Button {
                            selectedWing = stat.wing
                            showingDetail = true
                        } label: {
                            HStack {
                                Text(stat.wing.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(stat.sessions)")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                                    .frame(width: 70, alignment: .trailing)

                                Text("\(stat.hours)h \(String(format: "%02d", stat.minutes))m")
                                    .font(.body)
                                    .foregroundStyle(.green)
                                    .frame(width: 80, alignment: .trailing)

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }

                        if stat.wing.id != wingStats.last?.wing.id {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)

                // Graphique
                if #available(iOS 16.0, *) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Répartition des heures")
                            .font(.headline)
                            .padding(.horizontal)

                        Chart {
                            ForEach(wingStats, id: \.wing.id) { stat in
                                BarMark(
                                    x: .value("Heures", Double(stat.hours * 60 + stat.minutes) / 60.0),
                                    y: .value("Voile", stat.wing.name)
                                )
                                .foregroundStyle(.blue.gradient)
                                .annotation(position: .trailing, alignment: .leading) {
                                    Text(stat.hours > 0 ? "\(stat.hours)h\(String(format: "%02d", stat.minutes))" : "\(stat.minutes)min")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(height: CGFloat(max(200, wingStats.count * 50)))
                        .chartXAxis {
                            AxisMarks(position: .bottom)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let wing = selectedWing {
                WingFlightsDetailView(wing: wing, flights: flights)
            }
        }
    }
}

// MARK: - StatsBySpotSection

struct StatsBySpotSection: View {
    @Environment(DataController.self) private var dataController
    let flights: [Flight]
    @State private var selectedSpot: String?
    @State private var showingDetail = false

    var spotStats: [(spot: String, sessions: Int, hours: Int, minutes: Int)] {
        let grouped = Dictionary(grouping: flights, by: { $0.spotName ?? "Spot inconnu" })

        return grouped.map { spot, spotFlights in
            let totalSeconds = spotFlights.reduce(0) { $0 + $1.durationSeconds }
            return (
                spot: spot,
                sessions: spotFlights.count,
                hours: totalSeconds / 3600,
                minutes: (totalSeconds % 3600) / 60
            )
        }
        .sorted { $0.hours * 60 + $0.minutes > $1.hours * 60 + $1.minutes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Par spot")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if spotStats.isEmpty {
                Text("Aucune donnée")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
            } else {
                // Tableau
                VStack(spacing: 0) {
                    // En-tête
                    HStack {
                        Text("Spot")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Sessions")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)

                        Text("Temps")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))

                    // Lignes
                    ForEach(spotStats, id: \.spot) { stat in
                        Button {
                            selectedSpot = stat.spot
                            showingDetail = true
                        } label: {
                            HStack {
                                Text(stat.spot)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(stat.sessions)")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                                    .frame(width: 70, alignment: .trailing)

                                Text("\(stat.hours)h \(String(format: "%02d", stat.minutes))m")
                                    .font(.body)
                                    .foregroundStyle(.green)
                                    .frame(width: 80, alignment: .trailing)

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }

                        if stat.spot != spotStats.last?.spot {
                            Divider()
                        }
                    }
                }
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)

                // Graphique
                if #available(iOS 16.0, *) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Répartition des heures")
                            .font(.headline)
                            .padding(.horizontal)

                        Chart {
                            ForEach(spotStats, id: \.spot) { stat in
                                BarMark(
                                    x: .value("Heures", Double(stat.hours * 60 + stat.minutes) / 60.0),
                                    y: .value("Spot", stat.spot)
                                )
                                .foregroundStyle(.green.gradient)
                                .annotation(position: .trailing, alignment: .leading) {
                                    Text(stat.hours > 0 ? "\(stat.hours)h\(String(format: "%02d", stat.minutes))" : "\(stat.minutes)min")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(height: CGFloat(max(200, spotStats.count * 50)))
                        .chartXAxis {
                            AxisMarks(position: .bottom)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let spot = selectedSpot {
                SpotFlightsDetailView(spotName: spot, flights: flights)
            }
        }
    }
}

// MARK: - WingFlightsDetailView (Détail des vols par voile)

struct WingFlightsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let wing: Wing
    let flights: [Flight]

    // Calculer les vols filtrés immédiatement lors de l'init
    private let wingFlights: [Flight]

    init(wing: Wing, flights: [Flight]) {
        self.wing = wing
        self.flights = flights
        // Pré-calculer les vols de cette voile
        self.wingFlights = flights
            .filter { $0.wing?.id == wing.id }
            .sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(wingFlights) { flight in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(flight.dateFormatted)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text(flight.durationFormatted)
                                    .font(.headline)
                                    .foregroundStyle(.blue)
                            }

                            if let spot = flight.spotName {
                                Label(spot, systemImage: "location.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(wing.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - SpotFlightsDetailView (Détail des vols par spot)

struct SpotFlightsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let spotName: String
    let flights: [Flight]

    // Calculer les vols filtrés immédiatement lors de l'init
    private let spotFlights: [Flight]

    init(spotName: String, flights: [Flight]) {
        self.spotName = spotName
        self.flights = flights
        // Pré-calculer les vols de ce spot
        self.spotFlights = flights
            .filter { $0.spotName == spotName }
            .sorted { $0.startDate > $1.startDate }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(spotFlights) { flight in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(flight.dateFormatted)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text(flight.durationFormatted)
                                    .font(.headline)
                                    .foregroundStyle(.blue)
                            }

                            if let wingName = flight.wing?.name {
                                Label(wingName, systemImage: "wind")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(spotName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - TimerView (Chrono redesigné)

struct TimerView: View {
    @Environment(DataController.self) private var dataController
    @Environment(LocationService.self) private var locationService
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<Wing> { !$0.isArchived }, sort: \Wing.createdAt, order: .reverse) private var wings: [Wing]

    @State private var selectedWing: Wing?
    @State private var isFlying = false
    @State private var startDate: Date?
    @State private var elapsedSeconds: Int = 0
    @State private var backgroundTask: Timer?
    @State private var currentSpot: String = "Recherche..."
    @State private var manualSpotOverride: String? = nil
    @State private var showingManualSpot = false
    @State private var showingWingPicker = false
    @State private var showingFlightSummary = false
    @State private var completedFlight: Flight?

    var body: some View {
        NavigationStack {
            ZStack {
                // Fond dégradé
                LinearGradient(
                    colors: isFlying ? [.green.opacity(0.2), .blue.opacity(0.2)] : [.gray.opacity(0.1), .gray.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 24) {
                    // Sélection de la voile (design compact)
                    if !isFlying {
                        VStack(spacing: 12) {
                            Text("Voile")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(1)

                            if wings.isEmpty {
                                Text("Ajoutez d'abord une voile dans l'onglet Voiles")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding()
                            } else {
                                Button {
                                    showingWingPicker = true
                                } label: {
                                    HStack(spacing: 12) {
                                        if let wing = selectedWing {
                                            // Photo miniature
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

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(wing.name)
                                                    .font(.headline)
                                                    .foregroundStyle(.primary)
                                                if let size = wing.size {
                                                    Text("\(size) m²")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }

                                            Spacer()

                                            Image(systemName: "chevron.down")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        } else {
                                            Image(systemName: "wind")
                                                .font(.title2)
                                                .foregroundStyle(.blue)

                                            Text("Sélectionner une voile")
                                                .font(.body)
                                                .foregroundStyle(.blue)

                                            Spacer()

                                            Image(systemName: "chevron.down")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding()
                                    .background(
                                        LinearGradient(
                                            colors: selectedWing == nil ? [.blue.opacity(0.1), .blue.opacity(0.05)] : [Color(.systemBackground)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(selectedWing == nil ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 2)
                                    )
                                    .cornerRadius(12)
                                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                                }
                                .padding(.horizontal)
                            }
                        }
                    } else {
                        // Afficher la voile sélectionnée pendant le vol
                        if let wing = selectedWing {
                            VStack(spacing: 8) {
                                if let photoData = wing.photoData, let uiImage = UIImage(data: photoData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(.blue.opacity(0.2))
                                        .frame(width: 80, height: 80)
                                        .overlay {
                                            Image(systemName: "wind")
                                                .font(.largeTitle)
                                                .foregroundStyle(.blue)
                                        }
                                }

                                Text(wing.name)
                                    .font(.title2)
                                    .fontWeight(.bold)

                                if let size = wing.size {
                                    Text("\(size) m²")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Spot actuel
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "location.fill")
                                .foregroundStyle(manualSpotOverride != nil ? .blue : .green)
                            Text(manualSpotOverride ?? currentSpot)
                                .font(.headline)
                        }

                        Button {
                            showingManualSpot = true
                        } label: {
                            Text(manualSpotOverride != nil ? "Changer le spot" : "Définir le spot manuellement")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding(.horizontal)

                    Spacer()

                    // Chrono
                    VStack(spacing: 8) {
                        Text("TEMPS DE VOL")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .tracking(2)

                        Text(formatElapsedTime(elapsedSeconds))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isFlying ? .green : .primary)
                    }

                    Spacer()

                    // Bouton Start/Stop (redesigné)
                    Button {
                        if isFlying {
                            stopFlight()
                        } else {
                            startFlight()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isFlying ? "stop.fill" : "play.fill")
                                .font(.title2)
                            Text(isFlying ? "ARRÊTER LE VOL" : "DÉMARRER LE VOL")
                                .font(.title3)
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(isFlying ? Color.red : Color.green)
                        .foregroundStyle(.white)
                        .cornerRadius(16)
                        .shadow(color: (isFlying ? Color.red : Color.green).opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    .disabled(!isFlying && selectedWing == nil)
                    .opacity((!isFlying && selectedWing == nil) ? 0.5 : 1.0)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Chrono")
            .sheet(isPresented: $showingManualSpot) {
                ManualSpotEditView(manualSpot: $manualSpotOverride)
            }
            .sheet(isPresented: $showingWingPicker) {
                WingPickerSheet(wings: wings, selectedWing: $selectedWing)
            }
            .sheet(isPresented: $showingFlightSummary) {
                if let flight = completedFlight {
                    FlightSummaryView(flight: flight)
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Gérer le timer en arrière-plan
            if isFlying {
                if newPhase == .background || newPhase == .inactive {
                    // Continuer le timer en background
                } else if newPhase == .active, let start = startDate {
                    // Recalculer le temps écoulé quand on revient au premier plan
                    elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        }
        .onAppear {
            if !isFlying && manualSpotOverride == nil {
                updateCurrentSpot()
            }
            // Démarrer le timer de mise à jour si un vol est en cours
            if isFlying, let start = startDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
                startBackgroundTimer()
            }
        }
    }

    private func startBackgroundTimer() {
        backgroundTask?.invalidate()
        backgroundTask = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = startDate {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func startFlight() {
        guard selectedWing != nil else { return }

        startDate = Date()
        elapsedSeconds = 0
        isFlying = true

        locationService.startUpdatingLocation()

        // Ne mettre à jour le spot que si aucun spot manuel n'est défini
        if manualSpotOverride == nil {
            updateCurrentSpot()
        }

        startBackgroundTimer()
    }

    private func stopFlight() {
        guard let wing = selectedWing, let start = startDate else { return }

        let end = Date()
        let duration = Int(end.timeIntervalSince(start))

        backgroundTask?.invalidate()
        backgroundTask = nil

        locationService.stopUpdatingLocation()

        // Utiliser le spot manuel en priorité, sinon le spot automatique
        let finalSpot: String?
        if let manual = manualSpotOverride {
            finalSpot = manual
        } else if currentSpot != "Recherche..." && currentSpot != "Position indisponible" {
            finalSpot = currentSpot
        } else {
            finalSpot = nil
        }

        locationService.requestLocation { [self] location in
            DispatchQueue.main.async {
                let flight = Flight(
                    wing: wing,
                    startDate: start,
                    endDate: end,
                    durationSeconds: duration,
                    spotName: finalSpot,
                    latitude: location?.coordinate.latitude,
                    longitude: location?.coordinate.longitude
                )

                dataController.modelContext.insert(flight)
                try? dataController.modelContext.save()

                // Afficher le récapitulatif
                completedFlight = flight
                showingFlightSummary = true
            }
        }

        isFlying = false
        elapsedSeconds = 0
        startDate = nil
        selectedWing = nil
        currentSpot = "Recherche..."
        manualSpotOverride = nil
    }

    private func updateCurrentSpot() {
        locationService.requestLocation { location in
            guard let location = location else {
                DispatchQueue.main.async {
                    currentSpot = "Position indisponible"
                }
                return
            }

            locationService.reverseGeocode(location: location) { spot in
                DispatchQueue.main.async {
                    currentSpot = spot ?? "Spot inconnu"
                }
            }
        }
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge", "red": return .red
        case "bleu", "blue": return .blue
        case "vert", "green": return .green
        case "jaune", "yellow": return .yellow
        case "orange": return .orange
        case "violet", "purple": return .purple
        case "noir", "black": return .black
        default: return .gray
        }
    }

    private func formatElapsedTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}

// MARK: - WingPickerSheet (Sélection de voile en sheet)

struct WingPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let wings: [Wing]
    @Binding var selectedWing: Wing?

    var body: some View {
        NavigationStack {
            List {
                ForEach(wings) { wing in
                    Button {
                        selectedWing = wing
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            // Photo de la voile
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
                                    .foregroundStyle(.primary)

                                HStack(spacing: 8) {
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
                            }

                            Spacer()

                            if selectedWing?.id == wing.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Choisir une voile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func colorFromString(_ colorString: String) -> Color {
        switch colorString.lowercased() {
        case "rouge", "red": return .red
        case "bleu", "blue": return .blue
        case "vert", "green": return .green
        case "jaune", "yellow": return .yellow
        case "orange": return .orange
        case "violet", "purple": return .purple
        case "noir", "black": return .black
        default: return .gray
        }
    }
}

// MARK: - ManualSpotEditView (Saisie manuelle du spot)

struct ManualSpotEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var manualSpot: String?
    @State private var tempSpot: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du spot", text: $tempSpot)
                } header: {
                    Text("Définir le spot manuellement")
                } footer: {
                    Text("Ce spot sera utilisé en priorité sur la détection GPS automatique")
                }

                if manualSpot != nil {
                    Section {
                        Button(role: .destructive) {
                            manualSpot = nil
                            dismiss()
                        } label: {
                            Label("Supprimer et utiliser le GPS", systemImage: "location.fill")
                        }
                    }
                }
            }
            .navigationTitle("Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        if !tempSpot.isEmpty {
                            manualSpot = tempSpot
                        }
                        dismiss()
                    }
                    .disabled(tempSpot.isEmpty)
                }
            }
            .onAppear {
                tempSpot = manualSpot ?? ""
            }
        }
    }
}

// MARK: - FlightSummaryView (Récapitulatif de vol)

struct FlightSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    let flight: Flight

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Icône de succès
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)
                    .padding(.top, 40)

                Text("Vol terminé !")
                    .font(.title)
                    .fontWeight(.bold)

                // Résumé du vol
                VStack(spacing: 16) {
                    // Durée
                    HStack {
                        Image(systemName: "timer")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 30)

                        Text("Durée")
                            .font(.headline)

                        Spacer()

                        Text(flight.durationFormatted)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Voile
                    if let wingName = flight.wing?.name {
                        HStack {
                            Image(systemName: "wind")
                                .font(.title3)
                                .foregroundStyle(.purple)
                                .frame(width: 30)

                            Text("Voile")
                                .font(.headline)

                            Spacer()

                            Text(wingName)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Spot
                    if let spot = flight.spotName {
                        HStack {
                            Image(systemName: "location.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                                .frame(width: 30)

                            Text("Spot")
                                .font(.headline)

                            Spacer()

                            Text(spot)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Date et heure
                    HStack {
                        Image(systemName: "calendar")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 30)

                        Text("Date")
                            .font(.headline)

                        Spacer()

                        Text(flight.dateFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Terminer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .navigationTitle("Récapitulatif")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
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
        case "rouge", "red": return .red
        case "bleu", "blue": return .blue
        case "vert", "green": return .green
        case "jaune", "yellow": return .yellow
        case "orange": return .orange
        case "violet", "purple": return .purple
        case "noir", "black": return .black
        default: return .gray
        }
    }
}

// MARK: - SettingsView (Paramètres et import de données)

struct SettingsView: View {
    @Environment(DataController.self) private var dataController
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(\.modelContext) private var modelContext
    @Query private var wings: [Wing]
    @Query private var flights: [Flight]
    @State private var showingImportSuccess = false
    @State private var importMessage = ""
    @State private var showingDocumentPicker = false
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            List {
                Section("Voiles") {
                    NavigationLink {
                        ArchivedWingsView()
                    } label: {
                        Label("Voiles archivées", systemImage: "archivebox")
                    }
                }

                Section("Apple Watch") {
                    HStack {
                        Text("App Watch")
                        Spacer()
                        if watchManager.isWatchAppInstalled {
                            Label("Installée", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Label("Non installée", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    HStack {
                        Text("Joignable")
                        Spacer()
                        if watchManager.isWatchReachable {
                            Label("Oui", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Label("Non", systemImage: "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }

                    HStack {
                        Text("Nombre de voiles")
                        Spacer()
                        Text("\(wings.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        print("📤 Manual sync button pressed - \(wings.count) wings available")
                        watchManager.sendWingsToWatch()
                        watchManager.sendWingsViaTransfer() // Essayer aussi transferUserInfo
                        importMessage = "\(wings.count) voile(s) envoyée(s) à la Watch"
                        showingImportSuccess = true
                    } label: {
                        Label("Synchroniser les voiles", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Section("Données") {
                    Button {
                        showingDocumentPicker = true
                    } label: {
                        Label("Importer depuis Excel/CSV", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        exportToCSV()
                    } label: {
                        Label("Exporter en CSV", systemImage: "square.and.arrow.up")
                    }
                }

                Section("Développeur") {
                    Button {
                        generateTestData()
                    } label: {
                        Label("Générer des données de test", systemImage: "wand.and.stars")
                    }

                    Button(role: .destructive) {
                        deleteAllData()
                    } label: {
                        Label("Supprimer toutes les données", systemImage: "trash")
                    }
                }

                Section("À propos") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text("1")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Réglages")
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker { url in
                    importExcelFile(from: url)
                }
            }
            .alert(isImporting ? "Import en cours..." : "Résultat", isPresented: Binding(
                get: { showingImportSuccess || isImporting },
                set: { if !$0 { showingImportSuccess = false; isImporting = false } }
            )) {
                if !isImporting {
                    Button("OK") { }
                }
            } message: {
                if isImporting {
                    Text("Importation des données...")
                } else {
                    Text(importMessage)
                }
            }
        }
    }

    private func generateTestData() {
        // Créer des voiles de test si aucune n'existe
        if wings.isEmpty {
            let testWings = [
                Wing(name: "Flare Props", size: "24", type: "Soaring", color: "Orange"),
                Wing(name: "Rush 5", size: "22", type: "Cross", color: "Bleu"),
                Wing(name: "Enzo 3", size: "23", type: "Cross", color: "Rouge")
            ]

            for wing in testWings {
                modelContext.insert(wing)
            }
        }

        // Créer des vols de test
        let testSpots = ["Chamonix", "Annecy", "Saint-Hilaire", "Passy", "Talloires"]
        let calendar = Calendar.current

        for _ in 0..<20 {
            let daysAgo = Int.random(in: 0...60)
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()

            let startDate = date
            let duration = Int.random(in: 900...7200) // 15min à 2h
            let endDate = startDate.addingTimeInterval(TimeInterval(duration))

            let randomWing = wings.randomElement()
            let randomSpot = testSpots.randomElement()

            // Créer des coordonnées fictives (région d'Annecy/Chamonix)
            let lat = 45.9 + Double.random(in: -0.2...0.2)
            let lon = 6.1 + Double.random(in: -0.2...0.2)

            let flight = Flight(
                wing: randomWing,
                startDate: startDate,
                endDate: endDate,
                durationSeconds: duration,
                spotName: randomSpot,
                latitude: lat,
                longitude: lon
            )

            modelContext.insert(flight)
        }

        Task { @MainActor in
            try? modelContext.save()
            importMessage = "✅ \(wings.count) voiles et 20 vols créés"
            showingImportSuccess = true
        }
    }

    private func importExcelFile(from url: URL) {
        isImporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Parse le fichier en arrière-plan
                let data = try ExcelImporter.parseExcelFile(at: url)

                print("✅ Parsed \(data.flights.count) flights from file")

                // Import dans la base DOIT être sur le main thread (SwiftData requirement)
                DispatchQueue.main.async {
                    do {
                        let result = try ExcelImporter.importToDatabase(data: data, dataController: self.dataController)

                        self.isImporting = false
                        self.importMessage = result.summary
                        self.showingImportSuccess = true
                    } catch {
                        self.isImporting = false
                        self.importMessage = "❌ Erreur d'import:\n\(error.localizedDescription)"
                        self.showingImportSuccess = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isImporting = false
                    self.importMessage = "❌ Erreur de lecture:\n\(error.localizedDescription)"
                    self.showingImportSuccess = true
                }
            }
        }
    }

    private func exportToCSV() {
        guard !flights.isEmpty else {
            importMessage = "⚠️ Aucun vol à exporter"
            showingImportSuccess = true
            return
        }

        // Générer le CSV
        var csvContent = "Date,Voile,Spot,Durée,Notes\n"

        for flight in flights.sorted(by: { $0.startDate < $1.startDate }) {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "dd/MM/yyyy"
            let dateString = dateFormatter.string(from: flight.startDate)

            let wingName = flight.wing?.name ?? "Inconnu"
            let spotName = flight.spotName ?? "Inconnu"
            let duration = formatDurationForExport(flight.durationSeconds)
            let notes = flight.notes ?? ""

            let line = "\(dateString),\(wingName),\(spotName),\(duration),\"\(notes)\"\n"
            csvContent += line
        }

        // Sauvegarder et partager
        let fileName = "ParaFlightLog_Export_\(Date().timeIntervalSince1970).csv"
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            importMessage = "❌ Erreur: impossible d'accéder aux documents"
            showingImportSuccess = true
            return
        }

        let fileURL = documentsPath.appendingPathComponent(fileName)

        do {
            try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)

            // Partager le fichier
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }

            importMessage = "✅ Export réussi: \(flights.count) vols"
            showingImportSuccess = true
        } catch {
            importMessage = "❌ Erreur d'export: \(error.localizedDescription)"
            showingImportSuccess = true
        }
    }

    private func formatDurationForExport(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(String(format: "%02d", minutes))"
        } else {
            return "\(minutes)min"
        }
    }

    private func deleteAllData() {
        // Supprimer tous les vols
        do {
            try modelContext.delete(model: Flight.self)
            try modelContext.delete(model: Wing.self)
            try modelContext.save()
            importMessage = "✅ Toutes les données ont été supprimées"
            showingImportSuccess = true
        } catch {
            importMessage = "❌ Erreur: \(error.localizedDescription)"
            showingImportSuccess = true
        }
    }
}

// MARK: - DocumentPicker (Import Excel/CSV)

import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {
    let onDocumentPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Support CSV, Excel files, and plain text
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .commaSeparatedText,
            .plainText,
            .data,
            UTType(filenameExtension: "xlsx")!,
            UTType(filenameExtension: "xls")!
        ])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentPicked: onDocumentPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentPicked: (URL) -> Void

        init(onDocumentPicked: @escaping (URL) -> Void) {
            self.onDocumentPicked = onDocumentPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onDocumentPicked(url)
        }
    }
}
