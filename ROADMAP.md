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

## Phases A + B (2026-06-12) ✅

- **Phase A** : voiles possédées vs empruntées (compteur matériel, alertes révision), type de vol au démarrage (iPhone + Watch, mémorisé par spot), analyse verticale (thermal viewer, graphes altitude/Vz, gain cumulé).
- **Phase B** : vario iPhone (bips audio en arrière-plan) + Watch (haptique) sur baromètre/Kalman — *à valider en vol réel* ; détection auto décollage/atterrissage (opt-in, Watch) ; **export IGC** ; **replay 2D/3D** du vol ; **librairie de voiles restaurée** (catalogue GitHub paraflightlog-wings, photos détourées, zéro serveur).

## V10.1 — Candidats restants

1. **Live Activities iOS** — vol en cours sur l'écran verrouillé / Dynamic Island.
2. **Icône SoarX dédiée** (l'icône actuelle est conservée de ParaFlightLog).
3. **Tests unitaires** ZipBackup / ExcelImporter / BadgeService / IGCExporter / FlightAutoDetector.
4. **Migration des contacts d'urgence** depuis l'ancienne app (re-saisie manuelle pour l'instant).
5. **Signature IGC validée XContest** (G-record cryptographique).

## Plus tard / à décider

- Couche communautaire **sans serveur** via CloudKit public database (spots partagés) si le besoin revient.
- Statistiques avancées (thermiques, gain d'altitude cumulé, records par spot).
- Export PDF du carnet de vol (exigence officielle de certaines fédérations).
