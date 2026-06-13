//
//  VoiceLinkService.swift
//  ParaFlightLog
//
//  Pont entre SoarX et l'app compagnon « SoarX Voice » (radio vocale pilotes).
//  Dérive un nom de canal stable depuis le spot courant puis ouvre l'app Voice
//  via le scheme `soarxvoice://join?channel=…`. Si l'app n'est pas installée,
//  redirige vers l'App Store. Target: iOS only
//

import Foundation
import UIKit

// MARK: - Service de lien vers SoarX Voice

enum VoiceLinkService {

    // MARK: Constantes

    /// Scheme de l'app compagnon (doit figurer dans LSApplicationQueriesSchemes).
    private static let voiceScheme = "soarxvoice"

    /// Canal par défaut quand aucun spot n'est connu.
    private static let defaultChannel = "SOARX"

    /// Page App Store de SoarX Voice.
    /// TODO: remplacer par l'URL réelle avec l'ID de l'app une fois publiée,
    /// p.ex. https://apps.apple.com/app/soarx-voice/id1234567890
    private static let appStoreURL = URL(string: "https://apps.apple.com/app/soarx-voice/")!

    // MARK: Dérivation du nom de canal

    /// Dérive un nom de canal court et stable depuis le nom d'un spot.
    /// Majuscules, sans accents ni espaces (remplacés par des tirets).
    /// Exemple : « Saint-Hilaire » → « SAINT-HILAIRE ». Renvoie « SOARX » si nil.
    static func channelName(forSpot spot: String?) -> String {
        guard let spot, !spot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultChannel
        }

        // 1. Retrait des accents/diacritiques (folding Unicode).
        let folded = spot.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))

        // 2. Majuscules.
        let upper = folded.uppercased()

        // 3. On ne garde que A-Z, 0-9 et le tiret ; tout le reste devient un tiret.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let scalars = upper.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var slug = String(scalars)

        // 4. Compactage des tirets multiples puis nettoyage des bords.
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return slug.isEmpty ? defaultChannel : slug
    }

    // MARK: Disponibilité de l'app

    /// Vrai si SoarX Voice est installée (nécessite `soarxvoice` dans
    /// LSApplicationQueriesSchemes, sinon canOpenURL renvoie toujours false).
    static var isVoiceAppInstalled: Bool {
        guard let url = URL(string: "\(voiceScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    // MARK: Ouverture de la radio

    /// Ouvre la radio SoarX Voice sur le canal du spot courant.
    /// Si l'app est installée → `soarxvoice://join?channel=<canal>`.
    /// Sinon → page App Store de SoarX Voice.
    static func openRadio(forSpot spot: String?) {
        let channel = channelName(forSpot: spot)

        if isVoiceAppInstalled {
            var components = URLComponents()
            components.scheme = voiceScheme
            components.host = "join"
            components.queryItems = [URLQueryItem(name: "channel", value: channel)]

            if let url = components.url {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }

        // App absente (ou URL invalide) → on propose le téléchargement.
        UIApplication.shared.open(appStoreURL, options: [:], completionHandler: nil)
    }
}
