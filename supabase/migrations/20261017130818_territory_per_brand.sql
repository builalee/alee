-- ============================================================
-- OBJECTIVE:      Make territory allocation per brand: a manufacturer
--                 allocates a brand he owns, for a family that brand covers.
--                 Lookups take the brand, and a new lookup tells the rate
--                 engine what territory does to any seller's rate for a
--                 brand in a buyer's area.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.43,
--                 replacing "a family he sells"). Type B hides only that
--                 distributor's rate for that brand in that area; his other
--                 brands are unaffected. Territory affects only the brand
--                 owner's factories and his appointed distributor; other
--                 sellers of the brand keep showing their own rates.
-- CHANGES:        public.territory_allocations: new column brand_id
--                 (required); one open allocation per brand, family and
--                 area.
--                 public.offer_territory(...) recreated with the brand as
--                 its first argument; public.resolve_territory(...)
--                 recreated taking the brand instead of the manufacturer
--                 (only allocations by the brand's current owner count).
--                 New function public.territory_effect(...).
-- DEPENDS ON:     20261017114039_resolve_territory.
--                 20261017130335_create_brand_factories.
-- TOUCHES EXISTING DATA: No. Existing allocations cannot be given a brand
--                 automatically (Regular is never owned), so the migration
--                 stops, changing nothing, if any exist. On alee-dev and
--                 live there are none.
-- REVERSIBLE:     Yes, by dropping the column and the new function and
--                 restoring the two functions from 20261017113939 and
--                 20261017114039, provided no allocation has been made.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/territory.sql (91, rewritten to
--                 allocate an owned brand; same rules).
--                 Only the owner allocates his brand for a family it covers;
--                 Regular and unowned brands refused; Type B: owner and his
--                 factory shown with tag, the distributor's brand hidden,
--                 his other brands and other sellers unaffected; Type A:
--                 owner and factory pointed to distributor; after the brand
--                 changes owner the old allocations stop counting.
-- DATE:           2026-10-17
-- ============================================================

do $$
begin
  if exists (select 1 from public.territory_allocations) then
    raise exception 'Territory allocations exist; assign each a brand by hand before running this migration';
  end if;
end;
$$;

alter table public.territory_allocations
  add column brand_id uuid not null references public.brands (id);

comment on column public.territory_allocations.brand_id is
  'The brand allocated (owned by the manufacturer). With the family and area: what the distributor covers.';

drop index public.territory_allocations_one_open_key;
drop index public.territory_allocations_lookup_idx;

-- One open allocation per brand, family and area.
create unique index territory_allocations_one_open_key
  on public.territory_allocations (brand_id, segment_id, region_id) where status in ('offered', 'active');
create index territory_allocations_lookup_idx
  on public.territory_allocations (brand_id, segment_id, region_id) where status = 'active';

-- The brand, like the parties and the area, never changes.
create or replace function public.territory_allocations_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.manufacturer_id <> old.manufacturer_id or new.distributor_id <> old.distributor_id
     or new.brand_id <> old.brand_id
     or new.segment_id <> old.segment_id or new.region_id <> old.region_id
     or new.offered_at <> old.offered_at then
    raise exception 'An allocation''s manufacturer, distributor, brand, product family, area and offer time never change; end it and offer a new one';
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

-- Offering, per brand -----------------------------------------------------------

drop function public.offer_territory(uuid, uuid, uuid, public.territory_type, uuid);

-- The brand's owner offers an area, for one family the brand covers, to a
-- distributor. It has no effect until the distributor accepts. An admin
-- may offer on the owner's behalf.
create function public.offer_territory(
  p_brand_id         uuid,
  p_distributor_id   uuid,
  p_segment_id       uuid,
  p_region_id        uuid,
  p_type             public.territory_type,
  p_manufacturer_id  uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_maker   uuid := coalesce(p_manufacturer_id, auth.uid());
  b         public.brands%rowtype;
  v_id      uuid;
  v_holder  text;
  v_area    text;
  v_label   text;
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if v_maker is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the manufacturer can offer his territory' using errcode = '42501';
  end if;
  select * into b from public.brands where id = p_brand_id;
  if not found or b.owner_id is distinct from v_maker then
    raise exception 'You don''t own %, so you cannot allocate it.', coalesce(b.name, 'that brand');
  end if;
  if p_type is null then
    raise exception 'Choose who sets the price in this area: the distributor, or you.';
  end if;
  if v_maker = p_distributor_id then
    raise exception 'You cannot allocate an area to yourself.';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = p_distributor_id) then
    raise exception 'That distributor is not a seller on ALEE.';
  end if;
  if not public.brand_covers_family(p_brand_id, p_segment_id) then
    raise exception '% is not listed for %.', b.name,
      coalesce((select s.name from public.segments s where s.id = p_segment_id), 'that product family');
  end if;

  select r.name into v_area from public.regions r
   where r.id = p_region_id and r.is_active and r.is_approved;
  if v_area is null then
    raise exception 'That area is not available.';
  end if;

  v_label := public.brand_line_label(p_brand_id, p_segment_id);
  select sp.store_name into v_holder
    from public.territory_allocations a
    join public.seller_profiles sp on sp.account_id = a.distributor_id
   where a.brand_id = p_brand_id and a.segment_id = p_segment_id and a.region_id = p_region_id
     and a.status in ('offered', 'active');
  if v_holder is not null then
    raise exception '% % is already offered to or held by %. End that first.', v_area, v_label, v_holder;
  end if;

  insert into public.territory_allocations (manufacturer_id, distributor_id, brand_id, segment_id, region_id, allocation_type)
  values (v_maker, p_distributor_id, p_brand_id, p_segment_id, p_region_id, p_type)
  returning id into v_id;

  perform public.territory_record(v_id, 'offered', p_type, v_maker);
  return v_id;
end;
$$;

revoke execute on function public.offer_territory(uuid, uuid, uuid, uuid, public.territory_type, uuid) from public, anon;
grant execute on function public.offer_territory(uuid, uuid, uuid, uuid, public.territory_type, uuid) to authenticated;

-- Lookups --------------------------------------------------------------------------

drop function public.resolve_territory(uuid, uuid, uuid);

-- At most one row: the allocation in effect, closest to the buyer, for a
-- brand and family. Only allocations made by the brand's current owner
-- count. Public; returns who and which type, never any rate.
create function public.resolve_territory(
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_region_id   uuid
)
returns table (
  allocation_id     uuid,
  distributor_id    uuid,
  distributor_name  text,
  allocation_type   public.territory_type,
  region_id         uuid,
  area_name         text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive chain as (
    select r.id, r.parent_id, 1 as depth
      from public.regions r where r.id = p_region_id
    union all
    select p.id, p.parent_id, c.depth + 1
      from chain c join public.regions p on p.id = c.parent_id
  )
  select a.id, a.distributor_id, sp.store_name, a.allocation_type, a.region_id, r.name
    from chain c
    join public.territory_allocations a
      on a.region_id = c.id
     and a.brand_id = p_brand_id
     and a.segment_id = p_segment_id
     and a.status = 'active'
    join public.brands b on b.id = a.brand_id and b.owner_id = a.manufacturer_id
    join public.seller_profiles sp on sp.account_id = a.distributor_id
    join public.regions r on r.id = a.region_id
   order by c.depth
   limit 1;
$$;

comment on function public.resolve_territory(uuid, uuid, uuid) is
  'The territory allocation in effect closest to the buyer, for a brand and family, if any. The rate engine checks this first.';

grant execute on function public.resolve_territory(uuid, uuid, uuid) to anon, authenticated;

-- What territory does to one seller's rate for a brand, family and buyer's
-- area. The rate engine checks this first, for every seller it shows.
--
--   none                    no effect: show his own rate as usual
--   pointed_to_distributor  he is the brand's owner or one of its factories,
--                           and the area is Type A: his rate is not shown;
--                           point the buyer to the distributor
--   shown_with_tag          he is the owner or a factory, and the area is
--                           Type B: show his rate, tagged "Authorised
--                           distributor for [area]: [distributor]"
--   hidden                  he is the appointed distributor and the area is
--                           Type B: his rate for this brand is not shown
--                           there (his other brands are unaffected)
--
-- Every other seller of the brand: none. Runs with owner rights because it
-- must know the brand's factories, which are private; it returns only the
-- effect and the public allocation details.
create function public.territory_effect(
  p_seller_id   uuid,
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_region_id   uuid
)
returns table (
  effect            text,
  distributor_id    uuid,
  distributor_name  text,
  area_name         text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  t        record;
  v_owner  uuid;
  v_maker  boolean;
begin
  select * into t from public.resolve_territory(p_brand_id, p_segment_id, p_region_id);
  if t.allocation_id is null then
    return query select 'none'::text, null::uuid, null::text, null::text;
    return;
  end if;

  select b.owner_id into v_owner from public.brands b where b.id = p_brand_id;
  v_maker := p_seller_id = v_owner or exists (
    select 1 from public.brand_factories f
     where f.brand_id = p_brand_id and f.factory_id = p_seller_id and f.status = 'active');

  return query select
    case
      when v_maker and t.allocation_type = 'distributor_prices' then 'pointed_to_distributor'
      when v_maker and t.allocation_type = 'manufacturer_prices' then 'shown_with_tag'
      when p_seller_id = t.distributor_id and t.allocation_type = 'manufacturer_prices' then 'hidden'
      else 'none'
    end,
    t.distributor_id, t.distributor_name, t.area_name;
end;
$$;

comment on function public.territory_effect(uuid, uuid, uuid, uuid) is
  'What territory does to one seller''s rate for a brand in a buyer''s area: none, pointed_to_distributor, shown_with_tag or hidden.';

grant execute on function public.territory_effect(uuid, uuid, uuid, uuid) to anon, authenticated;
