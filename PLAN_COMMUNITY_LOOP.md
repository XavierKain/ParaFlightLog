# Plan d'implémentation — La boucle communautaire SoarX (inspirée Surfr)

*Planifié le 2026-07-10 (Fable). Implémentation par agents Opus 4.8. Source stratégique : SURFR_PLAYBOOK.md.*

Boucle cible : `carte → qui vole → conditions (apprises + reportées) → alertes push → enregistrer → feed/classements`.

---

## Phase 1 — Brique push (le verrou qui débloque tout)

**Architecture** : APNs via **Appwrite Messaging** + une **Appwrite Function** de fan-out.
- **Client iOS** : `PushService` — demande d'autorisation UNUserNotificationCenter, enregistrement APNs, envoi du device token à Appwrite (`account.createPushTarget`), gestion du tap sur notification (deep link spot/vol). Enregistré au sign-in, rafraîchi au launch, supprimé au sign-out.
- **Serveur** : Function Node.js `notify-fanout`, déclenchée par événement de création de document sur `spot_reports` (et plus tard `shared_flights`/presence) : lit les abonnés du spot (`spot_subscriptions`) + les followers de l'auteur (phase 4), déduplique, envoie via Messaging (`messaging.createPush` ciblé par userIds/targets).
- **Étape manuelle Xavier (5 min, documentée)** : créer une clé APNs (.p8) dans le portail Apple Developer et la coller dans Appwrite Console → Messaging → Provider APNs (team ID, key ID, bundle ID `com.xavierkain.ParaFlightLog2`, sandbox pour dev). Sans ça, tout est en place et fail-soft.
- **Tables** : `spot_subscriptions` (docID = `userId_spotKeyHash`, champs userId, spotKey, spotName, notifyReports, notifyPresence, createdAt).

## Phase 2 — Flyability apprise (le cœur de la vision)

- **Données** : les vols locaux portent déjà `takeoffWindSpeed/Gusts/Direction/Temperature`. Ajouter ces 3 champs optionnels à `shared_flights` (upload avec le résumé, opt-in existant) → apprentissage **communautaire** par spot.
- **Nouveau service `SpotIntelligenceService`** :
  - `learnedWindow(spotKey)` : agrège les vols (locaux + communautaires) → histogramme direction×force → « fenêtre volable » (secteurs + plage de vitesse, nb de vols en support, par type de vol si volume suffisant).
  - `seed` ParaglidingEarth (API publique, orientations 0/1/2) quand < N vols appris ; fallback = orientations configurées à la main.
  - `flyabilityV2(spot, forecast)` : score = fenêtre apprise × prévision (direction ET force), avec libellé provenance (« appris de 23 vols » / « orientations du spot »).
- **UI** : page spot — bloc « Ce spot vole quand… » (rose des vents apprise + plage) ; Explore — pastilles colorées par flyabilityV2 ; dashboard réutilise.

## Phase 3 — Reports de conditions (là où on bat Surfr)

- **Table `spot_reports`** : spotKey, spotName, userId, pilotName, status (flying|goingToFly|flyable|notFlyable|tooStrong), windDirectionDeg, windForce (calm|light|moderate|strong|tooMuch), wingSize?, note?, createdAt, expiresAt (TTL 3 h). Row security, read any, create users.
- **UI 2 taps** : bouton « Report conditions » sur page spot + dashboard ; sheet : puces statut (1 tap) + force (1 tap) ; direction pré-remplie (prévision Open-Meteo du spot, modifiable via cadran 8 points) ; taille de voile pré-remplie depuis la voile par défaut ; note/photo optionnelles v2.
- **Affichage** : page spot & Explore sheet — « consensus » (dernier report < 3 h : statut + vent + fraîcheur) + liste des reports récents ; badge sur la carte Explore quand un report frais existe.
- **Abonnement spot** : bouton « Suivre ce spot » → `spot_subscriptions` → la Function push notifie (« 🪂 Xavier vole à Dune du Pilat — SW modéré »).
- **Watch (v2)** : report statut+force depuis la Watch.

## Phase 4 — Boucle sociale (profils, follow, feed, classements)

- Tables : `profiles` (docID = userId : pilotName, bio?, homeSpotKey?, statsPublic), `follows` (followerId, followedId). Feed = requête shared_flights des suivis (client-side v1).
- Classements par spot × période (jour/semaine/all-time) sur airtime/durée/nb vols — depuis shared_flights, opt-in.
- Badges record perso (plus long vol, plus haut gain) sur la carte de vol + notif.
- **Métrique-signature soaring/air-surf : DÉCISION XAVIER en attente** — candidats : airtime total, gain max, « surf score » (G-force + passages). Le schéma réserve un champ `signatureScore` optionnel.

## Phase 5 — Média (refonte replay 3D, export vidéo)

- Replay : parité Wingman d'abord (caméra plus stable, terrain hybrid realistic, transitions, timeline propre), puis nos subtilités (comète/vario). Bench sur les vols réels de Xavier.
- Export vidéo verticale avec overlay stats (ReplayKit/AVFoundation) — candidat payant.

## Phase 6 — Trace publique par défaut + privée payante

- Upload de la trace GPS compressée avec le résumé partagé (table `shared_tracks`, payload string compressé ; ou champ dans shared_flights si < limites).
- Toggle « private track » par vol : **gratuit au début**, basculera payant (StoreKit) quand la monétisation ouvre — mécanisme prévu, paywall différé (DÉCISION XAVIER : abo vs one-time).

## Ordre d'exécution & dépendances

1. Tables Appwrite (fait par le coordinateur via API) → 2. Phase 1 client+function ∥ Phase 2 ∥ Phase 3 UI (fichiers disjoints) → CI → 3. Phase 4 → 4. Phases 5/6.
Chaque phase : agents Opus 4.8, fichiers disjoints, staging sans commit, commit+push+CI par le coordinateur, revue adversariale sur les grosses phases.

## Garde-fous

- Tout fail-soft si backend/APNs non configurés (pattern existant).
- Jamais de trace GPS dans shared_flights/reports (résumés + vent seulement) tant que la Phase 6 n'est pas explicitement activée.
- Open-Meteo : rester non-commercial tant que pas de monétisation active.
