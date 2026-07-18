# ParaFlightLog v20 — Setup & Testing Guide

v20 is a simplified, hardened rebuild of the app around its core: **track flights from the Apple Watch, browse them with clean stats on the iPhone, never lose data**. English-only UI. It installs **side by side** with your current app (new bundle id `com.xavierkain.SoarX`, display name "ParaFlightLog 2"), so your production data is never at risk while testing.

## What changed (summary)

### Reliability (the big one)
- **Watch flights can no longer be lost.** Every finished flight is written to a persistent on-watch outbox *before* anything else, and only removed after the iPhone confirms it saved it (delivery ACK). Retries happen automatically on reconnection.
- The iPhone saves incoming flights **immediately** and geocodes the spot afterwards (previously a missing GPS fix could silently drop a flight). Duplicate deliveries are deduplicated by flight id.
- Crash recovery no longer inflates flight duration (it now ends at the last recorded update, not "now").
- **Backup v2**: JSON manifest instead of the corrupting CSV escaping. Old `.paraflightlog` backups (v1) still import, with a hardened parser. Merge imports deduplicate by id; replace mode validates everything before touching existing data.
- **iCloud sync (CloudKit)** wired into SwiftData with graceful fallback to local-only.

### Simplification
- 4 tabs: **Flights / Wings / Stats / Settings** (Stats and Charts merged into one tab with Overview / Charts / Map segments). A **Timer** tab appears when "Use iPhone as tracker" is enabled in Settings.
- English only (multilingual removed for now).
- Removed: legacy CSV export, "Excel" import, StatsCache, localization machinery, dead code.

### New features
- **Flight types**: Soaring / Thermal / Air Surfing / Ground Handling / Other — picked on the Watch when stopping a flight, editable on the iPhone, shown in lists and stats.
- **Manual flight entry** ("+" on the Flights tab).
- **3D flight replay** (Wingman-style flyover) from the flight detail.
- **GPX and IGC export** per flight (share sheet from flight detail).
- **Vario** with beeps/haptics on both Watch and iPhone (toggle in Settings, off by default).
- **Flight simulator** (Developer settings) to test the whole pipeline live in the Xcode simulator: fake GPS/altitude/vario feed, saved with a real GPS track so replay/export can be tested.
- **Account (email + password via Appwrite)** with one-slot cloud backup/restore.
- Watch display fix: metric tiles auto-scale — 4-digit altitudes no longer get clipped.
- Wing library from your Appwrite back-office: unchanged (it was great).

## One-time setup before the first build

### 1. Xcode
1. Open the project on your Mac, select the **ParaFlightLog** iOS target → Signing & Capabilities.
2. Signing is unchanged (team S96H22CQ8W, automatic). The new bundle ids will register on first build.
3. **iCloud**: the entitlements file (`ParaFlightLog/ParaFlightLog.entitlements`) already declares CloudKit with container `iCloud.com.xavierkain.SoarX`. In Signing & Capabilities, Xcode should pick it up; if the container is missing, add the iCloud capability once so Xcode creates the container on the developer portal.
   - Until the capability/container exists, the app logs a warning and runs on the local store (`DataController.isCloudSyncActive == false`) — everything else works.
4. Build & run. The Watch app pairs with the new iOS app automatically (companion bundle id updated).

### 2. Appwrite console (for the new Account feature)
Project `69524ce30037813a6abb` at `https://fra.cloud.appwrite.io/v1`:
1. **Auth** → enable the *Email/Password* method.
2. **Storage** → create a bucket with ID exactly `user-backups`, **File security ON**, and bucket permissions Create/Read/Update/Delete for role **users**. Optionally cap the max file size.
The wing catalog (databases/bucket) is untouched.

### 3. Migrating your real data
1. In your **current** app: Settings → Export Backup → save the `.paraflightlog` file.
2. In **ParaFlightLog 2**: Settings → Import Backup → pick that file. The v1 format is auto-detected; the import summary tells you what was imported/skipped.
3. Your original app and its data remain untouched.

## Testing checklist
- [ ] Watch: start a flight, put the iPhone in airplane mode, stop the flight → reconnect → flight appears on the iPhone (outbox retry).
- [ ] Watch: altitude above 1000 m displays fully (simulator: Features > Location > custom altitude, or the flight simulator below).
- [ ] iPhone Developer settings → "Simulate a flight (live)" → watch the vario/HUD, stop, then open the flight → 3D replay + GPX/IGC export.
- [ ] Import your real v1 backup → counts match your logbook.
- [ ] Create an account, Back Up Now, delete the app, reinstall, Sign In, Restore.
- [ ] Two devices signed into the same iCloud: flights appear on both (once the iCloud capability is set up).

## Known limitations / deferred
- Community/social features, live tracking, SoarX Voice: intentionally out (placeholder row in Settings for Voice).
- Multilingual UI: removed for now (English only); can return later via the string catalog.
- Widget extension: untouched from v1 (static launcher); a proper live-flight widget needs an App Group and is deferred.
- The account currently syncs a single backup slot, not live data; CloudKit handles continuous sync.
- **None of this has been compiled** — it was written on a Linux machine without Xcode. Expect a first pass of compiler fixes on Mac; the code is conservative iOS 17 / watchOS 10 Swift.

## Release notes for the App Store listing (draft)
"Simplified, faster, and safer: reliable Watch sync that never loses a flight, flight types, 3D flight replay, GPX/IGC export, vario beeps, iCloud sync, and account backup."
