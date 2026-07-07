# Appwrite console setup — community sharing (roadmap Step C)

> **Status (2026-07-07): all backend objects below were created via API and verified.**
> Tables `community_spots`, `shared_flights`, `presence` exist with the exact
> columns / indexes / permissions here. A fourth table `user_backups` was added
> for cloud backup: the free Appwrite plan allows only **one storage bucket**
> (already used by `wing-images`), so cloud backup stores a JSON payload in a DB
> table instead of Storage — private per user, **photos excluded** (they stay in
> the local file backup). Nothing more to do in the console unless you recreate
> the project from scratch.

One-time console setup for the opt-in community features (shared flight
summaries, live presence, per-spot stats). Until this is done, every
community call in the app fails soft (logged under the `Community`
category) and the app keeps working normally.

- Console: https://cloud.appwrite.io (region **fra**)
- Project: `69524ce30037813a6abb` (ParaFlightLog)
- Database: `69524e510015a312526b` (the existing one holding `manufacturers` / `wings`)

The client uses the TablesDB API, so recent consoles show these as
**Tables** (older consoles: **Collections**) — same thing. Create all three
inside database `69524e510015a312526b` with **exactly** these IDs.

---

## 1. Table `community_spots`

Databases → `69524e510015a312526b` → **Create table** → Table ID:
`community_spots` (type it, don't auto-generate), name: `Community Spots`.

The document ID of each row IS the global spot key
(`<geohash6>-<name-slug>`, e.g. `eykhbk-punta-paloma`), created by the
first pilot who shares a flight there.

### Columns (Attributes)

| Key         | Type    | Size | Required | Default |
|-------------|---------|------|----------|---------|
| `name`      | String  | 128  | Yes      | —       |
| `latitude`  | Float   | —    | Yes      | —       |
| `longitude` | Float   | —    | Yes      | —       |
| `createdBy` | String  | 64   | Yes      | —       |

### Indexes

None needed (rows are fetched by their ID).

### Permissions (table → Settings → Permissions)

- Role **Users**: **Create** only
- Role **Any**: **Read**
- **Row security** (a.k.a. Document security): **ON**

The app additionally sets per-row permissions on create:
read `any`, update/delete `user:<creator>`.

---

## 2. Table `shared_flights`

**Create table** → Table ID: `shared_flights`, name: `Shared Flights`.

One row per shared flight; the row ID is the flight's UUID (lowercased),
which makes re-sharing idempotent. Summaries only — never a GPS track or
notes. Coordinates are rounded to 2 decimals (~1 km) by the client.

### Columns (Attributes)

| Key               | Type     | Size | Required | Default |
|-------------------|----------|------|----------|---------|
| `userId`          | String   | 64   | Yes      | —       |
| `pilotName`       | String   | 64   | Yes      | —       |
| `spotKey`         | String   | 40   | Yes      | —       |
| `spotName`        | String   | 128  | Yes      | —       |
| `latitude`        | Float    | —    | Yes      | —       |
| `longitude`       | Float    | —    | Yes      | —       |
| `date`            | Datetime | —    | Yes      | —       |
| `durationSeconds` | Integer  | —    | Yes      | —       |
| `flightType`      | String   | 32   | No       | —       |

### Indexes (table → Indexes → Create index)

| Index key      | Type | Columns   | Order |
|----------------|------|-----------|-------|
| `idx_spot_key` | Key  | `spotKey` | ASC   |
| `idx_user_id`  | Key  | `userId`  | ASC   |
| `idx_date`     | Key  | `date`    | DESC  |

(Optional but nice for the stats query: a composite Key index on
`spotKey` + `date`.)

### Permissions

- Role **Users**: **Create** only
- Role **Any**: **Read**
- **Row security**: **ON**

Per-row permissions set by the app: read `any`, update/delete
`user:<owner>` — so "Stop & delete my shared data" can remove them.

---

## 3. Table `presence`

**Create table** → Table ID: `presence`, name: `Presence`.

Live "flying now" heartbeat: exactly one row per user (row ID = user ID),
upserted at takeoff with `expiresAt = now + 2h`, deleted at landing.
Clients ignore rows whose `expiresAt` is in the past, so leftovers from a
dead Watch/phone expire by themselves.

### Columns (Attributes)

| Key         | Type     | Size | Required | Default |
|-------------|----------|------|----------|---------|
| `spotKey`   | String   | 40   | Yes      | —       |
| `spotName`  | String   | 128  | Yes      | —       |
| `latitude`  | Float    | —    | Yes      | —       |
| `longitude` | Float    | —    | Yes      | —       |
| `startedAt` | Datetime | —    | Yes      | —       |
| `expiresAt` | Datetime | —    | Yes      | —       |

### Indexes

| Index key        | Type | Columns     | Order |
|------------------|------|-------------|-------|
| `idx_expires_at` | Key  | `expiresAt` | ASC   |
| `idx_spot_key`   | Key  | `spotKey`   | ASC   |

### Permissions

- Role **Users**: **Create** only
- Role **Any**: **Read**
- **Row security**: **ON**

Per-row permissions set by the app: read `any`, update/delete
`user:<owner>` (needed for the takeoff upsert and the landing delete).

---

## Verification checklist

1. All three tables exist under database `69524e510015a312526b` with the
   exact IDs `community_spots`, `shared_flights`, `presence`.
2. Every column above exists with the exact key, type and required flag
   (a typo in a required column makes the app's writes fail with
   "Invalid document structure" — visible in the `Community` log category).
3. Row/Document security is ON for all three tables.
4. Role `users` has Create, role `any` has Read on all three tables
   (no Update/Delete at the table level — per-row permissions handle those).
5. In the app: Settings → sign in → enable community sharing → save a
   flight with a located spot → the row appears in `shared_flights` and
   the spot in `community_spots`.
