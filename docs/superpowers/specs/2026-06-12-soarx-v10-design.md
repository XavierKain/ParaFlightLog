# SoarX V10 — Design de refonte

**Date** : 2026-06-12
**Branche** : `V10`
**Statut** : validé par Xavier (réponses aux questions du 2026-06-12, puis carte blanche)

## 1. Objectif

Refonte profonde de ParaFlightLog (rebrandée SoarX) pour obtenir une app **simple, fiable et 100 % fonctionnelle**, installable **à côté** de l'app existante sans toucher à ses données.

Décisions actées avec Xavier :
- **Refonte profonde du code existant** (pas de réécriture from scratch).
- **Périmètre conservé** : carnet de vol + stats + GPS, app Apple Watch, widget, import/export.
- **Périmètre supprimé** : Appwrite et toutes les fonctions cloud/communautaires/sociales (feed Découvrir, amis, likes/commentaires, live flights, leaderboards, zones communautaires + votes, notifications cloud, auth).
- **Backend** : local-first avec **SwiftData + CloudKit** (sync iCloud privée automatique, zéro serveur).
- **Migration** : import des backups `.paraflightlog` existants.

## 2. Identité de l'app (séparation totale des données)

| Élément | Ancien | V10 |
|---|---|---|
| Nom affiché | ParaFlightLog / SOARX Beta | **SoarX** |
| Bundle ID iOS | com.xavierkain.ParaFlightLog.beta | **com.xavierkain.SoarX** |
| Bundle ID Watch | …ParaFlightLog.beta.watchkitapp | **com.xavierkain.SoarX.watchkitapp** |
| Bundle ID Widget | …watchkitapp.ParaFlightLogWidgetExtension | **com.xavierkain.SoarX.watchkitapp.widget** |
| URL scheme | paraflightlog | **soarx** |
| Conteneur iCloud | (aucun) | **iCloud.com.xavierkain.SoarX** |
| App Group | (aucun) | **group.com.xavierkain.SoarX** |
| OSLog subsystems / queues | com.xavierkain.ParaFlightLog.* / com.paraflightlog.* | com.xavierkain.SoarX.* / com.soarx.* |

Le sandbox iOS étant lié au bundle ID, les données de l'app actuelle sur l'iPhone de Xavier sont **intactes par construction**. Les deux apps coexistent.

## 3. Architecture cible

### 3.1 Navigation (5 onglets → 4 onglets)

```
SoarXApp → ContentView (TabView)
├── Vol        : TimerView (chrono + tracking GPS, départ de vol) — l'action principale au premier plan
├── Carnet     : LogbookView (Timeline | Stats | Cartes) — inchangé dans l'esprit
├── Carte      : carte de mes vols + spots locaux + heatmap
└── Réglages   : voiles, spots, contacts d'urgence, Watch, sauvegarde/import, profil pilote local, préférences
```

Supprimés : onglet **Découvrir** (cloud), onglet **Profil** (remplacé par une fiche pilote locale dans Réglages). Plus d'écran d'authentification : l'app démarre directement sur le contenu.

### 3.2 Persistance

- SwiftData avec `ModelContainer` configuré pour **CloudKit private database** (`iCloud.com.xavierkain.SoarX`).
- Mise en conformité CloudKit des modèles :
  - `Wing.name`, `Flight.startDate/endDate/durationSeconds` : valeurs par défaut (CloudKit exige optionnel ou défaut).
  - Pas de `@Attribute(.unique)` (déjà le cas).
  - Relation `Wing.flights` ⇄ `Flight.wing` avec inverse (déjà défini côté Wing).
- Champs cloud Appwrite retirés du modèle `Flight` (cloudId, needsSync, likeCount, etc.).
- **Fallback robuste** : si le conteneur CloudKit est indisponible (pas de compte iCloud, entitlement absent), l'app bascule sur un store local pur — jamais de crash au démarrage.
- Le store V10 vit dans le sandbox de la nouvelle app : aucune interaction avec l'ancien store.

### 3.3 Services conservés (locaux)

