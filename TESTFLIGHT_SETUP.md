# SoarX → TestFlight

Deux façons d'uploader une nouvelle version. Les deux utilisent la **même
clé API App Store Connect** que ton projet CodexBar (même compte Apple) —
tu n'as rien de nouveau à créer côté Apple.

- **App** : SoarX (nom affiché) — bundle ID `com.xavierkain.ParaFlightLog2`, Team `S96H22CQ8W`
- **Prérequis Apple (une seule fois)** : l'app doit exister dans App Store
  Connect **pour le bundle ID `com.xavierkain.ParaFlightLog2`**. Si une app
  existe déjà pour cet ID, elle est réutilisée (rien à faire). Sinon :
  <https://appstoreconnect.apple.com> → Apps → + → Nouvelle app → iOS,
  nom « SoarX », bundle ID `com.xavierkain.ParaFlightLog2`, SKU `paraflightlog2`.
  (fastlane te le rappellera avec ce message s'il manque.)

---

## Option A — Depuis ton Mac (le plus simple, recommandé pour le 1er upload)

Signature **automatique** : Xcode/ton trousseau signent les 4 cibles (app,
widget iOS, app Watch, widget Watch). Rien à configurer côté certificats.

```bash
cd "…/SoarX/ParaFlightLog"
bundle install                      # une fois

export ASC_KEY_ID=…                 # ID de la clé API App Store Connect
export ASC_ISSUER_ID=…              # App Store Connect > Users > Integrations
export ASC_KEY_P8_BASE64="$(base64 -i /chemin/vers/AuthKey_XXXX.p8)"

bundle exec fastlane beta
```

(Ce sont les 3 mêmes valeurs que pour CodexBar — récupère la clé `.p8` et
les IDs là où tu les as déjà.)

fastlane incrémente le build automatiquement (dernier TestFlight + 1),
archive, signe et upload. Dispo dans l'app TestFlight ~10-30 min après.

Changelog optionnel : `bundle exec fastlane beta changelog:"Replay 3D Mapbox, etc."`

---

## Option B — En 1 clic sur GitHub (CI, répétable)

Runner macOS + **signature automatique** via la clé API App Store Connect
(`-allowProvisioningUpdates` : Xcode gère certificat de distribution
cloud-managed + profils). **Pas de match, pas de MATCH_PASSWORD, pas de repo
de certificats.** Une fois les secrets posés, chaque upload = 1 clic.

### Secrets à ajouter au repo (une seule fois)

Repo `XavierKain/ParaFlightLog` → **Settings → Secrets and variables →
Actions → New repository secret**. Seulement **4 secrets** :

| Secret | Valeur |
|--------|--------|
| `ASC_KEY_ID` | `73PNP8Z93X` |
| `ASC_ISSUER_ID` | `0cf39ed9-c1a9-43b7-8d10-e8bcdae31bdf` |
| `ASC_KEY_P8_BASE64` | le `.p8` encodé base64 (`base64 -i ~/.appstoreconnect/AuthKey_73PNP8Z93X.p8 \| pbcopy`) |
| `APPLE_TEAM_ID` | `S96H22CQ8W` |

### Déclencher

Onglet **Actions → TestFlight → Run workflow → branche v20 → Run**. Le
collaborateur n'a besoin que d'un accès write au repo — ni Mac, ni credentials
en main : les secrets vivent dans GitHub.

---

## Ce que je n'ai pas pu tester (et où ça peut coincer au 1er run)

Je n'ai pas de Mac ni tes identifiants Apple, donc le code est écrit d'après
le pattern CodexBar mais non exécuté. Points à surveiller au premier upload :

1. **Bundle IDs des cibles** — le Fastfile suppose ces 4 identifiants :
   `com.xavierkain.ParaFlightLog2`, `.FlightWidget`, `.watchkitapp`,
   `.watchkitapp.ParaFlightLogWidgetExtension`. Si l'archive se plaint d'un
   profil manquant, l'ID exact est dans le message → corrige-le dans
   `ALL_IDS` (fastlane/Fastfile). L'option A (Mac, signature auto) contourne
   ce point : elle n'a pas besoin de cette liste.
2. **Certificat de distribution (option B)** — la signature auto utilise un
   certificat de distribution *cloud-managed* Apple, sans occuper de slot
   classique. Si jamais Apple refuse (limite de certificats atteinte), révoque
   un vieux certificat inutilisé sur developer.apple.com puis relance.
3. **`aps-environment`** — l'entitlement de l'app est `development`. Pour que
   les push marchent en TestFlight, il faudra le passer à `production`
   (Xcode le gère si tu utilises la signature automatique ; à vérifier sur
   un vrai build TestFlight — cf. BETA_TESTPLAN.md).

**Recommandation** : fais le tout premier upload avec **l'option A** (fiable
tout de suite), puis bascule sur **l'option B** pour les suivantes.
