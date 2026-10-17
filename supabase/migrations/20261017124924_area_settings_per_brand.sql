-- ============================================================
-- OBJECTIVE:      Make area settings per brand line: each brand a seller
--                 sells in a family has its own area-settings versions.
--                 Saving and both lookups take the brand. Existing setups
--                 move to Regular.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.20 as
--                 updated, 2.40). Brands differ, so each has its own area
--                 difference, charts, premiums and areas. Charts stay per
--                 seller and family, so two brands can share one chart.
-- CHANGES:        public.area_setting_versions: new column brand_id
--                 (required); version numbers are now counted per seller,
--                 brand and family.
--                 Guards on the area-settings tables recognise the brand.
--                 public.save_area_settings(...),
--                 public.resolve_area_settings(...) and
--                 public.resolve_size_figures(...) recreated with a new last
--                 argument p_brand_id (resolve_size_figures now also reads
--                 the sizes offered for that brand).
--                 public.publish_rates(...) replaced (same arguments) to
--                 publish the Regular line until brands step 6.
--                 TRANSITIONAL (docs/decisions.md 2.44, removed in brands
--                 step 11): p_brand_id empty = Regular.
-- DEPENDS ON:     20261017124455_offerings_per_brand.
--                 20261017111605_publish_rates_settled.
-- TOUCHES EXISTING DATA: YES. Every existing area-settings version is given
--                 the Regular brand. Nothing else changes. On alee-dev there
--                 are none.
-- REVERSIBLE:     Partly: the column can be dropped and the functions
--                 restored, provided no seller has saved area settings for a
--                 brand other than Regular (those would be lost).
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/brand_area_settings.sql (12).
--                 Two brands keep separate settings and version numbers
--                 while sharing one chart; each lookup uses its brand's
--                 settings and offered sizes; saving for a brand not sold
--                 refused in plain words; no brand given = Regular;
--                 publishing pins the Regular line; area_settings.sql,
--                 size_figures.sql and publishes.sql unchanged and passing.
-- DATE:           2026-10-17
-- ============================================================

-- Column, carried across to Regular -------------------------------------------------

alter table public.area_setting_versions add column brand_id uuid references public.brands (id);

alter table public.area_setting_versions disable trigger area_setting_versions_prevent_update;
update public.area_setting_versions set brand_id = (select id from public.brands where is_regular);
alter table public.area_setting_versions enable trigger area_setting_versions_prevent_update;

alter table public.area_setting_versions alter column brand_id set not null;
alter table public.area_setting_versions drop constraint area_setting_versions_number_key,
  add constraint area_setting_versions_number_key unique (seller_id, brand_id, segment_id, version_number);

comment on column public.area_setting_versions.brand_id is
  'The brand this area setup is for (with seller and family: the brand line).';

-- Guards recognise the brand line being saved -----------------------------------------

create or replace function public.area_setting_versions_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('alee.saving_area_settings', true)
       is distinct from new.seller_id::text || '/' || new.brand_id::text || '/' || new.segment_id::text then
    raise exception 'Area settings can only be saved through save_area_settings';
  end if;
  new.created_at := now();
  return new;
end;
$$;

create or replace function public.area_settings_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v record;
begin
  select av.seller_id, av.brand_id, av.segment_id into v
    from public.area_setting_versions av where av.id = new.version_id;

  if current_setting('alee.saving_area_settings', true)
       is distinct from v.seller_id::text || '/' || v.brand_id::text || '/' || v.segment_id::text then
    raise exception 'Areas can only be added while their version is being saved; save a new version instead';
  end if;

  if new.region_id is not null and not exists (
    select 1 from public.regions r where r.id = new.region_id and r.is_active and r.is_approved
  ) then
    raise exception 'That area is not available';
  end if;

  perform public.area_chart_is_usable(new.size_chart_id,     v.seller_id, v.segment_id, 'size');
  perform public.area_chart_is_usable(new.loading_chart_id,  v.seller_id, v.segment_id, 'loading');
  perform public.area_chart_is_usable(new.discount_chart_id, v.seller_id, v.segment_id, 'discount');
  return new;
end;
$$;

