-- ============================================================
-- OBJECTIVE:      Make the grades and sizes a seller offers, and their
--                 history, per brand line instead of per seller. Existing
--                 choices move to the seller's Regular line.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.17 as
--                 updated, 2.40): each brand a seller sells has its own
--                 grades and sizes.
-- CHANGES:        public.seller_grades, public.seller_sizes,
--                 public.seller_offering_history: new column brand_id
--                 (required). Primary keys of seller_grades / seller_sizes
--                 become (seller, brand, grade / size).
--                 Selecting now requires an active brand line (seller_brands)
--                 for that brand and family, instead of only the family.
--                 public.select_all_in_family(...) recreated with a new last
--                 argument p_brand_id.
--                 public.resolve_size_figures(...) replaced (same
--                 arguments) to read the Regular line's sizes; brands step 5
--                 gives it a brand argument.
--                 TRANSITIONAL (docs/decisions.md 2.44, removed in brands
--                 step 11): a choice saved without a brand, and
--                 select_all_in_family without p_brand_id, mean Regular.
-- DEPENDS ON:     20261017124056_create_seller_brands.
--                 20261017062930_create_seller_offerings.
--                 20261017084916_resolve_figures_as_published.
-- TOUCHES EXISTING DATA: YES. Every existing grade / size choice and
--                 history entry is given the Regular brand. Nothing is
--                 removed. On alee-dev there are none.
-- REVERSIBLE:     Partly: the column can be dropped and the old keys
--                 restored, provided no seller has chosen grades or sizes
--                 for a brand other than Regular (those would be lost).
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/brand_offerings.sql (17).
--                 Choices for one brand are independent of another; select
--                 all per brand; history records the brand; choosing needs
--                 an active brand line; a choice saved without a brand is
--                 Regular; the per-size lookup lists each size once, from
--                 the Regular line; offerings.sql unchanged and passing.
-- DATE:           2026-10-17
-- ============================================================

-- Columns, carried across to Regular ----------------------------------------------

alter table public.seller_grades add column brand_id uuid references public.brands (id);
alter table public.seller_sizes add column brand_id uuid references public.brands (id);
alter table public.seller_offering_history add column brand_id uuid references public.brands (id);

update public.seller_grades set brand_id = (select id from public.brands where is_regular);
update public.seller_sizes set brand_id = (select id from public.brands where is_regular);
-- History rows are never changed, except this once, to label them Regular.
alter table public.seller_offering_history disable trigger seller_offering_history_prevent_update;
update public.seller_offering_history set brand_id = (select id from public.brands where is_regular);
alter table public.seller_offering_history enable trigger seller_offering_history_prevent_update;

alter table public.seller_grades alter column brand_id set not null;
alter table public.seller_sizes alter column brand_id set not null;
alter table public.seller_offering_history alter column brand_id set not null;

alter table public.seller_grades drop constraint seller_grades_pkey,
  add primary key (seller_id, brand_id, product_id);
alter table public.seller_sizes drop constraint seller_sizes_pkey,
  add primary key (seller_id, brand_id, size_id);

create index seller_offering_history_brand_idx on public.seller_offering_history (seller_id, brand_id, changed_at);

-- TRANSITIONAL: no brand given = Regular --------------------------------------------

create function public.default_to_regular_brand()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.brand_id is null then
    new.brand_id := (select b.id from public.brands b where b.is_regular);
  end if;
  return new;
end;
$$;

comment on function public.default_to_regular_brand() is
  'TRANSITIONAL (docs/decisions.md 2.44): a row saved without a brand is Regular. Removed in brands step 11.';

-- Named to run before the existing rules triggers (triggers run in name order).
create trigger seller_grades_a_default_brand
  before insert on public.seller_grades
  for each row execute function public.default_to_regular_brand();
create trigger seller_sizes_a_default_brand
  before insert on public.seller_sizes
  for each row execute function public.default_to_regular_brand();

-- Rules: selecting needs an active brand line ---------------------------------------

create or replace function public.seller_offerings_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_segment  uuid;
  v_active   boolean;
