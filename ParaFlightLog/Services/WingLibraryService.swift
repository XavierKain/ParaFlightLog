//
//  WingLibraryService.swift
//  ParaFlightLog
//
//  Service pour récupérer et mettre en cache le catalogue de voiles en ligne
//  Target: iOS only
//

import Foundation
import UIKit

// MARK: - Models

/// Catalogue complet des voiles
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
}

/// Voile dans la bibliothèque
struct LibraryWing: Codable, Identifiable, Hashable {
    let id: String
    let manufacturer: String
    let model: String
    let fullName: String
    let type: String
    let sizes: [String]
    let imageUrl: String?
    let year: Int?

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

@Observable
final class WingLibraryService {
    static let shared = WingLibraryService()

    // Published state
    private(set) var catalog: WingCatalog?
    private(set) var isLoading = false
    private(set) var lastError: WingLibraryError?
    private(set) var isOfflineMode = false

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

    /// Fetch the catalog from the server (always tries network first for fresh data)
    @MainActor
    func fetchCatalog(forceRefresh: Bool = false) async throws -> WingCatalog {
        isLoading = true
        lastError = nil
        isOfflineMode = false

        defer { isLoading = false }

        // Always try network first to get fresh data
        do {
            let newCatalog = try await fetchFromNetwork()
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
            logWarning("Network fetch failed: \(error.localizedDescription)", category: .wingLibrary)

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

            lastError = error as? WingLibraryError ?? .networkUnavailable
            throw lastError!
        }
    }

    /// Fetch image data for a wing (always fetches from network, with disk cache fallback)
    func fetchImage(for wing: LibraryWing) async throws -> Data {
        guard let imageUrl = wing.imageUrl else {
            throw WingLibraryError.invalidResponse
        }

        let diskCachePath = imageCacheDirectory.appendingPathComponent("\(wing.id).png")

        // Check memory cache first (only valid during session)
        if let cached = imageCache[wing.id] {
            return cached
        }

        // Try to fetch from network (always prefer fresh data)
        let url = URL(string: "\(WingLibraryConstants.baseURL)/\(imageUrl)")!

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = WingLibraryConstants.networkTimeout

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw WingLibraryError.invalidResponse
            }

            // Cache to memory and disk
            imageCache[wing.id] = data
            try? data.write(to: diskCachePath)

            logInfo("Fetched image for \(wing.fullName): \(data.count) bytes", category: .wingLibrary)
            return data
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

    private func fetchFromNetwork() async throws -> WingCatalog {
        guard let url = URL(string: WingLibraryConstants.catalogURL) else {
            throw WingLibraryError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = WingLibraryConstants.networkTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WingLibraryError.invalidResponse
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WingCatalog.self, from: data)
        } catch {
            throw WingLibraryError.decodingFailed(error)
        }
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
