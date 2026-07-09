# SoarX — Analyse de marché & monétisation (parapente / vol libre)

*Rédigé le 2026-07-09 à partir d'une recherche web sourcée (5 volets : nav/instrument, logbook/social, Apple Watch & replay 3D, météo, monétisation). Toutes les affirmations chiffrées renvoient à une source ; les prix « (approx) » sont à revérifier avant de les citer.*

---

## 0. Verdict en une page

- **On ne développe PAS un doublon.** Le seul concurrent qui occupe exactement notre positionnement (Apple-Watch-first + logbook + replay 3D + design propre) est **Wingman** — bien exécuté et mis à jour chaque semaine. C'est LA menace à surveiller, pas les instruments de nav.
- **On ne joue pas contre XCTrack / SeeYou / Flymaster** (calculateurs de vol pour compétiteurs XC) ni contre **XContest** (scoring de compétition, ~40 000 pilotes, culture « trace publique »). Ces catégories sont des forteresses ; on est **complémentaire**, pas concurrent.
- **Le siège « Strava du vol libre casual » est libre** : Strava n'a même pas le type d'activité parapente, Ayvri et Fatmap (replay 3D) sont morts, et aucun concurrent ne combine *tracking Watch-first + social respectueux de la vie privée + découverte par spot*.
- **Notre différenciation la plus nette = le modèle privé « résumé seulement »** (l'inverse de la culture trace-publique) + **Watch-first Apple** + **replay 3D cinématique** + un **catalogue de voiles structuré par marque** (alors que le catalogue neutre historique para2000 est en train de mourir).
- **Manque n°1 à combler : la conscience de l'espace aérien** (alerte de proximité légère, Wingman l'a déjà). Puis : **vent live des balises** (gratuit via Pioupiou) et **profils/follow + feed léger**.
- **Monétisation : viser les marques, pas l'utilisateur.** Aucune plateforme financée par les marques n'existe dans ce créneau — c'est un espace vide. On est assis sur les deux actifs que les marques veulent le plus influencer : **le catalogue de voiles (la décision d'achat à ~4 000 €)** et **les spots/communauté (où volent les pilotes)**.

---

## 1. Contexte marché (fixe le plafond de toute stratégie)

- **~780 000 pilotes brevetés actifs** dans le monde (~92 fédérations), **~58 000 nouveaux/an**, ~520+ écoles. Audience **petite** → on ne gagne pas au volume de pub, on gagne sur les **transactions à fort ticket et forte intention**.
- **Marché équipement ≈ 270–490 M$/an.** Une **voile neuve = 3 000–5 000 $**, kit complet 5 000–8 000 $, voile remplacée tous les **2–4 ans**. → *Une seule vente de voile vaut plus que des années d'abonnement d'un utilisateur.* C'est le chiffre qui rend le modèle « marques » viable.

---

## 2. Panorama par catégorie & où l'on se situe

### A. Instruments de nav in-flight — *complémentaires, on n'y va pas*
| Produit | Plateforme | Prix | Public |
|---|---|---|---|
| XCTrack / Pro | **Android seul** | Gratuit + Pro (~50 €/an, offert sur Air³) | XC/compét (leader) |
| SeeYou Navigator (Naviter) | iOS+Android | ~58 €/an (bundle) | XC/compét |
| Flyskyhy | **iOS, pas de Watch** | 8,99 $ + IAP | pilote iOS sérieux |
| XCSoar | multi, open-source | Gratuit | XC tactique/planeur |
| Air³ / Flymaster / Syride / Skytraxx | **matériel dédié** 200–1 500 $ | app = companion gratuit | XC/hike&fly/compét |

Tous ont **espace aérien + assistant thermique + optimisation XC + FLARM/FANET**. **Aucun ne tourne sur Apple Watch.** Effort/audience incompatibles avec nous → **on reste le logbook + conditions + social, le pilote peut voler avec XCTrack ET nous.**

