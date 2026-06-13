// ============================================================================
// SoarX — Edge Function · cleanup-live
// ----------------------------------------------------------------------------
// Supprime les positions live périmées (TTL ~2 min) et rafraîchit les
// leaderboards. Pensée pour être déclenchée par un planificateur :
//   * Supabase Scheduled Functions (cron dashboard), ou
//   * pg_cron appelant net.http_post, ou
//   * un cron externe (GitHub Actions) frappant l'URL avec le header secret.
//
// Déploiement (manuel, NON fait par ce scaffold) :
//   supabase functions deploy cleanup-live --no-verify-jwt
//   supabase secrets set CLEANUP_SECRET=<aléa long>
//
// Sécurité : on exige l'en-tête `x-cleanup-secret` == CLEANUP_SECRET pour
// éviter qu'un tiers déclenche la purge. Le client interne utilise la
// SERVICE_ROLE_KEY (injectée automatiquement par Supabase dans l'environnement
// de la fonction) pour bypasser la RLS sur les fonctions SECURITY DEFINER.
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request): Promise<Response> => {
  // --- Auth de déclenchement ------------------------------------------------
  const expected = Deno.env.get("CLEANUP_SECRET");
  const provided = req.headers.get("x-cleanup-secret");
  if (!expected || provided !== expected) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "content-type": "application/json" },
    });
  }

  // --- Client service_role (bypass RLS) ------------------------------------
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, serviceKey);

  try {
    // 1) Purge des positions live périmées (RPC SECURITY DEFINER).
    const { data: purged, error: purgeErr } = await supabase.rpc(
      "purge_stale_live_positions",
    );
    if (purgeErr) throw purgeErr;

    // 2) Rafraîchissement des leaderboards (RPC SECURITY DEFINER).
    const { error: refreshErr } = await supabase.rpc("refresh_leaderboards");
    if (refreshErr) throw refreshErr;

    return new Response(
      JSON.stringify({ ok: true, purged_live_positions: purged ?? 0 }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return new Response(JSON.stringify({ ok: false, error: message }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
});
