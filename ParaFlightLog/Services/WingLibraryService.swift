//
//  WingLibraryService.swift
//  ParaFlightLog
//
//  Service pour récupérer et mettre en cache le catalogue de voiles depuis Appwrite
//  Target: iOS only
//

import Foundation
import UIKit


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
    case timeout

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "No internet connection"
        case .invalidResponse:
            return "Invalid server response"
        case .decodingFailed(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .imageFetchFailed(let error):
            return "Image download error: \(error.localizedDescription)"
        case .appwriteError(let error):
            return "Appwrite error: \(error.localizedDescription)"
        case .timeout:
            return "The wing library took too long to respond. Check your connection, or verify this app's bundle id is registered as an Apple platform in the Appwrite console."
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

    // File manager for image cache
    private var imageCacheDirectory: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("WingLibrary", isDirectory: true)
    }

    private init() {}

    // MARK: - Public API

    /// Loads the catalog that ships with the app.
    ///
    /// This used to come from Appwrite, whose free plan pauses a project after
    /// seven days with no *development* activity — API traffic does not count,
    /// so no keep-alive could have fixed it, and a paused project took the
    /// library down with it. The catalog is read-only reference data: 23 wings
    /// and 12 manufacturers that change a few times a year. It never needed a
    /// database, so it now ships in the bundle and cannot break.
    ///
    /// `forceRefresh` is kept for the call sites (the Retry button): with no
    /// network involved there is nothing to refresh, but re-reading the file
    /// is cheap and harmless.
    @MainActor
    func fetchCatalog(forceRefresh: Bool = false) async throws -> WingCatalog {
        isLoading = true
        lastError = nil
        // Nothing can be stale or unreachable any more.
        isOfflineMode = false
        defer { isLoading = false }

        if let catalog, !forceRefresh {
            return catalog
        }

        do {
            let loaded = try Self.loadBundledCatalog()
            catalog = loaded
            logInfo("Loaded bundled catalog: \(loaded.wings.count) wings, \(loaded.manufacturers.count) manufacturers", category: .wingLibrary)
            return loaded
        } catch {
            logError("Bundled catalog unreadable: \(error.localizedDescription)", category: .wingLibrary)
            lastError = .invalidResponse
            throw WingLibraryError.invalidResponse
        }
    }

    /// Image data for a wing, read from the bundle.
    ///
    /// No cache layer: the file is already on the device, and a copy of a
    /// bundled file in the Caches directory is pure waste.
    func fetchImage(for wing: LibraryWing) async throws -> Data {
        guard let imageFileId = wing.imageFileId,
              let url = Bundle.main.url(forResource: imageFileId, withExtension: "png") else {
            throw WingLibraryError.invalidResponse
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw WingLibraryError.imageFetchFailed(error)
        }
    }

    /// Drops the in-memory catalog and the caches left behind by the Appwrite
    /// era, so an app updated from an older build stops carrying them around.
    func clearCache() async {
        catalog = nil
        UserDefaults.standard.removeObject(forKey: catalogCacheKey)
        UserDefaults.standard.removeObject(forKey: catalogCacheDateKey)
        try? FileManager.default.removeItem(at: imageCacheDirectory)
        logInfo("Cache cleared", category: .wingLibrary)
    }

    /// Get wings filtered by manufacturer
    func wings(for manufacturerId: String) -> [LibraryWing] {
        catalog?.wings.filter { $0.manufacturer == manufacturerId } ?? []
    }

    // MARK: - Private

    /// Reads and decodes `WingCatalog.json` from the app bundle.
    static func loadBundledCatalog() throws -> WingCatalog {
        guard let url = Bundle.main.url(forResource: "WingCatalog", withExtension: "json") else {
            throw WingLibraryError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WingCatalog.self, from: Data(contentsOf: url))
    }

}
