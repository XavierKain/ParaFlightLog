# APNs push setup — SoarX community loop (Phase 1)

This is the **only remaining manual step** to turn on push notifications for
condition reports. Everything else (client registration, the fan-out Appwrite
Function) is already built and deployed, and the whole feature is fail-soft:
until you finish the steps below, the app and the function keep running and
just don't deliver pushes.

- Project: `69524ce30037813a6abb` (region **fra**, `https://fra.cloud.appwrite.io/v1`)
- Database: `69524e510015a312526b`
- Bundle ID: `com.xavierkain.ParaFlightLog2`
- Apple Team ID: `S96H22CQ8W`

---

## What was auto-deployed (nothing to do here)

- **iOS client** — `PushService` requests notification authorization *lazily*
  (only when a pilot opts into a push feature), registers for APNs, and
  registers the device token with Appwrite as a **push target**
  (`account.createPushTarget`). The target is refreshed on token change and
  deleted on sign-out. `aps-environment` (development) and the
  `remote-notification` background mode are already in the project.
- **Appwrite Function `notify-fanout`** — created, built and **active**:
  - Function ID: `notify-fanout`
  - Runtime: `node-22`, entrypoint `index.js`, build `npm install`
  - Event trigger:
    `databases.69524e510015a312526b.collections.spot_reports.documents.*.create`
  - Scopes: `documents.read`, `messages.write`
  - Source: `functions/notify-fanout/`
  - On each new `spot_reports` row it pushes the report to every pilot
    subscribed to that spot (`spot_subscriptions_v20`, `notifyReports == true`),
    excluding the author.

---

## Step 1 — Create an APNs Auth Key (.p8) in the Apple Developer portal

1. Go to <https://developer.apple.com/account> → **Certificates, Identifiers &
   Profiles** → **Keys**.
2. Click **+** (Create a key), name it e.g. `SoarX APNs`, tick
   **Apple Push Notifications service (APNs)**, Continue → Register.
3. **Download** the `.p8` file (you can only download it once) and note:
   - **Key ID** (10 characters, shown on the key page),
   - **Team ID**: `S96H22CQ8W`.
4. Confirm the App ID `com.xavierkain.ParaFlightLog2` has the **Push
   Notifications** capability enabled (Identifiers → your app ID).

One APNs auth key works for **both** sandbox (development) and production.

## Step 2 — Add the Apple APNs provider in Appwrite

Appwrite Console → **Messaging** → **Providers** → **Add provider** → **Apple
(APNs)**:

- **Name**: `SoarX APNs`
- **App bundle ID**: `com.xavierkain.ParaFlightLog2`
- **Team ID**: `S96H22CQ8W`
- **Key ID**: the 10-char key ID from Step 1
- **Auth key (.p8)**: paste the *full contents* of the downloaded `.p8`
  (including the `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----`
  lines)
- **Sandbox**: **ON** for development / TestFlight builds signed with the
  `development` `aps-environment` (the current entitlement). Turn OFF only for
  an App Store production build. Enable the provider.

That's it — the function already targets users by ID, so no topic wiring is
needed.

## Step 3 — Send a test push

1. Build & run the app on a **real device** (APNs doesn't work in the
   Simulator), sign in, and opt into a push feature (subscribe to a spot /
   enable sharing) so a push target is created. You can verify the target in
   Console → **Auth** → the user → **Targets** (an APNs target appears).
2. Fastest test — Console → **Messaging** → **Messages** → **Create push
   message**, pick your user/target, send. The banner should arrive.
3. End-to-end test — from a *second* account, create a `spot_reports` row for a
   spot the first account is subscribed to (via the app's report UI, or
   Console → the `spot_reports` table → **Create row**). The `notify-fanout`
   function fires and the first account gets the push.

## Step 4 — Check the function logs

Console → **Functions** → **notify-fanout** → **Executions**. Each run logs the
audience size and per-batch send result, e.g.
`Fan-out for <spotKey>: 3/3 users, 0 failed batch(es).`

Via API:

```bash
curl -s "https://fra.cloud.appwrite.io/v1/functions/notify-fanout/executions" \
  -H "X-Appwrite-Project: 69524ce30037813a6abb" \
  -H "X-Appwrite-Key: <ADMIN_API_KEY>"
```

---

## Redeploying the function (if you change the code)

From `functions/notify-fanout/` with the Appwrite CLI:

```bash
appwrite functions createDeployment \
  --functionId notify-fanout \
  --code . \
  --activate true \
  --entrypoint index.js
```

Or via REST (tar the folder, POST as `code`, `activate=true`):

```bash
tar --exclude=node_modules --exclude='*.tar.gz' -czf /tmp/notify-fanout.tar.gz -C functions/notify-fanout .
curl -s -X POST "https://fra.cloud.appwrite.io/v1/functions/notify-fanout/deployments" \
  -H "X-Appwrite-Project: 69524ce30037813a6abb" \
  -H "X-Appwrite-Key: <ADMIN_API_KEY>" \
  -F "code=@/tmp/notify-fanout.tar.gz" -F "activate=true"
```

---

## Troubleshooting

- **No push target created** — the pilot must grant notification permission
  *and* be signed in. Denied permission (Settings → Notifications) is
  respected and never re-prompted by the app.
- **Function runs but nothing delivers** — the APNs provider (Step 2) is
  missing/disabled, or Sandbox is set wrong for the build's `aps-environment`.
- **`createPush` 401 / listing rows 401 in function logs** — the row-read scope
  name changed on the server; add `rows.read` / `tables.read` to the function's
  scopes alongside `documents.read` (Console → Functions → notify-fanout →
  Settings → Scopes).
- **Wrong environment** — development/TestFlight builds use the APNs **sandbox**
  gateway; an App Store build uses production. Toggle **Sandbox** on the
  provider to match, or add two providers.
