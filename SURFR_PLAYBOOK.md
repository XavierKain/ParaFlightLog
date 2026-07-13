# Surfr → SoarX — Carte de correspondance (kite → parapente)

*Analyse Surfr (thesurfr.app) réalisée le 2026-07-10, 4 volets sourcés (produit, spots/conditions/enrichissement, communauté/social, monétisation). Objectif : transposer ce que Surfr a réussi pour le kite vers le parapente soaring/air-surf. Complément visuel à venir via captures d'écran fournies par Xavier.*

---

## 1. Ce que Surfr a compris (les patterns à voler)

1. **Une métrique-signature propre au sport, faite à la perfection** : la hauteur de saut via IA on-device (pas de matériel). C'est leur identité et leur hook viral.
2. **Une boucle serrée** : `carte → riders en live → prévisions/alertes → enregistrer → feed → compétition/classement`. Tout tourne autour.
3. **L'enrichissement des spots par les vraies sessions** (« kiteability score », historique vent, sessions/mois, heatmap de popularité) — dérivé des tracks GPS, **sans balise**. = *exactement la vision de Xavier pour le parapente.*
4. **Présence live « qui est à l'eau »** (anneaux de couleur : en saut / posé / au repos) + boussole amis + alarme SOS vocale.
5. **Classements auto** depuis chaque session, multi-échelle (spot/pays/monde) × temps (jour/semaine/all-time), opt-in.
6. **Les alertes météo = le déclencheur maître de ré-engagement** (épingle un spot + seuil + fenêtre → push).
7. **Freemium 3 paliers** : cœur (tracking + sécurité + spots + classements + social) **gratuit**, on fait payer la profondeur (prévisions détaillées, analyse avancée, **replay 3D**, export). Bootstrap, ~100-150k users, pas de levée.
8. **Virality UGC** : export vidéo avec overlay de stats (« Surfie ») + concours communautaire avec vote.

## 2. Ce qui rend ça réaliste : on a déjà ~la moitié du squelette

| Brique Surfr | Notre état |
|---|---|
| Spots comme entités | ✅ (clé geohash) |
| **Données étiquetées vol × météo** | ✅ **snapshot météo-au-décollage sur chaque vol** = la donnée d'entraînement du score de flyability |
| Prévision par spot | ✅ Open-Meteo courant + 7 j |
| Présence « en vol » | ✅ (table `presence`, TTL 2 h) |
| Carte communautaire | ✅ Explore |
| Types de vol (soaring/air-surf/thermique) | ✅ |
| Replay 3D | ⚠️ existe mais **à refaire** (Surfr meilleur) |
| G-force, quiver/voiles, GPX/IGC | ✅ |
| **Notifications push** | ❌ **manquant — le vrai verrou** |

## 3. Où l'on peut faire MIEUX que Surfr

- **Report manuel de conditions** : Surfr **n'en a pas** (que la présence implicite). Ton combo *enrichissement auto par les vols + report manuel communautaire* est plus complet.
- **Vraies stations de vent** : non confirmé chez Surfr (leur « live wind » est peut-être du nowcast). Brancher Pioupiou/FFVL là où elles existent nous distingue.
- **Météo thermique** : Surfr est vent-de-surface only. Le parapente a besoin de plafond/thermique/CAPE — qu'Open-Meteo renvoie déjà.
- **Direction du vent alertes** : Surfr ne l'a toujours pas (backlog). Pour nous c'est critique sécurité → à faire dès le départ.

## 4. La carte de correspondance priorisée

**Tier 1 — La boucle différenciante (la vision de Xavier).**
| Feature Surfr | Adaptation SoarX | On a | Effort |
|---|---|---|---|
| Kiteability score + stats par spot depuis les sessions | **Flyability apprise** : agréger les snapshots météo-au-décollage → « ce spot vole en N/NE 10-18 km/h » + heatmap vols/mois ; seed ParaglidingEarth au démarrage | données ✅ | **M** |
| (absent chez Surfr) | **Report de conditions manuel** en 2 taps (force + direction + « ça vole / je vais voler / taille de voile ») → push aux amis/abonnés du spot | presence ✅ | **M** |
| Présence « qui est à l'eau » + anneaux | **« Qui vole maintenant »** enrichi (statut décollé/en vol/posé) | presence ✅ | S-M |
| Wind Alerts (épingle + seuil → push) | **Alertes flyability** : épingle un spot + seuil vent **max** + fenêtre direction → push | flyability ✅ | **M** |
| (infra) | **Push notifications** (Appwrite Messaging + tokens APNs) — *le verrou qui débloque presque tout* | ❌ | **M** (une fois) |

