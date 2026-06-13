# SoarX — Décision d'architecture backend & plan de migration

**Date** : 2026-06-13 · **Demandeur** : Xavier · **Statut** : conçu + scaffoldé, **rien provisionné**.
Suite de : `2026-06-12-soarx-etude-fonctionnalites.md` (phase D « communautaire »).
Le propriétaire a choisi explicitement le **backend complet** (feed, vols publics,
spots partagés, classements, live), en connaissant coûts/maintenance.

---

## 1. Décision

**Stack retenue : Supabase** (Postgres managé + Auth GoTrue + Realtime + Storage
+ RLS). **Auth : Sign in with Apple uniquement** (pas de mot de passe / SMS).

**Justification (1 paragraphe).** Le communautaire impose un serveur
multi-utilisateurs : c'est la seule décision structurante du backlog. Supabase
donne un **Postgres qu'on possède** (data exportable, requêtes/agrégations SQL,
pas de lock-in NoSQL), une **RLS** qui exprime la confidentialité par vol/profil
au plus près de la donnée (cœur de la contrainte « privé par défaut »), un
**Realtime** prêt pour le live, du **Storage** pour les traces, et un free tier
généreux **sans auto-hébergement** — exactement ce que le propriétaire cherchait
en supprimant Appwrite. Comparé à Firebase (Firestore), plus rapide en temps réel
clé-en-main mais NoSQL propriétaire à règles de sécurité moins exprimables et data
hors d'un SQL exportable : Supabase l'emporte sur la propriété de la donnée et la
finesse de la RLS.

**Invariant non négociable** : l'app reste **local-first + CloudKit privé**. Le
cloud communautaire est **additif et flag-gated** (`CloudConfig.isEnabled`,
`false` par défaut). Aucune donnée utilisateur n'est jamais supprimée ni
dégradée ; rien ne change tant que le flag est off.

---

## 2. Ce qui a été produit (scaffold, sans déploiement)

- `backend/README.md` — architecture, schéma, **étapes de mise en ligne**
  numérotées, coûts (free tier + seuils de bascule payante), RGPD.
- `backend/migrations/0001_init.sql` — schéma complet : `profiles`, `flights`,
  `spots`, `spot_reviews`, `follows`, `likes`, `comments`, `live_positions` ;
  enum `flight_visibility('private','followers','public')` (défaut `private`) ;
  vues matérialisées `leaderboard_spot_hours` + `leaderboard_max_altitude` ;
  **RLS activée sur chaque table** avec policies graduées + grants anon/auth.
- `backend/migrations/0002_functions.sql` — triggers de comptage
  (`like_count`/`comment_count`), RPC `nearby_spots(lat,lon,radius_km)`
  (Haversine, sans PostGIS), `refresh_leaderboards()`,
  `purge_stale_live_positions()` (TTL 2 min), `delete_my_account()` (RGPD,
  cascade).
- `backend/functions/cleanup-live/index.ts` — edge function Deno (purge live +
  refresh leaderboards), protégée par secret.
- `ParaFlightLog/CloudConfig.swift` — drapeaux/clé (vides, `isEnabled = false`).
- `ParaFlightLog/Services/SoarXCloudService.swift` — client REST hand-rollé
  (URLSession, **aucune dépendance SPM**), `@Observable @MainActor` singleton,
  Sign in with Apple (échange `id_token` → session GoTrue), Keychain, modèles
  Codable alignés sur le schéma, `CloudError`. **No-op `.notConfigured`** tant
  que le flag est off. **Vérifié** : `xcrun swiftc -typecheck` passe (0 erreur,
  0 warning).

**Non fait volontairement** (étapes manuelles, cf. README §3) : création du
projet Supabase, secrets, provider Apple, buckets Storage, **et l'entitlement
`com.apple.developer.applesignin`** (l'ajouter avant de provisionner la
capability casserait la signature) — à activer dans Xcode le moment venu.
**Aucun câblage UI** (pas d'onglet, pas de bouton).

---

## 3. Plan de migration progressive

Activation **par phases**, chacune derrière le même flag, livrable
indépendamment et réversible. Ordre choisi pour exposer d'abord la valeur la
moins risquée (lecture publique) avant l'écriture sociale puis le live.

### Phase 1 — Spots partagés en **lecture** (risque minimal)
- Activer `CloudConfig`, jouer les migrations, peupler quelques spots.
- App : carte/liste de spots via `nearbySpots(lat:lon:)` — **lecture seule, sans
  authentification** (rôle `anon`, RLS lecture publique). Aucune donnée perso.
- Objectif : valider la plomberie (URL, anon key, RLS) sans aucun enjeu privé.

### Phase 2 — **Publication de vols** (premier écrit authentifié)
- Activer Sign in with Apple (capability Xcode + provider Supabase).
- Onboarding profil (`upsertProfile`), puis publication d'un vol local vers le
  cloud (`publishFlight`) avec sélecteur de visibilité — **`private` par défaut**.
- Upload de la trace GPS vers le bucket `gps-tracks` (URL signée). Avis de spots
  (`spot_reviews`) possibles ici aussi.
- Le vol cloud est une **copie** publiée ; la source de vérité reste SwiftData.

### Phase 3 — **Feed & social**
- `fetchPublicFeed` (pagination), `follow` / `unfollow`, `like` / `unlike`,
  `comment` — compteurs maintenus par triggers.
- Visibilité `followers` exploitée (RLS `is_follower`). Profils publics
  consultables.

### Phase 4 — **Live & leaderboards**
- `updateLivePosition` (TTL 2 min) + abonnement Realtime aux positions des
  pilotes suivis ; `clearLivePosition` en fin de vol.
- Planifier `cleanup-live` (purge + refresh leaderboards). Exposer
  `leaderboard_spot_hours` / `leaderboard_max_altitude`.
- Arbitrage **session audio** à anticiper (vario + voice + live simultanés) —
  cf. note SoarX Voice de l'étude du 12/06.

**Gouvernance** : ne pas activer une phase tant que la précédente n'est pas
stable. Chaque phase = un flag UI distinct envisageable plus tard (ex.
`CloudConfig.feature.live`) pour un rollout progressif.

---

## 4. Risques & points de vigilance

- **Coûts traces GPS** (poste n°1) : compression + URL signées + purge ;
  surveiller le quota Storage (cf. README §4).
- **Pause d'inactivité free tier** (~1 semaine) : OK en pilote, bascule Pro
  (~25 $/mois) quand l'usage devient régulier.
- **RGPD** : région UE à la création, `delete_my_account` câblé en phase 2+,
  spots anonymisés (`created_by → NULL`) à la suppression de compte.
- **Sécurité** : ne jamais embarquer la `service_role` key dans l'app ; toute la
  protection repose sur la RLS — relire les policies à chaque ajout de table.

---

## Sources / artefacts

- Migrations & client : `backend/`, `ParaFlightLog/CloudConfig.swift`,
  `ParaFlightLog/Services/SoarXCloudService.swift`.
- Vérification Swift : `xcrun swiftc -typecheck` (iOS SDK) — 0 erreur.
- Doc amont : `docs/superpowers/specs/2026-06-12-soarx-etude-fonctionnalites.md`.
