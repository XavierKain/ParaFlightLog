//
//  WingLibrary.swift
//  ParaFlightLog
//
//  Bibliothèque de voiles préenregistrées avec chargement JSON distant
//  Target: iOS only
//

import Foundation
import SwiftUI

// MARK: - Wing Library Item

/// Représente une voile dans la bibliothèque préenregistrée
struct WingLibraryItem: Codable, Identifiable, Hashable {
    let id: String              // Identifiant unique (ex: "ozone-moustache-m1-2025")
    let brand: String           // Marque (ex: "Ozone", "Niviuk", "Advance")
    let model: String           // Modèle (ex: "Moustache M1", "Chili 5")
    let year: Int?              // Année de sortie (optionnel)
    let type: String            // Type: "Soaring", "Cross", "Thermique", "Speedflying", "Acro"
    let sizes: [String]         // Tailles disponibles (ex: ["13", "15", "18", "22"])
    let color: String?          // Couleur principale (optionnel)
    let imageURL: String?       // URL de l'image détourée (optionnel)
    let trimSpeed: Double?      // Vitesse de trim en km/h (pour estimation vent)

    /// Nom complet pour l'affichage
    var fullName: String {
        if let year = year {
            return "\(brand) \(model) \(year)"
        }
        return "\(brand) \(model)"
    }

    /// Nom sans la marque (pour Watch)
    var shortName: String {
        if let year = year {
            return "\(model) \(year)"
        }
        return model
    }
}

// MARK: - Wing Library Response

/// Réponse du serveur JSON
struct WingLibraryResponse: Codable {
    let version: String
    let lastUpdated: String
    let wings: [WingLibraryItem]
}

// MARK: - Wing Library Manager

/// Gestionnaire de la bibliothèque de voiles
@Observable
final class WingLibraryManager {
    static let shared = WingLibraryManager()

    // URL du fichier JSON distant (à configurer)
    // Pour le moment, on utilise un JSON local embarqué comme fallback
    private let remoteURL = "https://raw.githubusercontent.com/XavierKain/ParaFlightLog/new-features2/ParaFlightLog/WingLibrary/wings.json"

    // Cache local
    private let cacheKey = "wingLibraryCache"
    private let cacheVersionKey = "wingLibraryCacheVersion"
    private let cacheDateKey = "wingLibraryCacheDate"

    // État
    var wings: [WingLibraryItem] = []
    var isLoading: Bool = false
    var lastError: String?
    var lastUpdated: Date?

    // Filtres disponibles
    var availableBrands: [String] {
        Array(Set(wings.map { $0.brand })).sorted()
    }

    var availableTypes: [String] {
        Array(Set(wings.map { $0.type })).sorted()
    }

    private init() {
        loadFromCache()
    }

    // MARK: - Public Methods

    /// Charge la bibliothèque (cache puis distant)
    func loadLibrary() async {
        await MainActor.run { isLoading = true }

        // Essayer de charger depuis le serveur distant
        do {
            let data = try await fetchRemoteData()
            let response = try JSONDecoder().decode(WingLibraryResponse.self, from: data)

            await MainActor.run {
                self.wings = response.wings
                self.lastError = nil
                self.isLoading = false
            }

            // Sauvegarder en cache
            saveToCache(data: data, version: response.version)

        } catch {
            print("❌ Erreur chargement bibliothèque distante: \(error)")

            await MainActor.run {
                self.lastError = error.localizedDescription
                self.isLoading = false
            }

            // Fallback: charger depuis le cache ou le bundle
            if wings.isEmpty {
                loadFromCache()
                if wings.isEmpty {
                    loadFromBundle()
                }
            }
        }
    }

    /// Recherche dans la bibliothèque
    func search(query: String, brand: String? = nil, type: String? = nil) -> [WingLibraryItem] {
        var results = wings

        // Filtre par marque
        if let brand = brand, !brand.isEmpty {
            results = results.filter { $0.brand == brand }
        }

        // Filtre par type
        if let type = type, !type.isEmpty {
            results = results.filter { $0.type == type }
        }

        // Filtre par recherche texte
        if !query.isEmpty {
            let lowercasedQuery = query.lowercased()
            results = results.filter {
                $0.fullName.lowercased().contains(lowercasedQuery) ||
                $0.brand.lowercased().contains(lowercasedQuery) ||
                $0.model.lowercased().contains(lowercasedQuery)
            }
        }

        return results.sorted { $0.fullName < $1.fullName }
    }

