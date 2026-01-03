# ParaFlightLog - Roadmap Features

## Vision

**Devenir le "Strava du parapente"** - Une app complète permettant aux pilotes de suivre leurs vols et progresser grâce à un système de gamification motivant.

---

## Ordre d'Implémentation

| Phase | Nom | Priorité | Complexité |
|-------|-----|----------|------------|
| **1** | Gamification (Badges, XP, Classements) | Haute | Moyenne |
| **2** | Notifications & Vols en Direct | Haute | Élevée |
| **3** | Features Avancées (Photos, SOS, Météo) | Moyenne | Élevée |
| **4** | Partage Social & Mode Hors-ligne | Moyenne | Moyenne |

---

## Phase 1: Gamification - Badges, XP & Classements
**Priorité: Haute | Complexité: Moyenne**

### 1.1 Définition des Badges

**Backend - Collection `badges`:**
```
Attributs:
- name (string, 100) - Nom FR du badge
- nameEn (string, 100) - Nom EN
- description (string, 500) - Description FR
- descriptionEn (string, 500) - Description EN
- icon (string, 50) - Nom SF Symbol (ex: "star.fill")
- category (string, 50) - flights/duration/spots/performance/streak
- tier (string, 20) - bronze/silver/gold/platinum
- requirementType (string, 50) - total_flights/total_hours/unique_spots/single_flight_duration/etc.
- requirementValue (integer) - Valeur cible
- xpReward (integer) - XP gagnés

Index: category (key), tier (key)
Permissions: Any read, Admins write
```

**Catalogue de Badges:**

| Badge | Catégorie | Condition | Tier | XP |
|-------|-----------|-----------|------|-----|
| Premier Vol | vols | 1 vol | Bronze | 50 |
| Pilote Régulier | vols | 10 vols | Bronze | 100 |
| Pilote Assidu | vols | 50 vols | Argent | 250 |
| Centurion | vols | 100 vols | Or | 500 |
| Maître des Airs | vols | 500 vols | Platine | 1000 |
| Première Heure | durée | 1h total | Bronze | 50 |
| 10 Heures | durée | 10h total | Bronze | 100 |
| 50 Heures | durée | 50h total | Argent | 250 |
| 100 Heures | durée | 100h total | Or | 500 |
| Explorateur | spots | 5 spots différents | Bronze | 100 |
| Globe-Trotter | spots | 20 spots différents | Argent | 250 |
| Voyageur | spots | 50 spots différents | Or | 500 |
| Vol Long | perf | 2h vol unique | Argent | 200 |
| Marathonien | perf | 4h vol unique | Or | 400 |
| Série de 7 | streak | 7 jours consécutifs | Bronze | 100 |
| Série de 30 | streak | 30 jours consécutifs | Argent | 300 |
| Altitude 2000 | perf | 2000m altitude | Argent | 200 |
| Altitude 3000 | perf | 3000m altitude | Or | 400 |
| Distance 50km | perf | 50km en un vol | Or | 400 |
| Distance 100km | perf | 100km en un vol | Platine | 800 |

### 1.2 Service Badges

**Backend - Collection `user_badges`:**
```
Attributs:
- userId (string, 36) - ID utilisateur
- badgeId (string, 36) - ID du badge
- earnedAt (datetime) - Date d'obtention

Index: userId (key), [userId, badgeId] (unique)
Permissions: Users read own, System write
```

**Service à créer:** `BadgeService.swift`
```swift
func getAllBadges() async throws -> [Badge]
func getUserBadges(userId: String) async throws -> [UserBadge]
func checkAndAwardBadges() async throws -> [Badge] // Retourne les nouveaux badges gagnés
func getProgress(badgeId: String) async throws -> BadgeProgress
```

**Logique de vérification:**
- Appelée après chaque sync de vol
- Compare les stats utilisateur aux requirements des badges
- Attribue les nouveaux badges et déclenche notification locale

### 1.3 Système XP & Niveaux

**État actuel:** `CloudUserProfile` a `xpTotal`, `level` (champs existants)

**Sources d'XP:**
- Vol complété: 10 XP + 1 XP par 10 minutes
- Badge gagné: XP du badge
- Premier vol sur un nouveau spot: 25 XP bonus
- Streak maintenu: 5 XP par jour

**Niveaux (existants dans UserService.calculateLevel):**
- Niveau 1: 0 XP → Niveau 2: 100 XP → Niveau 3: 250 XP → ... (progression exponentielle)

### 1.4 Classements Globaux

**Backend:** Pas de nouvelle collection - utilise les données existantes de `users`

