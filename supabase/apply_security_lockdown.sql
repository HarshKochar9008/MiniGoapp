-- MiniGo security lockdown — run this whole file once in the Supabase SQL Editor
-- (or: supabase db execute --file supabase/apply_security_lockdown.sql).
-- Idempotent and name-agnostic; safe to re-run. Lines kept short on purpose.

-- 1. columns
alter table public.users add column if not exists public_key text;
alter table public.users add column if not exists deleted_at timestamptz;
alter table public.transfer_files add column if not exists is_encrypted boolean not null default false;
alter table public.transfer_files add column if not exists enc_algo text;
alter table public.transfer_files add column if not exists enc_wrapped_key text;
alter table public.transfer_files add column if not exists enc_nonce text;
alter table public.transfer_files add column if not exists enc_chunk_size integer;

-- 2. enable RLS
alter table public.users enable row level security;
alter table public.transfers enable row level security;
alter table public.transfer_files enable row level security;

-- 3. ensure bucket is private
insert into storage.buckets (id, name, public)
values ('transfers', 'transfers', false)
on conflict (id) do update set public = excluded.public;

-- 4. drop ALL existing policies on our objects (name-agnostic)
do $$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where (schemaname = 'public'
           and tablename in ('users', 'transfers', 'transfer_files'))
       or (schemaname = 'storage' and tablename = 'objects'
           and (policyname like 'transfers%'
                or policyname in ('Auth users can upload',
                                  'Auth users can read',
                                  'Auth users can update')))
  loop
    execute format('drop policy if exists %I on %I.%I',
                   p.policyname, p.schemaname, p.tablename);
  end loop;
end $$;

-- helper: current user's app id(s)
--   auth.uid() = users.auth_uid  (NOT users.id)
--   transfers.sender_id / receiver_id reference users.id

-- 5. users: owner-only
create policy users_select_self on public.users
  for select using (auth_uid = auth.uid());

create policy users_insert_self on public.users
  for insert with check (auth_uid = auth.uid());

create policy users_update_self on public.users
  for update using (auth_uid = auth.uid())
  with check (auth_uid = auth.uid());

-- 6. transfers: participant-scoped
create policy transfers_select_participant on public.transfers
  for select using (
    sender_id in (select id from public.users where auth_uid = auth.uid())
    or receiver_id in (select id from public.users where auth_uid = auth.uid())
  );

create policy transfers_insert_sender on public.transfers
  for insert with check (
    sender_id in (select id from public.users where auth_uid = auth.uid())
  );

create policy transfers_update_sender on public.transfers
  for update using (
    sender_id in (select id from public.users where auth_uid = auth.uid())
  ) with check (
    sender_id in (select id from public.users where auth_uid = auth.uid())
  );

-- 7. transfer_files: scoped via parent transfer
create policy transfer_files_select_participant on public.transfer_files
  for select using (
    exists (
      select 1 from public.transfers t
      where t.id = transfer_files.transfer_id
        and (
          t.sender_id in (select id from public.users where auth_uid = auth.uid())
          or t.receiver_id in (select id from public.users where auth_uid = auth.uid())
        )
    )
  );

create policy transfer_files_insert_sender on public.transfer_files
  for insert with check (
    exists (
      select 1 from public.transfers t
      where t.id = transfer_files.transfer_id
        and t.sender_id in (select id from public.users where auth_uid = auth.uid())
    )
  );

-- 8. storage objects: transfers bucket, participant-scoped
-- path is {transfer_id}/{filename}; foldername(name)[1] = transfer_id
create policy transfers_obj_select on storage.objects
  for select using (
    bucket_id = 'transfers'
    and exists (
      select 1 from public.transfers t
      where t.id::text = (storage.foldername(name))[1]
        and (
          t.sender_id in (select id from public.users where auth_uid = auth.uid())
          or t.receiver_id in (select id from public.users where auth_uid = auth.uid())
        )
    )
  );

create policy transfers_obj_insert on storage.objects
  for insert with check (
    bucket_id = 'transfers'
    and exists (
      select 1 from public.transfers t
      where t.id::text = (storage.foldername(name))[1]
        and t.sender_id in (select id from public.users where auth_uid = auth.uid())
    )
  );

create policy transfers_obj_update on storage.objects
  for update using (
    bucket_id = 'transfers'
    and exists (
      select 1 from public.transfers t
      where t.id::text = (storage.foldername(name))[1]
        and t.sender_id in (select id from public.users where auth_uid = auth.uid())
    )
  ) with check (
    bucket_id = 'transfers'
    and exists (
      select 1 from public.transfers t
      where t.id::text = (storage.foldername(name))[1]
        and t.sender_id in (select id from public.users where auth_uid = auth.uid())
    )
  );

