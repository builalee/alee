-- ============================================================
-- OBJECTIVE:      Add resolve_territory: for a manufacturer, a product
--                 family and a buyer's area, is there an allocation in
--                 effect, and if so to whom and of which type. The closer
--                 area wins.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.34): the
--                 rate engine checks territory first, before exclusions and
--                 area settings (CLAUDE.md section 8). One lookup, used
--                 everywhere, in a single query.
-- CHANGES:        New function public.resolve_territory(...).
-- DEPENDS ON:     20261017113839_create_territory_allocations.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the function.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/territory.sql (77).
--                 An offer has no effect until accepted; a decline leaves no
--                 allocation; Karad taluka beats Satara district for a Karad
--                 city buyer; ending restores the manufacturer, who serves
--                 Satara again; returns no rate.
-- DATE:           2026-10-17
-- ============================================================

-- At most one row: the allocation in effect at the closest area to the
-- buyer (city, taluka, district, state). No row = no allocation; the
-- manufacturer's own settings decide. Public, like allocations in effect.
-- Returns who and which type, never any rate.
create function public.resolve_territory(
  p_manufacturer_id  uuid,
  p_segment_id       uuid,
  p_region_id        uuid
)
returns table (
  allocation_id     uuid,
  distributor_id    uuid,
  distributor_name  text,
  allocation_type   public.territory_type,
  -- The allocated area, and its name for the tag "Authorised distributor
  -- for [area]: [distributor]".
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
     and a.manufacturer_id = p_manufacturer_id
     and a.segment_id = p_segment_id
     and a.status = 'active'
    join public.seller_profiles sp on sp.account_id = a.distributor_id
    join public.regions r on r.id = a.region_id
   order by c.depth
   limit 1;
$$;

comment on function public.resolve_territory(uuid, uuid, uuid) is
  'The one place territory is resolved: the allocation in effect closest to the buyer, if any. The rate engine checks this first.';

grant execute on function public.resolve_territory(uuid, uuid, uuid) to anon, authenticated;
