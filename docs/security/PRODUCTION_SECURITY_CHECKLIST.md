# MiniGo — Production Security Checklist

Run before every store release. State as of the 2026-11-15 audit is shown; "?" means it could not be checked from the repository and needs the owner.

## Release gate

| Gate | State | Reference |
|---|---|---|
| No open P0 | ✅ none found | — |
| No open P1 without written risk acceptance | ❌ six open | MG-01 … MG-06 |
| File access authorised server-side | ✅ by source review; ? on the deployed database | `API_SECURITY_REPORT.md` T1–T8 |
| Codes resist guessing and enumeration | ⚠️ user codes adequate once MG-01/02 land; room codes not | MG-12, MG-18 |
| Storage private | ✅ `transfers` in migrations; ? deployed. `releases` is public by design | MG-06 |
| Expiry and deletion work | ? | MG-07 |
| APIs enforce authorisation | ✅ by source review; not exercised | T1–T17 |
| No production secrets exposed | ✅ | manual sweep |
| Android configuration reviewed | ✅ | `ANDROID_SECURITY_REPORT.md` |
| iOS configuration reviewed | ✅ reviewed; ❌ not ready | MG-04 |
| Third-party SDKs reviewed | ✅ | `THIRD_PARTY_SDK_INVENTORY.md` |
| Privacy declarations match behaviour | ❌ | MG-14 |
| Abuse reporting and response operational | ❌ | MG-01 |
| Regression tests pass | ✅ 258/258 (client only; no backend tests) | `SECURITY_TEST_RESULTS.md` |
| Production monitoring operational | ? | below |

**Result: do not release.**

## Backend (Supabase dashboard / SQL editor)

- [ ] All migrations applied: `select version from supabase_migrations.schema_migrations order by 1 desc limit 1;` shows `20261115000001` or later.
- [ ] RLS enabled on every public table: `select relname from pg_class where relnamespace='public'::regnamespace and relkind='r' and not relrowsecurity;` returns nothing.
- [ ] No stray permissive policies: review `select tablename, policyname, cmd, roles from pg_policies where schemaname in ('public','storage');`.
- [ ] `transfers` bucket is private and has the size limit: `select id, public, file_size_limit from storage.buckets;`.
- [ ] Expiry job scheduled and succeeding: `select jobname, schedule, active from cron.job;` and recent rows in `cron.job_run_details`.
- [ ] Identity sweep and rate-limit prune scheduled.
- [ ] Vault holds `minigo_project_url` and `minigo_service_role_key`.
- [ ] Edge functions deployed with the intended JWT setting (`verify_jwt = true` for the two signers and the push function).
- [ ] Function secrets set; none of them appear in the client `.env`.
- [ ] Anonymous sign-ins: rate limit set; CAPTCHA or attestation enabled.
- [ ] Database network restrictions and SSL enforcement reviewed.
- [ ] Backups: retention period known and written into the retention policy.
- [ ] No rows older than the stated retention: `select count(*) from transfers where created_at < now() - interval '8 days';` is 0; no `expired` rows with `files_purged_at is null` older than an hour.

## Storage (Cloudflare)

- [ ] R2 bucket is private; one-day lifecycle rule exists.
- [ ] R2 API token is scoped to this bucket only, object read/write.
- [ ] No public development URL enabled on the bucket.

## Android build

- [ ] Built with `--release --obfuscate --split-debug-info`, from a clean commit (the release script currently builds the working tree).
- [ ] Signed with the upload key; Play app-signing certificate hash present in `rasp_config.dart` (MG-03).
- [ ] Merged manifest: no `debuggable`, no unexpected permissions, no restricted media permissions (MG-13).
- [ ] `playStoreListed = true`; QR fallback points to the Play listing (MG-06).
- [ ] Internal-testing install from Play opens normally (no "Reinstall" screen) and completes a transfer.

## iOS build

- [ ] Team, entitlements (`aps-environment`), URL scheme, privacy manifest present (MG-04).
- [ ] Encryption declaration decided.
- [ ] TestFlight build receives a push and opens from a QR link.

## Client configuration

- [ ] `.env` contains only publishable values.
- [ ] Policy, terms and deletion URLs set; role-based contact addresses in place (MG-05).
- [ ] Firebase API keys restricted to the app's package / bundle id.

## Monitoring

- [ ] Alert when `expire-transfers` has not run for 30 minutes or reports errors.
- [ ] Alert on storage growth and egress beyond a threshold.
- [ ] Alert on spikes in transfer creation, lookups rejected by the rate limit, and abuse reports.
- [ ] Crashlytics alerts for `security_threat` non-fatals and velocity.
- [ ] Someone is named as on call for the abuse and security mailboxes.

## Automation still to build (MG-16)

A CI workflow on every pull request running: `flutter analyze`, `flutter test`, osv-scanner on `pubspec.lock`, gitleaks, and a small script that fails on a debuggable release manifest, a cleartext-traffic flag, a restricted permission, an ATS exception, or a non-publishable key in `.env`. New warnings should be reviewed before they are made blocking.
