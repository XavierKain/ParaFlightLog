//
//  WingLibraryService.swift
//  ParaFlightLog
//
//  Service pour récupérer et mettre en cache le catalogue de voiles
//  Source : repo GitHub public (raw.githubusercontent.com) — zéro serveur
//  - wings.json : catalogue (fabricants + modèles + tailles)
//  - images/*.png : photos détourées des voiles
//  Target: iOS only
//

import Foundation

// MARK: - Cache d'images thread-safe (acteur)

/// Actor garantissant un accès thread-safe au cache d'images (mémoire + disque)
/// Inclut un throttling des téléchargements concurrents et un retry automatique
actor WingImageCache {
    private var memoryCache: [String: Data] = [:]
    private var pendingRequests: [String: Task<Data, Error>] = [:]
    private let cacheDirectory: URL

    // Throttling : limite les téléchargements réseau concurrents
    private let maxConcurrentDownloads = 5
    private var activeDownloads = 0
    private var waitingQueue: [(String, CheckedContinuation<Void, Never>)] = []

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    /// Attend qu'un slot de téléchargement soit disponible
    private func acquireDownloadSlot(for wingId: String) async {
        if activeDownloads < maxConcurrentDownloads {
            activeDownloads += 1
            return
        }

        // File d'attente si tous les slots sont occupés
        await withCheckedContinuation { continuation in
            waitingQueue.append((wingId, continuation))
        }
    }

    /// Libère un slot de téléchargement
    private func releaseDownloadSlot() {
        if let next = waitingQueue.first {
            waitingQueue.removeFirst()
            next.1.resume()
        } else {
            activeDownloads -= 1
        }
    }

    /// Récupère une image depuis le cache ou la télécharge
    /// - Parameters:
    ///   - wingId: ID unique de la voile
    ///   - fetcher: Closure async pour télécharger l'image si pas en cache
    /// - Returns: Data de l'image
    func getImage(
        for wingId: String,
        fetcher: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        // 1. Cache mémoire (le plus rapide)
        if let cached = memoryCache[wingId] {
            return cached
        }

        // 2. Cache disque
        let diskPath = cacheDirectory.appendingPathComponent("\(wingId).png")
        if let diskData = try? Data(contentsOf: diskPath), !diskData.isEmpty {
            memoryCache[wingId] = diskData
            return diskData
        }

        // 3. Requête déjà en cours pour cette voile (thread-safe grâce à l'actor)
        if let pending = pendingRequests[wingId] {
            return try await pending.value
        }

        // 4. Attendre un slot disponible (throttling)
        await acquireDownloadSlot(for: wingId)

        // 5. Re-vérifier le cache (quelqu'un d'autre a pu le charger pendant l'attente)
        if let cached = memoryCache[wingId] {
            releaseDownloadSlot()
            return cached
        }

        // 6. Nouvelle tâche de téléchargement avec retry
        Log.info("Fetching image from network for wing \(wingId) (active: \(activeDownloads)/\(maxConcurrentDownloads))", category: .wingLibrary)

        let task = Task<Data, Error> {
            var lastError: Error?

            // Retry jusqu'à 3 fois en cas d'erreur réseau
            for attempt in 1...3 {
                do {
                    let data = try await fetcher()

                    // Vérifier que les données ne sont pas vides
                    guard !data.isEmpty else {
                        throw WingLibraryError.invalidResponse
                    }

                    return data
                } catch {
                    lastError = error
                    if attempt < 3 {
                        Log.warning("Fetch failed for wing \(wingId): \(error), retrying... (attempt \(attempt)/3)", category: .wingLibrary)
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0,5 seconde
                    }
                }
            }

            throw lastError ?? WingLibraryError.invalidResponse
        }

        pendingRequests[wingId] = task

        do {
            let data = try await task.value
            // Cache mémoire + disque après téléchargement réussi
            memoryCache[wingId] = data
            try? data.write(to: diskPath)
            pendingRequests.removeValue(forKey: wingId)
            releaseDownloadSlot()
            Log.info("Cached image for wing \(wingId): \(data.count) bytes", category: .wingLibrary)
            return data
        } catch {
            pendingRequests.removeValue(forKey: wingId)
            releaseDownloadSlot()
            Log.error("Failed to fetch image for wing \(wingId) after 3 attempts: \(error)", category: .wingLibrary)
            throw error
        }
    }

    /// Vide le cache mémoire et les requêtes en attente
    func clearMemory() {
        memoryCache.removeAll()
        pendingRequests.removeAll()
    }

    /// Vide complètement le cache (mémoire + disque)
    func clearAll() {
        memoryCache.removeAll()
        pendingRequests.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - Modèles

/// Catalogue complet des voiles (format wings.json du repo GitHub)
struct WingCatalog: Codable {
    let version: String
    let lastUpdated: String
    let manufacturers: [WingManufacturer]
    let wings: [LibraryWing]
}

/// Fabricant de voiles
struct WingManufacturer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

/// Voile dans la bibliothèque en ligne
struct LibraryWing: Codable, Identifiable, Hashable {
    let id: String
    let manufacturer: String   // id du fabricant (ex: "flare")
    let model: String          // ex: "Moustache M1"
    let fullName: String       // ex: "Flare Moustache M1"
    let type: String           // ex: "Soaring", "Thermique", "Speedflying"
    let sizes: [String]        // ex: ["13", "15", "18"]
    let imageUrl: String?      // chemin relatif dans le repo (ex: "images/moustache-m1.png")
    let year: Int?

    // Hashable basé sur l'id uniquement
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LibraryWing, rhs: LibraryWing) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Erreurs

enum WingLibraryError: LocalizedError {
    case networkUnavailable
    case invalidResponse
    case decodingFailed(Error)
    case imageFetchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "Connexion internet indisponible"
        case .invalidResponse:
            return "Réponse invalide du serveur"
        case .decodingFailed(let error):
            return "Erreur de décodage: \(error.localizedDescription)"
        case .imageFetchFailed(let error):
            return "Erreur de téléchargement d'image: \(error.localizedDescription)"
        }
    }
}

