-- ============================================================
-- OBJECTIVE:      Let resolve_size_figures look figures up exactly as they
--                 were in a past publish: using that publish's pinned
--                 area-settings version and chart versions, whatever the
--                 seller has changed since.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.26): any
--                 past rate must rebuild exactly as it was. Done by adding
--                 an option to the existing lookup, not a second copy of
--                 it, so past and present can never be worked out
--                 differently.
-- CHANGES:        public.resolve_size_figures(...) recreated with a new
--                 last argument p_publish_id. Without it, behaviour is
--                 unchanged (latest versions).
-- DEPENDS ON:     20261017075041_size_figures_per_size.
--                 20261017084616_create_publishes.
-- TOUCHES EXISTING DATA: No. Function only.
-- REVERSIBLE:     Yes, by restoring the function from 20261017075041.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/publishes.sql (88).
--                 A publish rebuilds exactly (42000, Pune +200, 8mm 500)
--                 after the seller changed his chart (8mm 900) and area
--                 settings (+300); without a publish the latest figures are
--                 used, as before (size_figures.sql still passes).
-- DATE:           2026-10-17
-- ============================================================

drop function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid);

-- As before (see 20261017075041), plus p_publish_id: when given, the
-- area-settings version and every chart version are the ones that publish
-- used, so a past rate rebuilds exactly. p_version_id is then ignored.
create function public.resolve_size_figures(
  p_seller_id   uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_version_id  uuid default null,
  p_publish_id  uuid default null
)
returns table (
  size_id               uuid,
  display_name          text,
  is_offered            boolean,
  size_difference       numeric,
  size_difference_unit  public.unit,
  size_difference_from  text,
  size_difference_chart text,
  loading               numeric,
  loading_unit          public.unit,
  loading_from          text,
  is_missing            boolean
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v          record;
  v_version  uuid := p_version_id;
begin
  if p_publish_id is not null then
    select pi.area_setting_version_id into v_version
      from public.publish_items pi
      join public.publishes p on p.id = pi.publish_id
     where pi.publish_id = p_publish_id and pi.segment_id = p_segment_id
       and p.seller_id = p_seller_id;
    if v_version is null then
      raise exception 'That publish was not found for this seller and product family';
    end if;
  end if;

  select r.version_id, r.is_served into v
    from public.resolve_area_settings(p_seller_id, p_segment_id, p_region_id, p_product_id, v_version) r;
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
    select l.depth, l.area_name, s.size_chart_id, s.loading_chart_id,
           g.size_chart_id as grade_chart_id
      from levels l
      join public.area_settings s
        on s.version_id = v.version_id and s.region_id is not distinct from l.region_id
      left join public.area_grade_settings g
        on g.area_setting_id = s.id and g.product_id = p_product_id
     where not s.is_excluded
  ),
  used_charts as (
    select a.size_chart_id as chart_id from areas a
    union select a.grade_chart_id from areas a
    union select a.loading_chart_id from areas a
  ),
  picked as (
    -- As published: the chart versions that publish pinned.
    select pcv.chart_id, pcv.chart_version_id
      from public.publish_chart_versions pcv
     where p_publish_id is not null
       and pcv.publish_id = p_publish_id and pcv.segment_id = p_segment_id
    union all
    -- Otherwise: each chart's latest version.
    (select distinct on (cv.chart_id) cv.chart_id, cv.id
       from public.chart_versions cv
      where p_publish_id is null and cv.chart_id in (select uc.chart_id from used_charts uc)
      order by cv.chart_id, cv.version_number desc)
  ),
  latest as (
    select pk.chart_id, pk.chart_version_id, cv.unit as chart_unit
      from picked pk join public.chart_versions cv on cv.id = pk.chart_version_id
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

comment on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid, uuid) is
  'The one place size differences and loading are resolved, per size; with p_publish_id, exactly as that publish used them.';

revoke execute on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid, uuid) to authenticated;
