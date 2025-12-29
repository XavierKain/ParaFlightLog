//
//  WingLibraryService.swift
//  ParaFlightLog
//
//  Service pour récupérer et mettre en cache le catalogue de voiles depuis Appwrite
//  Target: iOS only
//

import Foundation
import UIKit
import Appwrite

// MARK: - Thread-Safe Image Cache Actor with Rate Limit Protection

/// Actor garantissant un accès thread-safe au cache d'images
/// Inclut un système de throttling pour éviter le rate limit Appwrite (60 req/min)
actor WingImageCache {
    private var memoryCache: [String: Data] = [:]
    private var pendingRequests: [String: Task<Data, Error>] = [:]
    private let cacheDirectory: URL

    // Throttling: limite les requêtes réseau concurrentes
    // Appwrite a une limite de 60 req/min, on limite à 5 concurrentes max
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
        fetcher: @escaping () async throws -> Data
    ) async throws -> Data {
        // 1. Check memory cache (fastest)
        if let cached = memoryCache[wingId] {
            return cached
        }

        // 2. Check disk cache
        let diskPath = cacheDirectory.appendingPathComponent("\(wingId).png")
        if let diskData = try? Data(contentsOf: diskPath), !diskData.isEmpty {
            memoryCache[wingId] = diskData
            logInfo("Loaded image from disk cache for wing \(wingId)", category: .wingLibrary)
            return diskData
        }

        // 3. Check pending request (thread-safe grâce à l'actor)
        if let pending = pendingRequests[wingId] {
            logInfo("Waiting for pending request for wing \(wingId)", category: .wingLibrary)
            return try await pending.value
        }

        // 4. Attendre un slot disponible (throttling)
        await acquireDownloadSlot(for: wingId)

        // 5. Vérifier à nouveau le cache (quelqu'un d'autre a pu le charger pendant l'attente)
        if let cached = memoryCache[wingId] {
            releaseDownloadSlot()
            return cached
        }

        // 6. Create new fetch task with retry logic
        logInfo("Fetching image from network for wing \(wingId) (active: \(activeDownloads)/\(maxConcurrentDownloads))", category: .wingLibrary)

        let task = Task<Data, Error> {
            var lastError: Error?

            // Retry jusqu'à 3 fois en cas d'erreur réseau ou rate limit
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
                    let errorDescription = String(describing: error)

                    // Si c'est un rate limit (429), attendre plus longtemps
                    if errorDescription.contains("429") || errorDescription.lowercased().contains("rate") {
                        logWarning("Rate limit hit for wing \(wingId), waiting 2s (attempt \(attempt)/3)", category: .wingLibrary)
                        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 secondes
                    } else if attempt < 3 {
                        // Autres erreurs: courte pause avant retry
                        logWarning("Fetch failed for wing \(wingId): \(errorDescription), retrying... (attempt \(attempt)/3)", category: .wingLibrary)
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconde
                    }
                }
            }

            throw lastError ?? WingLibraryError.invalidResponse
        }

        pendingRequests[wingId] = task

        do {
            let data = try await task.value
            // Cache to memory and disk after successful fetch
            memoryCache[wingId] = data
            try? data.write(to: diskPath)
            pendingRequests.removeValue(forKey: wingId)
            releaseDownloadSlot()
            logInfo("Cached image for wing \(wingId): \(data.count) bytes", category: .wingLibrary)
            return data
        } catch {
            pendingRequests.removeValue(forKey: wingId)
            releaseDownloadSlot()
            logError("Failed to fetch image for wing \(wingId) after 3 attempts: \(error)", category: .wingLibrary)
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

    /// Retourne le nombre d'images en cache mémoire (pour debug)
    func cacheCount() -> Int {
        return memoryCache.count
    }
}

// MARK: - Models

/// Catalogue complet des voiles (construit à partir des données Appwrite)
struct WingCatalog: Codable {
    let version: String
    let lastUpdated: Date
    let manufacturers: [WingManufacturer]
    let wings: [LibraryWing]
}

/// Fabricant de voiles
struct WingManufacturer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayOrder: Int

    init(id: String, name: String, displayOrder: Int = 0) {
        self.id = id
        self.name = name
        self.displayOrder = displayOrder
    }

    /// Init from Appwrite document
    init(from document: Document<[String: AnyCodable]>) {
        self.id = document.id
        self.name = document.data["name"]?.value as? String ?? ""
        self.displayOrder = document.data["displayOrder"]?.value as? Int ?? 0
    }
}

