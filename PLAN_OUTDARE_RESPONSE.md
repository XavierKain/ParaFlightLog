# Plan — réponse à OutDare (validé 2026-07-29)

Ce document est le plan de travail agréé avec Xavier après l'analyse comparative
avec **OutDare** (« OutDare: Paragliding Weather », App Store `id6768607246`,
éditeur *menandiere llc*, sorti le 2026-05-13, gratuit sans paywall, 7 langues,
iOS/Watch/Mac/Vision + web app). Il existe pour survivre à un compactage de
conversation : tout ce qu'il faut pour reprendre le travail est ici.

## État du repo au moment où ce plan est écrit

- `main` et `v20` pointent tous les deux sur `6fc6272`, CI verte (build + tests).
- Dernier travail livré : OAuth Apple/Google/Facebook (`5434f9a`) et le ping
  quotidien Appwrite anti-pause (`6fc6272`).
- **Bloquant non levé** : les 3 providers OAuth ne sont pas encore activés dans
  la console Appwrite → les boutons n'aboutissent pas. Voir `AUTH_OAUTH_SETUP.md`.
  C'est une manip console qui n'appartient qu'à Xavier.

## Périmètre validé

Xavier a validé « tout ce que tu dis » sur la liste des recommandations à fort
ratio gain/effort. Cela couvre les **items 1 à 5 ci-dessous**. Le tier « ensuite,
mais pas maintenant » (§ Différé) reste explicitement hors périmètre.

Ordre d'exécution : 1 → 2 → 3 → 5 → 4 (le multilingue en dernier parce qu'il fige
les chaînes, et que les items 1-3 en créent de nouvelles).

---

## 1. Verdict de volabilité expliqué — LE gros morceau

**Pourquoi** : on calcule déjà le secteur bloquant, la bande de vitesse apprise,
le nombre d'observations et la provenance, et on jette tout pour ne renvoyer
qu'un enum. OutDare a la même idée mais avec des limites **déclaratives** ; les
nôtres sont **dérivées des vents réels au décollage**. Rendre le verdict bavard
est le seul moyen de rendre visible le seul endroit où on est meilleurs qu'eux.

**Code concerné**
- `ParaFlightLog/Services/WeatherService.swift` — `flyability(...)` v1
  (`good`/`marginal`/`bad`/`unknown`, ±45°/±67.5° sur les orientations, seuils
  25/40 et 35/55 km/h).
- `ParaFlightLog/Services/SpotIntelligenceService.swift` — v2 apprise
  (≥5 observations, seuil de significativité 20 %/secteur, bande p10–p90 padée
  ±20 %, chaîne de provenance appris → semé ParaglidingEarth → configuré).
- Affichage : `ParaFlightLog/Views/SpotInsightsViews.swift` (`HourlyForecastStrip`,
  rose des vents), carte « Conditions » du `DashboardView`, `SpotDetailView`,
  feuille spot communautaire d'`ExploreView`.

**À faire**
- Introduire un type de retour porteur de raison plutôt qu'un simple enum :
  verdict + **facteur bloquant unique** (direction / vitesse / rafales) + **à qui
  appartient la limite** (le spot, ta fenêtre apprise, ou le défaut) + provenance
  + nombre d'observations.
