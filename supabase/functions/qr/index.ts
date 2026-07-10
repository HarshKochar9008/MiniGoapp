/**
 * QR redirect — makes MiniGo QR codes openable from any camera app.
 *
 * Stock cameras only treat http(s) URLs in QR codes as tappable links, so the
 * QR encodes `https://<project>.supabase.co/functions/v1/qr?code=XXXXXX`.
 *
 * Supabase's gateway forces `text/plain` + a sandbox CSP on HTML served from
 * the shared supabase.co domain (anti-phishing), so this endpoint cannot
 * render a redirect *page*. Instead it answers with a 302 straight to the
 * app: an Android intent:// URL (resolved against the minigo:// BROWSABLE
 * intent filter in AndroidManifest.xml) whose browser_fallback_url points
 * back here with ?fallback=1 — a plain-text page shown when the app is not
 * installed. Non-Android visitors get the raw minigo:// scheme attempt.
 *
 * Public endpoint, no auth (it only echoes a strictly validated 6-char code).
 * Deploy:
 *   supabase functions deploy qr --no-verify-jwt
 */

const ANDROID_PACKAGE = "com.Zen.app";

// Mirrors AppConstants: 6 chars from an alphabet excluding O, 0, I, 1, L.
const CODE_RE = /^[A-HJ-NP-Z2-9]{6}$/;

function fmtCode(code: string): string {
  return `${code.slice(0, 3)} · ${code.slice(3)}`;
}

Deno.serve((req) => {
  if (req.method !== "GET") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  const url = new URL(req.url);
  const code = (url.searchParams.get("code") ?? "").trim().toUpperCase();
  if (!CODE_RE.test(code)) {
    return new Response("Invalid code", { status: 400 });
  }

  // App missing (or a browser that refused the intent) lands back here.
  if (url.searchParams.get("fallback") === "1") {
    return new Response(
      `MiniGo send code: ${fmtCode(code)}\n\n` +
        `Install MiniGo, then enter this code in the Send screen to ` +
        `share files with this person.`,
      {
        status: 200,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      },
    );
  }

  // Build the external URL explicitly: behind the gateway url.origin reports
  // http:// and url.pathname has the /functions/v1 prefix already stripped.
  const fallbackUrl =
    `https://${url.host}/functions/v1/qr?code=${code}&fallback=1`;
  const isAndroid = /Android/i.test(req.headers.get("User-Agent") ?? "");
  const target = isAndroid
    ? `intent://send?code=${code}#Intent;scheme=minigo;package=${ANDROID_PACKAGE};S.browser_fallback_url=${
      encodeURIComponent(fallbackUrl)
    };end`
    : `minigo://send?code=${code}`;

  return new Response(null, {
    status: 302,
    headers: {
      "Location": target,
      // Response differs by User-Agent — don't let caches mix them up.
      "Cache-Control": "no-store",
    },
  });
});