// MARK: - Service

/// Singleton @Observable qui télécharge le catalogue de voiles depuis GitHub raw
/// avec cache disque (Caches/WingLibrary/) et fallback hors-ligne
@Observable
@MainActor
final class WingLibraryService {
    static let shared = WingLibraryService()

    // MARK: Configuration GitHub raw

    /// URL de base du repo GitHub contenant le catalogue et les images
    private static let baseURLString = "https://raw.githubusercontent.com/XavierKain/paraflightlog-wings/main"
    private static let catalogURL = URL(string: "\(baseURLString)/wings.json")!

    // MARK: État publié

    private(set) var catalog: WingCatalog?
    private(set) var isLoading = false
    private(set) var lastError: WingLibraryError?
    private(set) var isOfflineMode = false

    /// Fabricants du catalogue (vide tant que le catalogue n'est pas chargé)
    var manufacturers: [WingManufacturer] { catalog?.manufacturers ?? [] }

    /// Voiles du catalogue (vide tant que le catalogue n'est pas chargé)
    var wings: [LibraryWing] { catalog?.wings ?? [] }

    // MARK: Cache

    /// Cache d'images thread-safe (acteur, mémoire + disque)
    private let wingImageCache: WingImageCache

    /// Dossier de cache : Caches/WingLibrary/
    private let cacheDirectory: URL

    /// Fichier de cache du catalogue (dernier JSON téléchargé, pour le mode hors-ligne)
    private var catalogCacheURL: URL {
        cacheDirectory.appendingPathComponent("wings.json")
    }