| Service | Évolution |
|---|---|
| DataController | Conservé ; CloudKit ; nettoyage des champs sync Appwrite |
| LocationService | Conservé tel quel (GPS iPhone) |
| WatchConnectivityManager | Conservé ; retrait des hooks live-flight cloud |
| WeatherService (Open-Meteo) | Conservé |
| ShareService | Réduit au partage local (image de vol) |
| EmergencyService | Adapté en 100 % local (contacts dans SwiftData/UserDefaults) |
| BadgeService | Adapté : définitions des badges embarquées en local, calcul depuis les vols locaux |
| StatsCache | Conservé |
| ZipBackup | Conservé + **ajout des traces GPS au backup** (gps/<flightId>.json) |
| ExcelImporter (CSV) | Conservé |
| LocalizationManager | Conservé |

### 3.4 Supprimés

Services : AppwriteService, AuthService, UserService, FlightSyncService, DiscoveryService, SpotService (partie cloud), SpotZoneService, ZoneVotingService, LiveFlightService, LeaderboardService, NotificationService (cloud), TrustService, WingLibraryService (catalogue cloud), DemoDataService, OfflineSyncService.
Vues : DiscoverViews, ProfileViews (auth + profil cloud), SpotViews (leaderboard/détail cloud), SearchViews, LeaderboardsView, LiveFlightsMapView, NotificationsView, ZoneProposalView, ZoneDrawingView, NOTAMViews (pas de vraie API NOTAM — données démo), FlightPhotosViews (upload cloud), parties publiques de ShareViews, OfflineViews.
Autres : dépendance SPM Appwrite (et ses ~20 packages transitifs), appwrite.config.json, APPWRITE_SETUP.md, web-admin/.

La gestion **locale** des spots (SpotsManagementView) est conservée ; le cache de zones côté Watch est alimenté par les spots locaux.

### 3.5 Watch et Widget

- Watch : déjà indépendante d'Appwrite. Conservée intégralement (GPS + workout HealthKit + Water Lock + crash recovery). Correctifs perf documentés : `LazyVStack` + `.equatable()` sur WingCard.
- Widget : ajout de l'**App Group** `group.com.xavierkain.SoarX` pour afficher l'état du vol en cours (timer) au lieu des données statiques actuelles.

## 4. Backup / migration des données

- Import `.paraflightlog` existant conservé tel quel (CSV wings + flights + images) → Xavier exporte depuis l'ancienne app, importe dans SoarX V10.
- Export V10 enrichi : `gps/<flightId>.json` ajouté au bundle (traces GPS, aujourd'hui perdues à l'export). L'import lit ce dossier s'il existe (rétro-compatible avec les anciens backups).
- Le format reste un bundle dossier `.paraflightlog` (compatibilité ascendante).

## 5. Gestion d'erreurs et qualité

- Démarrage sans réseau, sans compte iCloud, sans autorisation GPS : aucun crash, fonctionnalités dégradées proprement.
- Suppression de tout `try?` silencieux sur les chemins critiques de sauvegarde des vols.
- Pas de migration de schéma nécessaire : le store V10 démarre vierge (nouveau sandbox), rempli par import backup.

## 6. Vérification

- `xcodebuild build` sur les schemes iOS et Watch (simulateurs iPhone 17 Pro Max + Watch S11 paired).
- Vérification manuelle scriptée : démarrage simulateur, création voile/vol, import du backup de test présent dans `/Users/xavier/VSCode3/ParaFlightLog/Backup/`.
- Le widget et la Watch compilent dans le build du scheme iOS.

## 7. Hors périmètre V10 (recommandations pour plus tard)

- Import/export IGC (format FAI) — fortement recommandé en V10.1 pour interop (XContest, etc.).
- Live Activities iOS (vol en cours sur l'écran verrouillé) — remplace avantageusement l'ancien « live flights » cloud.
- Réintroduction éventuelle d'une couche communautaire via CloudKit public database (spots partagés) — sans serveur à maintenir.
- App icon SoarX dédiée (placeholder conservé en attendant le logo).