create policy transfers_obj_delete on storage.objects
  for delete using (
    bucket_id = 'transfers'
    and exists (
      select 1 from public.transfers t
      where t.id::text = (storage.foldername(name))[1]
        and t.sender_id in (select id from public.users where auth_uid = auth.uid())
    )
  );

-- 9. shared per-caller throttle (also used by the send-transfer-fcm dry run)
create table if not exists public.rate_limit_counters (
  bucket       text        not null,
  subject      uuid        not null,
  window_start timestamptz not null default now(),
  hits         integer     not null default 0,
  primary key (bucket, subject)
);

-- rls on with no policy = denied for every app role; the owner
-- (security definer) and service_role bypass it.
alter table public.rate_limit_counters enable row level security;
revoke all on table public.rate_limit_counters from public, anon, authenticated;

create index if not exists rate_limit_counters_window_idx
  on public.rate_limit_counters (window_start);

create or replace function public.rate_limit_hit(
  p_bucket text, p_subject uuid, p_limit integer, p_window interval
) returns boolean
language plpgsql security definer set search_path = public
as $fn$
declare v_hits integer;
begin
  if p_subject is null then return false; end if;

  insert into public.rate_limit_counters as c
         (bucket, subject, window_start, hits)
  values (p_bucket, p_subject, now(), 1)
  on conflict (bucket, subject) do update
    set window_start = case
          when c.window_start < now() - p_window then now()
          else c.window_start end,
        hits = case
          when c.window_start < now() - p_window then 1
          else c.hits + 1 end
  returning c.hits into v_hits;

  return v_hits <= p_limit;
end;
$fn$;

revoke all on function public.rate_limit_hit(text, uuid, integer, interval)
  from public, anon, authenticated;
grant execute on function public.rate_limit_hit(text, uuid, integer, interval)
  to service_role;

create or replace function public.prune_rate_limit_counters()
returns integer
language plpgsql security definer set search_path = public
as $fn$
declare v_deleted integer;
begin
  delete from public.rate_limit_counters
  where window_start < now() - interval '1 day';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$fn$;

revoke all on function public.prune_rate_limit_counters()
  from public, anon, authenticated;

-- 10. recipient-lookup RPC: authenticated only, and metered.
-- NOT granted to anon — the anon key ships in the APK, which made this an
-- unauthenticated enumeration oracle over the 6-char code space.
-- drop first: the function's return type has changed over time (nickname was
-- added), and create-or-replace cannot change a return type.
drop function if exists public.lookup_user_by_code(text);
create function public.lookup_user_by_code(p_code text)
returns table (id uuid, short_code text, public_key text, nickname text)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if auth.uid() is null then
    raise exception 'lookup_user_by_code: authentication required';
  end if;

  -- ~1200/hour per identity; a 10-member room send costs 10.
  if not public.rate_limit_hit(
        'lookup_user_by_code', auth.uid(), 200, interval '10 minutes') then
    raise exception
      'lookup_user_by_code: too many lookups, please try again shortly';
  end if;

  return query
    select u.id, u.short_code, u.public_key, u.nickname
    from public.users u
    where u.short_code = upper(trim(p_code))
      and u.deleted_at is null
    limit 1;
end;
$fn$;

revoke all on function public.lookup_user_by_code(text) from public, anon;
grant execute on function public.lookup_user_by_code(text) to authenticated;

-- 11. rooms + room_members: they were created out-of-band (rooms_schema.sql)
-- and never had RLS, while being in the realtime publication. See
-- migrations/20260803000001_rooms_lockdown.sql for the full rationale.

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;

-- security definer predicates: break policy recursion on room_members and let
-- the join policy see a room the joiner cannot select yet. app roles must keep
-- execute — policies are evaluated as the calling role.
create or replace function public.is_room_member(p_room_id uuid)
returns boolean language sql security definer set search_path = public stable
as $fn$
  select exists (
    select 1 from public.room_members m
    join public.users u on u.id = m.user_id
    where m.room_id = p_room_id and u.auth_uid = auth.uid()
  );
$fn$;

create or replace function public.is_room_owner(p_room_id uuid)
returns boolean language sql security definer set search_path = public stable
as $fn$
  select exists (
    select 1 from public.rooms r
    join public.users u on u.id = r.owner_id
    where r.id = p_room_id and u.auth_uid = auth.uid()
  );