create or replace function public.area_grade_settings_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  a record;
begin
  select s.is_excluded, av.seller_id, av.brand_id, av.segment_id into a
    from public.area_settings s
    join public.area_setting_versions av on av.id = s.version_id
   where s.id = new.area_setting_id;

  if current_setting('alee.saving_area_settings', true)
       is distinct from a.seller_id::text || '/' || a.brand_id::text || '/' || a.segment_id::text then
    raise exception 'Grade settings can only be added while their version is being saved; save a new version instead';
  end if;
  if a.is_excluded then
    raise exception 'An excluded area carries no grade settings';
  end if;
  if not exists (
    select 1 from public.products p
     where p.id = new.product_id and p.segment_id = a.segment_id and p.is_active
  ) then
    raise exception 'That grade is not in this product family';
  end if;

  perform public.area_chart_is_usable(new.size_chart_id, a.seller_id, a.segment_id, 'size');
  return new;
end;
$$;

-- Saving, per brand line -------------------------------------------------------------

drop function public.save_area_settings(uuid, jsonb, uuid);

-- As before (see 20261017065310), plus p_brand_id: the brand this setup is
-- for. The seller must sell that brand in that family (an active brand
-- line). Amounts are in his unit for the family.
create function public.save_area_settings(
  p_segment_id  uuid,
  p_areas       jsonb,
  p_seller_id   uuid default null,
  -- TRANSITIONAL: empty = Regular (until brands step 11).
  p_brand_id    uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller   uuid := coalesce(p_seller_id, auth.uid());
  v_brand    uuid := coalesce(p_brand_id, (select b.id from public.brands b where b.is_regular));
  v_unit     public.unit;
  v_number   integer;
  v_version  uuid;
  v_area     uuid;
  a          jsonb;
  g          jsonb;
  k          text;
  everywhere boolean;
begin
  if v_seller is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if v_seller is distinct from auth.uid() and not public.is_admin() then
    raise exception 'You can only change your own area settings' using errcode = '42501';
  end if;

  select ss.base_unit into v_unit
    from public.seller_segments ss
   where ss.seller_id = v_seller and ss.segment_id = p_segment_id and ss.is_active;
  if not found then
    raise exception 'Add this product family to the seller first';
  end if;
  if not exists (
    select 1 from public.seller_brands sb
     where sb.seller_id = v_seller and sb.brand_id = v_brand and sb.segment_id = p_segment_id and sb.is_active
  ) then
    raise exception 'Add % to the brands you sell first.',
      coalesce(public.brand_display_name(v_brand, p_segment_id), 'this brand');
  end if;

  if p_areas is null or jsonb_typeof(p_areas) <> 'array' then
    raise exception 'Give a list of areas (an empty list means serving nowhere)';
  end if;

  for a in select * from jsonb_array_elements(p_areas) loop
    if jsonb_typeof(a) <> 'object' then
      raise exception 'Each area must be an object';
    end if;
    for k in select jsonb_object_keys(a) loop
      if k not in ('region_id', 'everywhere', 'excluded', 'area_difference', 'size_chart_id',
                   'loading_chart_id', 'discount_chart_id', 'display_unit', 'grades') then
        raise exception 'Unknown setting "%"', k;
      end if;
    end loop;

    everywhere := coalesce((a ->> 'everywhere')::boolean, false);
    if everywhere and coalesce(jsonb_typeof(a -> 'region_id'), 'null') <> 'null' then
      raise exception 'An area is either a region or "everywhere", not both';
    end if;
    if not everywhere and coalesce(jsonb_typeof(a -> 'region_id'), 'null') = 'null' then
      raise exception 'Each area must name a region, or be "everywhere": true';
    end if;

    if coalesce(a ->> 'display_unit', 'tonne') not in ('tonne', 'kg', 'piece', 'metre') then
      raise exception 'Display unit must be tonne, kg, piece or metre';
    end if;

    if coalesce((a ->> 'excluded')::boolean, false) and (
         coalesce(jsonb_typeof(a -> 'area_difference'), 'null') <> 'null'
      or coalesce(jsonb_typeof(a -> 'size_chart_id'), 'null') <> 'null'
      or coalesce(jsonb_typeof(a -> 'loading_chart_id'), 'null') <> 'null'
      or coalesce(jsonb_typeof(a -> 'discount_chart_id'), 'null') <> 'null'
      or coalesce(jsonb_typeof(a -> 'display_unit'), 'null') <> 'null'
      or coalesce(jsonb_array_length(case when jsonb_typeof(a -> 'grades') = 'array' then a -> 'grades' end), 0) > 0) then
      raise exception 'An excluded area is not served, so it cannot carry other settings';
    end if;

    if coalesce(jsonb_typeof(a -> 'grades'), 'null') not in ('null', 'array') then
      raise exception '"grades" must be a list';
    end if;
    for g in select * from jsonb_array_elements(coalesce(a -> 'grades', '[]')) loop
      for k in select jsonb_object_keys(g) loop
        if k not in ('product_id', 'premium', 'size_chart_id', 'sold') then
          raise exception 'Unknown grade setting "%"', k;
        end if;
      end loop;
      if coalesce(jsonb_typeof(g -> 'product_id'), 'null') = 'null' then
        raise exception 'Each grade setting must name the grade';
      end if;
    end loop;
  end loop;

  perform set_config('alee.saving_area_settings',
                     v_seller::text || '/' || v_brand::text || '/' || p_segment_id::text, true);

  select coalesce(max(v.version_number), 0) + 1 into v_number
    from public.area_setting_versions v
   where v.seller_id = v_seller and v.brand_id = v_brand and v.segment_id = p_segment_id;

  insert into public.area_setting_versions (seller_id, brand_id, segment_id, version_number, unit)
  values (v_seller, v_brand, p_segment_id, v_number, v_unit)
  returning id into v_version;

  for a in select * from jsonb_array_elements(p_areas) loop
    insert into public.area_settings (
      version_id, region_id, is_excluded, area_difference,
      size_chart_id, loading_chart_id, discount_chart_id, display_unit
    ) values (
      v_version,
      (a ->> 'region_id')::uuid,
      coalesce((a ->> 'excluded')::boolean, false),
      (a ->> 'area_difference')::numeric,
      (a ->> 'size_chart_id')::uuid,
      (a ->> 'loading_chart_id')::uuid,
      (a ->> 'discount_chart_id')::uuid,
      (a ->> 'display_unit')::public.unit
    )
    returning id into v_area;

    insert into public.area_grade_settings (area_setting_id, product_id, grade_premium, size_chart_id, is_sold)
    select v_area, (ge ->> 'product_id')::uuid, (ge ->> 'premium')::numeric,
           (ge ->> 'size_chart_id')::uuid, (ge ->> 'sold')::boolean
      from jsonb_array_elements(coalesce(a -> 'grades', '[]')) ge;
  end loop;

  perform set_config('alee.saving_area_settings', '', true);
  return v_version;
end;
$$;

comment on function public.save_area_settings(uuid, jsonb, uuid, uuid) is
  'The only way to save area settings, per brand line. Always creates a new, complete version.';

revoke execute on function public.save_area_settings(uuid, jsonb, uuid, uuid) from public, anon;
grant execute on function public.save_area_settings(uuid, jsonb, uuid, uuid) to authenticated;

-- Whole-area lookup, per brand line -----------------------------------------------------

drop function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid);