**Types de classements:**
| Classement | Champ utilisé | Portée |
|------------|---------------|--------|
| Heures de vol | totalFlightSeconds | Global / National |
| Nombre de vols | totalFlights | Global / National |
| Niveau | level / xpTotal | Global |
| Plus long streak | longestStreak | Global |

**Service à créer:** `LeaderboardService.swift`
```swift
func getGlobalLeaderboard(type: LeaderboardType, limit: Int) async throws -> [LeaderboardEntry]
func getNationalLeaderboard(type: LeaderboardType, country: String, limit: Int) async throws -> [LeaderboardEntry]
func getUserRank(type: LeaderboardType) async throws -> (rank: Int, total: Int)
```

**Vues:**
- Créer `LeaderboardsView` - Onglets par type de classement
- Filtres: Global / Par pays
- Afficher son propre rang
- Navigation vers profil pilote

### 1.5 Vues Badges & Progression

- Créer `BadgesView` - Grille de tous les badges (gagnés vs verrouillés)
- Créer `BadgeDetailView` - Détail avec barre de progression
- Ajouter section badges au profil
- Animation de level-up et badge gagné
- Créer `LevelProgressView` - Barre de progression vers niveau suivant

### Fichiers Phase 1:
- **Créer:** `BadgeService.swift`, `LeaderboardService.swift`
- **Créer:** `BadgesView.swift`, `LeaderboardsView.swift`
- **Modifier:** `ProfileViews.swift` - Ajouter section badges
- **Modifier:** `FlightSyncService.swift` - Trigger vérification badges après sync
- **Modifier:** `UserService.swift` - Logique XP

---

## Phase 2: Notifications & Vols en Direct
**Priorité: Haute | Complexité: Élevée**

### 2.1 Infrastructure Notifications

**Backend:** Collection `notifications`
- Schema: `{ userId, type, title, body, data, isRead, createdAt }`
- Types: `flight_started`, `badge_earned`, `spot_activity`

**Appwrite Function requise:**
- Trigger sur création de vol → notifier les abonnés du spot
- Intégration APNs pour push notifications

**Service à étendre:** `NotificationService.swift`
```swift
func fetchNotifications() async throws -> [AppNotification]
func markAsRead(notificationId: String) async throws
func getUnreadCount() async throws -> Int
```

**Vues:**
- Créer `NotificationsView` - Liste des notifications
- Ajouter badge sur l'icône de notification
- Navigation vers le contenu concerné

### 2.2 Vols en Direct (Live Flights)

**Backend:** Collection `live_flights`
- Schema: `{ userId, pilotName, pilotUsername, pilotPhotoFileId, startedAt, latitude, longitude, spotName, isActive }`

**Service à créer:** `LiveFlightService.swift`
```swift
func startLiveFlight(location: CLLocationCoordinate2D, spotName: String?) async throws
func updateLocation(location: CLLocationCoordinate2D) async throws
func endLiveFlight() async throws
func getLiveFlights() async throws -> [LiveFlight]
```

**Intégration Watch:**
- Quand un vol démarre sur la Watch → notifier l'iPhone
- L'iPhone déclenche `startLiveFlight()`

**Vues:**
- Créer `LiveFlightsMapView` - Carte temps réel des vols en cours
- Ajouter segment "Live" dans `DiscoverView`
- Indicateur "En vol" sur les profils pilotes

### 2.3 Notifications d'Activité Spot

- Quand quelqu'un vole sur un spot auquel on est abonné → notification
- Utilise les subscriptions existantes dans `SpotService`

### Fichiers Phase 2:
- **Créer:** `LiveFlightService.swift`
- **Créer:** `NotificationsView.swift`, `LiveFlightsMapView.swift`
- **Modifier:** `NotificationService.swift` - Notifications cloud
- **Modifier:** `DiscoverViews.swift` - Segment Live

---

## Phase 3: Features Avancées
**Priorité: Moyenne | Complexité: Élevée**

### 3.1 Photos de Vol

**Backend:** Bucket `flight-photos` (déjà défini)

**FlightSyncService extension:**
```swift
func uploadFlightPhotos(flightId: String, images: [UIImage]) async throws
func deleteFlightPhoto(photoId: String) async throws
```

**Vues:**
- Galerie photos dans `PublicFlightDetailView`
- Picker photo lors de l'édition de vol
- Carousel dans les cartes de vol

### 3.2 Profil Pilote Amélioré

- Header complet avec photo, bio, stats, niveau
- Historique des vols timeline
- Showcase des badges gagnés
- Activité récente

### 3.3 Système SOS/Urgence

**Backend:** Collections `emergency_contacts` et `sos_alerts`

