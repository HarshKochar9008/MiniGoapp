# MiniGo — Apple App Store Compliance Assessment

Audit date 2026-11-15 · app 1.0.0+1 · bundle id `com.zen.app` · internal engineering evidence.

Assessed against the App Store Review Guidelines as understood at the audit date. Re-read the current guidelines before submitting. **This does not guarantee approval.**

**Status: NOT READY.** The project cannot currently be signed and uploaded, and the user-generated-content requirements are unmet.

Result: PASS · FAIL · PARTIAL · OWNER (an App Store Connect or account task).

## Matrix

| Guideline | Requirement | Result | Evidence | Action |
|---|---|---|---|---|
| **1.2 User-generated content** | Applies: users deliver files to other users. Anonymity does not exempt the app. | — | — | — |
| | Method for filtering objectionable material | FAIL | Content is end-to-end encrypted, so server filtering is not possible. Compensating controls (consent, block, report, throttles) are absent. | MG-01, MG-02 |
| | Mechanism to report offensive content, with timely response | FAIL | none | MG-01 |
| | Ability to block abusive users | FAIL | none between individuals | MG-01 |
| | Published contact information | PARTIAL | a personal email address, in-app only | MG-05 |
| | Terms the user agrees to, with no tolerance for objectionable content | FAIL | four-sentence terms, no acceptance | MG-01 |
| **1.6 Data security** | Protect user data from unauthorised access | PARTIAL | Strong server-side authorisation and E2E encryption. Session tokens outside the Keychain; decrypted files in a shared, backed-up folder. | MG-11, MG-15 |
| **2.1 App completeness** | No placeholders; all features work | FAIL | Push and QR deep links cannot work on iOS as configured | MG-04 |
| **2.3 Accurate metadata** | Claims match behaviour | PARTIAL | encryption and deletion wording | MG-07, MG-09, MG-14 |
| **2.5.4 Background modes** | Used only for their purpose | PASS | `remote-notification` only | — |
| **3.1 Payments** | — | PASS | paywall is debug-only; no purchases | Keep it out of release builds |
| **4.2 Minimum functionality** | — | PASS | native app with clear utility | — |
| **5.1.1 Data collection** | Privacy policy link in App Store Connect and in the app | FAIL | no hosted URL | MG-05 |
| | Policy identifies data, uses, third parties, retention and deletion | FAIL | omissions and inaccuracies | MG-14 |
| | Account deletion in the app | PARTIAL | present; soft retire | MG-23 |
| | Permission purpose strings accurate | PARTIAL | Photos read-write string vs add-only request | MG-15 |
| **5.1.2 Data use and sharing** | Disclose third-party sharing; no tracking without consent | PARTIAL | no tracking; Talsec undisclosed | MG-14 |
| **Privacy manifest** | App-level `PrivacyInfo.xcprivacy` with required-reason APIs | FAIL | absent | MG-04 |
| | Third-party SDK manifests and signatures | PARTIAL | most plugins ship one; three wrappers do not; signatures not checked | Verify on an archive build |
| **Export compliance** | Accurate encryption declaration | NEEDS DECISION | flag is `false`; app uses its own standard-algorithm encryption | MG-04 |
| **Signing** | Distribution-signed with entitlements | FAIL | no team, no entitlements | MG-04 |
| **5.6 / Developer identity** | Reachable support | PARTIAL | personal address | MG-05 |

## App Review preparation

| Item | Status |
|---|---|
| Reviewer can test the whole flow | Needs two devices. Provide notes and, ideally, a standing demo recipient code that auto-accepts so a single reviewer device can send. Offer a short screen recording of a two-device transfer. |
| Backend live during review | OWNER. The service-unavailable sheet exists; make sure the project is not paused. |
| Review notes | Explain: no login; what the six-character code is; that content is end-to-end encrypted and therefore moderated by report, block and account action; where report and block are in the UI; the encryption declaration. |
| App Privacy answers | Draft in `PRIVACY_COMPLIANCE_REPORT.md`. |
| Age rating | OWNER. Unrestricted user-to-user file sharing typically requires 17+. |
| iPad | The target includes iPad in all orientations; either test and support it or restrict to iPhone. |

## Blocking items for the App Store

MG-04 (project readiness), MG-01, MG-02, MG-05, MG-14, plus an Apple Developer Program membership. MG-06 applies once the iOS QR fallback is switched from a TestFlight link to the App Store URL.
