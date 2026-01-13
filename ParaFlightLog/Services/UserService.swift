//
//  UserService.swift
//  ParaFlightLog
//
//  Service de gestion des profils utilisateurs
//  Création, mise à jour, récupération des profils
//  Target: iOS only
//

import Foundation
import Appwrite
import UIKit

// MARK: - User Profile Errors

enum UserProfileError: LocalizedError {
    case notAuthenticated
    case profileNotFound
    case usernameAlreadyTaken
    case invalidUsername
    case uploadFailed
    case networkError(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Vous devez être connecté"
        case .profileNotFound:
            return "Profil non trouvé"
        case .usernameAlreadyTaken:
            return "Ce nom d'utilisateur est déjà pris"
        case .invalidUsername:
            return "Le nom d'utilisateur doit contenir entre 3 et 20 caractères alphanumériques"
        case .uploadFailed:
            return "Échec de l'upload de l'image"
        case .networkError(let message):
            return "Erreur réseau: \(message)"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - User Profile Model

struct CloudUserProfile: Identifiable, Equatable {
    let id: String
    let authUserId: String
    let email: String
    var displayName: String
    var username: String
    var bio: String?
    var profilePhotoFileId: String?
    var homeLocationLat: Double?
    var homeLocationLon: Double?
    var homeLocationName: String?
    var pilotWeight: Double?
    var isPremium: Bool
    var premiumUntil: Date?
    var notificationsEnabled: Bool
    var totalFlights: Int
    var totalFlightSeconds: Int
    var xpTotal: Int
    var level: Int
    var currentStreak: Int
    var longestStreak: Int
    let createdAt: Date
    var lastActiveAt: Date

    /// Initialise depuis un dictionnaire Appwrite avec gestion des valeurs manquantes
    init(from data: [String: Any]) throws {
        guard let id = data["$id"] as? String else {
            throw UserProfileError.unknown("Missing $id field")
        }
        guard let authUserId = data["authUserId"] as? String else {
            throw UserProfileError.unknown("Missing authUserId field")
        }

        self.id = id
        self.authUserId = authUserId
        self.email = data["email"] as? String ?? ""
        self.displayName = data["displayName"] as? String ?? "Pilote"
        self.username = data["username"] as? String ?? "pilot"
        self.bio = data["bio"] as? String
        self.profilePhotoFileId = data["profilePhotoFileId"] as? String
        self.homeLocationLat = data["homeLocationLat"] as? Double
        self.homeLocationLon = data["homeLocationLon"] as? Double
        self.homeLocationName = data["homeLocationName"] as? String
        self.pilotWeight = data["pilotWeight"] as? Double

        // Booléens avec valeurs par défaut
        self.isPremium = data["isPremium"] as? Bool ?? false
        self.notificationsEnabled = data["notificationsEnabled"] as? Bool ?? true

        // Entiers avec valeurs par défaut
        self.totalFlights = data["totalFlights"] as? Int ?? 0
        self.totalFlightSeconds = data["totalFlightSeconds"] as? Int ?? 0
        self.xpTotal = data["xpTotal"] as? Int ?? 0
        self.level = data["level"] as? Int ?? 1
        self.currentStreak = data["currentStreak"] as? Int ?? 0
        self.longestStreak = data["longestStreak"] as? Int ?? 0

        // Dates - parser depuis string ISO8601 ou utiliser Date()
        if let premiumUntilStr = data["premiumUntil"] as? String {
            self.premiumUntil = ISO8601DateFormatter().date(from: premiumUntilStr)
        } else {
            self.premiumUntil = nil
        }

        if let createdAtStr = data["createdAt"] as? String,
           let createdAt = ISO8601DateFormatter().date(from: createdAtStr) {
            self.createdAt = createdAt
        } else if let createdAt = data["$createdAt"] as? String,
                  let date = ISO8601DateFormatter().date(from: createdAt) {
            self.createdAt = date
        } else {
            self.createdAt = Date()
        }

        if let lastActiveAtStr = data["lastActiveAt"] as? String,
           let lastActiveAt = ISO8601DateFormatter().date(from: lastActiveAtStr) {
            self.lastActiveAt = lastActiveAt
        } else if let updatedAt = data["$updatedAt"] as? String,
                  let date = ISO8601DateFormatter().date(from: updatedAt) {
            self.lastActiveAt = date
        } else {
            self.lastActiveAt = Date()
        }
    }

    /// Initialisation directe (pour créer un profil local)
    init(
        id: String,
        authUserId: String,
        email: String,
        displayName: String,
        username: String,
        bio: String? = nil,
        profilePhotoFileId: String? = nil,
        homeLocationLat: Double? = nil,
        homeLocationLon: Double? = nil,
        homeLocationName: String? = nil,
        pilotWeight: Double? = nil,
        isPremium: Bool = false,
        premiumUntil: Date? = nil,
        notificationsEnabled: Bool = true,
        totalFlights: Int = 0,
        totalFlightSeconds: Int = 0,
        xpTotal: Int = 0,
        level: Int = 1,
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        createdAt: Date = Date(),
        lastActiveAt: Date = Date()
    ) {
        self.id = id
        self.authUserId = authUserId
        self.email = email
        self.displayName = displayName
        self.username = username
        self.bio = bio
        self.profilePhotoFileId = profilePhotoFileId
        self.homeLocationLat = homeLocationLat
        self.homeLocationLon = homeLocationLon
        self.homeLocationName = homeLocationName
        self.pilotWeight = pilotWeight
        self.isPremium = isPremium
        self.premiumUntil = premiumUntil
        self.notificationsEnabled = notificationsEnabled
        self.totalFlights = totalFlights
        self.totalFlightSeconds = totalFlightSeconds
        self.xpTotal = xpTotal
        self.level = level
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}

// MARK: - UserService

@Observable
final class UserService {
    static let shared = UserService()

    // MARK: - Properties

    private let databases: Databases
    private let tablesDB: TablesDB
    private let storage: Storage

    private(set) var currentUserProfile: CloudUserProfile?
    private(set) var isLoading: Bool = false

    // Cache des profils consultés
    private var profileCache: [String: CloudUserProfile] = [:]

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases
        self.tablesDB = AppwriteService.shared.tablesDB
        self.storage = AppwriteService.shared.storage
    }

    // MARK: - Profile Creation

    /// Crée un profil utilisateur après inscription
    @discardableResult
    func createProfile(authUserId: String, email: String, displayName: String, username: String) async throws -> CloudUserProfile {
        logInfo("createProfile: Starting for authUserId=\(authUserId), email=\(email)", category: .auth)
        logInfo("createProfile: Using database=\(AppwriteConfig.databaseId), collection=\(AppwriteConfig.usersCollectionId)", category: .auth)

        isLoading = true
        defer { isLoading = false }

        // Vérifier que le username est valide
        guard isValidUsername(username) else {
            logError("createProfile: Invalid username format: \(username)", category: .auth)
            throw UserProfileError.invalidUsername
        }

        // Vérifier que le username n'est pas déjà pris
        do {
            let isAvailable = try await isUsernameAvailable(username)
            if !isAvailable {
                logError("createProfile: Username already taken: \(username)", category: .auth)
                throw UserProfileError.usernameAlreadyTaken
            }
        } catch let error as UserProfileError {
            throw error
        } catch {
            logError("createProfile: Error checking username availability: \(error.localizedDescription)", category: .auth)
            // Continue anyway - le serveur vérifiera l'unicité
        }

        let now = Date()
        let profileData: [String: Any] = [
            "authUserId": authUserId,
            "email": email,
            "displayName": displayName,
            "username": username.lowercased(),
            "bio": "",
            "isPremium": false,
            "notificationsEnabled": true,
            "totalFlights": 0,
            "totalFlightSeconds": 0,
            "xpTotal": 0,
            "level": 1,
            "currentStreak": 0,
            "longestStreak": 0,
            "createdAt": now.ISO8601Format(),
            "lastActiveAt": now.ISO8601Format()
        ]

        logInfo("createProfile: Sending data to Appwrite...", category: .auth)

        do {
            let document = try await tablesDB.createRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                rowId: ID.unique(),
                data: profileData
            )

            logInfo("createProfile: Document created with ID=\(document.id)", category: .auth)

            let profile = try parseProfile(from: document.data)
            currentUserProfile = profile
            profileCache[profile.id] = profile

            logInfo("createProfile: Profile created successfully for user: \(email)", category: .auth)
            return profile
        } catch let error as AppwriteError {
            logError("createProfile: Appwrite error - \(error.message)", category: .auth)
            logError("createProfile: Error type - \(error.type ?? "unknown")", category: .auth)
            logError("createProfile: This usually means the 'users' collection doesn't exist or has wrong attributes/permissions", category: .auth)
            throw UserProfileError.unknown(error.message)
        } catch {
            logError("createProfile: Unknown error - \(error.localizedDescription)", category: .auth)
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Profile Retrieval

    /// Récupère le profil de l'utilisateur connecté
    func getCurrentProfile() async throws -> CloudUserProfile? {
        guard let authUserId = AuthService.shared.currentUserId else {
            logWarning("getCurrentProfile: No authUserId available", category: .auth)
            return nil
        }

        logInfo("getCurrentProfile: Looking for profile with authUserId=\(authUserId)", category: .auth)
        logInfo("getCurrentProfile: Using database=\(AppwriteConfig.databaseId), collection=\(AppwriteConfig.usersCollectionId)", category: .auth)

        isLoading = true
        defer { isLoading = false }

        do {
            let documents = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.equal("authUserId", value: authUserId),
                    Query.limit(1)
                ]
            )

            logInfo("getCurrentProfile: Found \(documents.rows.count) document(s)", category: .auth)

            if let doc = documents.rows.first {
                logInfo("getCurrentProfile: Parsing document \(doc.id)", category: .auth)
                let profile = try parseProfile(from: doc.data)
                currentUserProfile = profile
                profileCache[profile.id] = profile
                logInfo("getCurrentProfile: Profile loaded successfully for \(profile.email)", category: .auth)
                return profile
            }

            logInfo("getCurrentProfile: No profile found for authUserId=\(authUserId)", category: .auth)
            return nil
        } catch let error as AppwriteError {
            logError("getCurrentProfile: Appwrite error - \(error.message)", category: .auth)
            logError("getCurrentProfile: Error type - \(error.type ?? "unknown")", category: .auth)
            throw UserProfileError.unknown(error.message)
        } catch {
            logError("getCurrentProfile: Unknown error - \(error.localizedDescription)", category: .auth)
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }

    /// Récupère le profil d'un utilisateur par son ID
    func getProfile(userId: String) async throws -> CloudUserProfile {
        // Vérifier le cache
        if let cached = profileCache[userId] {
            return cached
        }

        do {
            let document = try await tablesDB.getRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                rowId: userId
            )

            let profile = try parseProfile(from: document.data)
            profileCache[profile.id] = profile
            return profile
        } catch {
            throw UserProfileError.profileNotFound
        }
    }

    /// Récupère le profil par username
    func getProfileByUsername(_ username: String) async throws -> CloudUserProfile? {
        do {
            let documents = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.equal("username", value: username.lowercased()),
                    Query.limit(1)
                ]
            )

            if let doc = documents.rows.first {
                let profile = try parseProfile(from: doc.data)
                profileCache[profile.id] = profile
                return profile
            }

            return nil
        } catch {
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Profile Update

    /// Met à jour le profil utilisateur
    func updateProfile(
        displayName: String? = nil,
        bio: String? = nil,
        username: String? = nil,
        homeLocationLat: Double? = nil,
        homeLocationLon: Double? = nil,
        homeLocationName: String? = nil,
        pilotWeight: Double? = nil,
        notificationsEnabled: Bool? = nil
    ) async throws {
        guard let profile = currentUserProfile else {
            throw UserProfileError.notAuthenticated
        }

        isLoading = true
        defer { isLoading = false }

        var updateData: [String: Any] = [
            "lastActiveAt": Date().ISO8601Format()
        ]

        if let displayName = displayName {
            updateData["displayName"] = displayName
        }
        if let bio = bio {
            updateData["bio"] = bio
        }
        if let username = username {
            guard isValidUsername(username) else {
                throw UserProfileError.invalidUsername
            }
            if username.lowercased() != profile.username {
                guard try await isUsernameAvailable(username) else {
                    throw UserProfileError.usernameAlreadyTaken
                }
            }
            updateData["username"] = username.lowercased()
        }
        if let lat = homeLocationLat {
            updateData["homeLocationLat"] = lat
        }
        if let lon = homeLocationLon {
            updateData["homeLocationLon"] = lon
        }
        if let name = homeLocationName {
            updateData["homeLocationName"] = name
        }
        if let weight = pilotWeight {
            updateData["pilotWeight"] = weight
        }
        if let notifs = notificationsEnabled {
            updateData["notificationsEnabled"] = notifs
        }

        do {
            logInfo("updateProfile: Starting with data: \(updateData)", category: .auth)

            let document = try await tablesDB.updateRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                rowId: profile.id,
                data: updateData
            )

            let updatedProfile = try parseProfile(from: document.data)

            // S'assurer que la mise à jour est faite sur le main actor pour la réactivité SwiftUI
            await MainActor.run {
                currentUserProfile = updatedProfile
                profileCache[updatedProfile.id] = updatedProfile
            }

            logInfo("updateProfile: currentUserProfile updated to: \(updatedProfile.displayName)", category: .auth)
        } catch let error as AppwriteError {
            logError("updateProfile: Appwrite error - message: \(error.message), code: \(error.code ?? 0), type: \(error.type ?? "unknown")", category: .auth)
            throw UserProfileError.unknown(error.message)
        } catch {
            logError("updateProfile: Unknown error - \(error.localizedDescription)", category: .auth)
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }

    /// Met à jour la photo de profil
    @discardableResult
    func updateProfilePhoto(imageData: Data) async throws -> String {
        guard let profile = currentUserProfile else {
            throw UserProfileError.notAuthenticated
        }

        isLoading = true
        defer { isLoading = false }

        // Supprimer l'ancienne photo si elle existe
        if let oldFileId = profile.profilePhotoFileId {
            _ = try? await storage.deleteFile(
                bucketId: AppwriteConfig.profilePhotosBucketId,
                fileId: oldFileId
            )
        }

        do {
            // Upload la nouvelle photo
            let file = try await storage.createFile(
                bucketId: AppwriteConfig.profilePhotosBucketId,
                fileId: ID.unique(),
                file: InputFile.fromData(imageData, filename: "profile.jpg", mimeType: "image/jpeg")
            )

            // Mettre à jour le profil avec le nouveau fileId
            let _ = try await tablesDB.updateRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                rowId: profile.id,
                data: [
                    "profilePhotoFileId": file.id,
                    "lastActiveAt": Date().ISO8601Format()
                ]
            )

            // Mettre à jour le profil local
            var updated = profile
            updated.profilePhotoFileId = file.id
            currentUserProfile = updated
            profileCache[updated.id] = updated

            logInfo("Profile photo updated", category: .auth)
            return file.id
        } catch {
            throw UserProfileError.uploadFailed
        }
    }

