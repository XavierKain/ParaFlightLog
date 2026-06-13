//
//  SoarXCloudService.swift
//  ParaFlightLog
//
//  Couche client du backend communautaire SoarX (Supabase : GoTrue Auth +
//  PostgREST + Storage + Realtime). Client REST hand-rollé sur URLSession —
//  AUCUNE dépendance SPM, pour garder le build propre.
//  Target: iOS only
//
//  ============================================================================
//  ÉTAT : DÉSACTIVÉ PAR DÉFAUT (cf. CloudConfig.isEnabled == false).
//  Tant que la config est absente, CHAQUE méthode retourne `.notConfigured`
//  sans toucher au réseau. L'app locale (SwiftData + CloudKit privé) n'est
//  jamais affectée. Rien n'est wiré dans l'UI.
//  ============================================================================
//
//  POUR ACTIVER (résumé — détails dans backend/README.md) :
//    1. Créer le projet Supabase, jouer les migrations (backend/migrations).
//    2. Renseigner CloudConfig.supabaseURL / anonKey, passer isEnabled = true.
//    3. Activer la capability « Sign in with Apple » dans Xcode.
//    4. Câbler l'UI (onboarding profil, feed, etc.) — non fait ici.
//
//  Auth : Sign in with Apple UNIQUEMENT. On échange l'`identityToken` Apple
//  contre une session Supabase via /auth/v1/token?grant_type=id_token.
//  Le token de session est stocké en Keychain (helper minimal ci-dessous).
//

import Foundation
import AuthenticationServices

// MARK: - Erreurs

/// Erreurs de la couche cloud. `notConfigured` est le cas nominal quand le
/// backend est désactivé : l'appelant doit la traiter comme « fonctionnalité
/// non disponible », pas comme un échec.
enum CloudError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case http(status: Int, body: String)
    case decoding(String)
    case appleTokenMissing
    case keychain(OSStatus)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Le backend communautaire n'est pas configuré."
        case .notAuthenticated:
            return "Connexion requise (Sign in with Apple)."
        case .invalidURL:
            return "URL du backend invalide."
        case .invalidResponse:
            return "Réponse serveur invalide."
        case let .http(status, body):
            return "Erreur HTTP \(status) : \(body)"
        case let .decoding(detail):
            return "Erreur de décodage : \(detail)"
        case .appleTokenMissing:
            return "Jeton Apple absent."
        case let .keychain(status):
            return "Erreur Keychain (\(status))."
        case let .underlying(error):
            return error.localizedDescription
        }
    }
}

// MARK: - Modèles (Codable, alignés sur le schéma Postgres)

/// Visibilité d'un vol — miroir de l'enum `flight_visibility` côté Postgres.
enum CloudVisibility: String, Codable, Sendable, CaseIterable {
    case `private`
    case followers
    case `public`
}

/// Profil public d'un pilote (table `profiles`).
struct CloudProfile: Codable, Identifiable, Sendable {
    let id: String                 // uuid (= auth.uid)
    var username: String
    var displayName: String?
    var bio: String?
    var avatarUrl: String?
    var country: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, bio, country
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
    }
}

/// Vol publié vers le cloud (table `flights`).
struct CloudFlight: Codable, Identifiable, Sendable {
    var id: String?                // nil => généré côté serveur
    var userId: String?            // nil à l'insert => rempli via auth.uid
    var startedAt: String          // ISO-8601
    var durationSeconds: Int
    var spotName: String?
    var lat: Double?
    var lon: Double?
    var flightType: String?
    var wingName: String?
    var wingSize: String?
    var maxAltitude: Double?
    var totalDistance: Double?
    var gpsTrackUrl: String?
    var visibility: CloudVisibility
    var likeCount: Int?
    var commentCount: Int?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, lat, lon, visibility
        case userId = "user_id"
        case startedAt = "started_at"
        case durationSeconds = "duration_seconds"
        case spotName = "spot_name"
        case flightType = "flight_type"
        case wingName = "wing_name"
        case wingSize = "wing_size"
        case maxAltitude = "max_altitude"
        case totalDistance = "total_distance"
        case gpsTrackUrl = "gps_track_url"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case createdAt = "created_at"
    }
}