    /// Télécharge l'image d'une voile
    func downloadImage(for wing: WingLibraryItem) async -> Data? {
        guard let urlString = wing.imageURL, let url = URL(string: urlString) else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        } catch {
            print("❌ Erreur téléchargement image: \(error)")
            return nil
        }
    }

    // MARK: - Private Methods

    private func fetchRemoteData() async throws -> Data {
        guard let url = URL(string: remoteURL) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return data
    }

    private func loadFromCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }

        do {
            let response = try JSONDecoder().decode(WingLibraryResponse.self, from: data)
            wings = response.wings

            if let dateInterval = UserDefaults.standard.object(forKey: cacheDateKey) as? TimeInterval {
                lastUpdated = Date(timeIntervalSince1970: dateInterval)
            }
        } catch {
            print("❌ Erreur lecture cache: \(error)")
        }
    }

    private func saveToCache(data: Data, version: String) {
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(version, forKey: cacheVersionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheDateKey)

        DispatchQueue.main.async {
            self.lastUpdated = Date()
        }
    }

    private func loadFromBundle() {
        // Charger le JSON embarqué dans l'app comme fallback
        guard let url = Bundle.main.url(forResource: "WingLibrary", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            // Si pas de fichier bundle, utiliser les données par défaut
            loadDefaultWings()
            return
        }

        do {
            let response = try JSONDecoder().decode(WingLibraryResponse.self, from: data)
            wings = response.wings
        } catch {
            print("❌ Erreur lecture bundle: \(error)")
            loadDefaultWings()
        }
    }

    /// Données par défaut si rien d'autre n'est disponible
    private func loadDefaultWings() {
        wings = [
            // Flare
            WingLibraryItem(id: "flare-moustache-m1-2025", brand: "Flare", model: "Moustache M1", year: 2025, type: "Soaring", sizes: ["13", "15", "18", "22"], color: "Pétrole", imageURL: nil, trimSpeed: 36),
            WingLibraryItem(id: "flare-moustache-m1-2024", brand: "Flare", model: "Moustache M1", year: 2024, type: "Soaring", sizes: ["13", "15", "18", "22"], color: "Pétrole", imageURL: nil, trimSpeed: 36),
            WingLibraryItem(id: "flare-moustache-m2", brand: "Flare", model: "Moustache M2", year: nil, type: "Soaring", sizes: ["15", "18", "21"], color: "Bleu", imageURL: nil, trimSpeed: 37),
            WingLibraryItem(id: "flare-arak", brand: "Flare", model: "ARAK", year: nil, type: "Thermique", sizes: ["21", "23", "25", "27"], color: "Bleu", imageURL: nil, trimSpeed: 38),
            WingLibraryItem(id: "flare-prop", brand: "Flare", model: "Prop", year: nil, type: "Soaring", sizes: ["18", "21", "24"], color: "Bleu", imageURL: nil, trimSpeed: 36),
            WingLibraryItem(id: "flare-line", brand: "Flare", model: "Line", year: nil, type: "Speedflying", sizes: ["12", "14", "15", "17"], color: "Bleu", imageURL: nil, trimSpeed: 45),

            // Skywalk
            WingLibraryItem(id: "skywalk-chili-5", brand: "Skywalk", model: "Chili 5", year: nil, type: "Thermique", sizes: ["18", "20", "22", "24", "26", "28"], color: "Bleu", imageURL: nil, trimSpeed: 39)
        ]
    }

    /// Vide le cache pour forcer le rechargement
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheVersionKey)
        UserDefaults.standard.removeObject(forKey: cacheDateKey)
        wings = []
        lastUpdated = nil
        print("🗑️ Cache de la bibliothèque vidé")
    }
}

// MARK: - Wing Library Picker View

