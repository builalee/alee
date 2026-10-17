-- ============================================================
-- OBJECTIVE:      Store territory allocations: a manufacturer allocating an
--                 area to a distributor for one product family, as an offer
--                 the distributor accepts or declines, of one of two types,
--                 with every step kept as history.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.33 to
--                 2.36). Type "distributor prices": the manufacturer's rate
--                 is not shown there and buyers are pointed to the
--                 distributor. Type "manufacturer prices" (as Tata or Apollo
--                 work): buyers see the manufacturer's rate, tagged with the
--                 authorised distributor. Nothing is ever deleted.
-- CHANGES:        New enums public.territory_type, public.territory_status,
--                 public.territory_event.
--                 New tables public.territory_allocations (current state)
--                 and public.territory_allocation_events (history).
-- DEPENDS ON:     20261017050059_create_seller_profiles.
--                 20261005164142_create_regions.
--                 20261017055742_create_chart_versions (prevent_update).
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the two tables and three enums. Every
--                 allocation and its history would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/territory.sql (77).
--                 RLS on; no rate, amount or margin column. Offers, declines
--                 and endings seen only by the two sides and admins;
--                 allocations in effect are public. One open allocation per
--                 area, family and manufacturer. History and allocations
--                 cannot be changed or deleted, an ended or declined one
--                 cannot be revived and its distributor cannot be swapped,
--                 even with the master key.
-- DATE:           2026-10-17
-- ============================================================

create type public.territory_type as enum (
  'distributor_prices',    -- Type A: the distributor sets and publishes the price
  'manufacturer_prices'    -- Type B: the manufacturer's rate is shown, tagged with the distributor
);

create type public.territory_status as enum (
  'offered',    -- waiting for the distributor; no effect yet
  'active',     -- accepted; in effect
  'declined',   -- the distributor said no; never took effect
  'withdrawn',  -- the manufacturer took the offer back before it was accepted
  'ended'       -- was active, ended by either side
);

create type public.territory_event as enum (
  'offered', 'type_changed', 'accepted', 'declined', 'withdrawn', 'ended'
);

create table public.territory_allocations (
  id               uuid primary key default gen_random_uuid(),
  manufacturer_id  uuid not null references public.seller_profiles (account_id) on delete cascade,
  distributor_id   uuid not null references public.seller_profiles (account_id) on delete cascade,
  segment_id       uuid not null references public.segments (id),
  -- Any level: state, district, taluka or city. The closer area wins.
  region_id        uuid not null references public.regions (id),
  allocation_type  public.territory_type not null,
  status           public.territory_status not null default 'offered',
  offered_at       timestamptz not null default clock_timestamp(),
  -- When it was accepted, declined, withdrawn or ended.
  accepted_at      timestamptz,
  closed_at        timestamptz,
  constraint territory_not_to_self check (manufacturer_id <> distributor_id)
);

comment on table public.territory_allocations is
  'A manufacturer''s area, for one product family, allocated to a distributor. Offer until accepted. Never deleted.';
comment on column public.territory_allocations.allocation_type is
  'distributor_prices (Type A): manufacturer''s rate not shown, buyers pointed to the distributor. manufacturer_prices (Type B): manufacturer''s rate shown, tagged "Authorised distributor".';

-- One distributor per area, per family, per manufacturer: at most one open
-- (offered or active) allocation at a time.
create unique index territory_allocations_one_open_key
  on public.territory_allocations (manufacturer_id, segment_id, region_id)
  where status in ('offered', 'active');

-- For the lookup: active allocations of a manufacturer and family.
create index territory_allocations_lookup_idx
  on public.territory_allocations (manufacturer_id, segment_id, region_id) where status = 'active';
create index territory_allocations_distributor_idx on public.territory_allocations (distributor_id, status);
create index territory_allocations_region_idx on public.territory_allocations (region_id);

create table public.territory_allocation_events (
  id             uuid primary key default gen_random_uuid(),
  allocation_id  uuid not null references public.territory_allocations (id) on delete cascade,
  event          public.territory_event not null,
  -- The type at that moment (shows what an offer or a change was).
  allocation_type public.territory_type not null,
  happened_at    timestamptz not null default clock_timestamp(),
  done_by        uuid not null,
  by_admin       boolean not null
);

comment on table public.territory_allocation_events is
  'Every offer, type change, acceptance, decline, withdrawal and ending, with its time and who did it. Never changed.';

create index territory_allocation_events_idx on public.territory_allocation_events (allocation_id, happened_at);

-- Rules for the current state ---------------------------------------------------
-- Who is involved, which family and which area never change. The status only
-- moves forward: offered -> active / declined / withdrawn; active -> ended.
-- The type can change only while it is still an offer. These hold for
-- everyone, including the database owner.
create function public.territory_allocations_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.manufacturer_id <> old.manufacturer_id or new.distributor_id <> old.distributor_id
     or new.segment_id <> old.segment_id or new.region_id <> old.region_id
     or new.offered_at <> old.offered_at then
    raise exception 'An allocation''s manufacturer, distributor, product family, area and offer time never change; end it and offer a new one';
  end if;
  if new.allocation_type <> old.allocation_type and old.status <> 'offered' then
    raise exception 'The type can only be changed while the allocation is still an offer';
  end if;
  if new.status <> old.status and not (
       (old.status = 'offered' and new.status in ('active', 'declined', 'withdrawn'))
    or (old.status = 'active' and new.status = 'ended')
  ) then
    raise exception 'An allocation cannot go from % to %', old.status, new.status;
  end if;
  if old.accepted_at is not null and new.accepted_at is distinct from old.accepted_at
     or old.closed_at is not null and new.closed_at is distinct from old.closed_at then
    raise exception 'Recorded times never change';
  end if;
  return new;
end;
$$;

create trigger territory_allocations_before_update
  before update on public.territory_allocations
  for each row execute function public.territory_allocations_before_update();

create trigger territory_allocations_prevent_direct_delete
  before delete on public.territory_allocations
  for each row execute function public.prevent_direct_delete();
create trigger territory_allocation_events_prevent_update
  before update on public.territory_allocation_events
  for each row execute function public.prevent_update();
create trigger territory_allocation_events_prevent_direct_delete
  before delete on public.territory_allocation_events
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------
-- That an allocation is in effect is public: buyers will see "Authorised
-- distributor" tags and be pointed to distributors. Offers, declines and
-- endings are seen only by the two sides and admins. Nothing here contains
-- any rate or margin.

alter table public.territory_allocations enable row level security;
alter table public.territory_allocation_events enable row level security;

create policy "Anyone can see allocations in effect"
  on public.territory_allocations for select
  to anon, authenticated
  using (status = 'active');

create policy "Both sides and admins see every allocation they are part of"
  on public.territory_allocations for select
  to authenticated
  using (manufacturer_id = (select auth.uid()) or distributor_id = (select auth.uid())
         or (select public.is_admin()));

create policy "Both sides and admins see the history"
  on public.territory_allocation_events for select
  to authenticated
  using (exists (
    select 1 from public.territory_allocations a
     where a.id = allocation_id
       and (a.manufacturer_id = (select auth.uid()) or a.distributor_id = (select auth.uid())
            or (select public.is_admin()))
  ));

-- Read only. Every change goes through the functions in the next migration.
grant select on public.territory_allocations to anon, authenticated;
grant select on public.territory_allocation_events to authenticated;