/// Spot communautaire (table `spots`) — résultat de `nearby_spots`.
struct CloudSpot: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var lat: Double
    var lon: Double
    var country: String?
    var windDirections: [String]?
    var altitudeTakeoff: Double?
    var altitudeLanding: Double?
    var description: String?
    var createdBy: String?
    var createdAt: String?
    var distanceKm: Double?        // présent uniquement via nearby_spots

    enum CodingKeys: String, CodingKey {
        case id, name, lat, lon, country, description
        case windDirections = "wind_directions"
        case altitudeTakeoff = "altitude_takeoff"
        case altitudeLanding = "altitude_landing"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case distanceKm = "distance_km"
    }
}

/// Commentaire (table `comments`).
struct CloudComment: Codable, Identifiable, Sendable {
    var id: String?
    var flightId: String
    var userId: String?
    var body: String
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, body
        case flightId = "flight_id"
        case userId = "user_id"
        case createdAt = "created_at"
    }
}

/// Position live (table `live_positions`).
struct CloudLivePosition: Codable, Sendable {
    var userId: String?
    var lat: Double
    var lon: Double
    var altitude: Double?
    var heading: Double?
    var visibility: CloudVisibility
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case lat, lon, altitude, heading, visibility
        case userId = "user_id"
        case updatedAt = "updated_at"
    }
}

// MARK: - Réponse GoTrue (auth)

/// Réponse de /auth/v1/token. On ne décode que ce dont on a besoin.
private struct GoTrueSession: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Keychain helper (minimal)

/// Stockage minimal du token de session en Keychain. Une seule entrée logique
/// (account "session") sous un service dédié. Volontairement simple.
enum CloudKeychain {
    private static let service = "com.xavierkain.SoarX.cloud"

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)  // remplace l'existant
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudError.keychain(status) }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - SoarXCloudService

/// Singleton de la couche cloud communautaire. `@Observable` pour exposer
/// `currentSession` / `isSignedIn` à l'UI le jour où on la câblera.
///
/// GARDE-FOU : si `!CloudConfig.isOperational`, toute méthode lève
/// `CloudError.notConfigured` AVANT tout accès réseau.
@Observable
@MainActor
final class SoarXCloudService {

    static let shared = SoarXCloudService()

    /// Token de session courant (chargé du Keychain au démarrage si présent).
    private(set) var accessToken: String?

    /// Indique si une session existe (token présent). Ne valide pas l'expiration.
    var isSignedIn: Bool { accessToken != nil }

