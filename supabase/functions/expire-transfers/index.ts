/**
 * Deletes storage files for transfers older than 24 hours, marks them as
 * expired in the DB, and hard-deletes rows older than 7 days to keep the
 * database lean.
 *
 * Deploy:
 *   supabase functions deploy expire-transfers --no-verify-jwt
 *
 * Schedule via pg_cron (Supabase Dashboard → Database → Cron Jobs).
 * Requires the pg_net extension to be enabled.
 *
 *   select cron.schedule(
 *     'expire-transfers-hourly',
 *     '0 * * * *',
 *     $$
 *       select net.http_post(
 *         url     := '<YOUR_SUPABASE_URL>/functions/v1/expire-transfers',
 *         headers := jsonb_build_object(
 *                      'Content-Type',  'application/json',
 *                      'Authorization', 'Bearer <YOUR_SERVICE_ROLE_KEY>'
 *                    ),
 *         body    := '{}'::jsonb
 *       )
 *     $$
 *   );
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const TTL_HOURS = 24;
const HARD_DELETE_DAYS = 7;
const BATCH_SIZE = 100; // transfers processed per invocation

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  // Only the service role key may trigger this — prevents arbitrary callers
  // from wiping storage via a public HTTP request.
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (req.headers.get("Authorization") !== `Bearer ${serviceKey}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabase = createClient(supabaseUrl, serviceKey);

  const now = Date.now();
  const ttlCutoff = new Date(now - TTL_HOURS * 3600 * 1000).toISOString();
  const hardDeleteCutoff = new Date(
    now - HARD_DELETE_DAYS * 24 * 3600 * 1000,
  ).toISOString();

  // ── 1. Find transfers past TTL whose storage has not been cleaned yet ──────
  const { data: toExpire, error: fetchErr } = await supabase
    .from("transfers")
    .select("id")
    .lt("created_at", ttlCutoff)
    .neq("status", "expired")
    .limit(BATCH_SIZE);

  if (fetchErr) {
    console.error("fetch expired transfers:", fetchErr.message);
    return new Response(JSON.stringify({ error: fetchErr.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const ids = (toExpire ?? []).map((t: { id: string }) => t.id);
  let deletedFiles = 0;
  let storageErrors = 0;

  // ── 2. Delete storage objects for each expired transfer ───────────────────
  for (const id of ids) {
    const { data: files, error: listErr } = await supabase.storage
      .from("transfers")
      .list(id);

    if (listErr) {
      console.error(`storage list ${id}:`, listErr.message);
      storageErrors++;
      continue;
    }

    if (!files || files.length === 0) continue;

    const paths = files.map((f: { name: string }) => `${id}/${f.name}`);
    const { error: removeErr } = await supabase.storage
      .from("transfers")
      .remove(paths);

    if (removeErr) {
      console.error(`storage remove ${id}:`, removeErr.message);
      storageErrors++;
    } else {
      deletedFiles += paths.length;
    }
  }

  // ── 3. Mark the batch as expired in the DB ────────────────────────────────
  let markedExpired = 0;
  if (ids.length > 0) {
    const { count, error: updateErr } = await supabase
      .from("transfers")
      .update({ status: "expired" })
      .in("id", ids)
      .select("id", { count: "exact", head: true });

    if (updateErr) {
      console.error("mark expired:", updateErr.message);
    } else {
      markedExpired = count ?? 0;
    }
  }

  // ── 4. Hard-delete rows older than 7 days (already expired, saves DB space) ─
  let purgedRows = 0;
  const { count: purgeCount, error: purgeErr } = await supabase
    .from("transfers")
    .delete()
    .lt("created_at", hardDeleteCutoff)
    .eq("status", "expired")
    .select("id", { count: "exact", head: true });

  if (purgeErr) {
    console.error("hard delete:", purgeErr.message);
  } else {
    purgedRows = purgeCount ?? 0;
  }

  console.log(
    `expire-transfers: markedExpired=${markedExpired} deletedFiles=${deletedFiles} purgedRows=${purgedRows} storageErrors=${storageErrors}`,
  );

  return new Response(
    JSON.stringify({ ok: true, markedExpired, deletedFiles, purgedRows, storageErrors }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
