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

-- 9. recipient-lookup RPC
create or replace function public.lookup_user_by_code(p_code text)
returns table (id uuid, short_code text, public_key text)
language sql
security definer
set search_path = public
stable
as $fn$
  select u.id, u.short_code, u.public_key
  from public.users u
  where u.short_code = upper(trim(p_code))
    and u.deleted_at is null
  limit 1;
$fn$;

revoke all on function public.lookup_user_by_code(text) from public;
grant execute on function public.lookup_user_by_code(text) to anon, authenticated;
