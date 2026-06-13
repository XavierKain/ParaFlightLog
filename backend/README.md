# SoarX — Backend communautaire (Supabase)

> **État : SCAFFOLD. Rien n'est provisionné.** Aucun projet, aucune facturation,
> aucun secret réel n'est créé par ce dossier. C'est une **conception + des
> migrations prêtes à jouer + une couche client iOS désactivée par défaut**.
> L'app reste strictement **local-first + CloudKit privé** tant que
> `CloudConfig.isEnabled == false`.

---

## 1. Pourquoi Supabase (décision de stack)

Le backend communautaire (feed social, vols publics, spots partagés, classements,
live) impose un vrai serveur multi-utilisateurs — c'est la seule décision
structurante du backlog. **On retient Supabase** : Postgres **managé** (on
« possède » ses données dans une vraie base SQL exportable, pas un format
propriétaire), **Auth GoTrue** avec Sign in with Apple natif, **Realtime** (pour
le live), **Storage** (traces GPS), et surtout **Row Level Security** — la
confidentialité par vol/profil est exprimée en SQL, au plus près de la donnée,
ce qui colle à la contrainte « vols privés par défaut ». Le free tier (1 projet,
500 Mo DB, 1 Go Storage, 50 000 MAU) couvre largement le démarrage, et la
maintenance est faible (pas d'auto-hébergement — ce que le propriétaire vient
justement de fuir en supprimant Appwrite). **Référence comparative :** Firebase
(Firestore) aurait été plus rapide pour le temps réel clé-en-main, mais c'est un
NoSQL propriétaire (lock-in, requêtes/agrégations limitées, règles de sécurité
moins exprimables que la RLS SQL et data hors d'un Postgres exportable) — d'où
Supabase.

**Auth = Sign in with Apple uniquement** : pas de mot de passe, pas de SMS, une
identité par compte Apple. Cohérent avec une app iOS/watchOS, respectueux de la
vie privée, zéro gestion de credentials.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  App iOS SoarX (local-first)                                       │
│  SwiftData (source de vérité)  ──sync privée──>  CloudKit privé    │
│                                                                    │
│  SoarXCloudService (FLAG-GATED, off par défaut)                   │
│    └── URLSession REST (anon key + Bearer JWT)                     │
└───────────────┬──────────────────────────────────────────────────┘
                │ HTTPS (REST/PostgREST, GoTrue, Storage, Realtime WS)
                ▼
┌──────────────────────────────────────────────────────────────────┐
│  SUPABASE (managé)                                                 │
│                                                                    │
│  GoTrue Auth ──(Sign in with Apple : id_token)──> session JWT      │
│                                                                    │
│  PostgREST  ──>  PostgreSQL  ─── RLS sur CHAQUE table ───┐         │
│                    │                                     │         │
│     profiles  flights  spots  spot_reviews              │         │
│     follows   likes    comments   live_positions        │         │
│     vues matérialisées : leaderboard_spot_hours,        │         │
│                          leaderboard_max_altitude       │         │
│     RPC : nearby_spots(), refresh_leaderboards(),       │         │
│           purge_stale_live_positions(), delete_my_account()        │
│                                                          │         │
│  Realtime (WebSocket)  ──>  live_positions (UPDATE diffusés)       │
│  Storage  ──>  bucket "gps-tracks" (traces IGC/JSON privées)       │
│                bucket "avatars" (photos de profil publiques)       │
│                                                                    │
│  Edge Function "cleanup-live" (planifiée)                          │
│     └── purge live périmées + refresh leaderboards                 │
└──────────────────────────────────────────────────────────────────┘
```

### Schéma relationnel (résumé)

```
auth.users (Supabase)
   └─1:1─ profiles (id = auth.uid)
            ├─1:N─ flights ──┬─1:N─ likes      (PK user_id+flight_id)
            │                └─1:N─ comments
            ├─1:N─ spots (created_by, SET NULL si compte supprimé)
            │        └─1:N─ spot_reviews
            ├─N:N─ follows (follower_id, following_id) — PK composite
            └─1:1─ live_positions (user_id PK, TTL ~2 min)

vues matérialisées (vols publics uniquement) :
   leaderboard_spot_hours   (heures totales / pilote)
   leaderboard_max_altitude (altitude max / pilote)
```

Détails colonnes/contraintes : `migrations/0001_init.sql`.
Triggers, RPC, RGPD : `migrations/0002_functions.sql`.

### Modèle de confidentialité (RLS)

| Ressource        | Lecture                                              | Écriture                       |
|------------------|------------------------------------------------------|--------------------------------|
| `profiles`       | Publique                                             | Propriétaire (`id = auth.uid`) |
| `flights`        | `public` = tous · `followers` = abonnés · `private` = soi | Propriétaire                   |
| `spots`          | Publique                                             | Authentifié (édition = créateur) |
| `spot_reviews`   | Publique                                             | Propriétaire (1 avis / spot)   |
| `follows`        | Relations qui me concernent                          | `follower_id = soi`            |
| `likes`          | Si le vol est visible                                | `user_id = soi`                |
| `comments`       | Si le vol est visible                                | `user_id = soi`                |
| `live_positions` | Selon `visibility` + fraîcheur (< 2 min)             | `user_id = soi`                |
| leaderboards     | Publique (n'agrègent que des vols publics)           | —                              |

RLS est **activée sur chaque table** ; le défaut est *deny*. La fonction
`is_follower()` (SECURITY DEFINER) implémente la visibilité `followers`.

---

## 3. Mise en ligne — étapes manuelles (à faire par le propriétaire)

> Aucune de ces étapes n'est automatisable sans compte/facturation. Elles sont
> volontairement laissées **hors du scaffold**.

1. **Créer le projet Supabase**
   - app.supabase.com → New project. Choisir une région proche (ex. `eu-west`).
   - Noter le mot de passe DB (gardé hors du repo).

2. **Récupérer URL + anon key**
   - Project Settings → API → copier `Project URL` et `anon public` key.
   - Les reporter dans `ParaFlightLog/CloudConfig.swift`
     (`supabaseURL`, `anonKey`). ⚠️ La `service_role` key NE doit JAMAIS
     entrer dans l'app (elle bypasse la RLS) : elle reste côté serveur/edge.

3. **Jouer les migrations**
   - Option A (SQL Editor) : coller `migrations/0001_init.sql` puis
     `migrations/0002_functions.sql`, dans cet ordre, et exécuter.
   - Option B (CLI) :
     ```bash
     supabase link --project-ref <ref>
     supabase db push        # si les fichiers sont dans supabase/migrations
     # ou : psql "$DATABASE_URL" -f migrations/0001_init.sql
     #      psql "$DATABASE_URL" -f migrations/0002_functions.sql
     ```

4. **Configurer le provider « Sign in with Apple »**
   - Apple Developer → Identifiers → Services ID dédié (ex.
     `com.xavierkain.SoarX.signin`), activer Sign in with Apple, créer une
     **clé Sign in with Apple** (.p8) + noter Key ID et Team ID.
   - Supabase → Authentication → Providers → **Apple** : renseigner Services ID
     (client_id), Team ID, Key ID, clé `.p8`. Activer.
   - Ajouter l'URL de callback Supabase dans la config Apple si demandé.
   - **Côté app (Xcode) :** activer la capability *Sign in with Apple*
     (Signing & Capabilities). **Volontairement non ajoutée à l'entitlement**
     par ce scaffold (ajouter `com.apple.developer.applesignin` casserait la
     signature actuelle tant que la capability n'est pas provisionnée). Voir §5.

5. **Créer les buckets Storage**
   - Storage → New bucket :
     - `gps-tracks` — **privé** (traces IGC/JSON). Policy : un user lit/écrit
       sous le préfixe `gps-tracks/<auth.uid>/...`. Les traces des vols publics
       seront exposées via URL signée à durée limitée, jamais le bucket en clair.
     - `avatars` — **public** (lecture), écriture sous `<auth.uid>/...`.
   - (Policies Storage à définir dans le dashboard — non incluses dans les
     migrations SQL car gérées via `storage.objects`.)

6. **Planifier le nettoyage (optionnel mais recommandé dès le live)**
   - Déployer l'edge function :
     ```bash
     supabase functions deploy cleanup-live --no-verify-jwt
     supabase secrets set CLEANUP_SECRET=$(openssl rand -hex 24)
     ```
   - Planifier toutes les 1–2 min : Supabase Scheduled Functions, **ou** pg_cron
     appelant l'URL avec l'en-tête `x-cleanup-secret`, **ou** un cron externe.
   - (Alternative tout-SQL si pg_cron dispo : planifier directement
     `select public.purge_stale_live_positions();` et
     `select public.refresh_leaderboards();`.)

7. **Activer la couche client**
   - Dans `ParaFlightLog/CloudConfig.swift` : passer `isEnabled = true`
     (une fois URL + anon key renseignées).
   - Câbler progressivement l'UI (voir le plan de migration dans
     `docs/superpowers/specs/2026-06-13-backend-design.md`).

---

## 4. Coûts (estimation)

**Free tier Supabase** (au moment de la rédaction — à revérifier) :
- 500 Mo de base Postgres, 1 Go de Storage, 5 Go d'egress/mois.
- 50 000 utilisateurs actifs mensuels (MAU) côté Auth.
- 2 Go de bande passante Realtime, 500 000 messages Realtime/mois.
- 500 000 invocations Edge Functions/mois.
- ⚠️ Pause d'inactivité : un projet free **se met en pause après ~1 semaine
  sans requête** (réveil manuel). Acceptable en phase pilote, à surveiller.

**Quand on commence à payer (~25 $/mois, plan Pro) :**
- Dépassement 500 Mo DB ou 1 Go Storage (traces GPS = poste de croissance n°1 :
  prévoir compression + URL signées + purge des vieilles traces).
- Plus de 50 000 MAU, ou besoin de retirer la pause d'inactivité, des sauvegardes
  quotidiennes, ou d'un egress supérieur.
- Le live (Realtime) et les leaderboards peuvent pousser la bande passante :
  poste à surveiller quand l'usage social décolle.

**Leviers de maîtrise des coûts (intégrés au design) :**
- Traces GPS dans Storage (pas en DB), purgeables ; live avec TTL 2 min + purge.
- Leaderboards en vues **matérialisées** rafraîchies périodiquement (pas de
  recalcul à chaque lecture).
- Feed paginé (limit/offset), images d'avatar dans un bucket dédié.

---

## 5. Confidentialité / RGPD

- **Privé par défaut** : `flights.visibility` vaut `private` à la création.
  Aucune donnée de vol n'est diffusée sans choix explicite du pilote
  (`followers` ou `public`).
- **Minimisation** : Sign in with Apple ne fournit que ce que l'utilisateur
  accepte ; on peut activer le *Private Email Relay* d'Apple. Le profil public
  ne contient que ce que le pilote saisit (username, bio, pays facultatif).
- **Droit à l'effacement** : RPC `delete_my_account()` — un utilisateur supprime
  **son** compte (`auth.uid() = self`), ce qui **cascade** sur profil, vols,
  follows, likes, commentaires, avis, position live. Les **spots** qu'il a créés
  sont **conservés** pour l'annuaire communautaire, avec `created_by → NULL`
  (anonymisation, pas de donnée personnelle résiduelle).
- **Portabilité** : données en Postgres standard, exportables (l'app dispose déjà
  d'un export local complet ZIP/IGC côté client).
- **Localisation** : choisir une région UE à la création du projet (étape 1) pour
  rester aligné RGPD.
- **Sécurité d'accès** : toute lecture/écriture passe par la RLS ; la `anon key`
  publique ne donne aucun accès au-delà des policies ; la `service_role` reste
  serveur.

---

## 6. Contenu du dossier

```
backend/
├── README.md                      ← ce fichier
├── migrations/
│   ├── 0001_init.sql              ← schéma + enums + RLS + grants + leaderboards
│   └── 0002_functions.sql         ← triggers compteurs, RPC nearby_spots,
│                                     refresh leaderboards, purge live, RGPD
└── functions/
    └── cleanup-live/
        └── index.ts               ← edge function Deno (purge + refresh)
```

Couche client iOS associée (dans l'app, auto-synchronisée par Xcode) :
- `ParaFlightLog/CloudConfig.swift` — drapeaux/config (vides, off par défaut).
- `ParaFlightLog/Services/SoarXCloudService.swift` — client REST hand-rollé.
