//
//  CloudConfig.swift
//  ParaFlightLog
//
//  Configuration du backend communautaire SoarX (Supabase).
//  Target: iOS only
//
//  IMPORTANT — l'app est LOCAL-FIRST + CloudKit privé. Le backend communautaire
//  est une couche additive, DÉSACTIVÉE PAR DÉFAUT. Tant que `isEnabled == false`
//  (ou que `supabaseURL` est vide), `SoarXCloudService` est un no-op total :
//  l'app locale n'est jamais affectée.
//
//  POUR ACTIVER PLUS TARD (après avoir créé le projet Supabase — voir
//  backend/README.md) :
//    1. Renseigner `supabaseURL` et `anonKey` ci-dessous (la `anon key` est
//       publique par conception : la sécurité repose sur la RLS Postgres).
//    2. Passer `isEnabled` à `true`.
//    3. Activer la capability « Sign in with Apple » dans Xcode (Signing &
//       Capabilities) — non incluse dans l'entitlement pour ne pas casser la
//       signature actuelle.
//
//  NOTE SECRETS : la `anon key` n'est PAS un secret serveur. Ne JAMAIS mettre
//  ici la `service_role` key (elle bypasse la RLS). Elle reste côté backend.
//

import Foundation

/// Drapeaux et constantes de configuration du backend communautaire.
/// Aucune valeur réelle n'est committée : on garde le build propre et l'app
/// strictement local-first par défaut.
enum CloudConfig {

    /// Interrupteur maître. `false` => toute la couche cloud est inerte.
    static let isEnabled = false

    /// URL du projet Supabase, ex. "https://xxxxxxxx.supabase.co".
    /// Vide tant que le projet n'est pas créé (voir backend/README.md).
    static let supabaseURL = ""

    /// Clé publique `anon` (PostgREST/GoTrue). Publique par conception ;
    /// la vraie barrière de sécurité est la Row Level Security côté Postgres.
    static let anonKey = ""

    /// Indique si la couche cloud est réellement utilisable (flag + URL valide).
    static var isOperational: Bool {
        isEnabled && !supabaseURL.isEmpty && !anonKey.isEmpty
    }
}
