-- ============================================================
-- OBJECTIVE:      Create one seller profile per person who sells: store
--                 name, description, banner, location, market closing time
--                 and public/private setting. Anyone can read it.
-- WHY:            Buyers find and view sellers by their profile. Contact
--                 details are deliberately not stored here; they stay in
--                 the private accounts table.
-- CHANGES:        New table public.seller_profiles.
-- DEPENDS ON:     20261017045859_create_accounts.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the table. All seller profiles would be
--                 lost.
-- TESTED:         On alee-dev 2026-10-17 (rehearsed in a rolled-back transaction with
--                 temporary logins, then applied; 61 checks passed).
--                 RLS enabled. Visitors can read profiles (public and
--                 private). Ordinary users cannot create or change another
--                 person's profile; admin can. A profile cannot be deleted
--                 on its own; deleting the login removes it.
-- DATE:           2026-10-17
-- ============================================================

create table public.seller_profiles (
  -- One profile per account; same id.
  account_id         uuid primary key references public.accounts (id) on delete cascade,
  store_name         text not null check (length(btrim(store_name)) > 0),
  description        text,
  -- Path of the banner picture in file storage (storage is set up later,
  -- with the compression and size cap rules).
  banner_path        text,
  region_id          uuid not null references public.regions (id),
  -- Daily market close as Indian wall-clock time (Asia/Kolkata). Empty
  -- until the seller sets it.
  market_close_time  time,
  -- Public: subscribers see rates at once. Private: each subscription needs
  -- the seller's approval. No default: it must be chosen.
  is_public          boolean not null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table public.seller_profiles is
  'Public seller profile. Holds no contact details; those stay in accounts.';
comment on column public.seller_profiles.market_close_time is
  'Daily market close, Indian time (Asia/Kolkata).';

create index seller_profiles_region_id_idx on public.seller_profiles (region_id);

-- Finding sellers by name.
create index seller_profiles_store_name_trgm_idx
  on public.seller_profiles using gin (lower(store_name) extensions.gin_trgm_ops);

create function public.seller_profiles_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.store_name  := btrim(new.store_name);
  new.description := nullif(btrim(new.description), '');
  return new;
end;
$$;

create trigger seller_profiles_before_write
  before insert or update on public.seller_profiles
  for each row execute function public.seller_profiles_before_write();

create trigger seller_profiles_set_updated_at
  before update on public.seller_profiles
  for each row execute function public.set_updated_at();

-- Removed only when the whole account is deleted.
create trigger seller_profiles_prevent_direct_delete
  before delete on public.seller_profiles
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------

alter table public.seller_profiles enable row level security;

create policy "Anyone can read seller profiles"
  on public.seller_profiles for select
  to anon, authenticated
  using (true);

create policy "People create their own seller profile; admins create any"
  on public.seller_profiles for insert
  to authenticated
  with check (account_id = (select auth.uid()) or (select public.is_admin()));

create policy "People change their own seller profile; admins change any"
  on public.seller_profiles for update
  to authenticated
  using (account_id = (select auth.uid()) or (select public.is_admin()))
  with check (account_id = (select auth.uid()) or (select public.is_admin()));

-- No DELETE grant.
grant select on public.seller_profiles to anon, authenticated;
grant insert, update on public.seller_profiles to authenticated;
