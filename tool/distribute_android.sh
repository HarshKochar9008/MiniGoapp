#!/usr/bin/env bash
# Builds a release APK and uploads it to Firebase App Distribution. Every
# phone in the "devices" tester group gets a notification and installs the
# update through the Firebase App Tester app — no cable, no laptop nearby.
#
#   tool/distribute_android.sh                     # release notes from git
#   tool/distribute_android.sh "new onboarding"    # your own release notes
#   tool/distribute_android.sh --public [notes]    # also the public download
#
# --public also replaces the APK that people without MiniGo download when
# they scan a MiniGo QR code with their camera (supabase/functions/qr).
# Anyone with the link can download it.
#
# One-time setup: `firebase login`, then add each phone's Google account:
#   firebase appdistribution:testers:add --project zensend-da43c \
#     --group-alias devices someone@gmail.com
# For --public: `supabase link`, and the releases bucket migration applied.
set -euo pipefail

PUBLIC=0
if [[ "${1:-}" == "--public" ]]; then
  PUBLIC=1
  shift
fi

cd "$(dirname "$0")/.."

PROJECT=zensend-da43c
# mobilesdk_app_id of com.Zen.app in android/app/google-services.json.
APP_ID=1:454168249027:android:1a50dcafc57eaf2a055876
GROUP=devices
APK=build/app/outputs/flutter-apk/app-release.apk
# Dart symbol files for the obfuscated build (build/ is git-ignored).
SYMBOLS=build/symbols/android

# Release builds need the upload key: phones refuse to update over a build
# signed with another key, and freeRASP treats any other key as tampering.
if [[ ! -f android/key.properties ]]; then
  echo "android/key.properties is missing — release builds need the upload key." >&2
  exit 1
fi

# pubspec stays at +1 between store releases, so give each upload a version
# code that always goes up (minutes since the epoch, ~29.7M — well under
# Android's 2.1B cap) and Android and App Tester treat it as an update.
BUILD_NUMBER=$(( $(date +%s) / 60 ))

if [[ $# -gt 0 ]]; then
  NOTES="$*"
else
  DIRTY=$(git diff --quiet HEAD -- || echo " + uncommitted changes")
  NOTES="$(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)${DIRTY}
$(git log -1 --format=%s)"
fi

# Obfuscated like a store build, so testers run what users will.
flutter build apk --release --build-number="$BUILD_NUMBER" \
  --obfuscate --split-debug-info="$SYMBOLS"

firebase appdistribution:distribute "$APK" \
  --project "$PROJECT" \
  --app "$APP_ID" \
  --groups "$GROUP" \
  --release-notes "$NOTES"

FAILED=0
# no-cache: a scan right after an upload gets the new build, not a cached one.
PUBLISH=(supabase storage cp "$APK" ss:///releases/minigo.apk --linked
  --experimental --content-type application/vnd.android.package-archive
  --cache-control no-cache)
if [[ $PUBLIC == 1 ]] && ! "${PUBLISH[@]}"; then
  echo "Build distributed, but the public APK upload failed. Retry:" >&2
  echo "  ${PUBLISH[*]}" >&2
  FAILED=1
fi

# Without these, Crashlytics shows obfuscated stack traces for this build.
if ! firebase crashlytics:symbols:upload --app="$APP_ID" "$SYMBOLS"; then
  echo "Build distributed, but the Crashlytics symbol upload failed. Retry:" >&2
  echo "  firebase crashlytics:symbols:upload --app=$APP_ID $SYMBOLS" >&2
  FAILED=1
fi
exit $FAILED
