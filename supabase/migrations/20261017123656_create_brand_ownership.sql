-- ============================================================
-- OBJECTIVE:      Let a manufacturer claim a brand, and an admin approve or
--                 reject the claim. One owner per brand; a manufacturer can
--                 own several. Every claim and decision is kept.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.38). Only
--                 a brand's owner may later appoint authorised distributors
--                 and link factories, so ownership must be verified by an
--                 admin and have a clear history.
-- CHANGES:        New enum public.brand_claim_status.
--                 public.brands: new column owner_id (set only through an
--                 approved claim).
--                 New table public.brand_claims.
--                 New functions public.claim_brand(...),
--                 public.decide_brand_claim(...), public.end_brand_ownership(...).
-- DEPENDS ON:     20261017123300_create_brands.
-- TOUCHES EXISTING DATA: No (new column is empty for every brand).
-- REVERSIBLE:     Yes, by dropping the functions, table, column and enum.
--                 All ownership and claims would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/brand_ownership.sql (37).
--                 Claims private; admin approval makes the owner; one owner
--                 per brand; several brands per manufacturer; Regular and
--                 unapproved brands cannot be claimed; the owner cannot be
--                 set except through a claim, not even by an admin or the
--                 master key; ending ownership; history only moves forward
--                 and is never deleted.
-- DATE:           2026-10-17
-- ============================================================

create type public.brand_claim_status as enum (
  'claimed',    -- waiting for an admin
  'approved',   -- the claimant owns the brand
  'rejected',   -- the admin said no
  'ended'       -- was the owner; ownership ended by an admin
);

alter table public.brands
  add column owner_id uuid references public.seller_profiles (account_id) on delete set null;

comment on column public.brands.owner_id is
  'The manufacturer who owns the brand. Set only through an approved claim. Regular is never owned.';

create index brands_owner_idx on public.brands (owner_id) where owner_id is not null;

create table public.brand_claims (
  id               uuid primary key default gen_random_uuid(),
  brand_id         uuid not null references public.brands (id),
  manufacturer_id  uuid not null references public.seller_profiles (account_id) on delete cascade,
  status           public.brand_claim_status not null default 'claimed',
  claimed_at       timestamptz not null default clock_timestamp(),
  decided_by       uuid,
  decided_at       timestamptz,
  ended_by         uuid,
  ended_at         timestamptz
);

comment on table public.brand_claims is
  'Every claim to own a brand, and what happened to it. Kept forever; the status only moves forward.';

-- At most one owner per brand, and one open claim per brand per claimant.
create unique index brand_claims_one_owner_key on public.brand_claims (brand_id) where status = 'approved';
create unique index brand_claims_one_open_claim_key on public.brand_claims (brand_id, manufacturer_id) where status = 'claimed';
create index brand_claims_manufacturer_idx on public.brand_claims (manufacturer_id, status);

-- Rules ---------------------------------------------------------------------

-- The owner can only be changed by the claim functions below (which mark
-- the brand being changed), never by editing the brand directly.
create function public.brands_owner_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.owner_id is distinct from old.owner_id
     and current_setting('alee.brand_ownership', true) is distinct from new.id::text then
    raise exception 'A brand''s owner is set only by approving a claim';
  end if;
  if new.owner_id is not null and new.is_regular then
    raise exception 'Regular is never owned';
  end if;
  return new;
end;
$$;

create trigger brands_owner_guard
  before update on public.brands
  for each row execute function public.brands_owner_guard();

-- Who, which brand and when never change; the status only moves forward.
create function public.brand_claims_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.brand_id <> old.brand_id or new.manufacturer_id <> old.manufacturer_id
     or new.claimed_at <> old.claimed_at then
    raise exception 'A claim''s brand, claimant and time never change';
  end if;
  if new.status <> old.status and not (
       (old.status = 'claimed' and new.status in ('approved', 'rejected'))
    or (old.status = 'approved' and new.status = 'ended')
  ) then
    raise exception 'A claim cannot go from % to %', old.status, new.status;
  end if;
  if old.decided_at is not null and new.decided_at is distinct from old.decided_at
     or old.ended_at is not null and new.ended_at is distinct from old.ended_at then
    raise exception 'Recorded decisions never change';
  end if;
  return new;
end;
$$;

create trigger brand_claims_before_update
  before update on public.brand_claims
  for each row execute function public.brand_claims_before_update();
