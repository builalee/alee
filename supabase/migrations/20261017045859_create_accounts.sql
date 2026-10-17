-- ============================================================
-- OBJECTIVE:      Create one account per person, linked to their login,
--                 holding name, phone, firm, GST number, signup role and
--                 location. Only the person and admins can see it.
-- WHY:            Every personal detail in ALEE must trace back to one
--                 account, so deleting the login removes everything. Phone
--                 and contact details must stay private even if someone
--                 queries the database directly.
-- CHANGES:        New enum public.account_role.
--                 New table public.accounts.
--                 New function public.current_login_phone() (the caller's
--                 own verified login phone).
--                 New shared helper public.prevent_direct_delete(), used by
--                 personal tables that may only disappear when the whole
--                 account is deleted.
-- DEPENDS ON:     20261005164142_create_regions (regions, is_admin()).
--                 20261009155105_create_segments (set_updated_at()).
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the table, enum and functions. Every
--                 account (and, through the links, every profile and
--                 consent) would be lost.
-- TESTED:         On alee-dev 2026-10-17 (rehearsed in a rolled-back transaction with
--                 temporary logins, then applied; 61 checks passed).
--                 RLS enabled. Visitors cannot read accounts at all. An
--                 ordinary user reading another person's phone, firm or GST
--                 gets nothing; creating an account for someone else, or
--                 with a phone other than their login phone, is refused.
--                 Admin can create and change any account. Deleting a login
--                 removes the account and everything linked to it.
-- DATE:           2026-10-17
-- ============================================================

-- The role chosen at signup. It only decides which home screen a person
-- sees first: every account can both buy and sell.
create type public.account_role as enum (
  'manufacturer', 'distributor', 'wholesaler', 'retailer'
);

create table public.accounts (
  -- Same id as the login. Deleting the login deletes the account, and every
  -- personal table links here with ON DELETE CASCADE.
  id           uuid primary key references auth.users (id) on delete cascade,
  full_name    text not null check (length(btrim(full_name)) > 0),
  -- Indian mobile in +91 form. For ordinary users it must match the phone
  -- they logged in with (see policies below).
  phone        text not null check (phone ~ '^\+91[6-9][0-9]{9}$'),
  firm_name    text,
  -- Recorded as given; not verified.
  gst_number   text,
  signup_role  public.account_role not null,
  region_id    uuid not null references public.regions (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.accounts is
  'One per person, same id as the login. Private: only the person and admins can read it.';
comment on column public.accounts.signup_role is
  'Role chosen at signup. Decides the first home screen only; everyone can buy and sell.';
comment on column public.accounts.gst_number is
  'Recorded as entered. Not verified.';

create unique index accounts_phone_key on public.accounts (phone);
create index accounts_region_id_idx on public.accounts (region_id);

-- Tidies free-text fields before saving.
create function public.accounts_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.full_name  := btrim(new.full_name);
  new.firm_name  := nullif(btrim(new.firm_name), '');
  new.gst_number := nullif(upper(btrim(new.gst_number)), '');
  return new;
end;
$$;

create trigger accounts_before_write
  before insert or update on public.accounts
  for each row execute function public.accounts_before_write();

create trigger accounts_set_updated_at
  before update on public.accounts
  for each row execute function public.set_updated_at();

-- Shared helper: rows in personal tables cannot be deleted one by one; they
-- go only when the whole account is deleted (the cascade from accounts runs
-- one trigger level deeper, which is what this checks).
create function public.prevent_direct_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_trigger_depth() <= 1 then
    raise exception '% rows cannot be deleted on their own; they are removed only when the account is deleted', tg_table_name;
  end if;
  return old;
end;
$$;

-- The caller's own verified login phone, in +91 form. Reads auth.users,
-- which callers cannot read directly, but only ever returns their own row.
create function public.current_login_phone()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select '+' || ltrim(u.phone, '+')
    from auth.users u
   where u.id = auth.uid()
     and coalesce(u.phone, '') <> '';
$$;

revoke execute on function public.current_login_phone() from public, anon;
grant execute on function public.current_login_phone() to authenticated;

-- Row Level Security --------------------------------------------------------
-- No policy for anon: visitors who are not logged in see nothing here.

alter table public.accounts enable row level security;

create policy "People read their own account; admins read all"
  on public.accounts for select
  to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()));

-- An ordinary user may create only their own account, with the phone they
-- logged in with. Admins may create an account for any existing login.
create policy "People create their own account; admins create any"
  on public.accounts for insert
  to authenticated
  with check (
    (select public.is_admin())
    or (id = (select auth.uid()) and phone = (select public.current_login_phone()))
  );

create policy "People change their own account; admins change any"
  on public.accounts for update
  to authenticated
  using (id = (select auth.uid()) or (select public.is_admin()))
  with check (
    (select public.is_admin())
    or (id = (select auth.uid()) and phone = (select public.current_login_phone()))
  );

-- No DELETE grant: an account is removed only by deleting the login, which
-- is done server-side.
grant select, insert, update on public.accounts to authenticated;
