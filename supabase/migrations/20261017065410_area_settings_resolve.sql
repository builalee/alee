-- ============================================================
-- OBJECTIVE:      Add resolve_area_settings: for one seller, product family
--                 and buyer area (and optionally one grade), work out which
--                 settings apply, in a single query.
-- WHY:            CLAUDE.md sections 8 and 9; docs/decisions.md 2.19 to
--                 2.21. Each setting is looked up separately, most specific
--                 first (city, taluka, district, state, everywhere). A
--                 setting not set carries down from above; zero is a real
--                 value and never carries down. Whether the area is served
--                 is decided by the most specific area the seller has
--                 mentioned, so an exclusion beats a broader area. This is
--                 the one place area resolution happens; the rate engine
--                 will use it, never repeat it.
-- CHANGES:        New function public.resolve_area_settings(...).
-- DEPENDS ON:     20261017065210_create_area_settings.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the function.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks (npm run check:db) pass, including
--                 tests/database/area_settings.sql (71).
--                 Carry-down state -> district -> taluka -> city; Pune's 0
--                 kept, not replaced by Maharashtra's 200; Kolhapur excluded
--                 beats Maharashtra and "everywhere"; North Goa served only
--                 once "everywhere" is chosen; grade premium 0 kept; grade
--                 size chart and grade not sold; older version still looks up
--                 as it was. Others cannot look up a seller's settings.
-- DATE:           2026-10-17
-- ============================================================

-- Returns one row. When the area is not served, every setting is empty.
-- Runs with the caller's rights: today only the seller himself and admins
-- can resolve his settings. The rate engine will call it on a buyer's
-- behalf and return only the final rate.
create function public.resolve_area_settings(
  p_seller_id   uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_version_id  uuid default null
)
returns table (
  version_id         uuid,
  unit               public.unit,
  is_served          boolean,
  -- The most specific area the seller mentioned for this buyer (empty with
  -- is_served = true means "everywhere").
  decided_by_region  uuid,
  area_difference    numeric,
  size_chart_id      uuid,
  loading_chart_id   uuid,
  discount_chart_id  uuid,
  display_unit       public.unit,
  grade_premium      numeric,
  -- Whether the grade is sold in this area (true unless set to false). The
  -- rate engine must also check the seller has selected the grade.
  grade_sold_here    boolean
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v record;
begin
  select av.id, av.unit into v
    from public.area_setting_versions av
   where av.seller_id = p_seller_id and av.segment_id = p_segment_id
     and (p_version_id is null or av.id = p_version_id)
   order by av.version_number desc
   limit 1;
  if not found then
    raise exception 'No area settings found for this seller and product family';
  end if;

  return query
  with recursive chain as (
    -- The buyer's area and every area above it; depth 1 = most specific.
    select r.id, r.parent_id, 1 as depth
      from public.regions r where r.id = p_region_id
    union all
    select p.id, p.parent_id, c.depth + 1
      from chain c join public.regions p on p.id = c.parent_id
  ),
  levels as (
    select c.id as region_id, c.depth from chain c
    union all
    select null::uuid, 99          -- "everywhere", above every state
  ),
  mentioned as (
    -- Only the areas this version mentions, most specific first.
    select l.depth, s.region_id, s.is_excluded, s.area_difference, s.size_chart_id,
           s.loading_chart_id, s.discount_chart_id, s.display_unit,
           g.grade_premium, g.size_chart_id as grade_size_chart_id, g.is_sold
      from levels l
      join public.area_settings s
        on s.version_id = v.id and s.region_id is not distinct from l.region_id
      left join public.area_grade_settings g
        on g.area_setting_id = s.id and g.product_id = p_product_id
  ),
  resolved as (
    select
      -- Served: decided by the most specific mentioned area. No mention
      -- anywhere (and no "everywhere") = not served.
      coalesce((array_agg(not m.is_excluded order by m.depth))[1], false) as served,
      (array_agg(m.region_id order by m.depth))[1] as decided_by,
      -- Every other setting: the first value actually set, most specific
      -- first. "is not null" keeps 0 as a real value.
      (array_agg(m.area_difference order by m.depth) filter (where m.area_difference is not null))[1] as diff,
      -- A grade's own size chart beats the family chart at the same area;
      -- a more specific area beats a broader one.
      (array_agg(coalesce(m.grade_size_chart_id, m.size_chart_id) order by m.depth)
         filter (where coalesce(m.grade_size_chart_id, m.size_chart_id) is not null))[1] as size_chart,
      (array_agg(m.loading_chart_id order by m.depth) filter (where m.loading_chart_id is not null))[1] as loading_chart,
      (array_agg(m.discount_chart_id order by m.depth) filter (where m.discount_chart_id is not null))[1] as discount_chart,
      (array_agg(m.display_unit order by m.depth) filter (where m.display_unit is not null))[1] as disp_unit,
      (array_agg(m.grade_premium order by m.depth) filter (where m.grade_premium is not null))[1] as premium,
      (array_agg(m.is_sold order by m.depth) filter (where m.is_sold is not null))[1] as sold
    from mentioned m
  )
  select v.id, v.unit, r.served,
         case when r.served then r.decided_by end,
         case when r.served then r.diff end,
         case when r.served then r.size_chart end,
         case when r.served then r.loading_chart end,
         case when r.served then r.discount_chart end,
         case when r.served then r.disp_unit end,
         case when r.served and p_product_id is not null then r.premium end,
         case when r.served and p_product_id is not null then coalesce(r.sold, true) end
    from resolved r;
end;
$$;

comment on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid) is
  'The one place area settings are resolved: most specific first, not-set carries down, zero never does.';

revoke execute on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid) to authenticated;
