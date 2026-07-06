# ParaFlightLog — Roadmap (v20.2+)

*Updated 2026-07-06. PLAN_V20.md is the historical audit that motivated the v20 rebuild; this file is the living plan. Step A (Spot entity) shipped in v20.1 on-device.*

## Where we are
- ✅ v20 core rebuild (Watch outbox+ACK, 4 tabs, flight types, replay, GPX/IGC, backup v2, account, vario, simulator)
- ✅ v20.1 on-device pass (compile fixes, dashboard, onboarding, replay v2, **Spot entity + GPS clustering + reassignment**, Speedflying, dev-3 backup compat)
- ✅ CI: GitHub Actions `Build check` on `macos-26` — every push to `v20`/`main` compile-checks the app without signing. The Linux side reads failures via check-run annotations and iterates without the Mac.

## The "Surfr" vision, step by step

### 🌬️ Step B — Weather per spot (S, next up)
Open-Meteo (free, no API key, ~10k req/day):
- **Spot detail**: current wind (speed/gusts/direction) + 7-day forecast (wind + precip + cloud), refreshed with a short cache (15 min TTL per spot).
- **Flyability hint**: compare forecast wind direction with the spot's launch orientations → "Looks flyable this afternoon" style indicator. Requires wind-orientation field(s) on Spot if not already present.
- **Weather at takeoff**: when a flight is saved, snapshot wind/temp at the spot (Open-Meteo current or archive API for backfilling old flights); shown in flight detail.
- **Dashboard tile**: conditions for your favorite/most-flown spot.
Deliverable is single-player value from day one and becomes the "conditions" brick of Explore.

### ☁️ Step C — Opt-in sharing to Appwrite (M)
- **C0 (design prerequisite): global spot identity.** Community features need spots that match across users. Plan: a shared `spots` collection keyed by location (geohash ~1 km + name), seeded from users' local spots on first share, deduped by proximity; curated via the existing web-admin. Local Spot keeps a nullable `communitySpotId`.
- **C1**: "Share my flights" toggle → upload flight *summaries* only (spot ref, date, duration, type — never GPS trace or notes) linked to the existing account.
- **C2**: live presence — heartbeat doc with 2h TTL while a flight is active ("2 pilots flying at Tarifa right now"), anonymous by default.
- **C3**: aggregated per-spot stats + leaderboards (Appwrite function, cached).

### 🌍 Step D — "Explore" tab (M-L)
Map of community spots with activity + current conditions; spot pages with community stats; public profiles (opt-in); later: follow + alerts.

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
