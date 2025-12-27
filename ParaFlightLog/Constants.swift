//
//  Constants.swift
//  ParaFlightLog
//
//  Centralisation de toutes les constantes de l'application
//  Facilite la maintenance et évite les valeurs hardcodées dispersées
//  Target: iOS + Watch (shared)
//

import Foundation

// MARK: - App Configuration

enum AppConstants {
    /// Bundle identifier pour OSLog
    static let bundleIdentifier = "com.xavierkain.ParaFlightLog"

    /// Nom de l'application
    static let appName = "ParaFlightLog"
}

// MARK: - Watch Sync Configuration

enum WatchSyncConstants: Sendable {
    /// Délai avant retry de synchronisation (secondes)
    static let retryDelay: TimeInterval = 1.0

    /// Nombre maximum de tentatives de synchronisation
    static let maxRetryAttempts = 5

    /// Timeout pour une opération de sync (secondes)
    static let syncTimeout: TimeInterval = 30.0

    /// Délai initial pour la première sync après activation (secondes)
    static let initialSyncDelay: TimeInterval = 2.0

    /// Taille maximale des données pour applicationContext (KB)
    /// WCSession supporte jusqu'à ~500KB pour applicationContext
    static let maxContextSizeKB = 200.0

    /// Backoff exponentiel : multiplicateur pour chaque retry
    static let backoffMultiplier: Double = 1.5
}

// MARK: - Image Processing Configuration

enum ImageConstants {
    /// Taille maximale des miniatures pour la Watch (pixels)
    static let watchThumbnailSize: CGFloat = 48

    /// Taille maximale des images compressées pour la Watch (pixels)
    static let watchImageMaxSize: CGFloat = 100

    /// Qualité de compression JPEG (0.0 à 1.0)
    static let jpegCompressionQuality: CGFloat = 0.7

    /// Tolérance pour la suppression du fond blanc (0.0 à 1.0)
    static let whiteBackgroundTolerance: CGFloat = 0.92

    /// Taille maximale du cache d'images sur Watch (nombre d'éléments)
    static let watchImageCacheCount = 20

    /// Taille maximale du cache d'images sur Watch (MB)
    static let watchImageCacheSizeMB = 10
}

// MARK: - GPS Tracking Configuration

enum GPSConstants {
    /// Nombre maximum de points GPS en mémoire sur Watch
    static let maxPointsInMemory = 500

    /// Seuil pour déclencher la compaction (80% de la limite)
    static let compactionThreshold = 400

    /// Intervalle entre chaque point GPS (secondes)
    static let trackPointInterval: TimeInterval = 5.0

    /// Distance minimale pour comptabiliser un déplacement (mètres)
    static let minDistanceFilter: Double = 3.0

    /// Distance maximale entre 2 points (filtre anti-saut GPS, mètres)
    static let maxDistanceBetweenPoints: Double = 100.0

    /// Précision horizontale acceptable (mètres)
    static let acceptableHorizontalAccuracy: Double = 20.0

    /// Vitesse minimale pour considérer un mouvement (m/s, ~1.8 km/h)
    static let minSpeedThreshold: Double = 0.5

    /// Vitesse maximale raisonnable pour filtrage (m/s, ~360 km/h)
    static let maxSpeedThreshold: Double = 100.0
}

// MARK: - Motion Tracking Configuration

enum MotionConstants {
    /// Intervalle de mise à jour du capteur de mouvement (secondes)
    static let updateInterval: TimeInterval = 0.1  // 10 Hz

    /// Taille du buffer pour la moyenne mobile du G-force
    static let gForceBufferSize = 3

    /// G-force maximum raisonnable (filtre anti-aberration)
    static let maxGForce: Double = 10.0
}

// MARK: - Stats Cache Configuration

enum StatsCacheConstants {
    /// Délai minimum entre deux rafraîchissements du cache (secondes)
    static let minRefreshInterval: TimeInterval = 1.0
}

// MARK: - Reverse Geocoding Configuration

enum GeocodingConstants {
    /// Timeout pour le reverse geocoding (secondes)
    static let timeout: TimeInterval = 5.0
}

// MARK: - UserDefaults Keys

enum UserDefaultsKeys {
    static let watchAutoWaterLock = "watchAutoWaterLock"
    static let watchAllowSessionDismiss = "watchAllowSessionDismiss"
    static let savedWings = "savedWings"
    static let currentLanguage = "currentLanguage"
    static let appleLanguages = "AppleLanguages"
    static let pendingSession = "pendingFlightSession"
    static let developerModeEnabled = "developerModeEnabled"
}

// MARK: - Notification Names

enum NotificationNames {
    static let flightSaved = Notification.Name("flightSaved")
    static let wingsSynced = Notification.Name("wingsSynced")
    static let statsCacheInvalidated = Notification.Name("statsCacheInvalidated")
}

// MARK: - Wing Library Configuration

enum WingLibraryConstants {
    /// URL de base du repository GitHub
    static let baseURL = "https://raw.githubusercontent.com/XavierKain/paraflightlog-wings/main"

    /// URL du catalogue JSON
    static let catalogURL = "\(baseURL)/wings.json"

    /// Durée de validité du cache catalogue (24 heures)
    static let catalogCacheMaxAge: TimeInterval = 24 * 60 * 60

    /// Durée de validité du cache images (7 jours)
    static let imageCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Timeout pour les requêtes réseau (15 secondes)
    static let networkTimeout: TimeInterval = 15.0
}