/// Voile dans la bibliothèque
struct LibraryWing: Codable, Identifiable, Hashable {
    let id: String
    let manufacturer: String  // manufacturerId
    let model: String
    let fullName: String
    let type: String
    let sizes: [String]
    let imageFileId: String?
    let year: Int?
    let displayOrder: Int

    init(id: String, manufacturer: String, model: String, fullName: String, type: String, sizes: [String], imageFileId: String?, year: Int?, displayOrder: Int = 0) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.fullName = fullName
        self.type = type
        self.sizes = sizes
        self.imageFileId = imageFileId
        self.year = year
        self.displayOrder = displayOrder
    }

    /// Init from Appwrite document
    init(from document: Document<[String: AnyCodable]>, manufacturerName: String) {
        self.id = document.id
        self.manufacturer = document.data["manufacturerId"]?.value as? String ?? ""
        self.model = document.data["model"]?.value as? String ?? ""
        self.type = document.data["type"]?.value as? String ?? ""
        self.year = document.data["year"]?.value as? Int
        self.displayOrder = document.data["displayOrder"]?.value as? Int ?? 0

        // Handle sizes array
        if let sizesArray = document.data["sizes"]?.value as? [Any] {
            self.sizes = sizesArray.compactMap { $0 as? String }
        } else {
            self.sizes = []
        }

        self.imageFileId = document.data["imageFileId"]?.value as? String
        self.fullName = "\(manufacturerName) \(self.model)"
    }

    // For backward compatibility with existing code that uses imageUrl
    var imageUrl: String? {
        imageFileId
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LibraryWing, rhs: LibraryWing) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Errors

enum WingLibraryError: LocalizedError {
    case networkUnavailable
    case invalidResponse
    case decodingFailed(Error)
    case imageFetchFailed(Error)
    case appwriteError(Error)

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
        case .appwriteError(let error):
            return "Erreur Appwrite: \(error.localizedDescription)"
        }
    }
}

// MARK: - Service

@Observable
final class WingLibraryService {
    static let shared = WingLibraryService()

    // Published state
    private(set) var catalog: WingCatalog?
    private(set) var isLoading = false
    private(set) var lastError: WingLibraryError?
    private(set) var isOfflineMode = false

    // Appwrite services
    private var databases: Databases { AppwriteService.shared.databases }
    private var storage: Storage { AppwriteService.shared.storage }

    // Cache
    private let catalogCacheKey = "wingLibraryCatalog"
    private let catalogCacheDateKey = "wingLibraryCatalogDate"

    // Thread-safe image cache (actor)
    private let wingImageCache: WingImageCache