### B. Enregistreurs Apple-Watch-natifs — *NOTRE arène (créneau mince)*
| App | Watch | Note App Store | Modèle | Replay 3D |
|---|---|---|---|---|
| **Wingman** | **Standalone** (sans tel) + alertes espace aérien | **4,8 / 101** | Free + PRO 9,99 $/mois, 29,99 $/an | Oui (concurrent direct) |
| **Vario One** | Standalone | **1,0 / 2** (mal reçu) | Abo 22,99 $/an | Logbook limité |
| Variometer+ | Vario live seul | 4,8 / 26 | Free + IAP | Non |
| **Gaggle** | **Companion seulement** | **4,8 / 743** (leader volume) | Free + 8,99/12,99 $/mois | Oui |

**Lecture :** Gaggle = leader en volume mais Watch companion + orienté paramoteur/calculateur lourd. Wingman = leader design/Watch mais abonnement. Vario One = notre niche exacte mais **mal noté = opportunité de positionnement.**

### C. Logbook / social / live-tracking
- **XContest** possède le **scoring XC** (culture *trace publique*). **LiveTrack24** = colonne vertébrale du **live-tracking** cellulaire. **Airtribune** = tracking de compét. **Syride Sy'Log** (~13k) = comparaison par-site (proche de nos stats par spot). **SkyViz** = logbook web + **replay 3D → vidéo verticale IG/TikTok** (freemium — monétise exactement le média).
- **Strava n'a PAS le parapente** (demande ouverte). **Ayvri (2022) et Fatmap (2024) ont fermé** → **trou réel sur le replay 3D partageable.**

### D. Météo (la seule catégorie où les pilotes PAIENT)
| Service | Prix | Force | Watch |
|---|---|---|---|
| Windy + Premium | ~23 £/an | tous modèles gratuits, radar, webcams | **Oui** |
| Meteo-Parapente | 36 €/an | thermique/plafond fin (modèle propre) | Non |
| **Burnair** | ~129 CHF/an | **thermique + balises live (Holfuy/Pioupiou/FFVL) + flyability** ← *le modèle à viser* | — |
| SkySight | 89 $/an | NWP soaring haut de gamme | Non |
| Paraglidable | Gratuit (ML) | **score flyability/XC par site** (réseau de neurones) | Non |
| Windguru | ~16 €/an | énorme base de spots + stations | limité |

Nous : **Open-Meteo (gratuit, sans clé) + flyability par orientation de décollage**. Verdict « volable ? » que la plupart des pros refusent de donner = atout débutant/inter. Manques : pas de **thermique/plafond/XC**, pas de **balises live**, pas d'**alertes bon jour**.

---

## 3. Notre différenciation (ce qu'on fait mieux / d'unique)

