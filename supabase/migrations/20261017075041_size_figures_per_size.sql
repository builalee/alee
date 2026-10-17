-- ============================================================
-- OBJECTIVE:      Look size differences and loading up one size at a time.
--                 For each size, the closest area that has a figure for
--                 that size wins: city, taluka, district, state, everywhere.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.22). An
--                 area only needs the sizes that differ. Maharashtra 8mm
--                 +6500, 10mm/12mm +5500 and Satara 10mm/12mm +5000 give a
--                 Satara buyer 8mm +6500 and 10mm/12mm +5000. Zero is a real
--                 figure and never carries down; a selected size with no
--                 figure anywhere is an error, never zero.
-- CHANGES:        New function public.resolve_size_figures(...): per size,
--                 the size difference and loading that apply, where each
--                 came from, and whether a selected size is missing a figure.
--                 public.resolve_area_settings(...) recreated WITHOUT its
--                 size_chart_id and loading_chart_id results: with per-size
--                 lookup no single chart is "the" chart, and leaving them
--                 would invite pricing a size from the wrong area.
--                 public.size_chart_missing_figures(...) removed: it judged
--                 one chart on its own, and would wrongly flag a Satara
--                 chart for not repeating Maharashtra's 8mm. Missing sizes
--                 are now reported per buyer area by resolve_size_figures.
-- DEPENDS ON:     20261017065410_area_settings_resolve.
--                 20261017063030_size_chart_missing_figures.
-- TOUCHES EXISTING DATA: No. Functions only.
-- REVERSIBLE:     Yes, by restoring the two functions from
--                 20261017065410 and 20261017063030 and dropping
--                 resolve_size_figures.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/size_figures.sql (24): the owner's
--                 Maharashtra/Satara example; Pune 8mm 0 kept; 16mm offered
--                 with no figure MISSING, never zero; Fe550D's own chart
--                 before the family chart at each area; loading per size;
--                 version 1 still looks up as it was; other sellers, buyers
--                 and visitors refused. area_settings.sql updated.
-- DATE:           2026-10-17
-- ============================================================

drop function public.size_chart_missing_figures(uuid);
drop function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid);

-- Settings that apply to the whole area (not per size). Same lookup as
-- before: each setting separately, most specific first, not-set carries
-- down, zero never does. Size differences and loading are per size: use
-- resolve_size_figures.
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
    select l.depth, s.region_id, s.is_excluded, s.area_difference,
           s.discount_chart_id, s.display_unit, g.grade_premium, g.is_sold
      from levels l
      join public.area_settings s
        on s.version_id = v.id and s.region_id is not distinct from l.region_id
      left join public.area_grade_settings g
        on g.area_setting_id = s.id and g.product_id = p_product_id
  ),
  resolved as (
    select
      coalesce((array_agg(not m.is_excluded order by m.depth))[1], false) as served,
      (array_agg(m.region_id order by m.depth))[1] as decided_by,
      (array_agg(m.area_difference order by m.depth) filter (where m.area_difference is not null))[1] as diff,
      (array_agg(m.discount_chart_id order by m.depth) filter (where m.discount_chart_id is not null))[1] as discount_chart,
      (array_agg(m.display_unit order by m.depth) filter (where m.display_unit is not null))[1] as disp_unit,
      (array_agg(m.grade_premium order by m.depth) filter (where m.grade_premium is not null))[1] as premium,
      (array_agg(m.is_sold order by m.depth) filter (where m.is_sold is not null))[1] as sold
    from mentioned m
  )
  select v.id, v.unit, r.served,
         case when r.served then r.decided_by end,
         case when r.served then r.diff end,
         case when r.served then r.discount_chart end,
         case when r.served then r.disp_unit end,
         case when r.served and p_product_id is not null then r.premium end,
         case when r.served and p_product_id is not null then coalesce(r.sold, true) end
    from resolved r;
end;
$$;

comment on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid) is
  'Whole-area settings (served, area difference, discount, display unit, grade premium, sold). Per-size figures: resolve_size_figures.';

