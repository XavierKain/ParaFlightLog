# SoarX — Étude fonctionnalités & plan (sans implémentation)

**Date** : 2026-06-12 · **Demandeur** : Xavier · **Statut** : étude — rien n'est engagé.
Backlog source : `BACKLOG.md`. Études menées : Surfr App v4, Wingman, SoarX Voice (code local), faisabilité vario iOS/watchOS, React Native vs natif.

---

## Synthèse exécutive

1. **Le cœur historique de SoarX (heures par aile, possédée vs empruntée) est un différenciateur réel** : ni Wingman ni Surfr ne distinguent « heures du matériel » et « heures d'expérience pilote ». C'est peu coûteux (modèle de données + stats) et ça mérite d'être la prochaine brique.
2. **Le trio thermique de Wingman est réplicable sans serveur** : vario (baromètre + filtre de Kalman), trace colorée par taux de montée, détection auto décollage/atterrissage. Faisabilité confirmée (M, ~2-3 semaines pour le vario MVP).
3. **Surfr v4 valide un modèle de monétisation et une trajectoire produit** (tracking → météo/spots → social). Les étages 1 et 2 sont atteignables en local/CloudKit ; l'étage 3 (feed, live, leaderboards) **force une décision backend** — la seule vraie décision structurante de ce backlog.
4. **SoarX Voice** : c'est une app React Native sur Agora (radio vocale par canaux). L'intégration propre = réécrire l'UI en SwiftUI (~3-4 sem) en réutilisant ses 5 modules Swift natifs ; l'intégration rapide = lien entre les deux apps via URL scheme (~1-2 sem). Conflit principal : la session audio (vario + voice + musique simultanés à arbitrer).
5. **React Native : non.** L'app Watch (impossible en RN), CloudKit (inexistant sur Android) et la fiabilité GPS en vol (sécurité) rendent la réécriture contre-productive. Critère de réouverture du dossier plus bas.

---

## 1. Type de vol au démarrage — *quick win*

