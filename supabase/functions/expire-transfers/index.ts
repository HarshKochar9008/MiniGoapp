/**
 * Deletes storage files for transfers older than 24 hours, marks them as
 * expired in the DB, and hard-deletes rows older than 7 days to keep the
 * database lean.
 *
 * Also handles room expiry: rooms live for the lifetime chosen at creation
 * (30 min / 1 h / 2 h). Transfers sent through an expired room have their
 * storage files deleted and are marked expired immediately (their history
 * rows are kept), then the room itself is deleted.
 *
 * Cloudflare R2 hybrid path: when R2_ACCOUNT_ID / R2_ACCESS_KEY_ID /
 * R2_SECRET_ACCESS_KEY secrets are set (see docs/R2_SETUP.md), expired
 * transfers' objects are also deleted from R2. A 1-day lifecycle rule on the
 * bucket is the recommended backstop — with it, this block only matters for
 * room transfers, which must lose their files at room expiry (as soon as
 * 30 minutes), well before the lifecycle rule fires.
 *
 * Deploy:
 *   supabase functions deploy expire-transfers --no-verify-jwt
 *
 * Schedule via pg_cron (Supabase Dashboard → Database → Cron Jobs).
 * Requires the pg_net extension to be enabled.
 *
 * Run every 15 minutes so 30-minute rooms are deleted promptly after expiry
 * (expired rooms are already invisible to clients in the meantime — the app
 * filters on expires_at).
 *
 *   select cron.schedule(
 *     'expire-transfers-15min',
 *     '0,15,30,45 * * * *',
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
import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";

const TTL_HOURS = 24;
const HARD_DELETE_DAYS = 7;
const BATCH_SIZE = 100; // transfers processed per invocation

/// Constant-time string compare. Length is allowed to leak (the length of a
/// service-role key is not a secret); the contents are not.
function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  // Only the service role key may trigger this — prevents arbitrary callers
  // from wiping storage via a public HTTP request. This endpoint is deployed
  // with verify_jwt = false (a service-role key is not a user JWT), so this
  // check is the ONLY thing standing in front of a destructive job.
  //
  // The env lookup is explicitly guarded: `Deno.env.get(...)!` is a
  // compile-time assertion only, so with the secret unset the comparison used
  // to degrade to `=== "Bearer undefined"` — which any caller can send.
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!serviceKey || !supabaseUrl) {
    console.error(
      "expire-transfers: SUPABASE_SERVICE_ROLE_KEY / SUPABASE_URL not set — " +
        "refusing to run rather than accepting an empty credential.",
    );
    return new Response("Server not configured", { status: 500 });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!timingSafeEqual(authHeader, `Bearer ${serviceKey}`)) {
    return new Response("Unauthorized", { status: 401 });
  }

  const supabase = createClient(supabaseUrl, serviceKey);

  const now = Date.now();
  const ttlCutoff = new Date(now - TTL_HOURS * 3600 * 1000).toISOString();
  const hardDeleteCutoff = new Date(
    now - HARD_DELETE_DAYS * 24 * 3600 * 1000,
  ).toISOString();

  // ── 0. Expired rooms: their transfers expire now (files gone, rows kept) ──
  const nowIso = new Date(now).toISOString();
  let expiredRoomIds: string[] = [];
  let roomTransferIds: string[] = [];
  const { data: expiredRooms, error: roomsErr } = await supabase
    .from("rooms")
    .select("id")
    .lt("expires_at", nowIso)
    .limit(BATCH_SIZE);

  if (roomsErr) {
    console.error("fetch expired rooms:", roomsErr.message);
  } else {
    expiredRoomIds = (expiredRooms ?? []).map((r: { id: string }) => r.id);
    if (expiredRoomIds.length > 0) {
      const { data: roomTransfers, error: rtErr } = await supabase
        .from("transfers")
        .select("id")
        .in("room_id", expiredRoomIds)
        .neq("status", "expired")
        .limit(BATCH_SIZE);
      if (rtErr) {
        console.error("fetch room transfers:", rtErr.message);
      } else {
        roomTransferIds = (roomTransfers ?? []).map(
          (t: { id: string }) => t.id,
        );
      }
    }
  }

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

  const ids = [
    ...new Set([
      ...(toExpire ?? []).map((t: { id: string }) => t.id),
      ...roomTransferIds,
    ]),
  ];
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

  // ── 2b. Delete R2 objects for the same transfers (hybrid path) ────────────
  let r2Deleted = 0;
  let r2Errors = 0;
  const r2AccountId = Deno.env.get("R2_ACCOUNT_ID");
  const r2AccessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const r2SecretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");
  const r2Bucket = Deno.env.get("R2_BUCKET") ?? "transfers";
  if (r2AccountId && r2AccessKeyId && r2SecretAccessKey && ids.length > 0) {
    const aws = new AwsClient({
      accessKeyId: r2AccessKeyId,
      secretAccessKey: r2SecretAccessKey,
      service: "s3",
      region: "auto",
    });

    // Object keys come from transfer_files rows, so no bucket listing is
    // needed (S3 deletes are free-tier friendly: they cost no operations).
    const { data: fileRows, error: filesErr } = await supabase
      .from("transfer_files")
      .select("storage_path")
      .in("transfer_id", ids);

    if (filesErr) {
      console.error("fetch transfer_files for R2 delete:", filesErr.message);
      r2Errors++;
    } else {
      for (const row of fileRows ?? []) {
        const path = (row as { storage_path?: string }).storage_path;
        if (!path) continue;
        const key = path
          .split("/")
          .map((seg: string) => encodeURIComponent(seg))
          .join("/");
        try {
          const res = await aws.fetch(
            `https://${r2AccountId}.r2.cloudflarestorage.com/${r2Bucket}/${key}`,
            { method: "DELETE" },
          );
          // 204 = deleted, 404 = already gone (lifecycle rule) — both fine.
          if (res.ok || res.status === 404) {
            r2Deleted++;
          } else {
            console.error(`r2 delete ${path}: HTTP ${res.status}`);
            r2Errors++;
          }
        } catch (e) {
          console.error(`r2 delete ${path}:`, e);
          r2Errors++;
        }
      }
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

  // ── 3b. Delete expired rooms (cascade removes members; transfers keep
  //        their history rows via room_id ON DELETE SET NULL) ────────────────
  let deletedRooms = 0;
  if (expiredRoomIds.length > 0) {
    const { count: roomCount, error: roomDelErr } = await supabase
      .from("rooms")
      .delete()
      .in("id", expiredRoomIds)
      .select("id", { count: "exact", head: true });
    if (roomDelErr) {
      console.error("delete expired rooms:", roomDelErr.message);
    } else {
      deletedRooms = roomCount ?? 0;
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
    `expire-transfers: markedExpired=${markedExpired} deletedFiles=${deletedFiles} r2Deleted=${r2Deleted} r2Errors=${r2Errors} purgedRows=${purgedRows} deletedRooms=${deletedRooms} storageErrors=${storageErrors}`,
  );

  return new Response(
    JSON.stringify({
      ok: true,
      markedExpired,
      deletedFiles,
      r2Deleted,
      r2Errors,
      purgedRows,
      deletedRooms,
      storageErrors,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