create trigger brand_claims_prevent_direct_delete
  before delete on public.brand_claims
  for each row execute function public.prevent_direct_delete();

-- Functions -------------------------------------------------------------------

-- A seller claims to own an approved brand. It waits for an admin.
create function public.claim_brand(p_brand_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  b     public.brands%rowtype;
  v_id  uuid;
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = auth.uid()) then
    raise exception 'Only a manufacturer selling on ALEE can claim a brand.';
  end if;

  select * into b from public.brands where id = p_brand_id;
  if not found or b.status <> 'approved' or not b.is_active then
    raise exception 'That brand is not available to claim.';
  end if;
  if b.is_regular then
    raise exception 'Regular is not a brand anyone can own.';
  end if;
  if b.owner_id = auth.uid() then
    raise exception 'You already own %.', b.name;
  end if;
  if b.owner_id is not null then
    raise exception '% already has an owner. If you believe it is yours, contact ALEE.', b.name;
  end if;
  if exists (select 1 from public.brand_claims c
              where c.brand_id = p_brand_id and c.manufacturer_id = auth.uid() and c.status = 'claimed') then
    raise exception 'You have already claimed %; an admin will check it.', b.name;
  end if;

  insert into public.brand_claims (brand_id, manufacturer_id)
  values (p_brand_id, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- An admin approves or rejects a claim. Approving makes the claimant the
-- owner; a brand that already has an owner must have that ownership ended
-- first.
create function public.decide_brand_claim(p_claim_id uuid, p_approve boolean)
returns public.brand_claim_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  c       public.brand_claims%rowtype;
  v_name  text;
  v_owner uuid;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can decide a brand claim' using errcode = '42501';
  end if;
  select * into c from public.brand_claims where id = p_claim_id for update;
  if not found then
    raise exception 'Claim not found';
  end if;
  if c.status <> 'claimed' then
    raise exception 'This claim has already been decided (%).', c.status;
  end if;

  if not p_approve then
    update public.brand_claims set status = 'rejected', decided_by = auth.uid(), decided_at = clock_timestamp()
     where id = p_claim_id;
    return 'rejected';
  end if;

  select b.name, b.owner_id into v_name, v_owner from public.brands b where b.id = c.brand_id for update;
  if v_owner is not null then
    raise exception '% already has an owner. End that ownership before approving another claim.', v_name;
  end if;

  update public.brand_claims set status = 'approved', decided_by = auth.uid(), decided_at = clock_timestamp()
   where id = p_claim_id;
  perform set_config('alee.brand_ownership', c.brand_id::text, true);
  update public.brands set owner_id = c.manufacturer_id where id = c.brand_id;
  perform set_config('alee.brand_ownership', '', true);
  return 'approved';
end;
$$;

-- An admin ends a brand's ownership (for example, the brand was sold). The
-- brand then has no owner until a new claim is approved.
create function public.end_brand_ownership(p_brand_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim uuid;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can end a brand''s ownership' using errcode = '42501';
  end if;
  select c.id into v_claim from public.brand_claims c
   where c.brand_id = p_brand_id and c.status = 'approved' for update;
  if v_claim is null then
    raise exception 'That brand has no owner.';
  end if;

  update public.brand_claims set status = 'ended', ended_by = auth.uid(), ended_at = clock_timestamp()
   where id = v_claim;
  perform set_config('alee.brand_ownership', p_brand_id::text, true);
  update public.brands set owner_id = null where id = p_brand_id;
  perform set_config('alee.brand_ownership', '', true);
end;
$$;

revoke execute on function public.claim_brand(uuid) from public, anon;
revoke execute on function public.decide_brand_claim(uuid, boolean) from public, anon;
revoke execute on function public.end_brand_ownership(uuid) from public, anon;
grant execute on function public.claim_brand(uuid) to authenticated;
grant execute on function public.decide_brand_claim(uuid, boolean) to authenticated;
grant execute on function public.end_brand_ownership(uuid) to authenticated;

-- Row Level Security --------------------------------------------------------
-- Who owns a brand is public (brands.owner_id, with the brand). Claims are
-- seen by the claimant and admins.

alter table public.brand_claims enable row level security;

create policy "Claimants see their own claims; admins see all"
  on public.brand_claims for select
  to authenticated
  using (manufacturer_id = (select auth.uid()) or (select public.is_admin()));

grant select on public.brand_claims to authenticated;
