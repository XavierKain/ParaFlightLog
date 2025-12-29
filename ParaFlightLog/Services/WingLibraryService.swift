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
import NIOCore
import NIOFoundationCompat

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

    init(id: String, manufacturer: String, model: String, fullName: String, type: String, sizes: [String], imageFileId: String?, year: Int?) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.fullName = fullName
        self.type = type
        self.sizes = sizes
        self.imageFileId = imageFileId
        self.year = year
    }

    /// Init from Appwrite document
    init(from document: Document<[String: AnyCodable]>, manufacturerName: String) {
        self.id = document.id
        self.manufacturer = document.data["manufacturerId"]?.value as? String ?? ""
        self.model = document.data["model"]?.value as? String ?? ""
        self.type = document.data["type"]?.value as? String ?? ""
        self.year = document.data["year"]?.value as? Int

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
    private var imageCache: [String: Data] = [:]

    // File manager for image cache
    private var imageCacheDirectory: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("WingLibrary", isDirectory: true)
    }

    private init() {
        // Create image cache directory if needed
        try? FileManager.default.createDirectory(at: imageCacheDirectory, withIntermediateDirectories: true)

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
                imageCache.removeAll()
                try? FileManager.default.removeItem(at: imageCacheDirectory)
                try? FileManager.default.createDirectory(at: imageCacheDirectory, withIntermediateDirectories: true)
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

    /// Fetch image data for a wing from Appwrite Storage
    func fetchImage(for wing: LibraryWing) async throws -> Data {
        guard let imageFileId = wing.imageFileId else {
            throw WingLibraryError.invalidResponse
        }

        let diskCachePath = imageCacheDirectory.appendingPathComponent("\(wing.id).png")

        // Check memory cache first (only valid during session)
        if let cached = imageCache[wing.id] {
            return cached
        }

        // Try to fetch from Appwrite Storage
        do {
            let byteBuffer = try await storage.getFileDownload(
                bucketId: AppwriteConfig.wingImagesBucketId,
                fileId: imageFileId
            )

            // Convert ByteBuffer to Data
            let fileData = byteBuffer.getData(at: 0, length: byteBuffer.readableBytes) ?? Data()

            // Cache to memory and disk
            imageCache[wing.id] = fileData
            try? fileData.write(to: diskCachePath)

            logInfo("Fetched image for \(wing.fullName): \(fileData.count) bytes", category: .wingLibrary)
            return fileData
        } catch {
            // Fallback to disk cache if network fails
            if let diskData = try? Data(contentsOf: diskCachePath) {
                logInfo("Using cached image for \(wing.fullName)", category: .wingLibrary)
                imageCache[wing.id] = diskData
                return diskData
            }
            throw WingLibraryError.imageFetchFailed(error)
        }
    }

    /// Clear all caches
    func clearCache() {
        catalog = nil
        imageCache.removeAll()
        UserDefaults.standard.removeObject(forKey: catalogCacheKey)
        UserDefaults.standard.removeObject(forKey: catalogCacheDateKey)

        // Clear disk cache
        try? FileManager.default.removeItem(at: imageCacheDirectory)
        try? FileManager.default.createDirectory(at: imageCacheDirectory, withIntermediateDirectories: true)

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