1. **Watch-first Apple, casual.** Toute la concurrence sérieuse est Android/instrument. Créneau mince (Wingman fort, Vario One faible). Notre moat = **qualité & fiabilité du Watch** : récupération après crash, outbox fiable, G-force, sélecteur de type de vol au poignet — que Wingman ne revendique pas.
2. **Modèle privé « résumé seulement » (opt-in).** L'inverse de la culture XContest « publie ta trace ». Strava a prouvé que le grand public veut le contrôle de sa vie privée. **Identité défendable : « le carnet de vol qui ne révèle pas où tu voles ».**
3. **Présence « en vol maintenant » (TTL 2 h).** Capte 80 % de la valeur sociale du live-tracking (« ça vole aujourd'hui ? ») sans diffuser de position (ni risque ni responsabilité). Personne ne le cadre ainsi.
4. **Spot = entité + météo/flyability fusionnées** dans une app grand public propre.
5. **Replay 3D cinématique** (caméra de poursuite, traînée comète, dégradé vario) — remplit le vide laissé par Ayvri ; plus filmique que le replay « carte » de Wingman. **Notre meilleur atout marketing** (visuel, partageable → captures App Store + clips sociaux).
6. **Catalogue de voiles par marque** — para2000 (catalogue neutre historique) meurt (~295 visites/mois) → **on peut devenir l'autorité neutre**. C'est aussi notre 1er actif de monétisation.

---

## 4. Ce qui nous manque — priorisé (à intégrer)

| # | Feature | Pourquoi | Effort |
|---|---|---|---|
| 1 | **Alerte de proximité espace aérien** (données OpenAIP/OpenAir) — affichage + alerte haptique à l'approche, PAS un calculateur | Manque n°1 de la catégorie ; Wingman l'a ; sécurité ; notre public côtier/casual vole près des CTR | **M** |
| 2 | **Vent live des balises** : Pioupiou/OpenWindMap (gratuit, usage commercial OK, sans clé) puis FFVL (France) ; + **enrichir l'appel Open-Meteo existant** avec CAPE/plafond/hauteur de couche (quasi zéro effort) | Plus gros manque *ressenti* en météo ; les pilotes vérifient les balises avant de rouler | **S→M** |
| 3 | **Spots + orientations depuis ParaglidingEarth** (API publique, orientations par direction 0/1/2 = exactement notre modèle) | Auto-remplit les spots + orientations mondialement, réduit la config manuelle | **S→M** |
| 4 | **Profils pilotes publics + follow + feed léger + kudos** (résumé seulement) | Le vrai écart entre « logbook » et « app sociale » ; boucle de rétention Strava ; déjà à la roadmap | **M** |
| 5 | **Classements par spot / « légendes du site »** (privacy-safe, dérivés des résumés) | Statut sans scoring XC ; différenciateur vs le ranking « élitiste » d'XContest | **M** |
| 6 | **Soumission IGC/XContest en un tap** (on exporte déjà l'IGC) | Retient les pilotes XC-curieux qui partiraient sur XCTrack | **S→M** |
| 7 | **Export replay 3D → vidéo verticale** (vide Ayvri, SkyViz le monétise) | Viralité top-of-funnel IG/TikTok, compatible vie privée (l'utilisateur choisit) | **M→L** |
| 8 | **Vario acoustique en vol sur la Watch** (on a déjà la donnée baro/vario) | Transforme un enregistreur passif en outil *utilisé* en vol ; approfondit le moat Watch | **S→M** |
| 9 | **Rappels d'entretien matériel** (repliage secours, révision voile, heures) | Les casual y tiennent ; on a déjà le logbook par voile | **S** |
| 10 | **Alertes « bon jour »** sur le score flyability existant | Feature payante ailleurs (Windy Premium) ; on calcule déjà le score | **S** |

**À surveiller :** Wingman itère chaque semaine et occupe notre position. Se différencier concrètement : **fiabilité Watch (crash recovery, outbox, G-force, type de vol au poignet) + beauté du replay + modèle gratuit/pas cher.**

---

## 5. Ce qu'il NE faut PAS construire

- **Diffusion GPS temps réel en vol.** LiveTrack24/FANET/OGN le possèdent ; responsabilité + course à l'armement + contredit notre identité privée. Notre présence 2 h suffit.
- **Scoring XC / ligues / optimisation triangle.** Moat XContest/DHV/FFVL insurmontable. Plutôt : *lier* une référence de vol XContest sur un résumé.
- **Partage public de traces complètes.** Effacerait notre différenciateur le plus clair. Traces privées ; seulement export vidéo à l'initiative de l'utilisateur.
- **Commentaires publics threadés (au début).** Coût de modération/toxicité > valeur à petite échelle ; les réactions (kudos) suffisent.
- **Nav in-flight complète** (routage espace aérien, assistant thermique, FANET RF) — effort énorme, mauvais public, moat des instruments.

---

## 6. Monétisation

### Constat
- Le logiciel de vol libre est une **course à 0 €** (donationware ou subventionné par le matériel). **La météo est la seule catégorie où les pilotes paient** (SkySight 89 $/an sans broncher). **Aucune app financée par les marques n'existe** = espace vide. **Leçon Komoot** : basculer une base gratuite en abonnement forcé brûle la confiance (rachat Bending Spoons, ~80 % de licenciements).
- Playbooks transférables prouvés : **Strava Sponsored Challenges (à partir de 30 000 $)** + **Strava Metro** (données agrégées) ; **Trailforks sponsor-a-trail/region** ; **Windy API** (B2B météo) ; **SkyViz** (média 3D payant).

### Playbook SoarX (marques d'abord, phasé)

**Phase 1 (0–6 mois) — Monétiser l'actif qu'on a déjà, sans échelle requise**
- **① Catalogue de voiles vérifié** : flow « revendique ta marque » → pages officielles enrichies (specs, photos, PDF de certif, CTA « demander un essai / trouver un revendeur »). On devient l'autorité neutre que para2000 n'est plus. **~500–3 000 $/marque/an × 10–20 = 10–40 k$/an.** Effort L→M, **risque confiance faible** (ne jamais laisser le paiement réordonner une comparaison objective de specs).
- **② Lead-gen essai/revendeur** (commission ou coût par lead) : au moment « je change de voile », router un clic essai/devis vers revendeur/marque. Ticket ~4 000 $ → même 3–5 % compte. **20–80 k$/an à échelle modérée.** Risque **moyen** (jamais spammy, cadre « utile quand tu shoppes vraiment »).

**Phase 2 (6–18 mois, dès qu'il y a une base active visible)**
- **③ Spots/régions sponsorisés** (écoles, flight-parks, offices de tourisme — modèle Trailforks). **200–2 000 $/spot/an.**
- **④ Défis sponsorisés par marques** (modèle Strava, réduit au créneau). **2–15 k$/défi.** Nécessite l'échelle pilote d'abord.
- *Backstop optionnel non-coercitif :* premium utilisateur sur le **média (replay/vidéo 3D)** et la **météo premium** — **achat unique ou petit annuel** (façon Flyskyhy 8,99 $), jamais le logging cœur ni la sécurité.

**Phase 3 (18 mois+, à l'échelle, avec consentement carré)**
- **⑤ Insights agrégés anonymisés opt-in aux marques** (« quelles voiles sont volées, où, combien, quand les pilotes upgradent ») — données que personne ne peut acheter aujourd'hui (analogie Strava Metro). **Plus forte marge** mais **plus fort risque confiance** → strictement opt-in, agrégé, jamais individuel, jamais vendu aux assureurs de façon à tarifer un individu.
- **⑥ API météo B2B** (modèle Windy) une fois la couche météo assez forte.

### Garde-fous
- **Cœur gratuit à vie** (logbook, Watch, catalogue, spots, météo de base). Les marques paient.
- **Jamais** de paiement qui réordonne les specs objectives ou masque une info sécurité/danger.
- **Caveat licence Open-Meteo** : la version gratuite est **non-commerciale**. Dès qu'on monétise (abo/pub), il faut un plan payant (~29 $/mois) + attribution CC-BY. À budgéter *avant* de monétiser.

### La phrase stratégique
> On est assis sur les deux actifs que les marques veulent le plus influencer — **le catalogue de voiles (la décision d'achat à ~4 000 €)** et **les spots/communauté (où et avec qui volent les pilotes)** — dans un créneau où **aucune plateforme financée par les marques n'existe et où le catalogue neutre historique meurt.** On monétise le désir des marques d'être choisies au moment des 4 000 €, on garde les pilotes gratuits, et l'abonnement utilisateur reste un simple backstop média/météo optionnel.

---

## 7. Recommandation de prochaines étapes

1. **Court terme produit** : alerte espace aérien (①), vent live Pioupiou + enrichissement Open-Meteo (②/③ météo), profils+follow+kudos (④).
2. **Court terme business** : construire le **flow catalogue vérifié** (monétise un actif déjà là, sans échelle) et nouer 2–3 relations marques/revendeurs.
3. **Continuer à faire croître la base gratuite + communauté** — l'échelle est la monnaie de tout le reste (spots sponsorisés, défis, data).
4. **Avant toute monétisation** : régler la licence commerciale Open-Meteo.