    private init() {
        // Créer le dossier de cache si nécessaire (fallback sur le dossier temporaire
        // si le dossier Caches est indisponible — évite tout crash au démarrage)
        let baseCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cacheDir = baseCacheDir.appendingPathComponent("WingLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cacheDirectory = cacheDir

        // Initialiser le cache d'images (acteur thread-safe)
        wingImageCache = WingImageCache(cacheDirectory: cacheDir)

        // Charger le catalogue mis en cache (disponible immédiatement hors-ligne)
        loadCachedCatalog()
    }

    // MARK: - API publique

    /// Télécharge le catalogue depuis GitHub raw (réseau d'abord pour des données fraîches),
    /// avec fallback sur le dernier JSON téléchargé en cas d'échec (mode hors-ligne)
    func loadCatalog() async {
        isLoading = true
        lastError = nil
        isOfflineMode = false

        defer { isLoading = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: Self.catalogURL)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw WingLibraryError.invalidResponse
            }

            let newCatalog: WingCatalog
            do {
                newCatalog = try JSONDecoder().decode(WingCatalog.self, from: data)
            } catch {
                throw WingLibraryError.decodingFailed(error)
            }

            catalog = newCatalog
            // Sauvegarder le JSON brut sur disque pour le mode hors-ligne
            try? data.write(to: catalogCacheURL, options: .atomic)

            Log.info("Fetched catalog from GitHub: \(newCatalog.wings.count) wings, \(newCatalog.manufacturers.count) manufacturers", category: .wingLibrary)
        } catch {
            Log.warning("Catalog fetch failed: \(error.localizedDescription)", category: .wingLibrary)

            // Fallback : dernier catalogue téléchargé (mémoire ou disque)
            if catalog == nil {
                loadCachedCatalog()
            }

            if catalog != nil {
                isOfflineMode = true
                Log.info("Using cached catalog in offline mode", category: .wingLibrary)
            } else if let libraryError = error as? WingLibraryError {
                lastError = libraryError
            } else if error is URLError {
                lastError = .networkUnavailable
            } else {
                lastError = .invalidResponse
            }
        }
    }

    /// Récupère l'image PNG détourée d'une voile (cache mémoire + disque, sinon GitHub raw)
    /// - Returns: Data de l'image, ou nil si indisponible
    func image(for wing: LibraryWing) async -> Data? {
        guard let imagePath = wing.imageUrl,
              let url = URL(string: "\(Self.baseURLString)/\(imagePath)") else {
            return nil
        }

        do {
            return try await wingImageCache.getImage(for: wing.id) {
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    throw WingLibraryError.invalidResponse
                }

                return data
            }
        } catch {
            // Échec silencieux : l'UI affichera un placeholder
            return nil
        }
    }

    /// Voiles d'un fabricant donné
    func wings(for manufacturerId: String) -> [LibraryWing] {
        wings.filter { $0.manufacturer == manufacturerId }
    }

    /// Nom du fabricant d'une voile (depuis le catalogue chargé)
    func manufacturerName(for wing: LibraryWing) -> String? {
        manufacturers.first { $0.id == wing.manufacturer }?.name
    }

    /// Vide tous les caches (catalogue + images)
    func clearCache() async {
        catalog = nil
        try? FileManager.default.removeItem(at: catalogCacheURL)

        // Vider le cache d'images via l'acteur (thread-safe)
        await wingImageCache.clearAll()

        Log.info("Wing library cache cleared", category: .wingLibrary)
    }

    // MARK: - Privé

    /// Charge le dernier catalogue téléchargé depuis le disque (mode hors-ligne)
    private func loadCachedCatalog() {
        guard let data = try? Data(contentsOf: catalogCacheURL) else { return }

        do {
            catalog = try JSONDecoder().decode(WingCatalog.self, from: data)
            Log.info("Loaded cached catalog: \(catalog?.wings.count ?? 0) wings", category: .wingLibrary)
        } catch {
            Log.warning("Failed to decode cached catalog: \(error.localizedDescription)", category: .wingLibrary)
        }
    }
}