`Flight.flightType` existe déjà en base (rempli librement à l'édition). À faire :
- **Liste canonique** : Soaring, Thermique, Planée (glide), Airsurfing, Gonflage, Hike & Fly, Cross (+ libre).
- **Sélection au démarrage** : sur l'onglet Vol (iPhone) et l'écran Start (Watch — ajout au `FlightDTO` et à l'`applicationContext` pour la liste des types).
- **Exploitation** : filtre dans le Logbook, répartition par type dans les Stats, type par défaut mémorisé par spot (ex. à Fort Penthièvre → Soaring).

**Effort : S** (2-4 jours). Aucune dépendance. Migration douce : les valeurs libres existantes restent valides.

## 2. Voiles possédées vs utilisées — *le cœur de l'app, à finir*

Deux compteurs distincts, deux usages :

| | Mes voiles (possédées) | Voiles empruntées/testées |
|---|---|---|
| Heures **matériel** | ✅ total de l'aile → retrim, révision, revente | ❌ sans objet (pas ma maintenance) |
| Heures **expérience pilote** | ✅ | ✅ comptées par type + taille d'aile |

Modèle (extension `Wing`, compatible CloudKit — tout en valeurs par défaut) :
- `isOwned: Bool = true`, `purchaseDate: Date?`, `initialHours: Double = 0` (heures déjà au compteur à l'achat d'occasion), `soldDate: Date?` (remplace/complète l'archivage), `maintenanceIntervalHours: Double?` + `lastMaintenanceDate/Hours` (alerte retrim/révision).
- Stats nouvelles : « Mon expérience » agrégée **par type d'aile et par taille** (toutes voiles confondues, possédées ou non) ; « Mon matériel » : compteur d'heures par voile possédée (= initialHours + vols), badge d'alerte maintenance, encart « historique pour revente » (export PDF/image du carnet de la voile plus tard).
- UI : section « À moi / Empruntée » dans AddWing/EditWing, pastille visuelle dans la liste.

**Effort : S-M** (3-6 jours). Aucune dépendance. C'est la fonctionnalité que je recommande en premier : c'est l'ADN de l'app.

## 3. Vario iPhone + Watch — *faisable, validé par le marché*

Conclusions de l'étude technique (sources : doc Apple, forums dev, apps existantes) :
- **Capteur** : `CMAltimeter` ~1 Hz (imposé par Apple, non configurable) sur iPhone ; Watch Series 6+ OK. → on peut faire un **bon vario de confort thermique** (latence effective ~1,5-2,5 s), pas un concurrent des varios IMU dédiés à 0,1 s. À positionner comme « assistant thermique ».
- **Algorithme** : Kalman 2 états (altitude pression brute → Vz), ~80 lignes de Swift, transposable du projet open source `igorinov/variometer`. Fusion accéléromètre = v2 éventuelle.
- **Restitution** : iPhone = bips AVAudioEngine (fréquence/cadence suivant Vz), background mode `audio`, mixé avec la musique ; Watch = **haptique cadencée** (`WKInterfaceDevice.play`, fonctionne en background grâce au HKWorkoutSession qu'on a déjà) + option bips haut-parleur. Calcul **local à chaque appareil** (pas de streaming Watch↔iPhone, latence rédhibitoire).
- **Réglages exposés** (le standard Wingman) : seuil de bip montée + hystérésis, sink tone, alarme de taux de chute, on/off en vol.
- **Risques identifiés** : ① bug connu d'attribution du baromètre (la Watch peut renvoyer les données baro de l'iPhone en background workout — **spike de validation 2-3 jours en premier**) ; ② ne jamais mettre le workout en pause (offset baro documenté) ; ③ nouvelle permission Motion & Fitness.
- **Batterie** : négligeable devant le GPS déjà actif (~+2-5 %/h Watch).

**MVP** : toggle « Vario » sur l'écran de vol → haptique Watch (3 niveaux montée + alarme sink) + bips iPhone en arrière-plan + seuils configurables. **Effort : M** (~2-3 semaines, dont tuning en vol réel).

## 4. Analyse verticale des traces — *quick win complémentaire*

Les données existent déjà (GPSTrackPoint : altitude + timestamp toutes les 2 s) :
- **Vz calculée post-vol** sur la trace → **mode « thermal viewer »** : coloration de la trace par taux de montée (on a déjà la coloration par vitesse horizontale — c'est un 2e mode du même composant).
- **Graphe altitude/temps + Vz/temps** dans le détail du vol ; stats : gain cumulé, plafond, meilleure ascendance (m/s), hauteur gagnée à la corde/treuil (détectable : montée à faible vitesse sol en début de vol).
- Quand le vario sera là : enregistrer la Vz baro dans la trace (champ optionnel de GPSTrackPoint, rétro-compatible JSON).

**Effort : S-M** (3-5 jours). Recommandé en même temps que le n°1 ou juste après.

## 5. Enseignements Wingman (wingmanfly.app)

App iOS 4,8/5, freemium (PRO 9,99 $/mois ou 29,99 $/an, socle gratuit très large). Ce qu'on lui prend (priorisé) :
- **P0** : vario fusion capteurs + haptique Watch (n°3) ; trace colorée par Vz (n°4).
- **P1** : **détection auto décollage/atterrissage** (vitesse sol + variation d'altitude → démarre/arrête le workout, réduit la friction) ; **export IGC** (déjà au ROADMAP V10.1 — leur IGC signé accepté par XContest est l'objectif de phase 2) ; **estimation du vent en vol** (dérive des cercles en thermique — absente sur leur Watch : différenciateur possible pour SoarX au poignet).
- **P2** : finesse + altitude au-dessus du déco comme champs d'instruments ; replay 3D de la trace (MapKit terrain).
- **P3** : espaces aériens + alertes (gros chantier OpenAIP, eux-mêmes sont derrière FlySkyHy là-dessus — pas prioritaire).
- **À ne pas copier** : compte serveur obligatoire pour backup. Notre angle inverse : « vos vols restent chez vous (iCloud privé) ».

## 6. Enseignements Surfr v4 (kite)

Rebuild complet avril 2026, 150k+ riders, « 5 apps en 1 » (vent, spot, matos, tracking, partage). Transposition :

**Atteignable sans serveur (local/CloudKit)** : équivalents gains d'altitude/plafond/meilleure ascendance ; replay 3D ; coaching audio Watch (= notre vario + annonces vocales) ; quiver insights (= notre n°2, on va plus loin qu'eux avec possédée/empruntée) ; reco de voile selon vent prévu vs mon quiver ; auto-trim de la trace près du domicile avant partage (privacy, à reprendre) ; Watch autonome ; météo de site + « volable demain » via Open-Meteo (alertes locales planifiées, sans push serveur).

**Exige un backend** : feed social (For You, commentaires, GIF), riders/pilotes en live sur la carte, leaderboards/compétitions, parrainage. CloudKit public database peut couvrir un **annuaire de spots communautaire en lecture/contribution simple**, pas un vrai réseau social.

**Modèle d'abonnement Surfr (fourchettes de marché validées)** :
| | Free | Plus (~4 €/mois, 29 $/an) | PRO (~7 €/mois, 65 $/an) |
|---|---|---|---|
| Logique | tracking de base illimité | l'**analyse** (détails, stats matos, alertes vent) | la **3D, le coaching, la montre autonome, les compétitions** |

Transposé à SoarX si monétisation un jour : Free = carnet complet (jamais brider les données du pilote) ; Plus = analyses avancées (thermal viewer, stats par voile, alertes météo) ; PRO = vario+coaching vocal, replay 3D, communautaire.

## 7. Intégration SoarX Voice

État du projet (`/Users/xavier/VSCode3/SoarXVoice`) : app **React Native 0.84 + TypeScript** (~3 200 lignes TS + 815 lignes Swift), radio vocale par canaux sur **Agora RTC** (SaaS), v1.6.1 en TestFlight, mature et active. Fonction : canaux vocaux nommés (« TARIFA-01 »), mute par bouton BLE (iTag) ou commande casque, annonces TTS, auto-déconnexion d'inactivité.

Deux options :

| | A. Intégration native dans SoarX (recommandée à terme) | B. Deux apps liées (rapide) |
|---|---|---|
| Principe | Réécrire l'UI en SwiftUI ; **réutiliser tels quels les 5 modules Swift existants** (AudioSessionManager, BLEButtonManager, HIDModule, TTSManager, HapticManager) ; porter la logique Agora (580 lignes TS) en service `@Observable` avec le SDK Agora natif iOS | SoarX ouvre SoarX Voice via URL scheme (`soarxvoice://join?channel=…`), p.ex. bouton « Radio » sur l'écran de vol qui propose le canal du spot |
| Effort | **M-L (3-4 semaines)** | **S (1-2 semaines)** |
| Points durs | Arbitrage **AVAudioSession** entre vario (bips) + voice (voip) + musique ; batterie GPS+audio+BLE en vol ; dépendance Agora (coût/compte) entre dans SoarX | Expérience moins intégrée ; double maintenance |

Recommandation : **B d'abord** (lien inter-apps, zéro risque pour SoarX), A plus tard si l'usage le justifie — idéalement **après** le vario, pour concevoir l'arbitrage audio une seule fois.

## 8. React Native / Android — décision : NON

- Une app **watchOS ne peut pas être écrite en React Native** (confirmé 2026) → il faudrait garder ~40 % du code en Swift de toute façon (Watch + widgets + pont), pour une Watch qui est notre différenciateur.
- **CloudKit n'existe pas sur Android** → retour obligatoire à un backend serveur (Firebase/Supabase/PowerSync)… qu'on vient de supprimer (Appwrite) volontairement.
- **GPS background Android** : foreground service, Doze, OEM killers (Samsung/Xiaomi) — issues ouvertes depuis des années ; pour une app où perdre la trace en vol est un problème de sécurité, risque réel.
- Effort estimé d'une réécriture : **6-12 mois solo**, pendant lesquels la roadmap (vario, types de vol, communautaire) serait gelée.

**Critère de réouverture du dossier** : ≥ 20-30 utilisateurs Android identifiés qui demandent activement l'app. À ce moment-là : app **Android native minimale** (Kotlin/Compose, ou Skip.dev si mûr) limitée au carnet + carte, **pas** de portage RN. En attendant, le geste à faible coût pour les amis Android : **export GPX/IGC + page web statique de partage d'un vol** (~1 % de l'effort, 80 % du besoin « regarde mon vol »).

---

## Plan proposé (à valider — aucune implémentation engagée)

**Phase A — « le cœur » (1-2 semaines)**
1. Voiles possédées vs empruntées + compteurs maintenance (n°2) — **S-M**
2. Type de vol au démarrage iPhone + Watch (n°1) — **S**
3. Analyse verticale post-vol : thermal viewer + graphes altitude/Vz (n°4) — **S-M**

**Phase B — « le thermique » (3-4 semaines)**
4. Spike capteurs 2-3 jours (bug baro Watch/iPhone en background) → **GO/NO-GO vario**
5. Vario MVP iPhone + Watch (n°3) — **M**
6. Détection auto décollage/atterrissage — **S-M**
7. Export IGC (ROADMAP V10.1, synergique avec le thermal viewer) — **S-M**

**Phase C — « la radio » (1-2 semaines puis réévaluation)**
8. Lien SoarX → SoarX Voice par URL scheme (option B) — **S**
9. (plus tard) intégration native complète — **M-L**

**Phase D — « le communautaire » (à décider)**
10. **Décision structurante backend** : rien / CloudKit public (spots partagés, léger) / vrai backend (feed, live, leaderboards à la Surfr). Je recommande de ne PAS trancher avant la fin des phases A-B : elles créent la valeur qui justifierait (ou non) l'investissement serveur + la monétisation freemium qui le financerait.

**Décisions attendues de Xavier** : ① validation de l'ordre des phases ; ② vario : positionnement « assistant thermique » accepté ? ③ Voice : option B d'abord ? ④ communautaire/backend : on en reparle après phase B ? ⑤ Android : critère de réouverture OK ?

---

## Sources principales

- Surfr : thesurfr.app (landing v4, release v3, help center), App Store id1527010145, Google Play com.kiter, kiteforum.com, olekite.com, kitemadworld.com
- Wingman : wingmanfly.app (+Help/FAQ/blog), App Store id1563883190, paraglidingforum.com (t=113200, t=115762)
- Vario : developer.apple.com (CMAltimeter, threads 123983/683056/654116/52630), theflightvario.com, github.com/igorinov/variometer, github.com/ghf20/ESP32-Realtime-Vario, vario-one.com, evario.variosoft.eu
- React Native : docs.expo.dev (location, new-architecture, barometer), github.com/expo/expo issues #14076/#30435, kotlinlang.org (KMP), skip.dev, statista.com (parts smartwatch), powersync.com
- SoarX Voice : analyse du code local `/Users/xavier/VSCode3/SoarXVoice` (33 commits, v1.6.1 TestFlight)