- Un seul facteur nommé, pas une liste — c'est tout l'intérêt.
- Formuler en anglais (l'app est en anglais jusqu'à l'item 4) :
  `"Red — wind is from the South; your window here is W to NW."`
  `"Learned from your 14 flights at this spot."`
- Réutiliser partout où le badge de volabilité apparaît déjà.
- Tests : étendre `ParaFlightLogTests/FlyabilityTests.swift` — un cas par facteur
  bloquant et par provenance.

**Critère d'acceptation** : sur un spot avec ≥5 observations, le verdict nomme le
facteur bloquant et dit qu'il vient de la fenêtre apprise ; sur un spot semé par
ParaglidingEarth, il le dit aussi ; sur un spot sans donnée, il reste honnête.

## 2. Alertes « jour volable » proposées à l'onboarding

**Pourquoi** : `ForecastAlertService` est construit et testé mais **désactivé par
défaut**, donc quasiment personne ne l'a. C'est la boucle de rétention d'une app
météo, et OutDare mène avec ça (alertes + résumé hebdo par e-mail).

**Code concerné**
- `ParaFlightLog/Services/ForecastAlertService.swift` (notification locale du
  matin, s'appuie sur flyabilityV2 — donc bénéficie directement de l'item 1).
- `ParaFlightLog/Views/OnboardingView.swift` (4 pages, premier lancement).
- `Views/SettingsViews.swift` — toggle « Alert me on flyable days ».

**À faire** : proposer explicitement l'activation pendant l'onboarding, avec le
bénéfice écrit en clair. Ne PAS forcer l'autorisation de notifications de force :
garder le pattern d'autorisation paresseuse déjà en place dans `PushService`.
Attention : `SpotAutoFollowService` est déjà ON par défaut, donc les spots suivis
existent — l'alerte a de la matière dès le premier vol.

## 3. Enrichir l'appel Open-Meteo — effort minuscule

**Code concerné** : `ParaFlightLog/Services/WeatherService.swift`
(`api.open-meteo.com/v1/forecast`, cache 15 min par coordonnée arrondie à 3 déc.).

**À faire**
- Ajouter `cape`, `cloud_base` (ou `lifted_index`), `boundary_layer_height` aux
  variables horaires.
- Passer le forecast quotidien de **7 à 10 jours** (OutDare affiche 10).
- Surfacer sobrement : ces variables intéressent le thermique, pas le soaring
  côtier — ne pas encombrer l'UI principale.
- **Licence** : le tier gratuit d'Open-Meteo est non commercial. Rien ne change
  tant qu'on ne monétise pas, mais c'est tracé dans `MARKET_ANALYSIS.md` §6.

## 4. Français + allemand

**Pourquoi** : OutDare est en 7 langues sur un marché dont le cœur est
franco-germano-suisse. C'est notre désavantage le plus concret et le plus
mécanique à effacer.

**Code concerné** : `Localizable.xcstrings` (839 clés, `sourceLanguage: en`, une
seule langue présente), `project.pbxproj` (`knownRegions = (en, Base)`).

**À faire**
- Ajouter `fr` et `de` aux `knownRegions` et au catalogue.
- Traduire les 839 clés.
- **Pièges connus** : le QA de 2026-07-25 a trouvé du français résiduel venant
  d'entrées de catalogue périmées (« Modifier » au lieu de « Edit » sur l'onglet
  Wings) — un cas contourné par `Text(verbatim:)` sur la montre. L'extension
  widget watchOS a un switch FR/EN **codé en dur** (`WidgetStrings.isFrench`,
  lisant un default `watch_app_language`) hérité de la v1 : à supprimer au profit
  du vrai mécanisme.
- Faire cet item **en dernier** : les items 1-3 créent de nouvelles chaînes.

## 5. Balises de vent live (OpenWindMap / Pioupiou)

**Pourquoi** : c'est la « contre-vérification honnête » d'OutDare, et c'est ce qui
fait qu'un pilote croit une app météo. Gratuit, sans clé, usage commercial permis
(tracé dans `MARKET_ANALYSIS.md`). Couplé à l'item 1, ça devient la raison
d'ouvrir l'app le matin :
`"Forecast: 20 km/h W. Pyla station, 6 min ago: 34 km/h — the forecast is optimistic today."`

**À faire** : nouveau service (à créer sous `ParaFlightLog/Services/`, groupe
synchronisé → aucune édition de pbxproj), balise la plus proche du spot avec
distance et fraîcheur, injectée dans le verdict de l'item 1.

**Risque assumé et à ne pas masquer** : la couverture des balises est concentrée
sur les sites officiels, or notre pari soaring côtier est justement hors sites
officiels. Sur beaucoup de nos spots cibles ça affichera « pas de balise » — et
c'est précisément l'argument qui justifie nos reports humains. L'UI doit dire
« pas de balise ici » sans donner l'impression d'un bug.

---

## Aussi promis

Écrire une section **OutDare** dans `MARKET_ANALYSIS.md`, et corriger le tableau
des manques du §4 qui est devenu trompeur : sur les 10 items priorisés le
2026-07-09, OutDare en couvre 8. Ce tableau ne décrit plus une feuille de route,
il décrit un concurrent.

## Différé — explicitement hors périmètre

- **Report de conditions depuis la montre** — notre fossé, pas du rattrapage ;
  à faire juste après ce plan. Prévu de longue date en Phase 3 v2, non construit.
- **Export vidéo verticale du replay 3D** — le seul levier de croissance gratuit,
  mais capturer une vue Mapbox en vidéo est un vrai chantier.
- **Marées sur les spots côtiers** — notre niche, mais la difficulté est la
  **donnée** : pas de source de marées gratuite et mondiale (NOAA = US only,
  SHOM = payant). À instruire avant de promettre.
- **Espaces aériens en indicatif** (openAIP sur la fiche spot, non bloquant).

## Écarté, décision tenue

Score XC / IGC signé / soumission XContest ; live tracking OGN ; chat et groupes ;
assistant IA ; import en masse des 14 000 sites ParaglidingEarth. Les raisons sont
dans `MARKET_ANALYSIS.md` §5 et n'ont pas changé — sauf à ce que Xavier revienne
dessus explicitement.
