# Replay 3D Mapbox — setup (5 minutes)

Le code du replay Mapbox est **déjà dans l'app** (`MapboxFlightReplayView.swift`),
mais il ne s'active que lorsque le SDK est lié ET qu'un token est configuré.
Tant que ce n'est pas fait, tous les replays utilisent l'ancien replay MapKit —
rien ne casse. Trois étapes, toutes côté Xavier (compte + Xcode).

## 1. Créer le compte Mapbox (gratuit, pas de CB)

1. <https://account.mapbox.com/auth/signup/> → crée le compte.
2. Sur le dashboard (<https://account.mapbox.com/>) tu as déjà un
   **Default public token** (`pk.…`) → copie-le.
3. Crée aussi un **token secret de téléchargement** pour que Xcode puisse
   récupérer le SDK : Tokens → *Create a token* → nom `SDK downloads`,
   coche uniquement le scope **DOWNLOADS:READ** → Create.
   ⚠️ Il commence par `sk.` et n'est montré qu'une fois — copie-le.

## 2. Coller le token public dans l'app

Dans `ParaFlightLog/Views/MapboxReplayConfig.swift` :

```swift
static let accessToken = "pk.TON_TOKEN_ICI"
```

(Le token public est fait pour être embarqué dans l'app — pas un secret.)

## 3. Ajouter le SDK dans Xcode

1. D'abord, autorise le téléchargement du SDK : crée/édite `~/.netrc` :

   ```
   machine api.mapbox.com
     login mapbox
     password sk.TON_TOKEN_SECRET_ICI
   ```

   puis `chmod 600 ~/.netrc`.
2. Xcode → projet ParaFlightLog → target **ParaFlightLog** (iOS uniquement,
   pas la Watch) → onglet *Package Dependencies* → **+** →
   URL : `https://github.com/mapbox/mapbox-maps-ios.git` →
   Dependency rule : *Up to Next Major* depuis **11.8.0** → Add Package →
   coche le produit **MapboxMaps** pour la target iOS.
3. Build. Dès que le package est présent, `#if canImport(MapboxMaps)`
   active le nouveau replay et `ReplayLauncherView` bascule automatiquement
   dessus (les vols locaux ET les vols partagés de la communauté).

## CI GitHub (sinon le build CI échoue à résoudre le package)

Une fois le package ajouté au projet, la CI a besoin du même `.netrc` :

1. GitHub → repo → Settings → Secrets and variables → Actions →
   *New repository secret* : nom `MAPBOX_DOWNLOAD_TOKEN`, valeur = le `sk.…`.
2. Le workflow `build.yml` contient déjà l'étape qui écrit le `.netrc`
   quand le secret existe — rien d'autre à faire.

## Ce que le replay Mapbox apporte

- **Terrain 3D réel** (relief exagéré ×1.3) + imagerie satellite.
- **Trace en 3D à sa vraie altitude GPS** (ligne élevée — impossible avec
  MapKit), colorée en continu par la vitesse verticale (vert = monte,
  rouge = descend).
- Caméra libre native : pincer = zoom, drag 2 doigts = inclinaison,
  rotation 2 doigts = orbite ; bouton *follow* pour recoller au pilote,
  bouton *map* pour la vue d'ensemble.
- Même moteur de lecture que l'ancien replay (scrubber par profil
  d'altitude, vitesses ×1/×4/×10/×30, HUD altitude/vario/heure).

## Notes

- Facturation : 25 000 utilisateurs actifs/mois gratuits ; seuls ceux qui
  OUVRENT un replay comptent (MapKit reste utilisé partout ailleurs).
- La ligne élevée (`lineZOffset`) est une API Mapbox *expérimentale*
  (`@_spi(Experimental)`). Si un futur bump du SDK la casse, supprimer les
  deux lignes marquées EXPERIMENTAL dans `configureStyle` — le replay
  retombe sur une ligne au sol (toujours en gradient vario + terrain 3D).
- Premier build après ajout du package : si des erreurs de compilation
  apparaissent dans `MapboxFlightReplayView.swift` (API du SDK ayant bougé),
  me les coller — écrites sans pouvoir compiler le SDK, une passe de
  correction est probable.