    /// Clé Keychain pour le token de session.
    private static let sessionAccount = "session"

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        // Restaure une éventuelle session existante.
        self.accessToken = CloudKeychain.get(account: Self.sessionAccount)
    }

    // MARK: Garde-fou de configuration

    /// Vérifie que le backend est opérationnel, sinon lève `.notConfigured`.
    private func ensureOperational() throws {
        guard CloudConfig.isOperational else { throw CloudError.notConfigured }
    }

    private func base() throws -> URL {
        guard let url = URL(string: CloudConfig.supabaseURL) else {
            throw CloudError.invalidURL
        }
        return url
    }

    // MARK: - Couche HTTP

    /// Construit une requête PostgREST/GoTrue avec les en-têtes Supabase.
    /// - apikey : la `anon key` (toujours).
    /// - Authorization : Bearer = token de session si présent, sinon anon key
    ///   (PostgREST traite alors la requête en rôle `anon`).
    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        let baseURL = try base()
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw CloudError.invalidURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CloudError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        let bearer = accessToken ?? CloudConfig.anonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    /// Exécute une requête et renvoie les données brutes (gère les codes HTTP).
    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyString = String(data: data, encoding: .utf8) ?? ""
                throw CloudError.http(status: http.statusCode, body: bodyString)
            }
            return data
        } catch let error as CloudError {
            throw error
        } catch {
            throw CloudError.underlying(error)
        }
    }

    /// Requête PostgREST renvoyant un tableau décodé.
    private func getList<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem]
    ) async throws -> [T] {
        let request = try makeRequest(path: path, method: "GET", query: query)
        let data = try await send(request)
        do {
            return try decoder.decode([T].self, from: data)
        } catch {
            throw CloudError.decoding(String(describing: error))
        }
    }

    /// INSERT/UPSERT PostgREST renvoyant la (ou les) ligne(s) créée(s).
    private func postReturning<Body: Encodable, T: Decodable>(
        _ type: T.Type,
        path: String,
        body: Body,
        upsert: Bool = false,
        query: [URLQueryItem] = []
    ) async throws -> [T] {
        var headers = ["Prefer": upsert
            ? "return=representation,resolution=merge-duplicates"
            : "return=representation"]
        headers["Content-Profile"] = "public"
        let payload = try encoder.encode(body)
        let request = try makeRequest(
            path: path, method: "POST", query: query,
            body: payload, extraHeaders: headers
        )
        let data = try await send(request)
        do {
            return try decoder.decode([T].self, from: data)
        } catch {
            throw CloudError.decoding(String(describing: error))
        }
    }

    /// INSERT/UPSERT « fire-and-forget » : on n'attend pas la représentation
    /// renvoyée (utile pour les tables-jointures comme follows / likes dont la
    /// ligne est sans intérêt côté client).
    private func postNoReturn<Body: Encodable>(
        path: String,
        body: Body,
        upsert: Bool = false
    ) async throws {
        let prefer = upsert
            ? "return=minimal,resolution=merge-duplicates"
            : "return=minimal"
        let payload = try encoder.encode(body)
        let request = try makeRequest(
            path: path, method: "POST", body: payload,
            extraHeaders: ["Prefer": prefer]
        )
        _ = try await send(request)
    }

    // MARK: - Auth : Sign in with Apple

    /// Échange l'`identityToken` Apple (JWT) contre une session Supabase.
    /// Endpoint GoTrue : POST /auth/v1/token?grant_type=id_token
    /// Body : { provider: "apple", id_token: "<jwt>" }.
    ///
    /// Le provider Apple doit être configuré côté Supabase (voir README).
    /// Stocke le token en Keychain et met à jour `accessToken`.
    func signInWithApple(identityToken: String) async throws {
        try ensureOperational()
        guard !identityToken.isEmpty else { throw CloudError.appleTokenMissing }

        struct AppleGrant: Encodable {
            let provider = "apple"
            let id_token: String  // swiftlint:disable:this identifier_name
        }
        let payload = try encoder.encode(AppleGrant(id_token: identityToken))
        let request = try makeRequest(
            path: "auth/v1/token",
            method: "POST",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: payload
        )
        let data = try await send(request)
        let goTrue: GoTrueSession
        do {
            goTrue = try decoder.decode(GoTrueSession.self, from: data)
        } catch {
            throw CloudError.decoding(String(describing: error))
        }
        try CloudKeychain.set(goTrue.accessToken, account: Self.sessionAccount)
        if let refresh = goTrue.refreshToken {
            try? CloudKeychain.set(refresh, account: "refresh")
        }
        self.accessToken = goTrue.accessToken
    }

    /// Helper de plus haut niveau : extrait l'identityToken d'une
    /// `ASAuthorization` (résultat d'un `ASAuthorizationAppleIDProvider`) puis
    /// délègue à `signInWithApple(identityToken:)`.
    func signInWithApple(authorization: ASAuthorization) async throws {
        try ensureOperational()
        guard
            let credential = authorization.credential
                as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let token = String(data: tokenData, encoding: .utf8)
        else { throw CloudError.appleTokenMissing }
        try await signInWithApple(identityToken: token)
    }

    /// Déconnexion locale : purge le token. (La révocation côté serveur est
    /// optionnelle ; GoTrue n'expose pas de logout obligatoire pour l'anon key.)
    func signOut() {
        CloudKeychain.delete(account: Self.sessionAccount)
        CloudKeychain.delete(account: "refresh")
        accessToken = nil
    }

    // MARK: - Profil

    /// Profil du pilote courant. Les profils sont lisibles par tous (RLS), on
    /// filtre donc côté requête sur `id = eq.<sub>`, où `<sub>` est l'auth.uid
    /// extrait du JWT de session. (Une vue serveur `me_profile` serait un
    /// raffinement ultérieur, non nécessaire ici.)
    func currentProfile() async throws -> CloudProfile? {
        try ensureOperational()
        guard isSignedIn else { throw CloudError.notAuthenticated }
        guard let sub = Self.jwtSubject(accessToken) else {
            throw CloudError.notAuthenticated
        }
        let rows = try await getList(
            CloudProfile.self,
            path: "rest/v1/profiles",
            query: [
                URLQueryItem(name: "id", value: "eq.\(sub)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "limit", value: "1"),
            ]
        )
        return rows.first
    }

    /// Crée ou met à jour le profil du pilote courant (onboarding).
    @discardableResult
    func upsertProfile(_ profile: CloudProfile) async throws -> CloudProfile {
        try ensureOperational()
        guard isSignedIn else { throw CloudError.notAuthenticated }
        let rows = try await postReturning(
            CloudProfile.self,
            path: "rest/v1/profiles",
            body: profile,
            upsert: true
        )
        guard let created = rows.first else { throw CloudError.invalidResponse }
        return created
    }

    // MARK: - Vols

    /// Publie un vol vers le cloud (INSERT). `userId` est ignoré côté serveur
    /// au profit de auth.uid() via la policy, mais on peut le fournir.
    @discardableResult
    func publishFlight(_ flight: CloudFlight) async throws -> CloudFlight {
        try ensureOperational()
        guard isSignedIn else { throw CloudError.notAuthenticated }
        var toInsert = flight
        toInsert.userId = Self.jwtSubject(accessToken) ?? flight.userId
        let rows = try await postReturning(
            CloudFlight.self,
            path: "rest/v1/flights",
            body: toInsert
        )
        guard let created = rows.first else { throw CloudError.invalidResponse }
        return created
    }

    /// Feed public paginé (vols visibility = public), triés par date desc.
    /// `page` 0-based, 20 éléments par page.
    func fetchPublicFeed(page: Int = 0, pageSize: Int = 20) async throws -> [CloudFlight] {
        try ensureOperational()
        let offset = max(0, page) * pageSize
        return try await getList(
            CloudFlight.self,
            path: "rest/v1/flights",
            query: [
                URLQueryItem(name: "visibility", value: "eq.public"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                // Pagination par limit/offset (PostgREST). Range serait une
                // alternative via en-tête, non requise ici.
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
            ]
        )
    }

    // MARK: - Spots

    /// Spots proches via la RPC Postgres `nearby_spots(lat, lon, radius_km)`.
    func nearbySpots(
        lat: Double,
        lon: Double,
        radiusKm: Double = 50
    ) async throws -> [CloudSpot] {
        try ensureOperational()
        struct Args: Encodable {
            let p_lat: Double      // swiftlint:disable:this identifier_name
            let p_lon: Double      // swiftlint:disable:this identifier_name
            let p_radius_km: Double // swiftlint:disable:this identifier_name
        }
        let payload = try encoder.encode(
            Args(p_lat: lat, p_lon: lon, p_radius_km: radiusKm)
        )
        let request = try makeRequest(
            path: "rest/v1/rpc/nearby_spots",
            method: "POST",
            body: payload
        )
        let data = try await send(request)
        do {
            return try decoder.decode([CloudSpot].self, from: data)
        } catch {
            throw CloudError.decoding(String(describing: error))
        }
    }

    // MARK: - Social : follow / like / comment

    /// Suit un pilote (INSERT dans follows ; follower_id = soi via RLS).
    func follow(userId: String) async throws {
        try ensureOperational()
        guard let me = Self.jwtSubject(accessToken) else {
            throw CloudError.notAuthenticated
        }
        struct FollowRow: Encodable {
            let follower_id: String   // swiftlint:disable:this identifier_name
            let following_id: String  // swiftlint:disable:this identifier_name
        }
        try await postNoReturn(
            path: "rest/v1/follows",
            body: FollowRow(follower_id: me, following_id: userId)
        )
    }

    /// Arrête de suivre un pilote (DELETE).
    func unfollow(userId: String) async throws {
        try ensureOperational()
        guard let me = Self.jwtSubject(accessToken) else {
            throw CloudError.notAuthenticated
        }
        let request = try makeRequest(
            path: "rest/v1/follows",
            method: "DELETE",
            query: [
                URLQueryItem(name: "follower_id", value: "eq.\(me)"),
                URLQueryItem(name: "following_id", value: "eq.\(userId)"),
            ]
        )
        _ = try await send(request)
    }

    /// Like un vol (INSERT dans likes ; user_id = soi via RLS).
    func like(flightId: String) async throws {
        try ensureOperational()
        guard let me = Self.jwtSubject(accessToken) else {
            throw CloudError.notAuthenticated
        }
        struct LikeRow: Encodable {
            let user_id: String       // swiftlint:disable:this identifier_name
            let flight_id: String     // swiftlint:disable:this identifier_name
        }
        try await postNoReturn(
            path: "rest/v1/likes",
            body: LikeRow(user_id: me, flight_id: flightId)
        )
    }

    /// Retire un like (DELETE).
    func unlike(flightId: String) async throws {
        try ensureOperational()
        guard let me = Self.jwtSubject(accessToken) else {
            throw CloudError.notAuthenticated
        }
        let request = try makeRequest(
            path: "rest/v1/likes",
            method: "DELETE",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(me)"),
                URLQueryItem(name: "flight_id", value: "eq.\(flightId)"),
            ]
        )
        _ = try await send(request)
    }

    /// Commente un vol (INSERT dans comments).
    @discardableResult
    func comment(flightId: String, body: String) async throws -> CloudComment {
        try ensureOperational()
        guard let me = Self.jwtSubject(accessToken) else {
            throw CloudError.notAuthenticated
        }
        let newComment = CloudComment(
            id: nil, flightId: flightId, userId: me, body: body, createdAt: nil
        )
        let rows = try await postReturning(
            CloudComment.self,
            path: "rest/v1/comments",
            body: newComment
        )
        guard let created = rows.first else { throw CloudError.invalidResponse }
        return created
    }

    /// Liste paginée des commentaires d'un vol (les plus anciens d'abord).
    func fetchComments(flightId: String, page: Int = 0, pageSize: Int = 50) async throws -> [CloudComment] {
        try ensureOperational()
        let offset = max(0, page) * pageSize
        return try await getList(
            CloudComment.self,
            path: "rest/v1/comments",
            query: [
                URLQueryItem(name: "flight_id", value: "eq.\(flightId)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.asc"),
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
            ]
        )
    }

    // MARK: - Live

    /// Met à jour (upsert) sa position live. user_id = soi via RLS.
    func updateLivePosition(
        lat: Double,
        lon: Double,
        altitude: Double? = nil,
        heading: Double? = nil,
        visibility: CloudVisibility = .followers
    ) async throws {
        try ensureOperational()
        guard let me = Self.jwtSubject(accessToken) else {
            throw CloudError.notAuthenticated
        }
        var position = CloudLivePosition(
            userId: me, lat: lat, lon: lon, altitude: altitude,
            heading: heading, visibility: visibility, updatedAt: nil
        )
        position.userId = me
        try await postNoReturn(
            path: "rest/v1/live_positions",
            body: position,
            upsert: true   // merge-duplicates sur la PK user_id
        )
    }

    /// Supprime sa position live (fin de vol).
    func clearLivePosition() async throws {
        try ensureOperational()
        guard let me = Self.jwtSubject(accessToken) else {
            throw CloudError.notAuthenticated
        }
        let request = try makeRequest(
            path: "rest/v1/live_positions",
            method: "DELETE",
            query: [URLQueryItem(name: "user_id", value: "eq.\(me)")]
        )
        _ = try await send(request)
    }

    // MARK: - RGPD : suppression de compte

    /// Supprime définitivement le compte et toutes les données associées via
    /// la RPC `delete_my_account` (cascade Postgres). Déconnecte localement.
    func deleteAccount() async throws {
        try ensureOperational()
        guard isSignedIn else { throw CloudError.notAuthenticated }
        let request = try makeRequest(
            path: "rest/v1/rpc/delete_my_account",
            method: "POST",
            body: Data("{}".utf8)
        )
        _ = try await send(request)
        signOut()
    }

    // MARK: - Utilitaires JWT

    /// Décode le claim `sub` (= auth.uid) d'un JWT sans vérifier la signature.
    /// Suffisant pour fournir `user_id` côté client ; la sécurité reste serveur.
    nonisolated static func jwtSubject(_ token: String?) -> String? {
        guard let token else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Padding base64.
        while base64.count % 4 != 0 { base64.append("=") }
        guard
            let data = Data(base64Encoded: base64),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sub = json["sub"] as? String
        else { return nil }
        return sub
    }
}
