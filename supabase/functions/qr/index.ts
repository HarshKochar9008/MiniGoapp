/**
 * QR redirect — makes MiniGo QR codes openable from any camera app.
 *
 * Stock cameras only treat http(s) URLs in QR codes as tappable links, so the
 * QR encodes `https://<project>.supabase.co/functions/v1/qr?code=XXXXXX`.
 *
 * Supabase's gateway forces `text/plain` + a sandbox CSP on HTML served from
 * the shared supabase.co domain (anti-phishing), so this endpoint cannot
 * render a page. It answers with a 302 picked by the phone's User-Agent:
 *
 *   Android  an intent:// URL (resolved against the minigo:// BROWSABLE
 *            intent filter in AndroidManifest.xml): opens MiniGo when it's
 *            installed. When it isn't, the browser falls back to the APK in
 *            the public `releases` bucket and asks before downloading it.
 *            `tool/distribute_android.sh --public` uploads that APK.
 *   iPhone   IOS_INSTALL_URL (a TestFlight public link) once it's set with
 *            `supabase secrets set`. iOS can't tell a page whether MiniGo is
 *            installed, so people who have it scan with MiniGo's own scanner.
 *   Other    the raw minigo:// scheme.
 *
 * Public endpoint, no auth (it only echoes a strictly validated 6-char code).
 * Deploy:
 *   supabase functions deploy qr --no-verify-jwt
 */

const ANDROID_PACKAGE = "com.Zen.app";
const ANDROID_APK_PATH = "/storage/v1/object/public/releases/minigo.apk";

// Mirrors AppConstants: 6 chars from an alphabet excluding O, 0, I, 1, L.
const CODE_RE = /^[A-HJ-NP-Z2-9]{6}$/;

Deno.serve((req) => {
  if (req.method !== "GET") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  const url = new URL(req.url);
  const code = (url.searchParams.get("code") ?? "").trim().toUpperCase();
  if (!CODE_RE.test(code)) {
    return new Response("Invalid code", { status: 400 });
  }

  const userAgent = req.headers.get("User-Agent") ?? "";
  const iosInstallUrl = Deno.env.get("IOS_INSTALL_URL");
  let target = `minigo://send?code=${code}`;
  if (/Android/i.test(userAgent)) {
    // Built explicitly: behind the gateway url.origin reports http://.
    const apkUrl = `https://${url.host}${ANDROID_APK_PATH}`;
    target = `intent://send?code=${code}#Intent;scheme=minigo;package=${ANDROID_PACKAGE};S.browser_fallback_url=${
      encodeURIComponent(apkUrl)
    };end`;
  } else if (/iPhone|iPad|iPod/i.test(userAgent) && iosInstallUrl) {
    target = iosInstallUrl;
  }

  return new Response(null, {
    status: 302,
    headers: {
      "Location": target,
      // Response differs by User-Agent — don't let caches mix them up.
      "Cache-Control": "no-store",
    },
  });
});