struct WingLibraryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var libraryManager = WingLibraryManager.shared

    @State private var searchText = ""
    @State private var selectedBrand: String?
    @State private var selectedType: String?

    let onSelect: (WingLibraryItem, String?) -> Void  // wing, selected size

    var filteredWings: [WingLibraryItem] {
        libraryManager.search(query: searchText, brand: selectedBrand, type: selectedType)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filtres
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Filtre marque
                        Menu {
                            Button("Toutes les marques") {
                                selectedBrand = nil
                            }
                            Divider()
                            ForEach(libraryManager.availableBrands, id: \.self) { brand in
                                Button(brand) {
                                    selectedBrand = brand
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedBrand ?? "Marque")
                                Image(systemName: "chevron.down")
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedBrand != nil ? Color.blue : Color(.secondarySystemBackground))
                            .foregroundStyle(selectedBrand != nil ? .white : .primary)
                            .clipShape(Capsule())
                        }

                        // Filtre type
                        Menu {
                            Button("Tous les types") {
                                selectedType = nil
                            }
                            Divider()
                            ForEach(libraryManager.availableTypes, id: \.self) { type in
                                Button(type) {
                                    selectedType = type
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedType ?? "Type")
                                Image(systemName: "chevron.down")
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedType != nil ? Color.blue : Color(.secondarySystemBackground))
                            .foregroundStyle(selectedType != nil ? .white : .primary)
                            .clipShape(Capsule())
                        }

                        // Réinitialiser
                        if selectedBrand != nil || selectedType != nil {
                            Button {
                                selectedBrand = nil
                                selectedType = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemBackground))

                Divider()

                // Liste des voiles
                if libraryManager.isLoading {
                    Spacer()
                    ProgressView("Chargement de la bibliothèque...")
                    Spacer()
                } else if filteredWings.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "wind")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Aucune voile trouvée")
                            .font(.headline)
                        Text("Essayez d'autres filtres ou une recherche différente")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(filteredWings) { wing in
                        WingLibraryRow(wing: wing, onSelect: onSelect)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Bibliothèque de voiles")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Rechercher une voile...")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await libraryManager.loadLibrary()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                if libraryManager.wings.isEmpty {
                    await libraryManager.loadLibrary()
                }
            }
        }
    }
}

// MARK: - Wing Library Row

struct WingLibraryRow: View {
    let wing: WingLibraryItem
    let onSelect: (WingLibraryItem, String?) -> Void

    @State private var selectedSize: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Ligne principale
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Icône type
                    Image(systemName: wingTypeIcon(wing.type))
                        .font(.title2)
                        .foregroundStyle(wingTypeColor(wing.type))
                        .frame(width: 40, height: 40)
                        .background(wingTypeColor(wing.type).opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(wing.fullName)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        HStack(spacing: 8) {
                            Text(wing.type)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let color = wing.color {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                Text(color)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            // Sélection de taille (si expanded)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sélectionner une taille :")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Grille de tailles
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: 8)], spacing: 8) {
                        ForEach(wing.sizes, id: \.self) { size in
                            Button {
                                selectedSize = size
                                onSelect(wing, size)
                            } label: {
                                Text(size)
                                    .font(.subheadline)
                                    .fontWeight(selectedSize == size ? .semibold : .regular)
                                    .frame(minWidth: 44)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(selectedSize == size ? Color.blue : Color(.tertiarySystemBackground))
                                    .foregroundStyle(selectedSize == size ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Bouton sans taille spécifique
                    Button {
                        onSelect(wing, nil)
                    } label: {
                        Text("Sélectionner sans taille")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .padding(.top, 4)
                }
                .padding(.top, 8)
                .padding(.leading, 52)
            }
        }
        .padding(.vertical, 4)
    }

    private func wingTypeIcon(_ type: String) -> String {
        switch type {
        case "Soaring": return "wind"
        case "Cross": return "arrow.triangle.swap"
        case "Thermique": return "arrow.up.circle"
        case "Speedflying": return "hare"
        case "Acro": return "arrow.triangle.2.circlepath"
        default: return "wind"
        }
    }

    private func wingTypeColor(_ type: String) -> Color {
        switch type {
        case "Soaring": return .blue
        case "Cross": return .purple
        case "Thermique": return .orange
        case "Speedflying": return .red
        case "Acro": return .green
        default: return .gray
        }
    }
}
