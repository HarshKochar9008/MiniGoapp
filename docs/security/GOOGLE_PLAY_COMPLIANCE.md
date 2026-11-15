# MiniGo — Google Play Compliance Assessment

Audit date 2026-11-15 · app 1.0.0+1 · package `com.Zen.app` · internal engineering evidence.

Assessed against the Google Play Developer Program Policies as understood at the audit date. Policies change; re-read the current text in Play Console before submitting. **This does not guarantee approval.**

**Status: READY AFTER CRITICAL REMEDIATION.**

Result: PASS · FAIL · PARTIAL · OWNER (a Play Console or account task that cannot be verified from the repository).

## Matrix

| Area | Requirement | Result | Evidence | Action |
|---|---|---|---|---|
| **User-generated content** | Terms of use that define objectionable content, accepted by users | FAIL | `legal_screens.dart:162-211`; no acceptance step | MG-01 |
| | In-app system to report content and users | FAIL | none in `lib/` | MG-01 |
| | Ability to block users | FAIL | room-host control only | MG-01 |
| | Moderation and timely response to reports | FAIL | no process, no dedicated contact | MG-01, MG-05, `INCIDENT_RESPONSE_PLAN.md` |
| | Child-safety standards (apps enabling user-to-user content sharing): published standards, in-app reporting, designated contact | FAIL | none | MG-01, MG-05 |
| **User data** | Privacy policy at a public URL and in the app | FAIL | in-app only; URLs null | MG-05 |
| | Policy accurately describes collection and sharing | FAIL | `PRIVACY_COMPLIANCE_REPORT.md` | MG-14 |
| | Data safety form matches behaviour, including SDKs | OWNER | draft in `PRIVACY_COMPLIANCE_REPORT.md` | Complete in Console |
| | Account deletion in-app and by web link | PARTIAL | in-app yes; no URL; soft retire | MG-05, MG-23 |
| | Secure handling (encryption in transit) | PASS | HTTPS only | — |
| | Prominent disclosure / consent for non-obvious collection | PARTIAL | crash reports carry the user id and code; disclosed in policy only | MG-21 |
| **Permissions** | Request only what is needed | FAIL | `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_EXTERNAL_STORAGE` unused | MG-13 |
| | Photo and video permissions policy | FAIL until removed | `AndroidManifest.xml:14-15` | MG-13 |
| | No background location, all-files access, install-packages, query-all-packages | PASS | merged manifest | Be ready to explain the runtime-protection SDK's `<queries>` |
| **Device and network abuse** | App does not update itself or download executable code outside Play | PASS | no install or self-update code | — |
| | No steering to off-Play APKs | FAIL | QR links fall back to a public APK | MG-06 |
| **Technical** | Target API level | PASS | targetSdk 36 | — |
| | Release build not debuggable, minified | PASS | `build.gradle.kts`; merged manifest | — |
| | Signed with upload key; Play App Signing | PARTIAL | upload key configured; Play certificate not yet in the tamper check | MG-03 (blocker) |
| | No embedded secrets | PASS | manual sweep | Run gitleaks in CI (MG-16) |
| | Exported components minimal and guarded | PARTIAL | see `ANDROID_SECURITY_REPORT.md` | MG-19, MG-24 |
| | 64-bit, App Bundle | OWNER | release script builds an APK; Play needs an AAB | `flutter build appbundle` |
| **Functionality** | No broken or placeholder features | PARTIAL | paywall is debug-only (OK). The tamper screen says "install from Google Play" and "check for updates" says the build is not from a store while `playStoreListed=false` | Set the flag at listing |
| | Reviewer can exercise the app | PASS | no login; needs two devices or a second install | Provide App access notes below |
| **Deceptive behaviour** | Claims are accurate | PARTIAL | encryption and deletion claims need the qualifiers in MG-07, MG-09, MG-14 | Fix copy |

## Play Console preparation

| Item | Status |
|---|---|
| App access instructions | Draft: "No account. On first launch the app assigns a six-character code. To test a transfer, install on a second device, enter the first device's code on the Send screen, pick a file and swipe to send. The file appears under Receive on the first device." |
| Data safety form | Draft in `PRIVACY_COMPLIANCE_REPORT.md`. |
| Content rating questionnaire | OWNER. Answer "yes" to users being able to share content with each other. |
| Target audience | OWNER. Excluding children avoids the Families requirements; state the minimum age in the terms. |
| Privacy policy URL | Missing (MG-05). |
| Account deletion URL | Missing (MG-05). |
| Store listing | OWNER. Do not claim "anonymous" in a way that implies untraceable; do not over-claim encryption. |
| Closed testing requirement | OWNER. New personal developer accounts must run a closed test with the required number of testers for the required period before production access. |
| Encryption / export declarations | OWNER. |
| Pre-launch report | Run on an internal-testing build **after** MG-03, otherwise every test device locks. |

## Blocking items for Google Play

MG-01, MG-02, MG-03, MG-05, MG-06, MG-13, MG-14. With those closed and the owner tasks done, the residual status would be "ready with documented limitations" (no dynamic test evidence until a staging backend exists).