$fn$;

create or replace function public.room_is_joinable(p_room_id uuid)
returns boolean language sql security definer set search_path = public stable
as $fn$
  select exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.expires_at > now()
  );
$fn$;

revoke all on function public.is_room_member(uuid) from public;
revoke all on function public.is_room_owner(uuid) from public;
revoke all on function public.room_is_joinable(uuid) from public;
grant execute on function public.is_room_member(uuid) to anon, authenticated;
grant execute on function public.is_room_owner(uuid) to anon, authenticated;
grant execute on function public.room_is_joinable(uuid) to anon, authenticated;

do $$
declare p record;
begin
  for p in
    select tablename, policyname from pg_policies
    where schemaname = 'public' and tablename in ('rooms', 'room_members')
  loop
    execute format('drop policy if exists %I on public.%I',
                   p.policyname, p.tablename);
  end loop;
end $$;

-- owner clause is required for createRoom's insert..returning (no membership
-- row exists yet at that instant)
create policy rooms_select_member on public.rooms
  for select using (
    public.is_room_member(id)
    or owner_id in (select id from public.users where auth_uid = auth.uid())
  );

create policy rooms_insert_owner on public.rooms
  for insert with check (
    owner_id in (select id from public.users where auth_uid = auth.uid())
  );

create policy rooms_update_owner on public.rooms
  for update using (
    owner_id in (select id from public.users where auth_uid = auth.uid())
  ) with check (
    owner_id in (select id from public.users where auth_uid = auth.uid())
  );

create policy rooms_delete_owner on public.rooms
  for delete using (
    owner_id in (select id from public.users where auth_uid = auth.uid())
  );

create policy room_members_select_member on public.room_members
  for select using (public.is_room_member(room_id));

create policy room_members_insert_self on public.room_members
  for insert with check (
    user_id in (select id from public.users where auth_uid = auth.uid())
    and public.room_is_joinable(room_id)
  );

create policy room_members_update_host on public.room_members
  for update using (public.is_room_owner(room_id))
  with check (public.is_room_owner(room_id));

create policy room_members_delete_self_or_host on public.room_members
  for delete using (
    user_id in (select id from public.users where auth_uid = auth.uid())
    or public.is_room_owner(room_id)
  );

-- member cap must be security definer: under the new select policy a joining
-- non-member counts 0 existing rows, so the cap would silently stop working.
create or replace function public.room_members_enforce_limits()
returns trigger language plpgsql security definer set search_path = public
as $fn$
declare
  v_expires timestamptz;
  v_count   integer;
begin
  select r.expires_at into v_expires
  from public.rooms r where r.id = NEW.room_id;
  if v_expires is null then raise exception 'room_not_found'; end if;
  if v_expires <= now() then raise exception 'room_expired'; end if;

  select count(*) into v_count
  from public.room_members m where m.room_id = NEW.room_id;
  if v_count >= 10 then raise exception 'room_full'; end if;

  return NEW;
end;
$fn$;

-- the original out-of-band trigger reads `rooms` as the invoking user; with
-- rooms now RLS-scoped a joiner sees no row there, so it would stop enforcing
-- the cap or raise a spurious room_not_found. superseded by the function above.
do $$
declare t record;
begin
  for t in
    select tg.tgname from pg_trigger tg
    where tg.tgrelid = 'public.room_members'::regclass
      and not tg.tgisinternal
      and tg.tgname <> 'room_members_enforce_limits'
      and (tg.tgtype & 2) <> 0   -- before
      and (tg.tgtype & 4) <> 0   -- insert
  loop
    raise notice
      'rooms_lockdown: superseding BEFORE INSERT trigger % on room_members',
      t.tgname;
    execute format('drop trigger if exists %I on public.room_members', t.tgname);
  end loop;
end $$;

drop trigger if exists room_members_enforce_limits on public.room_members;
create trigger room_members_enforce_limits
  before insert on public.room_members
  for each row execute function public.room_members_enforce_limits();

revoke all on function public.room_members_enforce_limits()
  from public, anon, authenticated;

-- join-by-code RPC (rooms select is membership-scoped). Expiry is NOT filtered
-- so the client can still tell "expired" apart from "not found".
drop function if exists public.lookup_room_by_code(text);
create function public.lookup_room_by_code(p_code text)
returns table (id uuid, code text, name text, owner_id uuid,
               expires_at timestamptz)
language sql security definer set search_path = public stable
as $fn$
  select r.id, r.code, r.name, r.owner_id, r.expires_at
  from public.rooms r
  where r.code = upper(trim(p_code))
  limit 1;