**Tier 2 — La boucle sociale/rétention.**
| Feature Surfr | Adaptation SoarX | Effort |
|---|---|---|
| Classements auto multi-échelle × temps | Classements par spot/région/monde × jour/semaine/all-time sur **métriques parapente** (airtime, gain d'altitude, distance, durée de soaring), opt-in | **M** |
| Badges PR + email classement fin de journée | « Nouveau record perso » sur la carte de vol + notif/email « tu es #3 à ton spot aujourd'hui » | S |
| Feed riche (commentaires/réactions/@mention) + profils | Carte de vol = objet social ; profils publics + follow + feed | **M** |
| **Métrique-signature (hauteur de saut)** | **Définir NOTRE métrique soaring/air-surf** (airtime ? gain max ? nb de passages ? « surf score » via G-force ?) — *décision à prendre* | design + S-M |

**Tier 3 — Média & viralité.**
| Feature Surfr | Adaptation SoarX | Effort |
|---|---|---|
| Replay 3D cinématique (payant) | **Refonte replay** → parité Surfr puis dépasser | M-L |
| « Surfie » (vidéo + overlay stats) + concours UGC | Export vidéo du vol avec overlay (altitude/vario/distance) + hashtag/concours | M |
| Tracks partagés | **Trace publique par défaut** (nourrit le feed) + **privée = payant** | M |

**Tier 4 — Plus tard / moat.**
- Prévision multi-modèles + thermique/plafond (dépasse Surfr) — M
- Stations de vent réelles (Pioupiou/FFVL) où elles existent — S-M
- Compétitions in-app + dashboards de site, quiver → reco de voile — L (partenariats)
- Boussole amis / alarme sécurité / coordination récup — M

## 5. Monétisation (le modèle Surfr, prouvé, + notre atout marques)

Surfr monétise **les utilisateurs** en freemium et ça marche à l'échelle niche (bootstrap, 100k+). On combine les deux :
- **Gratuit à vie** : enregistrement, logbook de base, spots, prévision de base (3 h), classements, présence, sécurité, reports.
- **Payant (façon Plus/PRO ~4-7 €/mois)** : prévisions détaillées + thermique, profondeur historique flyability, **replay 3D + export vidéo**, analyse avancée, export GPX/IGC, **trace privée** (la privacy-as-paid de Xavier), alertes avancées.
- **Notre ajout unique que Surfr n'a pas** : le **catalogue de voiles par marque** monétisé côté marques (pages vérifiées, lead-gen essai). Les utilisateurs financent la profondeur, les marques financent le catalogue/leads.

## 6. L'insight stratégique

Surfr **prouve le modèle** ET on a déjà ~la moitié du squelette (spots, snapshot météo = la donnée étiquetée, présence, types de vol, replay, quiver). **Le verrou unique est la notification push** : presque toutes les boucles à forte valeur (alertes, « tes amis volent », email classement, reports) en dépendent. → *Construire la brique push tôt débloque tout le reste.* Et il faut **décider notre métrique-signature soaring/air-surf** (l'équivalent de la hauteur de saut de Surfr) — c'est ce qui donne une identité et un hook viral.

## 7. Séquence de build recommandée

1. **Brique push** (Appwrite Messaging + tokens APNs) — l'infra qui débloque.
2. **Flyability apprise** depuis les snapshots existants + seed ParaglidingEarth (réutilise l'existant, cœur de la vision).
3. **Reports de conditions + abonnement spot + alertes** (là où on bat Surfr).
4. **Classements + PR + profils/feed** (boucle sociale).
5. **Refonte replay 3D + export vidéo** (média/viralité).
6. **Trace publique par défaut + privée payante** (bascule + monétisation).
7. Plus tard : thermique/multi-modèles, stations réelles, compétitions.

*Décisions en attente de Xavier :* (a) la métrique-signature soaring/air-surf ; (b) abo vs one-time pour la trace privée ; (c) feu vert sur la brique push (choix Appwrite Messaging vs autre).

---

## 8. Analyse visuelle — captures d'écran (2026-07-13)

*6 captures fournies par Xavier : profil pilote (Marc Remmerde), page spot Balneario (records, infos, forecast), stats de spot (Activity / Temp / Wind), reviews. Ce que les écrans révèlent au-delà de l'analyse produit du §1-7.*

### 8.1 La page spot Surfr, décomposée (l'écran le plus riche)

Ordre vertical chez Surfr : **nom + pays + distance + note ⭐ + "Suggest edit" → 4 records du spot → Spot Information (fiche structurée) → Live Wind → Wind Forecast (tableau horaire) → photos → Competitions → Leaderboard → Spot Statistics (5 onglets) → Sessions → Reviews.** Tout est sur UNE page scrollable — aucune navigation profonde. C'est la philosophie qu'on vient d'adopter (Conditions now en premier) ; à pousser jusqu'au bout.

### 8.2 Les bonnes idées à reprendre, priorisées

**A. Climatologie mensuelle du spot (onglets Wind/Temp/Activity) — LA meilleure idée des captures.**
Barres empilées par mois avec bandes de vent (<10 / 10-20 / 20-25 / 25-35 / 35+ kn), température jour/nuit, mois le plus actif. Répond à « quand venir à ce spot ? » = planification de trip, très fort pour un sport de voyage. **Notre atout : Open-Meteo expose gratuitement l'archive ERA5 (Historical Weather API)** → on peut calculer la climatologie de n'importe quel spot sans données utilisateur, puis la CROISER avec la fenêtre apprise du spot (« en mai, 62 % des jours dans ta fenêtre N/NE 10-18 km/h ») — un « % de jours volables par mois » qu'aucun concurrent parapente n'a. Effort **M**, données 100 % dispo.

**B. Records du spot + records perso (4 tuiles : highest jump / max airtime / max distance / max speed).**
Transposition directe : **plus long vol / plus longue session soaring / max heures dans une journée / record d'airtime au spot**, depuis `shared_flights` (agrégat déjà côté client). Sur le profil : les mêmes en PR personnels. Chaque record est un hook de compétition douce et alimente la future métrique-signature. Effort **S-M**.

**C. Tableau de prévision horaire compact** (heures × knots/gusts/direction/°C/météo, cellules colorées par force, chips de jours avec min/max, lever/coucher du soleil).
Bien plus dense et lisible que notre liste 7 jours. Open-Meteo renvoie déjà l'horaire + sunrise/sunset. La ligne **« ideal »** (verrouillée chez Surfr) = chez nous la fenêtre apprise → **une ligne « volable ✓/✗ » calculée par heure**, notre différenciateur affiché au cœur du forecast. Effort **M**.

**D. Reviews de spot** (résumé 4.6 + histogramme d'étoiles + avis texte + « crowd rate »).
Enrichissement communautaire complémentaire de nos reports temps réel : le report dit « ça vole maintenant », la review dit « ce spot vaut le détour / attention aux locaux / décollage technique ». Table Appwrite `spot_reviews` (1/user/spot, étoiles + texte + tags). Effort **M**.

**E. Fiche spot structurée + « Suggest edit »** (Disciplines, Facilities, Water, Crowd, Favours).
Version parapente : **orientation décollage (on l'a), altitude déco/atterro, difficulté (école→expert), dangers (câbles, rotors, espace aérien), accès (marche, navette), atterrissage officiel**. Le « Suggest edit » wiki-style évite le goulot d'étranglement d'un seul mainteneur. Effort **M**.

**F. Photos de spot** (galerie UGC « 16 images », +13 verrouillées derrière Plus).
Bucket Appwrite + upload à la création du report/vol. Les 3 premières gratuites, le reste en Plus = leur placement paywall le plus malin (contenu créé par les users, monétisé par la plateforme). Effort **M**.

**G. Profil pilote « héro »** (photo de couverture, drapeau, badge PRO, 801 sessions / 248 followers / 215 following, records).
Notre PublicProfileView est fonctionnel mais austère. Ajouter : photo/bannière, drapeau pays, compteurs en tête, records perso, et le **badge de rang dans la carte de vol** (« 1st in Ouddorp — Weekend Boosting ») qui transforme chaque vol partagé en mini-compétition. Effort **S-M** (hors compétitions).

**H. Trace GPS colorée par vitesse** sur la carte de session (dégradé vert→jaune→rouge).
Immédiatement lisible, très partageable. À appliquer à nos cartes de vol + replay (on a la vitesse par point). Effort **S** pour les vols locaux.

### 8.3 Leçons de placement paywall (confirmées visuellement)

Surfr verrouille : modèles météo haute précision (ICON-EU 7km vs GFS gratuit), la ligne « ideal/kite » du forecast, les photos au-delà de 3, l'historique long. **Jamais** le tracking, le social, les stats de base. → Confirme notre plan §5 : la ligne « volable » basique gratuite, le multi-modèles + climatologie profonde + % jours volables en Plus.

### 8.4 Ce qu'on ne copie PAS (pour l'instant)

- **Competitions in-app** (11 au spot, badges 1st) : gros système (inscriptions, périodes, anti-triche). Le leaderboard par spot qu'on a déjà couvre 80 % de la valeur. Plus tard.
- **Live Wind** : même Surfr affiche « coming soon ». Nos reports manuels + (plus tard) Pioupiou/FFVL font mieux.
- **Tides/Waves** : sans objet en parapente (remplacer par thermique/plafond à terme).

### 8.5 Séquence suggérée pour ces items visuels

1. **B. Records spot + perso** (S-M, réutilise les agrégats existants, effet immédiat).
2. **C. Forecast horaire + ligne « volable » + sunrise/sunset** (M, cœur météo).
3. **A. Climatologie mensuelle ERA5 × fenêtre apprise** (M, le différenciateur trip-planning).
4. **G. Profil héro + H. trace colorée** (S-M, polish social/média).
5. **D. Reviews + E. fiche structurée + F. photos** (M chacun, enrichissement long terme).
