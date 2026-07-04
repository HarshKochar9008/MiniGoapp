-- ============================================================================
-- 20260704000005_denormalize_codes
-- ----------------------------------------------------------------------------
-- After the users lockdown, a caller can only read their OWN users row, so the
-- history / rooms screens could no longer resolve the *counterparty's* short
-- code via a users join (it showed "???"). Rather than re-widen users access,
-- we denormalize the display code onto the rows the counterparties can already
-- see: transfers (participant-scoped) and room_members (room-scoped).
--
-- Idempotent: safe to re-run. Includes a one-time backfill for existing rows.
-- ============================================================================

alter table public.transfers add column if not exists sender_code text;
alter table public.transfers add column if not exists receiver_code text;

alter table public.room_members add column if not exists short_code text;
alter table public.room_members add column if not exists nickname text;

-- Backfill existing rows (runs as the migration/service role, bypassing RLS).
update public.transfers t
set sender_code = su.short_code
from public.users su
where t.sender_id = su.id and t.sender_code is null;

update public.transfers t
set receiver_code = ru.short_code
from public.users ru
where t.receiver_id = ru.id and t.receiver_code is null;

update public.room_members m
set short_code = u.short_code,
    nickname   = u.nickname
from public.users u
where m.user_id = u.id and m.short_code is null;
