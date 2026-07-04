# ParaFlightLog — Analyse en profondeur & Plan v20

*Analyse réalisée le 2026-07-04 sur `main` (79918cd). Codebase : ~13 000 lignes Swift (app iOS SwiftUI, app watchOS, extension widget), + web-admin Appwrite, Fastlane.*

---

## 1. État des lieux

### Ce qui est bien
- **Stack moderne et saine** : SwiftUI + SwiftData + framework Observation (iOS 17+), OSLog structuré, DTOs partagés iOS↔Watch (`SharedModels.swift`).
- **Le cœur métier est simple et correct** : 2 modèles (`Wing`, `Flight`), relation cascade propre, trace GPS en JSON dans le vol.
- **L'app Watch est le vrai produit** : tracking GPS + altitude + G-force + distance, récupération de session après crash (persistance UserDefaults toutes les 30 s), Water Lock, envoi différé des vols via `transferUserInfo` (survit au hors-ligne).
- **La bibliothèque de voiles en ligne** (Appwrite) a une bonne posture sécurité (aucun secret embarqué, catalogue public en lecture seule) et un fallback hors-ligne correct.
- **États vides gérés partout** (`ContentUnavailableView`), UX de premier lancement pensée.

### Ce qui pose problème (résumé)
| Gravité | Problème | Où |
|---|---|---|
| 🔴 Perte de données | Un vol Watch peut être **perdu silencieusement** : envoi sans accusé de réception, puis la session locale est effacée immédiatement | `WatchConnectivityManager.swift:76`, `ContentView.swift:195-198` |
| 🔴 Crash / corruption | `StatsCache` fait des fetch SwiftData **hors main thread** (ModelContext n'est pas thread-safe) | `StatsCache.swift:32-77` |
| 🔴 Perte de données | Le backup "ZIP" échappe le CSV en **remplaçant les virgules par `;` et les retours ligne par des espaces** → données mutilées de façon irréversible ; ré-import sans déduplication → doublons ; ligne courte → crash `cols[8]` | `ZipBackup.swift:347-350, 240, 310-317` |
| 🟠 Non fonctionnel | Le **widget est mort** : l'état "en vol" n'est jamais atteignable en production, pas d'App Group → sa localisation ne marche pas non plus | `ParaFlightLogWidget.swift:74-86` |
| 🟠 Fiabilité | Côté iPhone, un vol reçu n'est sauvé **que si** le callback localisation se déclenche ; pas de timeout, pas d'idempotence | `WatchConnectivityManager.swift:369-388` |
| 🟠 Perf | `WingRow` recalcule les heures de **tous les vols à chaque rendu de chaque ligne** | `WingsViews.swift:206` |
| 🟡 Qualité | Localisation incohérente : système de localisation complet, mais énormément de **français codé en dur** (un utilisateur EN voit une UI bilingue) | partout |
| 🟡 Release | **Team ID divergent** entre `Appfile` (`S96H22CQ8W`) et `ExportOptions.plist` (`XYKT5R2M8V`) | `ExportOptions.plist:12` |

---

## 2. Diagnostic détaillé

### 2.1 Architecture
- Deux modèles SwiftData (`Wing`, `Flight`) — c'est le bon niveau de simplicité. Le **spot n'est pas une entité** (juste `Flight.spotName: String?`), ce qui bloque plusieurs features (favoris, coordonnées de spot, renommage global).
- **Layout physique incohérent** : `Models.swift`, `DataController.swift` et tout `Views/` sont à la racine du repo, hors du dossier `ParaFlightLog/`.
- Les vues lisent les données via `@Query` **ET** via `DataController`, et certaines suppressions bypassent le contrôleur (`FlightsViews.swift:146`) → invalidation du cache incohérente. Deux implémentations complètes des mêmes agrégations de stats coexistent (`DataController.swift:294-353` et `StatsCache.swift:56-78`), et `StatsCache` n'est **lu par aucune vue**.
- Photos de voiles stockées en blobs `Data` dans SwiftData — acceptable aujourd'hui, à surveiller.

### 2.2 App Watch (le point fort… et le risque majeur)
Le pipeline de tracking est bien conçu (GPS filtré 5 m, points toutes les 5 s plafonnés à 500, G-force lissée à 10 Hz, outliers >10 G écartés). Mais :
- **`sendFlightToPhone` fait `guard sessionActivated else { return }`** — abandon silencieux, aucune file d'attente locale — puis `endSession()` efface la session persistée juste après. Si WCSession n'est pas encore activée : vol perdu, sans trace.
- `sendFlightWithReply` (le seul chemin avec accusé de réception) existe mais **n'est jamais appelé** (`WatchConnectivityManager.swift:90-122`).
- La récupération après crash **gonfle la durée du vol** : `durée = maintenant − début`, incluant tout le temps où l'app était morte (`FlightSessionManager.swift:229`).
- Deux algorithmes de compaction GPS **divergents** coexistent (`WatchLocationService.swift:175-198` vs `FlightSessionManager.swift:118-130`).
- `WATCH_PERFORMANCE_GUIDE.md` documente une architecture **qui n'existe plus** (flags, méthodes et logs introuvables dans le code actuel) — documentation trompeuse.
- Un workout HealthKit est démarré **uniquement** pour activer le Water Lock, jamais terminé ni enregistré (`WorkoutManager.swift:93-131`) — l'infrastructure d'une vraie feature est là, mais inutilisée.

### 2.3 Backup / import
- `ZipBackup` **ne produit pas de ZIP** (bundle dossier `.paraflightlog`) et `ExcelImporter` **ne lit pas d'Excel** (CSV uniquement). Les deux noms mentent.
- Échappement CSV destructif et non round-trippable ; `DateFormatter` sans locale ni timezone ; mode "replace" qui supprime tout **avant** de vérifier que le parse a réussi ; merge sans déduplication alors que les UUID sont préservés (le matériel pour dédupliquer existe déjà !).
- Trois systèmes d'export/import coexistent : backup bundle, export CSV "ancien format" (`SettingsViews.swift:730-833`, avec échappement encore différent et hack de présentation du share sheet), et import "Excel". Un seul devrait survivre.

### 2.4 Sur-ingénierie caractérisée
- **`StatsCache`** (142 lignes) : cache threadé + invalidation câblée dans ~8 méthodes CRUD… pour un cache que personne ne lit. Complexité maximale, bénéfice nul, et c'est lui qui introduit le data race principal.
- **Mémoïsation maison de `ChartsView`** (`ChartsView.swift:29-135`) : hash de filtres + cache + 6 `onChange` pour remplacer… une propriété calculée. Bug inclus : un résultat vide n'est jamais mis en cache (recalcul infini).
- **`WingImageCache`** (acteur avec sémaphore, dédup de requêtes en vol, retry 429) : bien écrit mais dimensionné pour un CDN, pas pour un catalogue de 500 voiles.
- **`StopFlightContainerView`** : machine à états manuelle avec transitions custom juste pour éviter un flash visuel entre deux sheets.
- Duplications : formulaire de voile (Add vs Edit quasi identiques, `WingsViews.swift:399-465` vs `551-645`), 2 map pickers complets (`MapCoordinatePicker`, `SpotMapPicker`), `formatDistance`/`formatDuration`/`formatHours` réimplémentés 4 à 6 fois, blocs de stat cards copiés-collés dans 4 vues.

### 2.5 UX
- 5 onglets : Voiles / Vols / Stats / Graphiques / Réglages. **Stats et Graphiques font doublon** (mêmes données, présentations différentes).
- Le **chronomètre — le principal moyen de logger un vol depuis l'iPhone — est enterré dans Réglages** ▸ Chronomètre. C'est la feature la moins découvrable de l'app.
- **Aucun bouton "+" pour ajouter un vol manuellement** depuis l'onglet Vols (saisie a posteriori impossible directement — c'est LE cas d'usage carnet de vol papier → app).
- Changer de langue **reconstruit toute la TabView** (`.id(currentLanguage)`) — flash visible.

### 2.6 Infra / release
- **Pas de CI** : le workflow GitHub Actions a été ajouté puis reverté (« pushed to wrong repo »). Release = Fastlane local macOS + rbenv + 4 variables d'env non documentées.
- Team ID incohérent (voir tableau). Snapshots limités à un seul simulateur nommé en dur (« iPhone 17 Pro Max »).
- `docs/` et `web-admin/docs/` sont **deux copies identiques** des mêmes pages privacy/support.
- web-admin : auth Appwrite correcte, pas de secrets exposés ; XSS stocké possible via `innerHTML` non échappé (`app.js:206-217, 450-498`) — faible impact (l'admin s'attaque lui-même) mais à corriger.
- Localisation : 308 clés EN/FR à ~88 % de couverture chacune, mais beaucoup de surfaces (erreurs import, bibliothèque, résumés) en français dur.

---

## 3. Ce que je SUPPRIMERAIS (trop compliqué et/ou non fonctionnel)

| # | Élément | Justification | Remplacement |
|---|---|---|---|
| S1 | **`StatsCache.swift` entier** + tous les appels `statsCache.invalidate()` | Inutilisé par l'UI, duplique `DataController`, cause le data race SwiftData | Agrégations à la demande dans `DataController` (les volumes — quelques centaines de vols — ne justifient aucun cache) |
| S2 | **Widget** (extension complète) — *ou* le réduire à un lanceur statique assumé | L'état "en vol" est inatteignable, la localisation ne peut pas marcher sans App Group, refresh 15 min pour un contenu constant | Le réintroduire proprement en Phase 4 avec App Group + reload sur événements de vol |
| S3 | **Export CSV "ancien format"** (`SettingsViews.swift:730-833`) | Troisième système d'export, échappement cassé, hack de présentation UIKit, déjà étiqueté "legacy" | Le backup unique (S4) |
| S4 | **`ExcelImporter` en tant que feature séparée** | Ne lit pas d'Excel ; format colonne rigide ; à garder uniquement comme *parseur CSV interne* du flux d'import unique | Un seul flux « Importer des données » (backup + CSV générique) |
| S5 | **Mémoïsation maison de `ChartsView`** (hash + cache + 6 `onChange`) | Bug (vide jamais caché), complexité injustifiée | Propriété calculée simple |
| S6 | **`TestImport.swift`** | Chemin absolu vers une autre machine, jamais appelé, shippé dans la target | rien |
| S7 | **`WATCH_PERFORMANCE_GUIDE.md`** | Documente du code qui n'existe plus — activement trompeur | Section courte dans un README à jour |
| S8 | **Code mort** : `Wing.toDTO()`/`toDTOForWatch()`, `NotificationNames`, `isCacheValid()` + `catalogCacheMaxAge`, `WorkoutManager.endWorkoutSession`/`isWorkoutActive`, `WatchSettings.enableWaterLock`, `AppLogger.legacy`, `lastKnownLocation` | Non référencé | rien |
| S9 | **Un des deux map pickers** (`SpotMapPicker` vs `MapCoordinatePicker`) | Deux implémentations complètes de la même chose | Un composant partagé |
| S10 | **`docs/` ou `web-admin/docs/`** (garder une seule copie) | Duplication identique | Une seule source |
| S11 | **Machine à états de `StopFlightContainerView`** | Complexité pour un anti-flash | Navigation standard (2 étapes dans une même sheet) |
| S12 | **Onglet "Graphiques" en tant qu'onglet séparé** | Doublon fonctionnel avec Stats | Fusion dans un onglet "Statistiques" unique (segments : Résumé / Graphiques / Carte) |
| S13 | Simplifier **`WingImageCache`** : garder cache mémoire+disque, retirer sémaphore maison et retry élaboré | Sur-dimensionné pour 500 images | `URLSession` + `URLCache` font 90 % du travail |

**Effet net attendu : ~2 000–2 500 lignes en moins, zéro perte fonctionnelle réelle.**

---

## 4. Ce que je CHANGERAIS / CORRIGERAIS

### 4.1 Fiabilité (bloquant, avant toute nouvelle feature)
1. **Outbox persistante côté Watch** : à l'arrêt du vol, écrire le `FlightDTO` dans une file locale persistée ; n'effacer une entrée **qu'après accusé de réception** (utiliser `sendFlightWithReply` déjà écrit, fallback `transferUserInfo` + confirmation applicative). `endSession()` ne purge que la session de tracking, jamais le vol non confirmé.
2. **Idempotence côté iPhone** : dédupliquer sur `flight.id` avant insertion ; sauver le vol immédiatement et enrichir le spot par géocodage **ensuite** (plus de vol perdu si le callback localisation ne vient pas) ; timeout sur la localisation.
3. **Récupération de session honnête** : borner la durée récupérée au dernier point GPS/dernière sauvegarde connue, pas à `Date()`.
4. **Réécrire le backup** :
   - Vrai échappement CSV RFC 4180 (guillemets doublés) — ou passer les données en JSON dans le bundle, le CSV ne restant que pour l'interop humaine ;
   - `DateFormatter` avec `en_US_POSIX` + timezone fixe (ou ISO 8601) ;
   - Déduplication par UUID en mode merge ; mode replace qui **valide le parse avant** de supprimer quoi que ce soit ;
   - Corriger l'indexation `cols[8]` (guard count ≥ 9) ;
   - Produire un vrai `.zip` (l'API `NSFileCoordinator`/`Archive` d'Apple ou une lib) et renommer honnêtement les types.
5. **Threading** : supprimer S1 règle le pire ; corriger le read non synchronisé de `WatchLogger.logger(for:)` ; auditer les closures de `WatchConnectivityManager` (hop main systématique avant tout accès modèle).
6. **`WingRow`** : calculer `totalHoursByWing()` une fois dans la vue liste et le passer aux lignes.
7. **Release** : aligner le team ID d'`ExportOptions.plist` sur l'`Appfile` ; documenter les 4 variables d'env Fastlane ; remettre le workflow GitHub Actions (sur le **bon** repo cette fois).

### 4.2 Restructuration du code
- Déplacer tous les sources dans `ParaFlightLog/` avec une arborescence claire : `Models/`, `Services/`, `Views/Flights/`, `Views/Wings/`, `Views/Stats/`, `Views/Settings/`, `Shared/` (DTOs + formatters communs iOS/Watch).
- Découper les god files (`FlightsViews` 1354 l., `SettingsViews` 1098 l., `WingsViews` 1027 l., `ContentView` Watch 944 l.) : une vue majeure = un fichier.
- **Un seul module de formatage** (`Formatters.swift` partagé) : durée, distance, vitesse, altitude, heures — remplace les ~6 copies.
- **Un seul formulaire de voile** (`WingFormView`) paramétré ajout/édition.
- **Une seule règle d'accès aux données** : tout write passe par `DataController` (plus de `modelContext.delete` dans les vues).
- Localisation : passer toutes les chaînes en dur dans `Localizable.xcstrings` (y compris erreurs d'import et de bibliothèque), supprimer les sentinelles magiques (`"Recherche..."` comme valeur de contrôle, `TimerViews.swift:323`), remplacer le `Locale(identifier: "fr_FR")` en dur de `Flight.dateFormatted` par la locale courante.
- Unifier la clé de langue (`LocalizationManager` utilise sa propre clé au lieu de `Constants`).

### 4.3 Restructuration UX
- **4 onglets** : `Vols` (accueil) / `Voiles` / `Statistiques` (fusion Stats+Graphiques) / `Réglages`.
- **Bouton "+" sur l'onglet Vols** → saisie manuelle d'un vol (date, durée, voile, spot, notes). C'est le gap n°1.
- **Chronomètre promu** : gros bouton "Démarrer un vol" en tête de l'onglet Vols (ou bouton flottant), plus enterré dans Réglages.
- Changement de langue sans reconstruction brutale de la TabView.

---

## 5. Features que j'AJOUTERAIS

### Quick wins (fort impact / faible coût)
| # | Feature | Pourquoi |
|---|---|---|
| F1 | **Ajout manuel de vol** (le "+") | Migration du carnet papier, vols oubliés, vols sans Watch. Indispensable pour un carnet de vol. |
| F2 | **Vrai workout HealthKit enregistré** | 90 % du code existe déjà (`WorkoutManager`) — il suffit de `finishWorkout()`. Calories, anneaux d'activité, historique Santé. |
| F3 | **Export GPX/IGC d'un vol** | La trace GPS est déjà stockée ; IGC est LE format standard du vol libre (SeeYou, XContest, Syride). Différenciateur réel. |
| F4 | **Spot = entité** (nom + coordonnées + favori) | Débloque : renommage global, suggestions au lancement du chrono (spot le plus proche), stats fiables (fini les doublons "St Gervais"/"Saint-Gervais"). |

### Milieu de gamme
| # | Feature | Pourquoi |
|---|---|---|
| F5 | **Sync iCloud (SwiftData + CloudKit)** | Remplace le backup manuel comme filet de sécurité principal, multi-appareils gratuit. Le backup fichier reste pour l'export/portabilité. |
| F6 | **Import IGC/GPX** | Récupérer l'historique depuis un vario ou XContest. |
| F7 | **Progression annuelle** : heures/vols par année, comparaison N vs N-1, objectif annuel | Les pilotes suivent leurs heures pour les qualifs (brevet, SIV, biplace). Toutes les données sont là. |
| F8 | **Live Activity iPhone** pendant un vol (chrono + spot sur l'écran verrouillé) | Pendant du widget Watch, techno mature, forte visibilité. |
| F9 | **Widget réparé** (App Group + reload sur start/stop) | Réintroduction propre de S2. |

### Plus tard (v2.1+)
- Météo du vol auto-enregistrée (vent/température au start via API météo).
- Partage d'un vol en image (carte + stats) pour réseaux sociaux.
- Statistiques de finesse/vario si la trace le permet.
- Multi-activités (speed-riding, kite) via le champ `flightType` déjà présent.

---

## 6. Roadmap proposée

### Phase 0 — Grand nettoyage (1–2 jours)
Suppressions S1–S13, réorganisation des dossiers, formatters unifiés, code mort. Aucun changement fonctionnel visible. **Livrable : ~-2 500 lignes, base saine.**

### Phase 1 — Fiabilité (3–5 jours)
Outbox Watch avec ACK + idempotence iPhone (4.1.1–3), réécriture backup (4.1.4), threading (4.1.5), perf WingRow, team ID + doc release. **Livrable : plus aucun scénario connu de perte de données.**

### Phase 2 — UX (3–4 jours)
4 onglets, fusion Stats/Graphiques, bouton "+" (F1), chrono promu, localisation complète EN/FR. **Livrable : app cohérente et découvrable, candidate TestFlight.**

### Phase 3 — Features cœur (1–2 semaines)
F2 (workout HealthKit), F3 (export IGC/GPX), F4 (entité Spot + migration des `spotName` existants), F7 (progression annuelle).

### Phase 4 — Écosystème (au fil de l'eau)
F5 (CloudKit), F6 (import IGC), F8 (Live Activity), F9 (widget), CI GitHub Actions.

---

## 7. Principes directeurs pour la v20

1. **La donnée d'un vol est sacrée** : rien n'est effacé avant confirmation de persistance ailleurs.
2. **Un seul chemin par fonction** : un système d'export, un formulaire de voile, un map picker, un module de formatage.
3. **Pas de cache sans lecteur, pas d'abstraction sans deuxième usage.**
4. **Les noms disent la vérité** (`ZipBackup` fera des ZIP, ou s'appellera autrement).
5. **La Watch d'abord** : c'est le différenciateur de l'app ; sa fiabilité prime sur toute nouvelle feature iPhone.
