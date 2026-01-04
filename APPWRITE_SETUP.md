# Configuration Appwrite pour ParaFlightLog

Ce document explique comment configurer les collections et buckets nécessaires dans Appwrite pour que la synchronisation cloud fonctionne.

## Prérequis

- Un compte Appwrite Cloud (https://cloud.appwrite.io) ou une instance self-hosted
- Projet Appwrite existant avec l'ID: `69524ce30037813a6abb`
- Base de données avec l'ID: `69524e510015a312526b`

## Collections à créer

### 1. Collection `users` (Profils utilisateurs)

**ID de collection**: `users`

**Attributs**:

| Nom | Type | Requis | Défaut | Notes |
|-----|------|--------|--------|-------|
| authUserId | string (255) | ✅ | - | ID de l'utilisateur Appwrite Auth |
| email | string (255) | ✅ | - | Email de l'utilisateur |
| displayName | string (100) | ✅ | - | Nom affiché |
| username | string (50) | ✅ | - | Nom d'utilisateur unique |
| bio | string (500) | ❌ | "" | Biographie |
| profilePhotoFileId | string (255) | ❌ | null | ID du fichier photo de profil |
| homeLocationLat | double | ❌ | null | Latitude du lieu de vol habituel |
| homeLocationLon | double | ❌ | null | Longitude du lieu de vol habituel |
| homeLocationName | string (100) | ❌ | null | Nom du lieu de vol habituel |
| pilotWeight | double | ❌ | null | Poids du pilote (kg) |
| isPremium | boolean | ✅ | false | Abonnement premium |
| premiumUntil | datetime | ❌ | null | Date de fin de l'abonnement |
| notificationsEnabled | boolean | ✅ | true | Notifications activées |
| totalFlights | integer | ✅ | 0 | Nombre total de vols |
| totalFlightSeconds | integer | ✅ | 0 | Temps de vol total (secondes) |
| xpTotal | integer | ✅ | 0 | Points d'expérience |
| level | integer | ✅ | 1 | Niveau du pilote |
| currentStreak | integer | ✅ | 0 | Série de vols actuelle |
| longestStreak | integer | ✅ | 0 | Plus longue série de vols |
| createdAt | datetime | ✅ | - | Date de création |
| lastActiveAt | datetime | ✅ | - | Dernière activité |

**Index**:
- `authUserId` (unique)
- `username` (unique)
- `email` (key)

**Permissions**:
```
Document Security: Enabled

Create: users (tout utilisateur authentifié peut créer son profil)
Read: users (tout utilisateur authentifié peut lire les profils)
Update: user:[ID] (seul le propriétaire peut modifier)
Delete: user:[ID] (seul le propriétaire peut supprimer)
```

### 2. Collection `flights` (Vols)

**ID de collection**: `flights`

**Attributs**:

| Nom | Type | Requis | Défaut | Notes |
|-----|------|--------|--------|-------|
| userId | string (255) | ✅ | - | ID du profil utilisateur (relation vers users) |
| localFlightId | string (255) | ✅ | - | UUID du vol local |
| isPrivate | boolean | ✅ | true | Vol privé ou public |
| startDate | datetime | ✅ | - | Date/heure de début |
| endDate | datetime | ✅ | - | Date/heure de fin |
| durationSeconds | integer | ✅ | - | Durée en secondes |
| spotName | string (200) | ❌ | null | Nom du spot |
| spotId | string (255) | ❌ | null | ID du spot (si lié) |
| latitude | double | ❌ | null | Latitude |
| longitude | double | ❌ | null | Longitude |
| geohash | string (20) | ❌ | null | Geohash pour recherche géo |
| startAltitude | double | ❌ | null | Altitude de départ |
| maxAltitude | double | ❌ | null | Altitude maximale |
| endAltitude | double | ❌ | null | Altitude d'arrivée |
| totalDistance | double | ❌ | null | Distance totale (m) |
| maxSpeed | double | ❌ | null | Vitesse maximale (m/s) |
| maxGForce | double | ❌ | null | G-Force maximale |
| wingId | string (255) | ❌ | null | ID de l'aile |
| wingBrand | string (100) | ❌ | null | Marque de l'aile |
| wingModel | string (100) | ❌ | null | Modèle de l'aile |
| wingSize | string (20) | ❌ | null | Taille de l'aile |
| weatherConditions | string (50) | ❌ | null | Conditions météo |
| windDirection | string (20) | ❌ | null | Direction du vent |
| windSpeed | double | ❌ | null | Vitesse du vent (km/h) |
| notes | string (2000) | ❌ | null | Notes du pilote |
| hasGpsTrack | boolean | ✅ | false | A une trace GPS |
| gpsTrackFileId | string (255) | ❌ | null | ID du fichier trace GPS |
| trackPointCount | integer | ✅ | 0 | Nombre de points GPS |
| pilotName | string (100) | ❌ | null | Nom du pilote (pour affichage) |
| pilotUsername | string (50) | ❌ | null | Username du pilote |
| pilotPhotoFileId | string (255) | ❌ | null | Photo du pilote |
| likeCount | integer | ✅ | 0 | Nombre de likes |
| commentCount | integer | ✅ | 0 | Nombre de commentaires |
| createdAt | datetime | ✅ | - | Date de création |
| syncedAt | datetime | ✅ | - | Date de synchronisation |
| deviceSource | string (20) | ✅ | "iphone" | Source (iphone, watch) |

**Index**:
- `userId` (key)
- `localFlightId` (unique)
- `startDate` (key, desc)
- `isPrivate` (key)
- `latitude`, `longitude` (key) - pour les recherches géo

**Permissions**:
```
Document Security: Enabled

Create: users
Read: any (pour les vols publics), user:[userId] (pour les vols privés)
Update: user:[userId]
Delete: user:[userId]
```

### 3. Collection `badges` (Définition des badges)

**ID de collection**: `badges`

**Attributs**:

| Nom | Type | Requis | Défaut | Notes |
|-----|------|--------|--------|-------|
| name | string (100) | ✅ | - | Nom du badge (FR) |
| nameEn | string (100) | ❌ | - | Nom du badge (EN) |
| description | string (500) | ✅ | - | Description (FR) |
| descriptionEn | string (500) | ❌ | - | Description (EN) |
| icon | string (50) | ✅ | - | Nom SF Symbol |
| category | string (50) | ✅ | - | flights/duration/spots/performance/streak |
| tier | string (20) | ✅ | - | bronze/silver/gold/platinum |
| requirementType | string (50) | ✅ | - | Type de condition |
| requirementValue | integer | ✅ | - | Valeur cible |
| xpReward | integer | ✅ | 50 | XP gagnés |

**Index**:
- `category` (key)
- `tier` (key)

**Permissions**:
```
Create: team:admins (seuls les admins créent les badges)
Read: any (tout le monde peut voir les badges)
Update: team:admins
Delete: team:admins
```

### 4. Collection `user_badges` (Badges obtenus par utilisateur)

**ID de collection**: `user_badges`

**Attributs**:

| Nom | Type | Requis | Défaut | Notes |
|-----|------|--------|--------|-------|
| userId | string (255) | ✅ | - | ID du profil utilisateur |
| badgeId | string (255) | ✅ | - | ID du badge |
| earnedAt | datetime | ✅ | - | Date d'obtention |

**Index**:
- `userId` (key)
- `badgeId` (key)
- `userId` + `badgeId` (unique) - pour éviter les doublons

**Permissions**:
```
Document Security: Enabled

Create: users (tout utilisateur authentifié peut recevoir un badge)
Read: any (tout le monde peut voir les badges obtenus)
Update: none (les badges ne sont jamais modifiés)
Delete: team:admins (seuls les admins peuvent supprimer)
```

## Buckets Storage à créer

### 1. Bucket `profile-photos`

**ID**: `profile-photos`

**Configuration**:
- Taille max: 5 MB
- Extensions autorisées: jpg, jpeg, png, webp
- Chiffrement: Activé
- Antivirus: Activé (si disponible)

**Permissions**:
```
Create: users
Read: any
Update: user:[ID]
Delete: user:[ID]
```

### 2. Bucket `gps-tracks`

**ID**: `gps-tracks`

**Configuration**:
- Taille max: 10 MB
- Extensions autorisées: json
- Chiffrement: Activé

**Permissions**:
```
Create: users
Read: any (pour vols publics), user:[ID] (pour vols privés)
Update: user:[ID]
Delete: user:[ID]
```

## Vérification

Après avoir créé les collections, tu peux vérifier que tout fonctionne en:

1. Ouvrant l'app sur ton iPhone
2. Te connectant avec ton compte
3. Allant sur l'onglet "Profil"
4. Regardant les logs dans Xcode Console (filtrer sur "ParaFlightLog")

Si la collection `users` est bien configurée, tu devrais voir:
```
[AUTH] Profile created successfully for user: ton@email.com
```

Sinon, tu verras:
```
[AUTH] Failed to create cloud profile: [message d'erreur]
```

## Problèmes courants

### "Collection could not be found"
→ La collection n'existe pas. Crée-la dans Appwrite Console.

### "Missing required attribute"
→ Un attribut requis n'est pas présent. Vérifie que tous les attributs marqués "Requis" sont créés.

### "Document with the requested ID already exists"
→ Le profil existe déjà. C'est normal si tu te reconnectes.

### "User unauthorized"
→ Les permissions ne sont pas correctement configurées. Vérifie que "users" peut créer des documents.