**Service à créer:** `EmergencyService.swift`
```swift
func addEmergencyContact(contact: EmergencyContact) async throws
func triggerSOS(location: CLLocationCoordinate2D) async throws
func cancelSOS() async throws
```

**Vues:**
- Gestion des contacts d'urgence dans Paramètres
- Bouton SOS accessible pendant le vol
- Intégration Watch

### 3.4 Météo des Spots

**Backend:** Collection `spot_weather_cache`
- Intégration API météo (OpenMeteo)

**Vues:**
- Widget météo sur `SpotDetailView`
- Indicateurs vent/conditions
- Prévisions

### Fichiers Phase 3:
- **Créer:** `EmergencyService.swift`
- **Modifier:** `FlightSyncService.swift` - Upload photos
- **Modifier:** `ProfileViews.swift` - Profil amélioré
- **Modifier:** `SpotViews.swift` - Widget météo

---

## Phase 4: Partage Social & Mode Hors-ligne
**Priorité: Moyenne | Complexité: Moyenne**

### 4.1 Partage Social

**Objectif:** Permettre aux pilotes de partager leurs vols et badges sur les réseaux sociaux.

**Fonctionnalités:**
- Générer une image de partage pour un vol (carte + stats)
- Générer une image pour un badge gagné
- Partage via ShareSheet iOS (Instagram Stories, Facebook, Twitter, etc.)
- Deep links pour ouvrir l'app depuis un partage

**Service à créer:** `ShareService.swift`
```swift
func generateFlightShareImage(flight: Flight) -> UIImage
func generateBadgeShareImage(badge: Badge) -> UIImage
func shareToInstagramStories(image: UIImage)
func getDeepLink(for flight: String) -> URL
```

**Vues:**
- Bouton partage sur `PublicFlightDetailView`
- Bouton partage sur `BadgeDetailView`
- Preview de l'image avant partage
- Template d'image avec branding ParaFlightLog

### 4.2 Mode Hors-ligne Amélioré

**Objectif:** Permettre une utilisation complète même sans connexion.

**Fonctionnalités:**
- Cache agressif des données de découverte
- Indicateur de statut de connexion
- Queue d'actions en attente de sync
- Gestion des conflits

**Service à modifier:** `OfflineSyncService.swift`
```swift
func queueAction(action: PendingAction)
func processPendingActions() async throws
func getCachedDiscoveryFeed() -> [PublicFlight]
func cacheDiscoveryFeed(flights: [PublicFlight])
```

**Stockage local:**
- SwiftData pour les actions en attente
- Cache disque pour les images et données feed
- Expiration configurable du cache

**Vues:**
- Indicateur "Hors ligne" dans la barre de navigation
- Badge sur les actions en attente de sync
- Notification quand la sync reprend

### Fichiers Phase 4:
- **Créer:** `ShareService.swift`, `OfflineSyncService.swift`
- **Créer:** `FlightShareView.swift`, `BadgeShareView.swift`
- **Modifier:** `PublicFlightDetailView` - Bouton partage
- **Modifier:** `BadgeDetailView` - Bouton partage

---

## Résumé des Fichiers

### Services à créer:
| Service | Phase | Description |
|---------|-------|-------------|
| `BadgeService.swift` | 1 | Badges, XP, vérification |
| `LeaderboardService.swift` | 1 | Classements globaux/nationaux |
| `LiveFlightService.swift` | 2 | Vols en direct |
| `EmergencyService.swift` | 3 | SOS et urgences |
| `ShareService.swift` | 4 | Partage social |

### Services à modifier:
- `UserService.swift` - Stats et progression XP
- `FlightSyncService.swift` - Trigger vérification badges après sync
- `NotificationService.swift` - Notifications cloud

### Vues à créer:
- `BadgesView.swift`, `BadgeDetailView.swift`, `LeaderboardsView.swift` (Phase 1)
- `NotificationsView.swift`, `LiveFlightsMapView.swift` (Phase 2)
- `FlightShareView.swift`, `BadgeShareView.swift` (Phase 4)

### Vues à modifier:
- `ProfileViews.swift` - Section badges, niveau, progression
- `DiscoverViews.swift` - Segment Live
- `SpotViews.swift` - Widget météo

### Collections Appwrite:
- `badges`, `user_badges` (Phase 1)
- `notifications`, `live_flights` (Phase 2)

---

## Prochaine Action Immédiate

Commencer par **Phase 1.1 - Badges**:
1. Vérifier/créer les collections `badges` et `user_badges` dans Appwrite
2. Créer `BadgeService.swift` avec les modèles Badge et UserBadge
3. Implémenter la logique de vérification des badges
4. Créer les vues `BadgesView` et `BadgeDetailView`
5. Intégrer dans le profil utilisateur