create function public.resolve_area_settings(
  p_seller_id   uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_version_id  uuid default null,
  -- TRANSITIONAL: empty = Regular (until brands step 11).
  p_brand_id    uuid default null
)
returns table (
  version_id         uuid,
  unit               public.unit,
  is_served          boolean,
  decided_by_region  uuid,
  area_difference    numeric,
  discount_chart_id  uuid,
  display_unit       public.unit,
  grade_premium      numeric,
  grade_sold_here    boolean
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v       record;
  v_brand uuid := coalesce(p_brand_id, (select b.id from public.brands b where b.is_regular));
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
    select r.id, r.parent_id, 1 as depth
      from public.regions r where r.id = p_region_id
    union all
    select p.id, p.parent_id, c.depth + 1
      from chain c join public.regions p on p.id = c.parent_id
  ),
  levels as (
    select c.id as region_id, c.depth from chain c
    union all
    select null::uuid, 99
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

comment on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid, uuid) is
  'Whole-area settings for one brand line (served, area difference, discount, display unit, grade premium, sold). Per-size figures: resolve_size_figures.';

revoke execute on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.resolve_area_settings(uuid, uuid, uuid, uuid, uuid, uuid) to authenticated;

-- Per-size lookup, per brand line ---------------------------------------------------------

drop function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid, uuid);

