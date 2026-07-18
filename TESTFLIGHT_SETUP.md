# SoarX → TestFlight

Deux façons d'uploader une nouvelle version. Les deux utilisent la **même
clé API App Store Connect** que ton projet CodexBar (même compte Apple) —
tu n'as rien de nouveau à créer côté Apple.

- **App** : SoarX — bundle ID `com.xavierkain.ParaFlightLog2`, Team `S96H22CQ8W`
- **Prérequis Apple (une seule fois)** : l'app doit exister dans App Store
  Connect. Si ce n'est pas déjà fait :
  <https://appstoreconnect.apple.com> → Apps → + → Nouvelle app → iOS,
  nom « SoarX », bundle ID `com.xavierkain.ParaFlightLog2`, SKU `soarx`.
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

Runner macOS + signature via **match** (mêmes certificats chiffrés que
CodexBar). Une fois les secrets posés, chaque upload = 1 clic.

### Secrets à ajouter au repo SoarX (une seule fois)

Repo `XavierKain/ParaFlightLog` → **Settings → Secrets and variables →
Actions → New repository secret**. Ce sont **exactement les mêmes valeurs**
que sur le repo CodexBar — recopie-les :

| Secret | Valeur |
|--------|--------|
| `ASC_KEY_ID` | ID de la clé API App Store Connect |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8_BASE64` | le `.p8` encodé base64 (`base64 -i AuthKey_XXXX.p8`) |
| `APPLE_TEAM_ID` | `S96H22CQ8W` |
| `MATCH_PASSWORD` | la passphrase match que tu utilises déjà |

> Astuce : sur le repo CodexBar → Settings → Secrets, tu as déjà ces 5
> entrées. GitHub ne ré-affiche pas leur valeur, mais tu les as notées
> quelque part lors du setup CodexBar — recolle-les ici à l'identique.

### Déclencher

Onglet **Actions → TestFlight → Run workflow → branche v20 → Run**.

Au **premier run**, match va créer une branche `match-certs` dans le repo
(certificats App Store chiffrés) et générer les profils des 4 cibles.

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
2. **Certificat de distribution (option B)** — si tu as déjà atteint la
   limite Apple de certificats de distribution, match échouera à en créer un
   nouveau. Solution : dans le workflow, match réutilise le certificat s'il
   est dans la branche `match-certs` ; sinon révoque un vieux certificat
   inutilisé sur developer.apple.com.
3. **`aps-environment`** — l'entitlement de l'app est `development`. Pour que
   les push marchent en TestFlight, il faudra le passer à `production`
   (Xcode le gère si tu utilises la signature automatique ; à vérifier sur
   un vrai build TestFlight — cf. BETA_TESTPLAN.md).

**Recommandation** : fais le tout premier upload avec **l'option A** (fiable
tout de suite), puis bascule sur **l'option B** pour les suivantes.