$fn$;

revoke all on function public.lookup_room_by_code(text) from public, anon;
grant execute on function public.lookup_room_by_code(text) to authenticated;

-- 12. displayed identity is derived server-side, and participants are frozen.
-- transfers_update_sender only re-asserts sender_id, so the sender could
-- otherwise rewrite receiver_id / sender_code / created_at after upload — and
-- sender_code is what the receiver's UI actually displays now that the users
-- join returns null for a counterparty. Same pattern on room_members.

create or replace function public.transfers_derive_codes()
returns trigger language plpgsql security definer set search_path = public
as $fn$
begin
  new.sender_code := (
    select u.short_code from public.users u where u.id = new.sender_id);
  if new.receiver_id is null then
    new.receiver_code := null;
  else
    new.receiver_code := (
      select u.short_code from public.users u where u.id = new.receiver_id);
  end if;
  return new;
end;
$fn$;

drop trigger if exists transfers_derive_codes on public.transfers;
create trigger transfers_derive_codes
  before insert on public.transfers
  for each row execute function public.transfers_derive_codes();

revoke all on function public.transfers_derive_codes()
  from public, anon, authenticated;

-- NOT frozen: status / upload_progress (the sender updates both), and room_id
-- (rooms.id is ON DELETE SET NULL, and that referential action is a real
-- UPDATE that fires this trigger — freezing it would break room deletion).
create or replace function public.transfers_freeze_participants()
returns trigger language plpgsql set search_path = public
as $fn$
begin
  if new.id is distinct from old.id
     or new.sender_id     is distinct from old.sender_id
     or new.receiver_id   is distinct from old.receiver_id
     or new.sender_code   is distinct from old.sender_code
     or new.receiver_code is distinct from old.receiver_code
     or new.room_name     is distinct from old.room_name
     or new.created_at    is distinct from old.created_at then
    raise exception 'transfer participants and creation time cannot be changed';
  end if;
  return new;
end;
$fn$;

drop trigger if exists transfers_freeze_participants on public.transfers;
create trigger transfers_freeze_participants
  before update on public.transfers
  for each row execute function public.transfers_freeze_participants();

revoke all on function public.transfers_freeze_participants()
  from public, anon, authenticated;

create or replace function public.room_members_derive_identity()
returns trigger language plpgsql security definer set search_path = public
as $fn$
begin
  select u.short_code, u.nickname into new.short_code, new.nickname
  from public.users u where u.id = new.user_id;
  return new;
end;
$fn$;

drop trigger if exists room_members_derive_identity on public.room_members;
create trigger room_members_derive_identity
  before insert or update on public.room_members
  for each row execute function public.room_members_derive_identity();

revoke all on function public.room_members_derive_identity()
  from public, anon, authenticated;

-- 13. transfer_files.file_name is sender-controlled and lands in
-- File.copy('<dir>/<file_name>') on the receiver. not valid = enforced going
-- forward without re-scanning pre-existing rows.
alter table public.transfer_files
  drop constraint if exists transfer_files_file_name_safe;
alter table public.transfer_files
  add constraint transfer_files_file_name_safe check (
    file_name is not null
    and length(file_name) between 1 and 255
    and file_name !~ '[/\\]'
    and file_name !~ '\.\.'
    and file_name !~ '[[:cntrl:]]'
    and btrim(file_name, '. ') <> ''
  ) not valid;

alter table public.transfer_files
  drop constraint if exists transfer_files_storage_path_safe;
alter table public.transfer_files
  add constraint transfer_files_storage_path_safe check (
    storage_path is null
    or (
      length(storage_path) between 1 and 512
      and storage_path !~ '\.\.'
      and storage_path !~ '[[:cntrl:]]'
      and storage_path !~ '^/'
    )
  ) not valid;

-- 14. every file row must be integrity-checkable, and every encrypted row must
-- say which chunk format it is in (v1 cannot detect truncation; v2 can).
alter table public.transfer_files
  drop constraint if exists transfer_files_sha256_present;
alter table public.transfer_files
  add constraint transfer_files_sha256_present check (
    sha256_hash is not null
    and sha256_hash ~ '^[0-9a-f]{64}$'
  ) not valid;

alter table public.transfer_files
  drop constraint if exists transfer_files_enc_algo_known;
alter table public.transfer_files
  add constraint transfer_files_enc_algo_known check (
    is_encrypted is not true
    or enc_algo in ('x25519-aesgcm-v1', 'x25519-aesgcm-v2')
  ) not valid;
