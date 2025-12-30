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

struct CloudUserProfile: Codable, Identifiable, Equatable {
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

    enum CodingKeys: String, CodingKey {
        case id = "$id"
        case authUserId, email, displayName, username, bio
        case profilePhotoFileId, homeLocationLat, homeLocationLon, homeLocationName
        case pilotWeight, isPremium, premiumUntil, notificationsEnabled
        case totalFlights, totalFlightSeconds
        case xpTotal, level, currentStreak, longestStreak
        case createdAt, lastActiveAt
    }
}

// MARK: - UserService

@Observable
final class UserService {
    static let shared = UserService()

    // MARK: - Properties

    private let databases: Databases
    private let storage: Storage

    private(set) var currentUserProfile: CloudUserProfile?
    private(set) var isLoading: Bool = false

    // Cache des profils consultés
    private var profileCache: [String: CloudUserProfile] = [:]

    // MARK: - Init

    private init() {
        self.databases = AppwriteService.shared.databases
        self.storage = AppwriteService.shared.storage
    }

    // MARK: - Profile Creation

    /// Crée un profil utilisateur après inscription
    @discardableResult
    func createProfile(authUserId: String, email: String, displayName: String, username: String) async throws -> CloudUserProfile {
        isLoading = true
        defer { isLoading = false }

        // Vérifier que le username est valide
        guard isValidUsername(username) else {
            throw UserProfileError.invalidUsername
        }

        // Vérifier que le username n'est pas déjà pris
        guard try await isUsernameAvailable(username) else {
            throw UserProfileError.usernameAlreadyTaken
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

        do {
            let document = try await databases.createDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                documentId: ID.unique(),
                data: profileData
            )

            let profile = try parseProfile(from: document.data)
            currentUserProfile = profile
            profileCache[profile.id] = profile

            logInfo("Profile created for user: \(email)", category: .auth)
            return profile
        } catch let error as AppwriteError {
            throw UserProfileError.unknown(error.message ?? "Unknown error")
        } catch {
            throw UserProfileError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Profile Retrieval

    /// Récupère le profil de l'utilisateur connecté
    func getCurrentProfile() async throws -> CloudUserProfile? {
        guard let authUserId = AuthService.shared.currentUserId else {
            return nil
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.equal("authUserId", value: authUserId),
                    Query.limit(1)
                ]
            )

            if let doc = documents.documents.first {
                let profile = try parseProfile(from: doc.data)
                currentUserProfile = profile
                profileCache[profile.id] = profile
                return profile
            }

            return nil
        } catch let error as AppwriteError {
            throw UserProfileError.unknown(error.message ?? "Unknown error")
        } catch {
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
            let document = try await databases.getDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                documentId: userId
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
            let documents = try await databases.listDocuments(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                queries: [
                    Query.equal("username", value: username.lowercased()),
                    Query.limit(1)
                ]
            )

            if let doc = documents.documents.first {
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
            let document = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                documentId: profile.id,
                data: updateData
            )

            let updatedProfile = try parseProfile(from: document.data)
            currentUserProfile = updatedProfile
            profileCache[updatedProfile.id] = updatedProfile

            logInfo("Profile updated", category: .auth)
        } catch let error as AppwriteError {
            throw UserProfileError.unknown(error.message ?? "Unknown error")
        } catch {
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
            try? await storage.deleteFile(
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
            let _ = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                documentId: profile.id,
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
        let documents = try await databases.listDocuments(
            databaseId: AppwriteConfig.databaseId,
            collectionId: AppwriteConfig.usersCollectionId,
            queries: [
                Query.equal("username", value: username.lowercased()),
                Query.limit(1)
            ]
        )

        return documents.documents.isEmpty
    }

    /// Vérifie si un username est valide (format)
    func isValidUsername(_ username: String) -> Bool {
        let regex = "^[a-zA-Z0-9_]{3,20}$"
        return username.range(of: regex, options: .regularExpression) != nil
    }

    // MARK: - Stats Update

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
            let document = try await databases.updateDocument(
                databaseId: AppwriteConfig.databaseId,
                collectionId: AppwriteConfig.usersCollectionId,
                documentId: profile.id,
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

    // MARK: - Logout Cleanup

    /// Nettoie les données locales lors de la déconnexion
    func clearLocalData() {
        currentUserProfile = nil
        profileCache.removeAll()
    }

    // MARK: - Private Helpers

    private func parseProfile(from data: [String: Any]) throws -> CloudUserProfile {
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudUserProfile.self, from: jsonData)
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
