# notify-fanout

Appwrite Function (Node.js) that pushes a spot condition report to every pilot
subscribed to that spot. Phase 1 of the SoarX community loop.

## What it does

Triggered by the create event on the `spot_reports` table:

```
databases.69524e510015a312526b.collections.spot_reports.documents.*.create
```

On each new report it:

1. reads the report from the event payload,
2. pages through `spot_subscriptions_v20` where `spotKey == report.spotKey`
   and `notifyReports == true`,
3. collects subscriber `userId`s, excluding the report's author and
   deduplicating,
4. sends one push per batch of ≤100 users via `messaging.createPush`, with
   `data = { spotKey, reportId }` so the client can deep-link on tap.

Push title/body:

```
Title: <spotName>
Body:  <pilotName>: <status text> — <windForce> <compass dir>
       e.g. "Xavier: flying now — moderate SW"
```

It is defensive: an unparseable payload, a report with no `spotKey`, an empty
audience, or a per-batch messaging failure are logged and returned as JSON,
not thrown.

## Runtime

- Node.js runtime (`node-22` / `node-18`+).
- Entrypoint: `index.js` (ESM — `package.json` has `"type": "module"`).
- Build command: `npm install`.
- SDK: `node-appwrite@^25.2.0` (matches Appwrite server 1.9.5 / TablesDB).

## Event trigger

Configure exactly one event on the function:

```
databases.69524e510015a312526b.collections.spot_reports.documents.*.create
```

(The TablesDB tables are exposed under the legacy `collections`/`documents`
event namespace — this string is correct for a table named `spot_reports`.)

## Required scopes (dynamic API key)

Appwrite injects a per-execution API key (`x-appwrite-key` header) carrying the
scopes configured on the function. This function needs:

- `documents.read` — to list `spot_subscriptions_v20` rows.
- `messages.write` — to send pushes via Messaging.

If listing rows returns 401 at runtime, the row-read scope was renamed on the
server; add `rows.read` / `tables.read` alongside `documents.read`.

## Environment variables

Appwrite injects these automatically; the code falls back to sensible defaults.

| Variable                        | Provided by | Purpose                                  |
|---------------------------------|-------------|------------------------------------------|
| `APPWRITE_FUNCTION_API_ENDPOINT`| Appwrite    | API endpoint (defaults to fra.cloud).    |
| `APPWRITE_FUNCTION_PROJECT_ID`  | Appwrite    | Project id.                              |
| `x-appwrite-key` (header)       | Appwrite    | Per-execution dynamic API key.           |
| `APPWRITE_DATABASE_ID`          | optional    | Overrides the database id.               |
| `SUBSCRIPTIONS_TABLE_ID`        | optional    | Overrides the subscriptions table id.    |
| `APPWRITE_API_KEY`              | optional    | Fallback key for local/manual runs only. |

Defaults baked in: database `69524e510015a312526b`, subscriptions table
`spot_subscriptions_v20`.

## Deploy

Deployed via the Appwrite REST API by the Phase 1 coordinator (see
`APNS_SETUP.md` at the repo root for status and the manual-deploy fallback).
Manual deploy from this folder with the CLI:

```bash
appwrite functions createDeployment \
  --functionId notify-fanout \
  --code . \
  --activate true \
  --entrypoint index.js
```

## Note

Pushes only actually deliver once an **Apple APNs provider** is configured in
the Appwrite console (Messaging → Providers). Until then the function still
runs and logs cleanly; `createPush` simply has no provider to deliver through.
See `APNS_SETUP.md`.
