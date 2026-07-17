# Replay 3D Mapbox — état & test (mis à jour dans la nuit du 17/07)

## ✅ TOUT EST FAIT — il ne reste qu'à builder sur ton Mac

Pendant la nuit :
- Compte Mapbox ✓ (toi) · token public `pk` intégré (encodé base64 dans
  `MapboxReplayConfig.swift` pour éviter les scanners du repo public) ✓
- Package SPM `mapbox-maps-ios` 11.8+ ajouté au projet Xcode (pbxproj) ✓
- **La CI compile déjà tout en vert, SDK inclus** — et bonne surprise : le
  téléchargement du SDK Mapbox ne demande plus d'authentification, donc ni
  `~/.netrc` ni secret GitHub ne sont nécessaires. Le token `sk` reste dans
  le `.env` au cas où Mapbox re-verrouille un jour.

## Pour tester demain matin

1. `git pull` sur ton Mac (branche v20).
2. Ouvre Xcode → il résout le package Mapbox tout seul (1-2 min la 1re fois).
   Si (improbable) il réclame une authentification : crée `~/.netrc` avec
   `machine api.mapbox.com` / `login mapbox` / `password <sk du .env>` puis
   `chmod 600 ~/.netrc`.
3. Build sur ton iPhone → ouvre n'importe quel vol avec trace → **Replay
   Flight** : c'est désormais le replay Mapbox (terrain 3D satellite, trace
   en altitude réelle colorée vario). Idem depuis un vol partagé (Explore).

## Ce que le replay Mapbox apporte

- **Terrain 3D réel** (relief ×1.3) + imagerie satellite.
- **Trace élevée à sa vraie altitude GPS** (impossible avec MapKit),
  gradient continu par vitesse verticale (vert = monte, rouge = descend).
- Caméra libre native : pincer = zoom, drag 2 doigts = inclinaison,
  rotation 2 doigts = orbite ; bouton follow (recolle au pilote), bouton
  map (vue d'ensemble), fly-in d'ouverture.
- Même moteur de lecture : scrubber par profil d'altitude, ×1/×4/×10/×30,
  HUD altitude/vario/heure.
- Fallback automatique : sans SDK ou sans token, l'ancien replay MapKit
  reprend (ReplayLauncherView) — rien ne casse jamais.

## Notes

- Facturation : 25 000 utilisateurs actifs/mois gratuits ; seuls ceux qui
  OUVRENT un replay comptent (MapKit partout ailleurs).
- La ligne élevée (`lineZOffset`) est une API expérimentale
  (`@_spi(Experimental)`). Si un futur bump du SDK la casse : supprimer les
  lignes marquées EXPERIMENTAL dans `configureStyle` de
  `MapboxFlightReplayView.swift` → ligne au sol, le reste intact.
- Le rendu 3D est à valider visuellement sur appareil (la CI ne teste que
  la compilation) : angle caméra, exagération terrain (1.3), largeur de
  ligne — dis-moi ce que tu veux ajuster.
