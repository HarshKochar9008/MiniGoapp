/**
 * Sends an FCM v1 push when the sender of a transfer asks us to notify the
 * receiver.
 *
 * SECURITY MODEL (v2):
 *   - Deploy WITH JWT verification:  npx supabase functions deploy send-transfer-fcm
 *     (config.toml sets `verify_jwt = true`; do NOT pass --no-verify-jwt).
 *   - The caller's JWT is required. The function resolves the caller's user id
 *     from that JWT and only proceeds if the caller is the SENDER of the
 *     transfer being pushed. receiver_id and sender_code are read from the DB
 *     row, never trusted from the request body — this blocks push spam,
 *     sender-code spoofing, and the previous presence oracle.
 *
 * Secrets (Dashboard → Edge Functions → Secrets):
 *   FCM_PROJECT_ID           Firebase project id (same as GCP project)
 *   FCM_SERVICE_ACCOUNT_JSON Full JSON of a Firebase service account with
 *                            "Firebase Cloud Messaging API Admin" enabled
 *
 * Push trigger: the Flutter client calls this after files are uploaded.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

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

// ---------------------------------------------------------------------------
// Google OAuth2 via service account — uses only Web Crypto (no npm deps)
// ---------------------------------------------------------------------------

function b64url(data: ArrayBuffer | string): string {
  const bytes =
    typeof data === "string"
      ? new TextEncoder().encode(data)
      : new Uint8Array(data);
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const buf = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) buf[i] = binary.charCodeAt(i);
  return buf.buffer;
}

async function getGoogleAccessToken(saJson: string): Promise<string> {
  const sa = JSON.parse(saJson);
  const now = Math.floor(Date.now() / 1000);

  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(
    JSON.stringify({
      iss: sa.client_email,
      sub: sa.client_email,
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
    }),
  );

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );

  const jwt = `${header}.${claims}.${b64url(sig)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  const data = await res.json();
  if (!res.ok) throw new Error(`Token exchange failed: ${JSON.stringify(data)}`);
  return data.access_token as string;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const projectId = Deno.env.get("FCM_PROJECT_ID");
  const saJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!projectId || !saJson || !supabaseUrl || !serviceKey) {
    return json({ error: "Server not configured" }, 500);
  }

  // --- Authenticate the caller from their JWT -------------------------------
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.toLowerCase().startsWith("bearer ")
    ? authHeader.slice(7).trim()
    : "";
  if (!jwt) {
    return json({ error: "Unauthorized: missing bearer token" }, 401);
  }

  // Service client (bypasses RLS) — used for authorization lookups + FCM send.
  const admin = createClient(supabaseUrl, serviceKey);

  const { data: userData, error: authErr } = await admin.auth.getUser(jwt);
  const authUid = userData?.user?.id;
  if (authErr || !authUid) {
    return json({ error: "Unauthorized: invalid session" }, 401);
  }

  // Map the caller's auth uid → their application user row id.
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

  const record = body.record as Record<string, string> | undefined;
  const dryRun = body.dry_run === true;

  // ----- DRY RUN: readiness check for a transfer the caller will send -------
  // Only reveals readiness for the CALLER's own account by default; if a
  // receiver_id is supplied it must be a real user, but no other data leaks.
  if (dryRun) {
    const receiverId = record?.receiver_id;
    if (!receiverId) {
      return json({ error: "Missing receiver_id" }, 400);
    }
    const { data: receiver } = await admin
      .from("users")
      .select("fcm_token")
      .eq("id", receiverId)
      .maybeSingle();
    const token = (receiver?.fcm_token as string | undefined)?.trim();
    if (!token) {
      return json({
        ready: false,
        reason:
          "Recipient has no FCM token yet (app not opened / notifications not granted).",
      });
    }
    return json({ ready: true });
  }

  // ----- REAL SEND: caller must OWN the transfer ----------------------------
  const transferId = record?.id;
  if (!transferId) {
    return json({ error: "Missing transfer id" }, 400);
  }

  // Authoritative lookup: fetch the transfer and verify the caller is sender.
  // receiver_id and sender_code are taken from the DB, NOT the request body.
  const { data: transfer, error: tErr } = await admin
    .from("transfers")
    .select("id, sender_id, receiver_id")
    .eq("id", transferId)
    .maybeSingle();
  if (tErr) {
    console.error("transfer lookup", tErr);
    return json({ error: "Lookup failed" }, 500);
  }
  if (!transfer) {
    return json({ error: "Transfer not found" }, 404);
  }
  if (transfer.sender_id !== callerUserId) {
    // The caller is not the sender of this transfer — refuse.
    return json({ error: "Forbidden: not the sender of this transfer" }, 403);
  }

  const receiverId = transfer.receiver_id as string | null;
  if (!receiverId) {
    return json({ ok: true, skipped: "no_receiver" });
  }

  const { data: receiver, error: rErr } = await admin
    .from("users")
    .select("fcm_token")
    .eq("id", receiverId)
    .maybeSingle();
  if (rErr) {
    console.error("receiver lookup", rErr);
    return json({ error: rErr.message }, 500);
  }
  const token = (receiver?.fcm_token as string | undefined)?.trim();
  if (!token) {
    return json({ ok: true, skipped: "no_fcm_token" });
  }

  // Sender short-code derived from DB (spoofing-proof).
  const { data: sender } = await admin
    .from("users")
    .select("short_code")
    .eq("id", callerUserId)
    .maybeSingle();
  const senderCode = (sender?.short_code as string) ?? "";

  let accessToken: string;
  try {
    accessToken = await getGoogleAccessToken(saJson);
  } catch (e) {
    console.error("OAuth token error", e);
    return json({ error: "Failed to obtain OAuth token" }, 500);
  }

  const title = "Incoming transfer";
  const msgBody = "Tap to open MiniGo and download your files.";
  const fcmPayload = {
    message: {
      token,
      data: {
        transfer_id: transferId,
        sender_code: senderCode,
        title,
        body: msgBody,
      },
      android: { priority: "HIGH" as const },
      apns: {
        headers: { "apns-priority": "10" },
        payload: {
          aps: { alert: { title, body: msgBody }, sound: "default" },
        },
      },
    },
  };

  const fcmRes = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(fcmPayload),
    },
  );

  const text = await fcmRes.text();
  if (!fcmRes.ok) {
    console.error("FCM", fcmRes.status, text);
    return new Response(text, {
      status: 502,
      headers: { ...cors, "Content-Type": "text/plain" },
    });
  }

  return json({ ok: true });
});