    // MARK: - Username Validation

    /// Vérifie si un username est disponible
    func isUsernameAvailable(_ username: String) async throws -> Bool {
        let documents = try await tablesDB.listRows(
            databaseId: AppwriteConfig.databaseId,
            tableId: AppwriteConfig.usersCollectionId,
            queries: [
                Query.equal("username", value: username.lowercased()),
                Query.limit(1)
            ]
        )

        return documents.rows.isEmpty
    }

    /// Vérifie si un username est valide (format)
    func isValidUsername(_ username: String) -> Bool {
        let regex = "^[a-zA-Z0-9_]{3,20}$"
        return username.range(of: regex, options: .regularExpression) != nil
    }

    // MARK: - Stats Update

    /// Ajoute de l'XP à l'utilisateur (pour les badges gagnés, etc.)
    func addXP(_ xp: Int) async {
        do {
            try await updateStats(addXP: xp)
        } catch {
            logWarning("Failed to add XP: \(error.localizedDescription)", category: .auth)
        }
    }

    /// Met à jour les statistiques de l'utilisateur (appelé après un vol)
    func updateStats(addFlights: Int = 0, addSeconds: Int = 0, addXP: Int = 0) async throws {
        guard let profile = currentUserProfile else {
            throw UserProfileError.notAuthenticated
        }

        let newTotalFlights = profile.totalFlights + addFlights
        let newTotalSeconds = profile.totalFlightSeconds + addSeconds
        let newXP = profile.xpTotal + addXP

        // Calculer le nouveau niveau basé sur l'XP
        let newLevel = calculateLevel(xp: newXP)

        do {
            let document = try await tablesDB.updateRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                rowId: profile.id,
                data: [
                    "totalFlights": newTotalFlights,
                    "totalFlightSeconds": newTotalSeconds,
                    "xpTotal": newXP,
                    "level": newLevel,
                    "lastActiveAt": Date().ISO8601Format()
                ]
            )

            let updatedProfile = try parseProfile(from: document.data)
            currentUserProfile = updatedProfile
            profileCache[updatedProfile.id] = updatedProfile

            logInfo("Stats updated: flights=\(newTotalFlights), xp=\(newXP), level=\(newLevel)", category: .auth)
        } catch {
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }

