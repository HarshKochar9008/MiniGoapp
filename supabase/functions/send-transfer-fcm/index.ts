/**
 * Sends an FCM v1 push when a new row is inserted into `transfers`.
 *
 * Deploy:
 *   npx supabase functions deploy send-transfer-fcm --no-verify-jwt
 *
 * Secrets (Dashboard → Edge Functions → Secrets):
 *   FCM_PROJECT_ID          Firebase project id (same as GCP project)
 *   FCM_SERVICE_ACCOUNT_JSON Full JSON of a Firebase service account with
 *                            "Firebase Cloud Messaging API Admin" enabled
 *
 * Push trigger: the **Flutter client** calls this function after files are uploaded
 * (`TransferService`). Do **not** also add a Database Webhook on `transfers` INSERT — that
 * would send duplicate FCMs for the same transfer (multiple notifications).
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

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

  const projectId = Deno.env.get("FCM_PROJECT_ID");
  const saJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!projectId || !saJson) {
    return new Response(
      JSON.stringify({ error: "Missing FCM_PROJECT_ID or FCM_SERVICE_ACCOUNT_JSON" }),
      { status: 500, headers: { ...cors, "Content-Type": "application/json" } },
    );
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const record = body.record as Record<string, string> | undefined;
  const dryRun = body.dry_run === true;
  if ((!dryRun && !record?.id) || !record?.receiver_id) {
    return new Response(JSON.stringify({ error: "Missing transfer record" }), {
      status: 400,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, serviceKey);

  const { data: receiver, error: rErr } = await supabase
    .from("users")
    .select("fcm_token")
    .eq("id", record.receiver_id)
    .maybeSingle();

  if (rErr) {
    console.error("receiver lookup", rErr);
    return new Response(JSON.stringify({ error: rErr.message }), {
      status: 500,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const token = receiver?.fcm_token as string | undefined;
  if (!token) {
    if (dryRun) {
      return new Response(
        JSON.stringify({
          ready: false,
          reason: "Recipient has no FCM token yet (app not opened / notifications not granted).",
        }),
        { status: 200, headers: { ...cors, "Content-Type": "application/json" } },
      );
    }
    return new Response(
      JSON.stringify({ ok: true, skipped: "no_fcm_token" }),
      { status: 200, headers: { ...cors, "Content-Type": "application/json" } },
    );
  }

  if (dryRun) {
    return new Response(
      JSON.stringify({ ready: true }),
      { status: 200, headers: { ...cors, "Content-Type": "application/json" } },
    );
  }

  let senderCode = "";
  if (record.sender_id) {
    const { data: sender } = await supabase
      .from("users")
      .select("short_code")
      .eq("id", record.sender_id)
      .maybeSingle();
    senderCode = (sender?.short_code as string) ?? "";
  }

  let accessToken: string;
  try {
    accessToken = await getGoogleAccessToken(saJson);
  } catch (e) {
    console.error("OAuth token error", e);
    return new Response(JSON.stringify({ error: "Failed to obtain OAuth token" }), {
      status: 500,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  // No top-level `notification` on Android: avoids a system tray entry that duplicates the
  // Flutter local notification (logo + single slot per transfer_id). Title/body live in
  // `data` for the app and in `apns` for iOS banner when backgrounded.
  const title = "Incoming transfer";
  const msgBody = "Tap to open Whoosh and download your files.";
  const fcmPayload = {
    message: {
      token,
      data: {
        transfer_id: record.id,
        sender_code: senderCode,
        title,
        body: msgBody,
      },
      android: {
        priority: "HIGH" as const,
      },
      apns: {
        headers: { "apns-priority": "10" },
        payload: {
          aps: {
            alert: { title, body: msgBody },
            sound: "default",
          },
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

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { ...cors, "Content-Type": "application/json" },
  });
});