-- One row per size of the family (switched on in the catalogue), for one
-- seller, buyer area and optionally one grade. No rows if the area is not
-- served.
--
-- Size difference, for each size: at each area, closest first, look in the
-- grade's own size chart (if the area gives the grade one), then in the
-- area's family size chart; the first figure found wins. Only if neither
-- has the size, move up to the next area.
--
-- Loading, for each size: at each area that has a loading chart, closest
-- first, that chart's figure for the size if it has one, otherwise its
-- figure for all sizes. Every loading chart has an all-sizes figure, so
-- the closest area with a loading chart always answers.
--
-- Zero is a figure and stops the search. A size the seller offers with no
-- size difference anywhere is marked is_missing: an error, never zero.
-- Figures are in each chart's own unit; the rate engine converts them.
-- Uses each chart's latest version.
create function public.resolve_size_figures(
  p_seller_id   uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_version_id  uuid default null
)
returns table (
  size_id               uuid,
  display_name          text,
  -- Whether the seller has selected this size.
  is_offered            boolean,
  size_difference       numeric,
  size_difference_unit  public.unit,
  -- Where it came from: the area's name, or "everywhere".
  size_difference_from  text,
  -- "grade" if from the grade's own chart, "family" otherwise.
  size_difference_chart text,
  loading               numeric,
  loading_unit          public.unit,
  loading_from          text,
  -- Offered, but no size difference anywhere: an error, never zero.
  is_missing            boolean
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
  select r.version_id, r.is_served into v
    from public.resolve_area_settings(p_seller_id, p_segment_id, p_region_id, p_product_id, p_version_id) r;
  if not v.is_served then
    return;
  end if;

  return query
  with recursive chain as (
    select r.id, r.parent_id, r.name, 1 as depth
      from public.regions r where r.id = p_region_id
    union all
    select p.id, p.parent_id, p.name, c.depth + 1
      from chain c join public.regions p on p.id = c.parent_id
  ),
  levels as (
    select c.id as region_id, c.name as area_name, c.depth from chain c
    union all
    select null::uuid, 'everywhere', 99
  ),
  areas as (
    -- The areas this version mentions for the buyer, with their charts.
    select l.depth, l.area_name, s.size_chart_id, s.loading_chart_id,
           g.size_chart_id as grade_chart_id
      from levels l
      join public.area_settings s
        on s.version_id = v.version_id and s.region_id is not distinct from l.region_id
      left join public.area_grade_settings g
        on g.area_setting_id = s.id and g.product_id = p_product_id
     where not s.is_excluded
  ),
  latest as (
    -- Latest version of each chart involved.
    select distinct on (cv.chart_id) cv.chart_id, cv.id as chart_version_id, cv.unit as chart_unit
      from public.chart_versions cv
     where cv.chart_id in (select a.size_chart_id from areas a
                           union select a.grade_chart_id from areas a
                           union select a.loading_chart_id from areas a)
     order by cv.chart_id, cv.version_number desc
  ),
  size_candidates as (
    select f.size_id as cand_size, f.amount, lv.chart_unit, a.depth, c.prio, a.area_name, c.kind
      from areas a
      cross join lateral (values (1, a.grade_chart_id, 'grade'), (2, a.size_chart_id, 'family'))
                 as c (prio, chart_id, kind)
      join latest lv on lv.chart_id = c.chart_id
      join public.chart_version_figures f on f.version_id = lv.chart_version_id
  ),
  size_pick as (
    select distinct on (sc.cand_size) sc.cand_size, sc.amount, sc.chart_unit, sc.area_name, sc.kind
      from size_candidates sc
     order by sc.cand_size, sc.depth, sc.prio
  ),
  loading_candidates as (
    select z.id as cand_size, f.amount, lv.chart_unit, a.depth,
           case when f.size_id is null then 2 else 1 end as prio, a.area_name
      from areas a
      join latest lv on lv.chart_id = a.loading_chart_id
      join public.chart_version_figures f on f.version_id = lv.chart_version_id
      join public.sizes z on z.segment_id = p_segment_id and (f.size_id = z.id or f.size_id is null)
  ),
  loading_pick as (
    select distinct on (lc.cand_size) lc.cand_size, lc.amount, lc.chart_unit, lc.area_name
      from loading_candidates lc
     order by lc.cand_size, lc.depth, lc.prio
  )
  select z.id, z.display_name, coalesce(ss.is_selected, false),
         sp.amount::numeric, sp.chart_unit, sp.area_name::text, sp.kind::text,
         lp.amount::numeric, lp.chart_unit, lp.area_name::text,
         coalesce(ss.is_selected, false) and sp.amount is null
    from public.sizes z
    left join public.seller_sizes ss on ss.seller_id = p_seller_id and ss.size_id = z.id
    left join size_pick sp on sp.cand_size = z.id
    left join loading_pick lp on lp.cand_size = z.id
   where z.segment_id = p_segment_id and z.is_active
   order by z.sort_order;
end;
$$;

comment on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid) is
  'The one place size differences and loading are resolved: per size, closest area first; grade chart before family chart at each area. Missing = error, never zero.';

revoke execute on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid) to authenticated;
revoke execute on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid) to authenticated;