create function public.resolve_size_figures(
  p_seller_id   uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_version_id  uuid default null,
  p_publish_id  uuid default null,
  -- TRANSITIONAL: empty = Regular (until brands step 11).
  p_brand_id    uuid default null
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
  v_brand    uuid := coalesce(p_brand_id, (select b.id from public.brands b where b.is_regular));
begin
  if p_publish_id is not null then
    select pi.area_setting_version_id into v_version
      from public.publish_items pi
      join public.publishes p on p.id = pi.publish_id
      join public.area_setting_versions av on av.id = pi.area_setting_version_id
     where pi.publish_id = p_publish_id and pi.segment_id = p_segment_id
       and p.seller_id = p_seller_id and av.brand_id = v_brand;
    if v_version is null then
      raise exception 'That publish was not found for this seller and product family';
    end if;
  end if;

  select r.version_id, r.is_served into v
    from public.resolve_area_settings(p_seller_id, p_segment_id, p_region_id, p_product_id, v_version, v_brand) r;
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
    select pcv.chart_id, pcv.chart_version_id
      from public.publish_chart_versions pcv
     where p_publish_id is not null
       and pcv.publish_id = p_publish_id and pcv.segment_id = p_segment_id
    union all
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
    left join public.seller_sizes ss
      on ss.seller_id = p_seller_id and ss.size_id = z.id and ss.brand_id = v_brand
    left join size_pick sp on sp.cand_size = z.id
    left join loading_pick lp on lp.cand_size = z.id
   where z.segment_id = p_segment_id and z.is_active
   order by z.sort_order;
end;
$$;

comment on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid, uuid, uuid) is
  'The one place size differences and loading are resolved, per size, for one brand line; with p_publish_id, exactly as that publish used them.';

revoke execute on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.resolve_size_figures(uuid, uuid, uuid, uuid, uuid, uuid, uuid) to authenticated;

-- Publishing uses the Regular line until brands step 6 -------------------------------
-- Same as 20261017111605, except the area-settings version used is the
-- seller's Regular line for each family.

