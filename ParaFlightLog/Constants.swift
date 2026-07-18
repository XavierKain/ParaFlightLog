//
//  Constants.swift
//  ParaFlightLog
//
//  Central place for all application constants.
//  Target: iOS + Watch (shared)
//

import Foundation

// MARK: - App Configuration

nonisolated enum AppConstants {
    /// Bundle identifier used for OSLog
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.xavierkain.SoarX"

    /// Application name
    static let appName = "ParaFlightLog"
}

// MARK: - Watch Sync Configuration

enum WatchSyncConstants: Sendable {
    /// Delay before the first sync after session activation (seconds)
    static let initialSyncDelay: TimeInterval = 2.0

    /// Maximum payload size for applicationContext (KB).
    /// WCSession supports up to ~500KB for applicationContext.
    static let maxContextSizeKB = 200.0
}

// MARK: - Image Processing Configuration

enum ImageConstants {
    /// Maximum thumbnail size for the Watch (pixels)
    static let watchThumbnailSize: CGFloat = 48

    /// Maximum compressed image size for the Watch (pixels)
    static let watchImageMaxSize: CGFloat = 100

    /// JPEG compression quality (0.0 to 1.0)
    static let jpegCompressionQuality: CGFloat = 0.7

    /// Tolerance for white background removal (0.0 to 1.0)
    static let whiteBackgroundTolerance: CGFloat = 0.92

    /// Maximum number of items in the Watch image cache
    static let watchImageCacheCount = 20

    /// Maximum Watch image cache size (MB)
    static let watchImageCacheSizeMB = 10
}

// MARK: - GPS Tracking Configuration

enum GPSConstants {
    /// Maximum GPS points kept in memory on the Watch
    static let maxPointsInMemory = 500

    /// Threshold that triggers compaction (80% of the limit)
    static let compactionThreshold = 400

    /// Interval between GPS track points (seconds)
    static let trackPointInterval: TimeInterval = 5.0

    /// Minimum distance to count a movement (meters)
    static let minDistanceFilter: Double = 3.0

    /// Maximum distance between 2 points (GPS jump filter, meters)
    static let maxDistanceBetweenPoints: Double = 100.0

    /// Acceptable horizontal accuracy (meters)
    static let acceptableHorizontalAccuracy: Double = 20.0

    /// Minimum speed to consider a movement (m/s, ~1.8 km/h)
    static let minSpeedThreshold: Double = 0.5

    /// Maximum reasonable speed for filtering (m/s, ~360 km/h)
    static let maxSpeedThreshold: Double = 100.0
}

// MARK: - Motion Tracking Configuration

enum MotionConstants {
    /// Motion sensor update interval (seconds)
    static let updateInterval: TimeInterval = 0.1  // 10 Hz

    /// Buffer size for the G-force moving average
    static let gForceBufferSize = 3

    /// Maximum reasonable G-force (outlier filter)
    static let maxGForce: Double = 10.0
}

// MARK: - UserDefaults Keys

nonisolated enum UserDefaultsKeys {
    static let watchAutoWaterLock = "watchAutoWaterLock"
    static let watchAllowSessionDismiss = "watchAllowSessionDismiss"
    static let developerModeEnabled = "developerModeEnabled"

    /// Developer tool: run a simulated (fake feed) flight on the Watch
    static let simulateFlightEnabled = "simulateFlightEnabled"

    /// UUID string of the wing used for the most recent flight — used to
    /// pre-select it wherever a wing must be picked.
    static let lastUsedWingId = "lastUsedWingId"

    /// True once the first-launch onboarding has been completed or skipped.
    static let hasCompletedOnboarding = "hasCompletedOnboarding"

    /// Vario (audio variometer) enabled
    static let varioEnabled = "varioEnabled"

    /// Phone-only mode: use the iPhone timer as the main flight tracker
    static let phoneOnlyMode = "phoneOnlyMode"

    /// Raw value of the last FlightType picked by the pilot
    static let lastFlightType = "lastFlightType"

    /// Automatically record wind/temperature at takeoff when a flight is
    /// saved (Open-Meteo, best-effort). Default TRUE: read through
    /// `WeatherService.autoSnapshotEnabled`, which treats a never-set key
    /// as enabled (`object(forKey:) == nil` pattern).
    static let autoWeatherSnapshot = "autoWeatherSnapshot"

    /// Opt-in community sharing (Step C): upload flight summaries to
    /// Appwrite. Default FALSE — read/written via
    /// `CommunityService.isSharingEnabled`.
    static let communitySharingEnabled = "communitySharingEnabled"

    /// Opt-in live presence heartbeat while a flight is active (Step C2).
    /// Default FALSE — read/written via `CommunityService.isPresenceEnabled`.
    static let presenceEnabled = "presenceEnabled"

    /// Public display name attached to shared flights (empty -> "A pilot").
    static let pilotDisplayName = "pilotDisplayName"

    /// Include the (downsampled, compressed) GPS track with shared flights so
    /// other pilots can see the full line and replay it in 3D. Default TRUE
    /// while sharing is on — read/written via `CommunityService.isTrackSharingEnabled`.
    static let communityShareTracks = "communityShareTracks"

    /// Appwrite push-target `$id` created via `account.createPushTarget`
    /// (Phase 1 push). Present means this device is registered for pushes on
    /// the current account; cleared on sign-out. Read/written by PushService.
    static let pushTargetId = "pushTargetId"

    /// The APNs device token (hex string) last registered as the push
    /// target's identifier. Used to detect token changes and avoid redundant
    /// `updatePushTarget` calls. Read/written by PushService.
    static let pushDeviceToken = "pushDeviceToken"
}

// MARK: - Weather Configuration

enum WeatherConstants {
    /// Open-Meteo request timeout (15 seconds)
    static let networkTimeout: TimeInterval = 15.0
}

// MARK: - Wing Library Configuration

enum WingLibraryConstants {
    /// Image cache validity (7 days)
    static let imageCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Network request timeout (15 seconds)
    static let networkTimeout: TimeInterval = 15.0
}