    /// Recalcule et met à jour toutes les statistiques utilisateur depuis les données locales
    /// À appeler après sync ou recalcul des badges
    func recalculateAndUpdateAllStats(
        totalFlights: Int,
        totalFlightSeconds: Int,
        longestStreak: Int,
        currentStreak: Int
    ) async throws {
        guard let profile = currentUserProfile else {
            throw UserProfileError.notAuthenticated
        }

        do {
            let document = try await tablesDB.updateRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                rowId: profile.id,
                data: [
                    "totalFlights": totalFlights,
                    "totalFlightSeconds": totalFlightSeconds,
                    "longestStreak": longestStreak,
                    "currentStreak": currentStreak,
                    "lastActiveAt": Date().ISO8601Format()
                ]
            )

            let updatedProfile = try parseProfile(from: document.data)
            currentUserProfile = updatedProfile
            profileCache[updatedProfile.id] = updatedProfile

            logInfo("All stats recalculated: flights=\(totalFlights), seconds=\(totalFlightSeconds), streak=\(currentStreak)/\(longestStreak)", category: .auth)
        } catch {
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Logout Cleanup

    /// Nettoie les données locales lors de la déconnexion
    func clearLocalData() {
        currentUserProfile = nil
        profileCache.removeAll()
    }

    // MARK: - Public Profiles

    /// Récupère le profil public d'un pilote par son ID
    /// Utilisé pour afficher le profil d'autres utilisateurs
    func getPublicProfile(userId: String) async throws -> CloudUserProfile {
        // Vérifier le cache d'abord
        if let cachedProfile = profileCache[userId] {
            return cachedProfile
        }

        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.equal("$id", value: userId),
                    Query.limit(1)
                ]
            )

