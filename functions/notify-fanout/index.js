/*
 * notify-fanout — SoarX community push fan-out (Phase 1).
 *
 * Trigger: create event on the `spot_reports` table
 *   databases.<db>.collections.spot_reports.documents.*.create
 *
 * Flow:
 *   1. Read the newly created report from the event payload (req.bodyJson).
 *   2. Page through `spot_subscriptions_v20` where spotKey == report.spotKey
 *      AND notifyReports == true.
 *   3. Collect subscriber userIds, excluding the report's author, deduped.
 *   4. Send ONE push per batch of users via Messaging.createPush.
 *
 * Defensive by design: missing fields, an empty audience, or a messaging
 * failure are logged and returned as a clean JSON result — never thrown so
 * hard the execution is marked failed for a recoverable reason.
 *
 * Auth: uses the dynamic API key Appwrite injects per execution
 * (req.headers['x-appwrite-key']), scoped to sessions/rows.read + messages.write.
 * See README.md for the env vars and required scopes.
 */

import { Client, TablesDB, Messaging, ID, Query } from 'node-appwrite';

// --- Configuration (env with sane fallbacks) --------------------------------

const DATABASE_ID = process.env.APPWRITE_DATABASE_ID || '69524e510015a312526b';
const SUBSCRIPTIONS_TABLE_ID = process.env.SUBSCRIPTIONS_TABLE_ID || 'spot_subscriptions_v20';
const PAGE_SIZE = 100;
const USER_BATCH_SIZE = 100; // users per createPush call

// --- Human-readable message text --------------------------------------------

const STATUS_TEXT = {
  flying: 'flying now',
  goingToFly: 'heading out',
  flyable: 'flyable',
  notFlyable: 'not flyable',
  tooStrong: 'too strong',
};

const WIND_FORCE_TEXT = {
  calm: 'calm',
  light: 'light',
  moderate: 'moderate',
  strong: 'strong',
  veryStrong: 'very strong',
  tooMuch: 'too much wind',
};

const COMPASS_8 = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

/** Maps a bearing in degrees to an 8-point compass label, or null. */
function compassDirection(deg) {
  if (typeof deg !== 'number' || Number.isNaN(deg)) return null;
  const normalized = ((deg % 360) + 360) % 360;
  return COMPASS_8[Math.round(normalized / 45) % 8];
}

/** Builds the push body: "<pilot>: <status> — <force> <dir>". */
function buildBody(report) {
  const pilot = (report.pilotName || 'A pilot').toString().slice(0, 64);
  const status = STATUS_TEXT[report.status] || report.status || 'conditions update';
  const force = WIND_FORCE_TEXT[report.windForce] || report.windForce || '';
  const dir = compassDirection(report.windDirectionDeg);

  let tail = force;
  if (dir) tail = tail ? `${tail} ${dir}` : dir;
  return tail ? `${pilot}: ${status} — ${tail}` : `${pilot}: ${status}`;
}

/** Splits an array into chunks of `size`. */
function chunk(array, size) {
  const out = [];
  for (let i = 0; i < array.length; i += size) out.push(array.slice(i, i + size));
  return out;
}

// --- Entry point ------------------------------------------------------------

export default async ({ req, res, log, error }) => {
  // 1. Parse the triggering report document from the event payload.
  let report;
  try {
    report = req.bodyJson ?? (req.body ? JSON.parse(req.body) : null);
  } catch (e) {
    error(`Could not parse event payload: ${e.message}`);
    return res.json({ ok: false, reason: 'unparseable_payload' }, 400);
  }

  if (!report || typeof report !== 'object') {
    error('Empty or non-object event payload.');
    return res.json({ ok: false, reason: 'empty_payload' }, 400);
  }

  const spotKey = report.spotKey;
  const authorId = report.userId;
  if (!spotKey) {
    log('Report has no spotKey; nothing to fan out.');
    return res.json({ ok: true, notified: 0, reason: 'no_spot_key' });
  }

  // 2. Appwrite client using the per-execution dynamic key.
  const endpoint = process.env.APPWRITE_FUNCTION_API_ENDPOINT || 'https://fra.cloud.appwrite.io/v1';
  const projectId = process.env.APPWRITE_FUNCTION_PROJECT_ID;
  const apiKey = req.headers['x-appwrite-key'] || process.env.APPWRITE_API_KEY || '';

  const client = new Client().setEndpoint(endpoint).setProject(projectId).setKey(apiKey);
  const tablesDB = new TablesDB(client);
  const messaging = new Messaging(client);

  // 3. Page through subscribers of this spot who opted into report pushes.
  const userIds = new Set();
  let cursor = null;
  try {
    for (let guard = 0; guard < 200; guard++) {
      const queries = [
        Query.equal('spotKey', spotKey),
        Query.equal('notifyReports', true),
        Query.limit(PAGE_SIZE),
      ];
      if (cursor) queries.push(Query.cursorAfter(cursor));

      const page = await tablesDB.listRows({
        databaseId: DATABASE_ID,
        tableId: SUBSCRIPTIONS_TABLE_ID,
        queries,
      });

      const rows = page.rows || [];
      for (const row of rows) {
        if (row.userId && row.userId !== authorId) userIds.add(row.userId);
      }

      if (rows.length < PAGE_SIZE) break;
      cursor = rows[rows.length - 1].$id;
    }
  } catch (e) {
    error(`Failed to list subscriptions for ${spotKey}: ${e.message}`);
    return res.json({ ok: false, reason: 'subscription_query_failed' }, 500);
  }

  const recipients = [...userIds];
  if (recipients.length === 0) {
    log(`No subscribers to notify for spot ${spotKey}.`);
    return res.json({ ok: true, notified: 0 });
  }

  // 4. Send one push per batch of users.
  const title = (report.spotName || 'Spot update').toString().slice(0, 128);
  const body = buildBody(report);
  const data = { spotKey, reportId: report.$id || '' };

  let notified = 0;
  let failedBatches = 0;
  for (const batch of chunk(recipients, USER_BATCH_SIZE)) {
    try {
      await messaging.createPush({
        messageId: ID.unique(),
        title,
        body,
        users: batch,
        data,
      });
      notified += batch.length;
    } catch (e) {
      failedBatches += 1;
      error(`createPush failed for a batch of ${batch.length}: ${e.message}`);
    }
  }

  log(`Fan-out for ${spotKey}: ${notified}/${recipients.length} users, ${failedBatches} failed batch(es).`);
  return res.json({ ok: failedBatches === 0, spotKey, notified, recipients: recipients.length });
};