begin
  if tg_op = 'UPDATE' and (new.seller_id <> old.seller_id or new.brand_id <> old.brand_id) then
    raise exception 'A selection cannot be moved to another seller or brand';
  end if;

  if tg_table_name = 'seller_grades' then
    if tg_op = 'UPDATE' and new.product_id <> old.product_id then
      raise exception 'A selection cannot be moved to another grade';
    end if;
    select p.segment_id, p.is_active into v_segment, v_active
      from public.products p where p.id = new.product_id;
  else
    if tg_op = 'UPDATE' and new.size_id <> old.size_id then
      raise exception 'A selection cannot be moved to another size';
    end if;
    select s.segment_id, s.is_active into v_segment, v_active
      from public.sizes s where s.id = new.size_id;
  end if;

  if new.is_selected then
    -- A switched-off grade or size is invisible to sellers, so "not found"
    -- also means switched off.
    if v_segment is null or not v_active then
      raise exception 'This grade or size is switched off in the catalogue';
    end if;
    if not exists (
      select 1 from public.seller_brands sb
       where sb.seller_id = new.seller_id and sb.brand_id = new.brand_id
         and sb.segment_id = v_segment and sb.is_active
    ) then
      raise exception 'Add % to the brands you sell first.',
        coalesce(public.brand_display_name(new.brand_id, v_segment), 'this brand');
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.seller_offerings_record_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.is_selected = old.is_selected then
    return null;
  end if;

  if tg_table_name = 'seller_grades' then
    insert into public.seller_offering_history (seller_id, brand_id, product_id, is_selected, changed_at, changed_by)
    values (new.seller_id, new.brand_id, new.product_id, new.is_selected, clock_timestamp(), auth.uid());
  else
    insert into public.seller_offering_history (seller_id, brand_id, size_id, is_selected, changed_at, changed_by)
    values (new.seller_id, new.brand_id, new.size_id, new.is_selected, clock_timestamp(), auth.uid());
  end if;
  return null;
end;
$$;

-- Select all / unselect all, per brand line -----------------------------------------

drop function public.select_all_in_family(uuid, text, boolean, uuid);

create function public.select_all_in_family(
  p_segment_id  uuid,
  p_what        text,
  p_selected    boolean default true,
  p_seller_id   uuid default null,
  -- TRANSITIONAL: empty = Regular (until brands step 11).
  p_brand_id    uuid default null
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_seller   uuid := coalesce(p_seller_id, auth.uid());
  v_brand    uuid := coalesce(p_brand_id, (select b.id from public.brands b where b.is_regular));
  v_changed  integer;
begin
  if p_what = 'grades' then
    if p_selected then
      insert into public.seller_grades (seller_id, brand_id, product_id, is_selected)
      select v_seller, v_brand, p.id, true
        from public.products p where p.segment_id = p_segment_id and p.is_active
      on conflict (seller_id, brand_id, product_id) do update set is_selected = true
        where public.seller_grades.is_selected is distinct from true;
    else
      update public.seller_grades g set is_selected = false
        from public.products p
       where p.id = g.product_id and p.segment_id = p_segment_id
         and g.seller_id = v_seller and g.brand_id = v_brand and g.is_selected;
    end if;
  elsif p_what = 'sizes' then
    if p_selected then
      insert into public.seller_sizes (seller_id, brand_id, size_id, is_selected)
      select v_seller, v_brand, s.id, true
        from public.sizes s where s.segment_id = p_segment_id and s.is_active
      on conflict (seller_id, brand_id, size_id) do update set is_selected = true
        where public.seller_sizes.is_selected is distinct from true;
    else
      update public.seller_sizes z set is_selected = false
        from public.sizes s
       where s.id = z.size_id and s.segment_id = p_segment_id
         and z.seller_id = v_seller and z.brand_id = v_brand and z.is_selected;
    end if;
  else
    raise exception 'Choose "grades" or "sizes"';
  end if;

  get diagnostics v_changed = row_count;
  return v_changed;
end;
$$;

revoke execute on function public.select_all_in_family(uuid, text, boolean, uuid, uuid) from public, anon;
grant execute on function public.select_all_in_family(uuid, text, boolean, uuid, uuid) to authenticated;

-- The per-size lookup reads the Regular line's sizes until step 5 --------------------

create or replace function public.resolve_size_figures(
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
  v_regular  uuid := (select b.id from public.brands b where b.is_regular);
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
      on ss.seller_id = p_seller_id and ss.size_id = z.id and ss.brand_id = v_regular
    left join size_pick sp on sp.cand_size = z.id
    left join loading_pick lp on lp.cand_size = z.id
   where z.segment_id = p_segment_id and z.is_active
   order by z.sort_order;
end;
$$;
