# MiniGo — Incident Response Plan

Version 0.1 (draft) · 2026-11-15 · proposed by the security audit. **Not yet adopted:** names, mailboxes and timings below need the owner's decisions, and the abuse-report tooling it refers to does not exist yet (MG-01).

## Roles

| Role | Who | Backup |
|---|---|---|
| Incident lead | _to assign_ | _to assign_ |
| Backend operator (Supabase, Cloudflare, Firebase access) | _to assign_ | _to assign_ |
| Communications (users, stores, authorities) | _to assign_ | — |

Contact points to create: `security@`, `abuse@`, `support@` on a project domain. Today the only address is a personal mailbox.

## Severity

| Level | Examples | First response |
|---|---|---|
| SEV1 | Service-role key, R2 key or signing key exposed; unauthorised access to other users' data; report of child sexual abuse material or imminent harm | Immediately |
| SEV2 | Mass abuse (spam, storage flooding); expiry job not deleting; a P1 vulnerability reported | Within 4 hours |
| SEV3 | Single abuse report; minor vulnerability; SDK advisory | Within 1 business day |

## Process

1. **Record.** Open an incident note: time, reporter, what is known. Keep times in UTC.
2. **Contain.** Use the playbook below.
3. **Assess.** What data, how many users, for how long.
4. **Eradicate and recover.** Fix, deploy, verify.
5. **Notify.** Users and regulators where the law requires it (for personal-data breaches under GDPR, the authority within 72 hours). Tell Apple or Google if a store build is affected.
6. **Review.** Within a week: cause, what worked, what changes. Add the item to `VULNERABILITY_REMEDIATION_LOG.md`.

## Playbooks

### Service-role key or database credential exposed
Rotate the key in the Supabase dashboard; update the Vault secret `minigo_service_role_key` so the expiry job keeps working; redeploy edge functions; review logs for use of the old key; check for unexpected rows, policies and functions.

### R2 credentials exposed
Revoke the token; create a new bucket-scoped token; update function secrets; review bucket access logs. Stored content is ciphertext, but object keys include file names.

### FCM service account exposed
Disable the key in Google Cloud; create a new one; update the function secret. Risk is spoofed notifications to users.

### Android upload key exposed
Request an upload-key reset in Play Console; update `key.properties` and the pinned hash in `rasp_config.dart`; ship a new build.

### Abuse report (single)
1. Acknowledge to the reporter.
2. Identify the transfer and sender from the report record. **Do not** attempt to obtain file contents; the service cannot decrypt them and should not collect them.
3. If credible: retire the sender's identity (`deleted_at`), remove the transfer's stored objects, keep the report record.
4. Repeat offenders: add the sender to the block list for the reporter automatically; consider device-level attestation signals if available.

### Illegal content, including CSAM
Treat as SEV1. Do not view, copy or forward the material. Preserve the relevant records (identifiers, timestamps) and stored objects as required by law; disable the sender; report to the competent authority (for example NCMEC's CyberTipline in the United States, or the national hotline where the operator is established). Take legal advice on preservation and reporting duties before launch so this step is not improvised.

### Mass abuse or storage flooding
Lower rate limits; temporarily disable anonymous sign-ups or enable CAPTCHA; identify offending identities by volume and retire them; run the expiry function manually; confirm storage returns to normal.

### Expiry not deleting
Check `cron.job_run_details` and function logs; run the function manually with the service key; look for transfers stuck with `files_purged_at is null`; correct user-facing claims if the gap was material.

### Vulnerability report
Acknowledge within 2 business days; reproduce on staging; fix by severity (P1 within 7 days as a target); credit the reporter if they wish. Publish a `security.txt` or a policy page with the contact.

### Takedown or legal request
Log it; verify the requester; act on stored objects and identities within the retention limits; respond in writing. The service holds metadata and ciphertext only, and most data is gone within 24 hours to 7 days.

## What can and cannot be provided

Available: account id, code, nickname if set, push token, transfer records (who, when, file names and sizes) for up to 7 days, stored ciphertext for up to 24 hours, provider logs per their retention. Not available: file contents of encrypted transfers, real-world identity, phone number, email.

## Evidence handling

Keep only what the incident needs, with access limited to the incident lead and operator. Delete it when the incident closes unless law requires longer. Never put file content, tokens or keys in tickets or chat.