            guard let document = response.rows.first else {
                throw UserProfileError.profileNotFound
            }

            let profile = try parseProfile(from: document.data)
            profileCache[userId] = profile

            return profile
        } catch let error as UserProfileError {
            throw error
        } catch _ as AppwriteError {
            // Si le profil n'existe pas, essayer avec authUserId
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.equal("authUserId", value: userId),
                    Query.limit(1)
                ]
            )

            guard let document = response.rows.first else {
                throw UserProfileError.profileNotFound
            }

            let profile = try parseProfile(from: document.data)
            profileCache[userId] = profile

            return profile
        }
    }

    /// Vérifie si l'utilisateur actuel suit un autre pilote
    func isFollowing(userId: String) async throws -> Bool {
        guard let currentUserId = AuthService.shared.currentUserId else {
            return false
        }

        do {
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.followsCollectionId,
                queries: [
                    Query.equal("followerId", value: currentUserId),
                    Query.equal("followedId", value: userId),
                    Query.limit(1)
                ]
            )
            return !response.rows.isEmpty
        } catch {
            return false
        }
    }

    /// Suit ou cesse de suivre un pilote
    func toggleFollow(userId: String) async throws -> Bool {
        guard let currentUserId = AuthService.shared.currentUserId else {
            throw UserProfileError.notAuthenticated
        }

        // Vérifier si on suit déjà
        let isCurrentlyFollowing = try await isFollowing(userId: userId)

        if isCurrentlyFollowing {
            // Trouver et supprimer le document de follow
            let response = try await tablesDB.listRows(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.followsCollectionId,
                queries: [
                    Query.equal("followerId", value: currentUserId),
                    Query.equal("followedId", value: userId),
                    Query.limit(1)
                ]
            )

            if let doc = response.rows.first {
                _ = try await tablesDB.deleteRow(
                    databaseId: AppwriteConfig.databaseId,
                    tableId: AppwriteConfig.followsCollectionId,
                    rowId: doc.id
                )
            }
            logInfo("Unfollowed user \(userId)", category: .auth)
            return false
        } else {
            // Créer un nouveau follow
            _ = try await tablesDB.createRow(
                databaseId: AppwriteConfig.databaseId,
                tableId: AppwriteConfig.followsCollectionId,
                rowId: ID.unique(),
                data: [
                    "followerId": currentUserId,
                    "followedId": userId,
                    "createdAt": Date().ISO8601Format()
                ]
            )
            logInfo("Followed user \(userId)", category: .auth)
            return true
        }
    }

    // MARK: - Private Helpers

    private func parseProfile(from data: [String: Any]) throws -> CloudUserProfile {
        // Convertir les valeurs AnyCodable en types natifs
        var nativeData: [String: Any] = [:]
        for (key, value) in data {
            if let anyCodable = value as? AnyCodable {
                nativeData[key] = anyCodable.value
            } else {
                nativeData[key] = value
            }
        }

        // Utiliser le constructeur direct qui gère les valeurs manquantes
        return try CloudUserProfile(from: nativeData)
    }

    /// Calcule le niveau basé sur l'XP
    private func calculateLevel(xp: Int) -> Int {
        // Seuils XP pour chaque niveau (inspiré du plan)
        let thresholds = [
            0, 100, 200, 300, 400, 500,      // Niveaux 1-5 (Débutant)
            600, 800, 1000, 1200, 1400,       // Niveaux 6-10
            1600, 1800, 2000, 2200, 2500,     // Niveaux 11-15 (Bronze)
            2800, 3100, 3500, 3900, 4300,     // Niveaux 16-20
            4700, 5100, 5600, 6100, 6700,     // Niveaux 21-25
            7300, 8000, 8700, 9500, 10500,    // Niveaux 26-30 (Argent)
            11500, 12500, 14000, 15500, 17000, // Niveaux 31-35
            18500, 20000, 22000, 24000, 26000, // Niveaux 36-40
            28000, 30000, 33000, 36000, 39000, // Niveaux 41-45
            42000, 46000, 50000, 55000, 60000, // Niveaux 46-50 (Or)
            65000, 70000, 76000, 82000, 88000, // Niveaux 51-55
            95000, 102000, 110000, 118000, 127000, // Niveaux 56-60
            // ... continue jusqu'à 100+
        ]

        var level = 1
        for (index, threshold) in thresholds.enumerated() {
            if xp >= threshold {
                level = index + 1
            } else {
                break
            }
        }

        return level
    }
}

// MARK: - Trust Level Extension

extension UserService {
    /// Récupère le trust info de l'utilisateur actuel
    func getTrustInfo() async throws -> TrustInfo {
        try await TrustService.shared.getCurrentUserTrustInfo()
    }

    /// Vérifie si l'utilisateur peut proposer un nom de spot
    func canProposeSpotName() async -> Bool {
        await TrustService.shared.canProposeName()
    }

    /// Vérifie si l'utilisateur peut dessiner une zone
    func canDrawSpotZone() async -> Bool {
        await TrustService.shared.canDrawZone()
    }
}
