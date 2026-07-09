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
