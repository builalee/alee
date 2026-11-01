-- ============================================================
-- OBJECTIVE:      resolve_area_settings also says which area each setting
--                 came from (area difference, discount chart, display unit,
--                 grade premium), as resolve_size_figures already does for
--                 size differences and loading.
-- WHY:            The rate engine's answer to a seller shows every
--                 component and where it came from (docs/decisions.md 12.4),
--                 so he can see why a buyer in Karad gets the figure he
--                 gets. The lookup itself is unchanged.
-- CHANGES:        public.resolve_area_settings: four columns added at the
--                 end (area_difference_from, discount_from,
--                 display_unit_from, grade_premium_from). Dropped and
--                 recreated, since its result changes; same arguments,
--                 same answers, same access.
-- DEPENDS ON:     20261017131658_brands_required.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by recreating the previous version from
--                 20261017131658_brands_required.
-- TESTED:         On alee-dev 2026-10-29: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/area_settings.sql (unchanged
--                 answers) and tests/database/rate_engine.sql (where each
--                 setting came from).
-- DATE:           2026-10-29
-- ============================================================

drop function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid, uuid);

create function public.resolve_area_settings(
  p_seller_id  uuid,
  p_segment_id uuid,
  p_region_id  uuid,
  p_product_id uuid default null,
  p_version_id uuid default null,
  p_brand_id   uuid default null
)
returns table (
  version_id           uuid,
  unit                 public.unit,
  is_served            boolean,
  decided_by_region    uuid,
  area_difference      numeric,
  discount_chart_id    uuid,
  display_unit         public.unit,
  grade_premium        numeric,
  grade_sold_here      boolean,
  -- Where each came from: an area's name, or "everywhere".
  area_difference_from text,
  discount_from        text,
  display_unit_from    text,
  grade_premium_from   text
)
language plpgsql
stable
set search_path = ''
as $$
#variable_conflict use_column
declare
  v       record;
  v_brand uuid := public.require_brand(p_brand_id);
begin
  select av.id, av.unit into v
    from public.area_setting_versions av
   where av.seller_id = p_seller_id and av.segment_id = p_segment_id and av.brand_id = v_brand
     and (p_version_id is null or av.id = p_version_id)
   order by av.version_number desc
   limit 1;
  if not found then
    raise exception 'No area settings found for this seller and product family';
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
  mentioned as (
    select l.depth, l.area_name, s.region_id, s.is_excluded, s.area_difference,
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
      (array_agg(m.area_name order by m.depth) filter (where m.area_difference is not null))[1] as diff_from,
      (array_agg(m.discount_chart_id order by m.depth) filter (where m.discount_chart_id is not null))[1] as discount_chart,
      (array_agg(m.area_name order by m.depth) filter (where m.discount_chart_id is not null))[1] as discount_from,
      (array_agg(m.display_unit order by m.depth) filter (where m.display_unit is not null))[1] as disp_unit,
      (array_agg(m.area_name order by m.depth) filter (where m.display_unit is not null))[1] as disp_from,
      (array_agg(m.grade_premium order by m.depth) filter (where m.grade_premium is not null))[1] as premium,
      (array_agg(m.area_name order by m.depth) filter (where m.grade_premium is not null))[1] as premium_from,
      (array_agg(m.is_sold order by m.depth) filter (where m.is_sold is not null))[1] as sold
    from mentioned m
  )
  select v.id, v.unit, r.served,
         case when r.served then r.decided_by end,
         case when r.served then r.diff end,
         case when r.served then r.discount_chart end,
         case when r.served then r.disp_unit end,
         case when r.served and p_product_id is not null then r.premium end,
         case when r.served and p_product_id is not null then coalesce(r.sold, true) end,
         case when r.served then r.diff_from end,
         case when r.served then r.discount_from end,
         case when r.served then r.disp_from end,
         case when r.served and p_product_id is not null then r.premium_from end
    from resolved r;
end;
$$;

revoke execute on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid, uuid) to authenticated;
