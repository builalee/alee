-- ============================================================
-- OBJECTIVE:      Record what each person agreed to, which version of the
--                 notice they saw, and when, as an add-only log.
-- WHY:            Consent is logged separately from the terms, and must be
--                 provable later. A record is never changed: a withdrawal
--                 is a new row with granted = false.
-- CHANGES:        New table public.consents.
-- DEPENDS ON:     20261017045859_create_accounts.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the table. All consent records would be
--                 lost.
-- TESTED:         On alee-dev 2026-10-17 (rehearsed in a rolled-back transaction with
--                 temporary logins, then applied; 61 checks passed).
--                 RLS enabled. People see only their own consents; nobody,
--                 including admins and the database owner, can change one
--                 or delete one on its own; admins cannot record consent on
--                 someone's behalf; a back-dated time is replaced by now;
--                 deleting the login removes them.
-- DATE:           2026-10-17
-- ============================================================

create table public.consents (
  id              uuid primary key default gen_random_uuid(),
  account_id      uuid not null references public.accounts (id) on delete cascade,
  -- What was agreed to, one row per purpose, e.g. 'terms_of_use',
  -- 'privacy_notice'. Each is recorded separately.
  purpose         text not null check (length(btrim(purpose)) > 0),
  notice_version  text not null check (length(btrim(notice_version)) > 0),
  -- true = agreed, false = withdrew.
  granted         boolean not null default true,
  -- Always the moment the row was saved; cannot be back-dated.
  recorded_at     timestamptz not null default now()
);

comment on table public.consents is
  'Add-only log of what each person agreed to, which notice version, and when. Never changed.';

-- Latest decision per person and purpose.
create index consents_account_purpose_idx
  on public.consents (account_id, purpose, recorded_at desc);

create function public.consents_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.recorded_at := now();
  return new;
end;
$$;

create trigger consents_before_insert
  before insert on public.consents
  for each row execute function public.consents_before_insert();

-- Never changed, not even by admins or the service role.
create function public.consents_prevent_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Consent records cannot be changed; add a new record instead';
end;
$$;

create trigger consents_prevent_update
  before update on public.consents
  for each row execute function public.consents_prevent_update();

-- Removed only when the whole account is deleted.
create trigger consents_prevent_direct_delete
  before delete on public.consents
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------

alter table public.consents enable row level security;

create policy "People read their own consents; admins read all"
  on public.consents for select
  to authenticated
  using (account_id = (select auth.uid()) or (select public.is_admin()));

-- Only the person can record their own consent, not an admin on their
-- behalf.
create policy "People record their own consent"
  on public.consents for insert
  to authenticated
  with check (account_id = (select auth.uid()));

-- No UPDATE or DELETE grant.
grant select, insert on public.consents to authenticated;
