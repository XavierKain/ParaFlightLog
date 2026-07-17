# Plan de test — bêta amis (TestFlight)

Objectif : distribuer l'app à tes amis **sans bug bloquant, tout fonctionnel**.
Trois niveaux : ce que la CI vérifie déjà toute seule, la passe manuelle à
faire sur TES appareils avant l'invitation, et la checklist de distribution.

## 0. Automatique (déjà en place, à chaque push)

- Build iOS + watchOS + widget (CI GitHub, simulateur).
- Tests unitaires : backup v1/v2, GPX/IGC import/export, flyability, geohash,
  modèles Flight/Wing, **payload de trace partagée (round-trip, downsample,
  fail-soft)**, **climatologie (parts par bande, % volable, secteurs
  voisins)**, **échelle de vent des reports (bandes contiguës, unités)**.

## 1. Passe fondamentale (1 h, iPhone + Watch réels)

### Vol & tracking (le cœur — zéro tolérance)
- [ ] Vol simulé complet depuis la Watch (Developer mode → Simulate flight on
      Watch) : départ, feed live (alti/vitesse/G), arrêt → le vol arrive sur
      l'iPhone avec trace, durée, spot auto-créé.
- [ ] Vol simulé iPhone (Simulate a Flight (Live)) : idem + vario sonore.
- [ ] Watch hors de portée pendant le vol → le vol reste dans l'outbox Watch
      et se synchronise à la reconnexion (rien de perdu).
- [ ] Tuer l'app iPhone pendant un vol Watch → pas de crash, sync au retour.
- [ ] Vol < 1 min, vol avec 0 point GPS (indoor) → sauvegarde propre, pas de
      crash dans le détail/replay.
- [ ] **Trim** : vol simulé long → Export menu → Trim flight → couper la fin
      → durée/stats recalculées, la version communautaire mise à jour.

### Detail de vol & replays
- [ ] Carte du vol : trace colorée par vitesse, marqueurs takeoff/landing.
- [ ] Replay MapKit : lecture, vitesses ×1/×4/×10/×30, scrub, gestes caméra.
- [ ] Replay Mapbox (si activé) : terrain 3D, ligne en altitude colorée
      vario, follow/overview, gestes — ET fallback MapKit propre si pas de
      réseau la première fois (tuiles absentes ≠ crash).
- [ ] Export GPX et IGC → réimport du fichier exporté = mêmes stats.

### Spots
- [ ] Page spot : ordre des sections (Conditions now → records → identité →
      orientations → météo → bandeau horaire → climatologie → learned →
      community → vols).
- [ ] Bandeau horaire 48 h : couleurs cohérentes avec les orientations ;
      spot SANS orientation → cellules grises, pas de crash.
- [ ] "Best months to fly" : s'affiche après quelques secondes (1er fetch
      ERA5), puis instantané (cache 30 j). Spot sans coordonnées → absent.
- [ ] Split par GPS, renommage, réassignation de vols, suppression de spot.

### Communauté (2 comptes — voir TESTING_COMMUNITY.md pour le protocole)
- [ ] Report de conditions : ouverture du sheet du 1er coup, préremplissage
      voile (modèle + taille du spot), post → visible côté compte B, UNE
      seule entrée par report.
- [ ] Report depuis Explore (spot communautaire, sans spot local).
- [ ] Report déconnecté → formulaire de connexion INTÉGRÉ fonctionne
      (sign-in ET création de compte).
- [ ] Vol partagé : visible côté B avec trace GPS + stats + replay 3D ;
      vol partagé SANS trace (toggle off) → détail dégradé propre.
- [ ] Profil pilote : héro, records, follow/unfollow, kudos aller-retour.
- [ ] Find Pilots : recherche par nom, invitation ShareLink.
- [ ] Push : report du compte B sur spot suivi par A → push < 30 s, le tap
      ouvre le spot (app fermée ET app ouverte).
- [ ] Leaderboard, feed, présence "flying now" (heartbeat + expiration 2 h).

### Résilience (ce qui casse les bêtas)
- [ ] **Mode avion total** : l'app démarre, les vols se sauvegardent, toutes
      les sections communautaires se cachent ou montrent l'état stale — zéro
      spinner infini, zéro crash. C'est LE test n°1 avant distribution.
- [ ] Compte tout neuf, zéro donnée : onboarding → ajout d'une voile depuis
      la bibliothèque (les 23 ailes + images) → premier vol simulé.
- [ ] Import backup de ton vrai compte (276 vols) → stats, spots, pas de
      doublons ; re-import du même backup → toujours pas de doublons.
- [ ] iPhone en français ET en anglais (l'UI est EN ; vérifier les dates).
- [ ] Batterie/mémoire : replay Mapbox 10 min → pas de surchauffe anormale.

## 2. Avant d'inviter les amis (checklist distribution)

- [ ] **Developer mode OFF par défaut** chez un nouvel utilisateur (vérifier
      qu'aucun outil dev n'est visible sans l'activer).
- [ ] APNs : l'entitlement passe en `production` sur TestFlight — vérifier
      qu'une push arrive sur un build TestFlight (pas seulement Xcode).
      Console Appwrite : provider APNs → Sandbox OFF pour ce test.
- [ ] Quotas Appwrite (plan gratuit) : 5-10 amis OK, mais surveiller
      Console → Usage la première semaine (rate limits sur les writes).
- [ ] Le token Mapbox est restreint : dashboard Mapbox → token pk → URL
      restrictions ne s'appliquent pas à iOS, mais surveiller Usage
      (25 000 MAU gratuits, seuls les replays comptent).
- [ ] Version/build bump + notes TestFlight : dire quoi tester (vol simulé,
      partage, reports, replay) et comment signaler un bug.
- [ ] Chaque ami : compte Appwrite = email/mot de passe ≥ 8 caractères —
      le mentionner dans les notes d'invitation.
- [ ] Plan de rollback : les tables v20 sont séparées de l'ancien backend ;
      un bug de données bêta ne touche jamais tes vraies données locales.

## 3. Scénarios amis (à leur donner comme missions)

1. "Installe, crée ton compte, ajoute ta voile, fais un vol simulé."
2. "Active le partage, partage ton vol, suis Xavier, mets un kudo."
3. "Poste un report de conditions sur le spot de Xavier."
4. "Regarde le replay 3D du vol de Xavier depuis Explore."
5. "Coupe le réseau et vérifie que tu peux toujours voir tes vols."