create or replace function public.publish_rates(
  p_items               jsonb,
  p_is_correction       boolean default false,
  p_corrects_publish_id uuid default null,
  p_seller_id           uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_by       uuid := auth.uid();
  v_seller   uuid;
  v_publish  uuid;
  v_at       timestamptz;
  it         jsonb;
  k          text;
  v_seg      uuid;
  v_family   text;
  v_unit     public.unit;
  v_version  uuid;
  v_quoting  boolean;
  bad        record;
  v_regular  uuid := (select b.id from public.brands b where b.is_regular);
begin
  if v_by is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  v_seller := coalesce(p_seller_id, v_by);
  if v_seller <> v_by and not public.is_admin() then
    raise exception 'You can only publish your own rates' using errcode = '42501';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = v_seller) then
    raise exception 'Only sellers can publish';
  end if;
  if (select sp.market_close_time from public.seller_profiles sp where sp.account_id = v_seller) is null then
    raise exception 'Set your daily closing time before your first publish.';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose at least one product family to publish.';
  end if;
  if (select count(*) from jsonb_array_elements(p_items) e)
     <> (select count(distinct e ->> 'segment_id') from jsonb_array_elements(p_items) e) then
    raise exception 'Each product family can appear only once in a publish.';
  end if;

  -- Check everything before writing anything.
  for it in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(it) <> 'object' then
      raise exception 'Each item must be an object';
    end if;
    for k in select jsonb_object_keys(it) loop
      if k not in ('segment_id', 'base_rate') then
        raise exception 'Unknown publish field "%"', k;
      end if;
    end loop;
    v_seg := (it ->> 'segment_id')::uuid;
    select s.name into v_family from public.segments s where s.id = v_seg;

    if not exists (
      select 1 from public.seller_segments ss
       where ss.seller_id = v_seller and ss.segment_id = v_seg and ss.is_active
    ) then
      raise exception 'You don''t sell % yet. Add it to your product families before publishing.', coalesce(v_family, 'this product family');
    end if;
    if coalesce(jsonb_typeof(it -> 'base_rate'), 'null') <> 'number' then
      raise exception 'Enter your basic rate for %.', v_family;
    end if;

    select av.id into v_version from public.area_setting_versions av
     where av.seller_id = v_seller and av.segment_id = v_seg and av.brand_id = v_regular
     order by av.version_number desc limit 1;
    if v_version is null then
      raise exception 'Choose where you sell % before publishing.', v_family;
    end if;

    -- The first area still pointing to a switched-off chart, if any.
    select x.area, x.grade, x.chart into bad
      from (
        -- An area's own size, loading or discount chart.
        select coalesce(r.name, 'Everywhere') as area, null::text as grade, c.name as chart, r.name as sort_area
          from public.area_settings s
          left join public.regions r on r.id = s.region_id
          join public.charts c on c.id in (s.size_chart_id, s.loading_chart_id, s.discount_chart_id)
         where s.version_id = v_version and not c.is_active
        union all
        -- A grade's own size chart in an area.
        select coalesce(r.name, 'Everywhere'), p.name, c.name, r.name
          from public.area_settings s
          left join public.regions r on r.id = s.region_id
          join public.area_grade_settings g on g.area_setting_id = s.id
          join public.products p on p.id = g.product_id
          join public.charts c on c.id = g.size_chart_id
         where s.version_id = v_version and not c.is_active
      ) x
     order by x.sort_area nulls first, x.grade nulls first
     limit 1;
    if found then
      if bad.grade is null then
        raise exception '% still uses ''%'', which you switched off. Choose a chart for %.',
          bad.area, bad.chart, bad.area;
      else
        raise exception '% (%) still uses ''%'', which you switched off. Choose a chart for % in %.',
          bad.area, bad.grade, bad.chart, bad.grade, bad.area;
      end if;
    end if;
  end loop;

  if p_corrects_publish_id is not null and not exists (
    select 1 from public.publishes p where p.id = p_corrects_publish_id and p.seller_id = v_seller
  ) then
    raise exception 'A correction can only correct one of the seller''s own earlier publishes';
  end if;

  -- Write the publish.
  perform set_config('alee.publishing', v_seller::text, true);

  insert into public.publishes (seller_id, published_by, by_admin, is_correction, corrects_publish_id)
  values (v_seller, v_by, v_seller <> v_by,
          coalesce(p_is_correction, false) or p_corrects_publish_id is not null, p_corrects_publish_id)
  returning id, published_at into v_publish, v_at;

  for it in select * from jsonb_array_elements(p_items) loop
    v_seg := (it ->> 'segment_id')::uuid;

    select ss.base_unit into v_unit from public.seller_segments ss
     where ss.seller_id = v_seller and ss.segment_id = v_seg;
    select av.id into v_version from public.area_setting_versions av
     where av.seller_id = v_seller and av.segment_id = v_seg and av.brand_id = v_regular
     order by av.version_number desc limit 1;

    insert into public.publish_items (publish_id, segment_id, base_rate, unit, area_setting_version_id)
    values (v_publish, v_seg, (it ->> 'base_rate')::numeric, v_unit, v_version);

    -- Pin the latest version of every chart these area settings use.
    insert into public.publish_chart_versions (publish_id, segment_id, chart_id, chart_version_id)
    select v_publish, v_seg, used.chart_id,
           (select cv.id from public.chart_versions cv
             where cv.chart_id = used.chart_id order by cv.version_number desc limit 1)
      from (select s.size_chart_id as chart_id from public.area_settings s where s.version_id = v_version
            union select s.loading_chart_id from public.area_settings s where s.version_id = v_version
            union select s.discount_chart_id from public.area_settings s where s.version_id = v_version
            union select g.size_chart_id from public.area_grade_settings g
                    join public.area_settings s on s.id = g.area_setting_id where s.version_id = v_version) used
     where used.chart_id is not null;

    -- Mark the charts as used ("used since" is set once and never cleared).
    update public.charts c set in_use_since = v_at
     where c.in_use_since is null
       and c.id in (select pcv.chart_id from public.publish_chart_versions pcv
                     where pcv.publish_id = v_publish and pcv.segment_id = v_seg);

    -- Current status: this is now the latest publish. That reopens a market
    -- closed earlier and switches "not quoting" back on, recorded in history.
    select st.is_quoting into v_quoting from public.seller_family_status st
     where st.seller_id = v_seller and st.segment_id = v_seg;

    insert into public.seller_family_status (seller_id, segment_id, latest_publish_id, last_published_at, is_quoting)
    values (v_seller, v_seg, v_publish, v_at, true)
    on conflict (seller_id, segment_id) do update
      set latest_publish_id = excluded.latest_publish_id,
          last_published_at = excluded.last_published_at,
          is_quoting = true;

    if v_quoting = false then
      insert into public.seller_family_status_history (seller_id, segment_id, event, happened_at, done_by, by_admin)
      values (v_seller, v_seg, 'resumed_quoting', v_at, v_by, v_seller <> v_by);
    end if;
  end loop;

  perform set_config('alee.publishing', '', true);
  return v_publish;
end;
$$;
