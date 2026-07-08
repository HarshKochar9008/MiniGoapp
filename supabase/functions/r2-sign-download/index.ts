/**
 * Mints a presigned Cloudflare R2 GET URL for one stored file
 * (object key: `<transferId>/<fileName>` — the same `storage_path` the app
 * records in transfer_files).
 *
 * SECURITY MODEL (mirrors the storage.objects RLS this replaces):
 *   - Deploy WITH JWT verification: npx supabase functions deploy r2-sign-download
 *     (config.toml sets `verify_jwt = true`; do NOT pass --no-verify-jwt).
 *   - The caller's JWT is resolved to their application user row, and a URL is
 *     only minted if that user is the RECEIVER or SENDER of the transfer and
 *     the transfer has not expired.
 *
 * Secrets: R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET
 * (see r2-sign-upload for details). Returns 503 { error: "r2_not_configured" }
 * when absent so the app falls back to Supabase Storage signed URLs.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";

const URL_EXPIRES_SECONDS = 3600;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isSafeFileName(name: string): boolean {
  if (!name || name.length > 255) return false;
  if (name.includes("/") || name.includes("\\")) return false;
  if (name.includes("..")) return false;
  // deno-lint-ignore no-control-regex
  if (/[\x00-\x1F<>:"|?*]/.test(name)) return false;
  return true;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json({ error: "Server not configured" }, 500);
  }

  const accountId = Deno.env.get("R2_ACCOUNT_ID");
  const accessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const secretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");
  const bucket = Deno.env.get("R2_BUCKET") ?? "transfers";
  if (!accountId || !accessKeyId || !secretAccessKey) {
    return json({ error: "r2_not_configured" }, 503);
  }

  // --- Authenticate the caller from their JWT -------------------------------
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.toLowerCase().startsWith("bearer ")
    ? authHeader.slice(7).trim()
    : "";
  if (!jwt) {
    return json({ error: "Unauthorized: missing bearer token" }, 401);
  }

  const admin = createClient(supabaseUrl, serviceKey);

  const { data: userData, error: authErr } = await admin.auth.getUser(jwt);
  const authUid = userData?.user?.id;
  if (authErr || !authUid) {
    return json({ error: "Unauthorized: invalid session" }, 401);
  }

  const { data: caller } = await admin
    .from("users")
    .select("id")
    .eq("auth_uid", authUid)
    .maybeSingle();
  const callerUserId = caller?.id as string | undefined;
  if (!callerUserId) {
    return json({ error: "Unauthorized: no user profile" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  // storage_path is `<transferId>/<fileName>`, exactly as stored in
  // transfer_files.storage_path by the sender.
  const storagePath = (body.storage_path ?? "").toString();
  const slash = storagePath.indexOf("/");
  const transferId = slash > 0 ? storagePath.slice(0, slash) : "";
  const fileName = slash > 0 ? storagePath.slice(slash + 1) : "";
  if (!UUID_RE.test(transferId) || !isSafeFileName(fileName)) {
    return json({ error: "Invalid storage_path" }, 400);
  }

  // --- Authorize: caller must be a party to a non-expired transfer ----------
  const { data: transfer, error: tErr } = await admin
    .from("transfers")
    .select("id, sender_id, receiver_id, status")
    .eq("id", transferId)
    .maybeSingle();
  if (tErr) {
    console.error("transfer lookup:", tErr.message);
    return json({ error: "Lookup failed" }, 500);
  }
  const isParty =
    transfer &&
    (transfer.receiver_id === callerUserId ||
      transfer.sender_id === callerUserId);
  if (!isParty) {
    // Same response for "not found" and "not yours" — no existence oracle.
    return json({ error: "Forbidden" }, 403);
  }
  if ((transfer.status ?? "").toString().toLowerCase() === "expired") {
    return json({ error: "Transfer has expired" }, 410);
  }

  // --- Presign ---------------------------------------------------------------
  const r2 = new AwsClient({
    accessKeyId,
    secretAccessKey,
    service: "s3",
    region: "auto",
  });
  const key = `${transferId}/${encodeURIComponent(fileName)}`;
  const url = new URL(
    `https://${accountId}.r2.cloudflarestorage.com/${bucket}/${key}`,
  );
  url.searchParams.set("X-Amz-Expires", String(URL_EXPIRES_SECONDS));
  const signed = await r2.sign(new Request(url, { method: "GET" }), {
    aws: { signQuery: true },
  });

  return json({ url: signed.url, expires_in: URL_EXPIRES_SECONDS });
});
