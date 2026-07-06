# ParaFlightLog — Roadmap (v20.2+)

*Updated 2026-07-06. PLAN_V20.md is the historical audit that motivated the v20 rebuild; this file is the living plan. Step A (Spot entity) shipped in v20.1 on-device.*

## Where we are
- ✅ v20 core rebuild (Watch outbox+ACK, 4 tabs, flight types, replay, GPX/IGC, backup v2, account, vario, simulator)
- ✅ v20.1 on-device pass (compile fixes, dashboard, onboarding, replay v2, **Spot entity + GPS clustering + reassignment**, Speedflying, dev-3 backup compat)
- ✅ CI: GitHub Actions `Build check` on `macos-26` — every push to `v20`/`main` compile-checks the app without signing. The Linux side reads failures via check-run annotations and iterates without the Mac.
- ✅ Step B (weather per spot), Step C (opt-in community sharing) and Step D v1 (Explore) shipped — details below.

## The "Surfr" vision, step by step

### 🌬️ Step B — Weather per spot (S, next up)
Open-Meteo (free, no API key, ~10k req/day):
- **Spot detail**: current wind (speed/gusts/direction) + 7-day forecast (wind + precip + cloud), refreshed with a short cache (15 min TTL per spot).
- **Flyability hint**: compare forecast wind direction with the spot's launch orientations → "Looks flyable this afternoon" style indicator. Requires wind-orientation field(s) on Spot if not already present.
- **Weather at takeoff**: when a flight is saved, snapshot wind/temp at the spot (Open-Meteo current or archive API for backfilling old flights); shown in flight detail.
- **Dashboard tile**: conditions for your favorite/most-flown spot.
Deliverable is single-player value from day one and becomes the "conditions" brick of Explore.

### ☁️ Step C — Opt-in sharing to Appwrite (M) — ✅ shipped
- **C0 shipped**: global spot identity — `CommunitySpotKey` (`<geohash6>-<name-slug>`, GeoHash.swift), shared `community_spots` collection seeded on first share, local Spot keeps a nullable `communitySpotKey`.
- **C1 shipped**: "Share my flights" toggle → flight *summaries* only (spot ref, date, duration, type — never GPS trace or notes), idempotent upsert, history backfill, "Stop & delete my shared data".
- **C2 shipped**: live presence heartbeat (`presence`, doc per user, 2h TTL) started at takeoff, removed at landing.
- **C3 shipped (client-side v1)**: per-spot community stats aggregated on device (SpotCommunitySection in spot detail); server-side Appwrite function deferred until the community grows.
- Console setup: APPWRITE_COMMUNITY_SETUP.md. Everything fails soft until the collections exist.

### 🌍 Step D — "Explore" (M-L) — ✅ v1 shipped
v1 (client-side aggregation, entered from the Home dashboard — Explore card + toolbar globe, deliberately NOT a tab yet):
- **ExploreView**: segmented Map/List of all community spots. Map annotations are capsules tinted by 30-day activity (gray 0 / blue 1–9 / orange 10+) with a pulsing 🪂 badge while pilots are flying there; list sorts live spots first, then busiest.
- **Spot detail sheet** (medium/large): live "flying now", community stats (existing `communityStats`), CURRENT wind/temp via WeatherService (no forecast/flyability — community spots have no launch orientations), recent shared flights (`recentFlights`), and a "View my spot" link when the key matches a local spot.
- **Service**: `CommunityService.exploreSpots()` (community_spots paginated to ~500 + ONE 30-day shared_flights query + ONE live presence query, merged on device, 15-min single-entry cache, pull-to-refresh bypass) and `recentFlights(forSpotKey:)` (15-min cache per spot). Backend-unconfigured shows a friendly placeholder; activity counts fail soft to zero.

Deferred (Step D v2+):
- public profiles (opt-in), follow + alerts
- promote Explore to its own tab once usage justifies it (tab bar untouched in v1)
- weather overlays on the Explore map
- server-side aggregation (Appwrite function) when the community outgrows client-side queries

### Parallel / opportunistic
- **TestFlight from CI**: extend GitHub Actions with fastlane + signing secrets (or Xcode Cloud) so betas ship without the Mac. Needs: ASC API key as repo secrets, match-style signing. (M)
- **IGC/GPX import** (from vario or XContest) — complements the existing export. (S)
- **Live Activity** during phone-tracked flights. (S)
- **Widget rework** with App Group (deferred from v20). (S)
- **Multilingual return** (string catalog is already regenerating). (S)

## Working agreement (Linux ↔ Mac)
- Linux (Claude) develops features, pushes to `v20`; CI compile-checks each push.
- Mac runs on-device testing and anything requiring signing/simulator UX; pushes fixes back.
- One machine edits at a time; always `git pull` before working.
