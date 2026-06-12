# SoarX — Roadmap

## V10 (2026-06) — Refonte « standalone » ✅

Refonte profonde livrée sur la branche `V10` (design : `docs/superpowers/specs/2026-06-12-soarx-v10-design.md`).

- **App séparée** : bundle ID `com.xavierkain.SoarX` (+ `.watchkitapp`, widget) — coexiste avec l'ancienne app sans toucher à ses données.
- **Navigation simplifiée** : 4 onglets (Vol / Logbook / Carte / Réglages), plus d'authentification.
- **Cloud** : Appwrite supprimé (~27 500 lignes). Persistance SwiftData + **CloudKit privé** (`iCloud.com.xavierkain.SoarX`) avec fallback local automatique.
- **Backups** `.paraflightlog` : traces GPS et données de tracking incluses ; import rétro-compatible et idempotent (dédoublonnage).
- **Widget** : chrono du vol en cours en temps réel via App Group `group.com.xavierkain.SoarX`.
- **Watch** : inchangée fonctionnellement (GPS + workout + Water Lock + crash recovery), re-renders réduits (WingButton Equatable).
- **Local** : badges, contacts d'urgence/SOS, spots, météo (Open-Meteo), partage d'images — tout fonctionne sans réseau.

## V10.1 — Candidats

1. **Import/Export IGC** (format FAI) — interop XContest, SeeYou, etc. La trace GPS est déjà stockée point par point, l'écriture IGC est directe.
2. **Live Activities iOS** — vol en cours sur l'écran verrouillé / Dynamic Island (remplace avantageusement l'ancien « live flights » cloud).
3. **Icône SoarX dédiée** (l'icône actuelle est conservée de ParaFlightLog).
4. **Tests unitaires** ZipBackup / ExcelImporter / BadgeService (le target UITests contient déjà un smoke test des 4 onglets).
5. **Migration des contacts d'urgence** depuis l'ancienne app (re-saisie manuelle pour l'instant).

## Plus tard / à décider

- Couche communautaire **sans serveur** via CloudKit public database (spots partagés) si le besoin revient.
- Statistiques avancées (thermiques, gain d'altitude cumulé, records par spot).
- Export PDF du carnet de vol (exigence officielle de certaines fédérations).