    // File manager for image cache
    private var imageCacheDirectory: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("WingLibrary", isDirectory: true)
    }

    private init() {
        // Create image cache directory if needed
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WingLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Initialize thread-safe image cache actor
        wingImageCache = WingImageCache(cacheDirectory: cacheDir)

        // Load cached catalog
        loadCachedCatalog()
    }

    // MARK: - Public API

    /// Fetch the catalog from Appwrite (always tries network first for fresh data)
    @MainActor
    func fetchCatalog(forceRefresh: Bool = false) async throws -> WingCatalog {
        isLoading = true
        lastError = nil
        isOfflineMode = false

        defer { isLoading = false }

        // Always try network first to get fresh data
        do {
            let newCatalog = try await fetchFromAppwrite()
            catalog = newCatalog
            saveCatalogToCache(newCatalog)
            // Clear image cache when catalog is updated to get fresh images
            if forceRefresh {
                await wingImageCache.clearAll()
            }
            logInfo("Fetched catalog: \(newCatalog.wings.count) wings, \(newCatalog.manufacturers.count) manufacturers", category: .wingLibrary)
            return newCatalog
        } catch {
            logWarning("Appwrite fetch failed: \(error.localizedDescription)", category: .wingLibrary)

            // Fallback to cache if available
            if let cached = catalog {
                isOfflineMode = true
                logInfo("Using cache in offline mode", category: .wingLibrary)
                return cached
            }

            // Try loading from persistent cache
            loadCachedCatalog()
            if let cached = catalog {
                isOfflineMode = true
                logInfo("Using persistent cache in offline mode", category: .wingLibrary)
                return cached
            }

            lastError = error as? WingLibraryError ?? .appwriteError(error)
            throw lastError!
        }
    }

    /// Fetch image data for a wing using direct URL (like web-admin)
    /// Uses URLSession instead of Appwrite SDK for better reliability
    func fetchImage(for wing: LibraryWing) async throws -> Data {
        guard let imageFileId = wing.imageFileId else {
            throw WingLibraryError.invalidResponse
        }

        // Build direct URL like web-admin does:
        // ${APPWRITE_ENDPOINT}/storage/buckets/${BUCKET_ID}/files/${FILE_ID}/view?project=${PROJECT_ID}
        let urlString = "\(AppwriteConfig.endpoint)/storage/buckets/\(AppwriteConfig.wingImagesBucketId)/files/\(imageFileId)/view?project=\(AppwriteConfig.projectId)"

        guard let url = URL(string: urlString) else {
            throw WingLibraryError.invalidResponse
        }

        // Delegate to thread-safe actor for cache management
        do {
            return try await wingImageCache.getImage(for: wing.id) {
                // Use URLSession like the old GitHub implementation
                let (data, response) = try await URLSession.shared.data(from: url)

                // Validate response
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw WingLibraryError.invalidResponse
                }

                guard httpResponse.statusCode == 200 else {
                    logWarning("Image fetch failed with status \(httpResponse.statusCode) for \(imageFileId)", category: .wingLibrary)
                    throw WingLibraryError.invalidResponse
                }

                return data
            }
        } catch {
            throw WingLibraryError.imageFetchFailed(error)
        }
    }

    /// Clear all caches
    func clearCache() async {
        catalog = nil
        UserDefaults.standard.removeObject(forKey: catalogCacheKey)
        UserDefaults.standard.removeObject(forKey: catalogCacheDateKey)

        // Clear image cache via actor (thread-safe)
        await wingImageCache.clearAll()

        logInfo("Cache cleared", category: .wingLibrary)
    }

    /// Get wings filtered by manufacturer
    func wings(for manufacturerId: String) -> [LibraryWing] {
        catalog?.wings.filter { $0.manufacturer == manufacturerId } ?? []
    }

    // MARK: - Private

    private func fetchFromAppwrite() async throws -> WingCatalog {
        // Fetch manufacturers
        let manufacturersResponse = try await databases.listDocuments<[String: AnyCodable]>(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.manufacturersCollectionId,
            queries: [
                Query.orderAsc("displayOrder"),
                Query.limit(100)
            ]
        )

        let manufacturers = manufacturersResponse.documents.map { WingManufacturer(from: $0) }

        // Create a lookup dictionary for manufacturer names
        let manufacturerNames = Dictionary(uniqueKeysWithValues: manufacturers.map { ($0.id, $0.name) })

        // Fetch wings
        let wingsResponse = try await databases.listDocuments<[String: AnyCodable]>(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.wingsCollectionId,
            queries: [
                Query.orderAsc("displayOrder"),
                Query.orderAsc("model"),
                Query.limit(500)
            ]
        )

        let wings = wingsResponse.documents.map { doc in
            let manufacturerId = doc.data["manufacturerId"]?.value as? String ?? ""
            let manufacturerName = manufacturerNames[manufacturerId] ?? ""
            return LibraryWing(from: doc, manufacturerName: manufacturerName)
        }

        // Build catalog
        return WingCatalog(
            version: "appwrite-1.0",
            lastUpdated: Date(),
            manufacturers: manufacturers,
            wings: wings
        )
    }

    private func loadCachedCatalog() {
        guard let data = UserDefaults.standard.data(forKey: catalogCacheKey) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            catalog = try decoder.decode(WingCatalog.self, from: data)
            logInfo("Loaded cached catalog: \(catalog?.wings.count ?? 0) wings", category: .wingLibrary)
        } catch {
            logWarning("Failed to decode cached catalog: \(error.localizedDescription)", category: .wingLibrary)
        }
    }

    private func saveCatalogToCache(_ catalog: WingCatalog) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(catalog)
            UserDefaults.standard.set(data, forKey: catalogCacheKey)
            UserDefaults.standard.set(Date(), forKey: catalogCacheDateKey)
        } catch {
            logWarning("Failed to cache catalog: \(error.localizedDescription)", category: .wingLibrary)
        }
    }

    private func isCacheValid() -> Bool {
        guard let cacheDate = UserDefaults.standard.object(forKey: catalogCacheDateKey) as? Date else {
            return false
        }
        return Date().timeIntervalSince(cacheDate) < WingLibraryConstants.catalogCacheMaxAge
    }
}
