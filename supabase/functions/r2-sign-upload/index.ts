/**
 * Mints a presigned Cloudflare R2 PUT URL so the sender can upload one file's
 * bytes directly to R2 (object key: `<transferId>/<fileName>`). Metadata,
 * auth, realtime and RLS stay on Supabase — only the blob moves to R2.
 *
 * SECURITY MODEL (mirrors the storage.objects RLS this replaces):
 *   - Deploy WITH JWT verification: npx supabase functions deploy r2-sign-upload
 *     (config.toml sets `verify_jwt = true`; do NOT pass --no-verify-jwt).
 *   - The caller's JWT is resolved to their application user row, and a URL is
 *     only minted if that user is the SENDER of the transfer and the transfer
 *     is not completed or expired. transfer_id and file_name are validated,
 *     never trusted raw into the object key.
 *
 * Secrets (Dashboard → Edge Functions → Secrets):
 *   R2_ACCOUNT_ID          Cloudflare account id
 *   R2_ACCESS_KEY_ID       R2 API token access key id
 *   R2_SECRET_ACCESS_KEY   R2 API token secret
 *   R2_BUCKET              Bucket name (defaults to "transfers")
 *
 * When the R2 secrets are absent this returns 503 { error: "r2_not_configured" }
 * and the app silently falls back to the Supabase Storage upload path.
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

/// Must accept exactly what the Dart client's sanitizeFileName can produce
/// and nothing more dangerous: no separators, no traversal, no control chars.
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
    // Deliberate, machine-readable signal: the client falls back to Supabase
    // Storage when it sees this, so the function can be deployed before R2 is.
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

  const transferId = (body.transfer_id ?? "").toString();
  const fileName = (body.file_name ?? "").toString();
  if (!UUID_RE.test(transferId)) {
    return json({ error: "Invalid transfer_id" }, 400);
  }
  if (!isSafeFileName(fileName)) {
    return json({ error: "Invalid file_name" }, 400);
  }

  // --- Authorize: caller must be the sender of a live transfer --------------
  const { data: transfer, error: tErr } = await admin
    .from("transfers")
    .select("id, sender_id, status")
    .eq("id", transferId)
    .maybeSingle();
  if (tErr) {
    console.error("transfer lookup:", tErr.message);
    return json({ error: "Lookup failed" }, 500);
  }
  if (!transfer || transfer.sender_id !== callerUserId) {
    // Same response for "not found" and "not yours" — no existence oracle.
    return json({ error: "Forbidden" }, 403);
  }
  const status = (transfer.status ?? "").toString().toLowerCase();
  if (status === "completed" || status === "expired") {
    return json({ error: "Transfer is not accepting uploads" }, 409);
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
  const signed = await r2.sign(new Request(url, { method: "PUT" }), {
    aws: { signQuery: true },
  });

  return json({ url: signed.url, expires_in: URL_EXPIRES_SECONDS });
});
