-- ============================================================
-- OBJECTIVE:      Make publishing and status per brand line. Each publish
--                 item names a brand; one publish can cover many brands and
--                 families. Current rate, "not quoting", "close market now"
--                 and open / closed are per brand line. Existing records
--                 move to Regular.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.25, 2.28,
--                 2.29 as updated, 2.40, 2.42).
-- CHANGES:        publish_items, publish_chart_versions,
--                 seller_family_status, seller_family_status_history: new
--                 column brand_id (required); keys include the brand.
--                 public.publish_rates(...) replaced (same arguments): each
--                 item may name "brand_id"; messages name the brand.
--                 public.market_status(...), public.set_quoting(...),
--                 public.close_market_now(...) recreated with a brand
--                 argument; close_market_now with nothing named closes every
--                 brand line the seller sells.
--                 public.resolve_size_figures(...) replaced (same arguments)
--                 to use only the publish's chart versions for that brand.
--                 TRANSITIONAL (docs/decisions.md 2.44, removed in brands
--                 step 11): no brand given = Regular.
-- DEPENDS ON:     20261017124924_area_settings_per_brand.
--                 20261017084716_create_seller_family_status.
-- TOUCHES EXISTING DATA: YES. Every existing publish item, pinned chart
--                 version, status row and status history entry is given the
--                 Regular brand. Nothing is removed. On alee-dev there are
--                 none.
-- REVERSIBLE:     Partly: the columns can be dropped and the functions
--                 restored, provided nothing has been published or switched
--                 for a brand other than Regular (that would be lost).
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/brand_publishes.sql (28).
--                 One publish covers three brand lines; latest per brand
--                 line; refusals name the brand; a switched-off chart on one
--                 brand doesn't block another; not quoting, close now and
--                 open / closed per brand line; close now with nothing named
--                 closes every open line; a brand's publish rebuilds from its
--                 own pinned versions; publishes.sql and territory.sql
--                 unchanged and passing.
-- DATE:           2026-10-17
-- ============================================================

-- Columns, carried across to Regular ------------------------------------------------

alter table public.publish_chart_versions drop constraint publish_chart_versions_publish_id_segment_id_fkey;

alter table public.publish_items add column brand_id uuid references public.brands (id);
alter table public.publish_chart_versions add column brand_id uuid references public.brands (id);
alter table public.seller_family_status add column brand_id uuid references public.brands (id);
alter table public.seller_family_status_history add column brand_id uuid references public.brands (id);

alter table public.publish_items disable trigger publish_items_prevent_update;
alter table public.publish_chart_versions disable trigger publish_chart_versions_prevent_update;
alter table public.seller_family_status_history disable trigger seller_family_status_history_prevent_update;
update public.publish_items set brand_id = (select id from public.brands where is_regular);
update public.publish_chart_versions set brand_id = (select id from public.brands where is_regular);
update public.seller_family_status set brand_id = (select id from public.brands where is_regular);
update public.seller_family_status_history set brand_id = (select id from public.brands where is_regular);
alter table public.publish_items enable trigger publish_items_prevent_update;
alter table public.publish_chart_versions enable trigger publish_chart_versions_prevent_update;
alter table public.seller_family_status_history enable trigger seller_family_status_history_prevent_update;

alter table public.publish_items alter column brand_id set not null;
alter table public.publish_chart_versions alter column brand_id set not null;
alter table public.seller_family_status alter column brand_id set not null;
alter table public.seller_family_status_history alter column brand_id set not null;

alter table public.publish_items drop constraint publish_items_pkey,
  add primary key (publish_id, brand_id, segment_id);
alter table public.publish_chart_versions drop constraint publish_chart_versions_pkey,
  add primary key (publish_id, brand_id, segment_id, chart_id),
  add foreign key (publish_id, brand_id, segment_id)
    references public.publish_items (publish_id, brand_id, segment_id) on delete cascade;
alter table public.seller_family_status drop constraint seller_family_status_pkey,
  add primary key (seller_id, brand_id, segment_id);

drop index public.seller_family_status_history_idx;
create index seller_family_status_history_idx
  on public.seller_family_status_history (seller_id, brand_id, segment_id, happened_at);
create index publish_items_brand_idx on public.publish_items (brand_id, segment_id);

comment on column public.publish_items.brand_id is 'The brand of this basic rate (with the family: the brand line).';

-- A publish item's area settings must be for the same brand line.
create or replace function public.publish_items_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_seller uuid;
begin
  select p.seller_id into v_seller from public.publishes p where p.id = new.publish_id;
  if current_setting('alee.publishing', true) is distinct from v_seller::text then
    raise exception 'Nothing can be added to a publish after it is made; publish again instead';
  end if;
  if not exists (
    select 1 from public.area_setting_versions av
     where av.id = new.area_setting_version_id
       and av.seller_id = v_seller and av.brand_id = new.brand_id and av.segment_id = new.segment_id
  ) then
    raise exception 'The area settings must be the seller''s own, for this brand and product family';
  end if;
  return new;
end;
$$;

-- How a brand line is named in messages: the family's name for Regular
-- ("TMT Bars"), otherwise brand and family ("Check Tiscon TMT").
create function public.brand_line_label(p_brand_id uuid, p_segment_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case when b.is_regular then s.name else b.name || ' ' || s.short_name end
    from public.brands b, public.segments s
   where b.id = p_brand_id and s.id = p_segment_id;
$$;

grant execute on function public.brand_line_label(uuid, uuid) to anon, authenticated;

-- Publishing ------------------------------------------------------------------------------

-- As 20261017111605, plus: each item may name "brand_id" (empty = Regular,
-- transitional); the seller must sell that brand there; the same brand and
-- family can appear only once; area settings, pinned charts and status are
-- per brand line; messages name the brand.
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
  v_regular  uuid := (select b.id from public.brands b where b.is_regular);
  it         jsonb;
  k          text;
  v_seg      uuid;
  v_brand    uuid;
  v_family   text;
  v_label    text;
  v_unit     public.unit;
  v_version  uuid;
  v_quoting  boolean;
  bad        record;
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
     <> (select count(distinct (coalesce(e ->> 'brand_id', v_regular::text), e ->> 'segment_id'))
           from jsonb_array_elements(p_items) e) then
    raise exception 'Each brand of each product family can appear only once in a publish.';
  end if;

  -- Check everything before writing anything.
  for it in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(it) <> 'object' then
      raise exception 'Each item must be an object';
    end if;
    for k in select jsonb_object_keys(it) loop
      if k not in ('segment_id', 'brand_id', 'base_rate') then
        raise exception 'Unknown publish field "%"', k;
      end if;
    end loop;
    v_seg := (it ->> 'segment_id')::uuid;
    v_brand := coalesce((it ->> 'brand_id')::uuid, v_regular);
    select s.name into v_family from public.segments s where s.id = v_seg;
    v_label := coalesce(public.brand_line_label(v_brand, v_seg), v_family, 'this product family');

    if not exists (
      select 1 from public.seller_segments ss
       where ss.seller_id = v_seller and ss.segment_id = v_seg and ss.is_active
    ) then
      raise exception 'You don''t sell % yet. Add it to your product families before publishing.', coalesce(v_family, 'this product family');
    end if;
    if not exists (
      select 1 from public.seller_brands sb
       where sb.seller_id = v_seller and sb.brand_id = v_brand and sb.segment_id = v_seg and sb.is_active
    ) then
      raise exception 'Add % to the brands you sell before publishing it.', v_label;
    end if;
    if coalesce(jsonb_typeof(it -> 'base_rate'), 'null') <> 'number' then
      raise exception 'Enter your basic rate for %.', v_label;
    end if;

    select av.id into v_version from public.area_setting_versions av
     where av.seller_id = v_seller and av.brand_id = v_brand and av.segment_id = v_seg
     order by av.version_number desc limit 1;
    if v_version is null then
      raise exception 'Choose where you sell % before publishing.', v_label;
    end if;

    select x.area, x.grade, x.chart into bad
      from (
        select coalesce(r.name, 'Everywhere') as area, null::text as grade, c.name as chart, r.name as sort_area
          from public.area_settings s
          left join public.regions r on r.id = s.region_id
          join public.charts c on c.id in (s.size_chart_id, s.loading_chart_id, s.discount_chart_id)
         where s.version_id = v_version and not c.is_active
        union all
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
      -- Branded lines say which brand first; Regular reads as before.
      if bad.grade is null then
        raise exception '%', (case when v_brand = v_regular then '' else v_label || ': ' end)
          || format('%s still uses ''%s'', which you switched off. Choose a chart for %s.', bad.area, bad.chart, bad.area);
      else
        raise exception '%', (case when v_brand = v_regular then '' else v_label || ': ' end)
          || format('%s (%s) still uses ''%s'', which you switched off. Choose a chart for %s in %s.',
                    bad.area, bad.grade, bad.chart, bad.grade, bad.area);
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
    v_brand := coalesce((it ->> 'brand_id')::uuid, v_regular);

    select ss.base_unit into v_unit from public.seller_segments ss
     where ss.seller_id = v_seller and ss.segment_id = v_seg;
    select av.id into v_version from public.area_setting_versions av
     where av.seller_id = v_seller and av.brand_id = v_brand and av.segment_id = v_seg
     order by av.version_number desc limit 1;

    insert into public.publish_items (publish_id, brand_id, segment_id, base_rate, unit, area_setting_version_id)
    values (v_publish, v_brand, v_seg, (it ->> 'base_rate')::numeric, v_unit, v_version);

    insert into public.publish_chart_versions (publish_id, brand_id, segment_id, chart_id, chart_version_id)
    select v_publish, v_brand, v_seg, used.chart_id,
           (select cv.id from public.chart_versions cv
             where cv.chart_id = used.chart_id order by cv.version_number desc limit 1)
      from (select s.size_chart_id as chart_id from public.area_settings s where s.version_id = v_version
            union select s.loading_chart_id from public.area_settings s where s.version_id = v_version
            union select s.discount_chart_id from public.area_settings s where s.version_id = v_version
            union select g.size_chart_id from public.area_grade_settings g
                    join public.area_settings s on s.id = g.area_setting_id where s.version_id = v_version) used
     where used.chart_id is not null;

    update public.charts c set in_use_since = v_at
     where c.in_use_since is null
       and c.id in (select pcv.chart_id from public.publish_chart_versions pcv
                     where pcv.publish_id = v_publish and pcv.brand_id = v_brand and pcv.segment_id = v_seg);

    -- Current status of this brand line: the latest publish. That reopens a
    -- market closed earlier and switches "not quoting" back on, recorded in
    -- history.
    select st.is_quoting into v_quoting from public.seller_family_status st
     where st.seller_id = v_seller and st.brand_id = v_brand and st.segment_id = v_seg;

    insert into public.seller_family_status (seller_id, brand_id, segment_id, latest_publish_id, last_published_at, is_quoting)
    values (v_seller, v_brand, v_seg, v_publish, v_at, true)
    on conflict (seller_id, brand_id, segment_id) do update
      set latest_publish_id = excluded.latest_publish_id,
          last_published_at = excluded.last_published_at,
          is_quoting = true;

    if v_quoting = false then
      insert into public.seller_family_status_history (seller_id, brand_id, segment_id, event, happened_at, done_by, by_admin)
      values (v_seller, v_brand, v_seg, 'resumed_quoting', v_at, v_by, v_seller <> v_by);
    end if;
  end loop;

  perform set_config('alee.publishing', '', true);
  return v_publish;
end;
$$;

-- Market status, per brand line ---------------------------------------------------------

drop function public.close_market_now(uuid[], uuid);
drop function public.set_quoting(uuid, boolean, uuid);
drop function public.market_status(uuid, uuid, timestamptz);

create function public.market_status(
  p_seller_id   uuid,
  p_segment_id  uuid,
  p_at          timestamptz default null,
  -- TRANSITIONAL: empty = Regular (until brands step 11).
  p_brand_id    uuid default null
)
returns table (
  status             text,
  last_published_at  timestamptz,
  closed_at          timestamptz
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  s           record;
  v_brand     uuid := coalesce(p_brand_id, (select b.id from public.brands b where b.is_regular));
  v_at        timestamptz := coalesce(p_at, clock_timestamp());
  v_close     time;
  v_daily     timestamptz;
  v_closes_at timestamptz;
begin
  select st.last_published_at, st.is_quoting, st.closed_early_at into s
    from public.seller_family_status st
   where st.seller_id = p_seller_id and st.brand_id = v_brand and st.segment_id = p_segment_id;

  if found and not s.is_quoting then
    return query select 'not_quoting'::text, s.last_published_at, null::timestamptz;
    return;
  end if;
  if not found or s.last_published_at is null then
    return query select 'not_published'::text, null::timestamptz, null::timestamptz;
    return;
  end if;

  select sp.market_close_time into v_close
    from public.seller_profiles sp where sp.account_id = p_seller_id;

  if v_close is not null then
    v_daily := (((s.last_published_at at time zone 'Asia/Kolkata')::date + v_close)
                at time zone 'Asia/Kolkata');
    if v_daily <= s.last_published_at then
      v_daily := v_daily + interval '1 day';
    end if;
  end if;

  v_closes_at := least(
    v_daily,
    case when s.closed_early_at > s.last_published_at then s.closed_early_at end
  );

  if v_closes_at is not null and v_closes_at <= v_at then
    return query select 'closed'::text, s.last_published_at, v_closes_at;
  else
    return query select 'open'::text, s.last_published_at, null::timestamptz;
  end if;
end;
$$;

comment on function public.market_status(uuid, uuid, timestamptz, uuid) is
  'Open, closed, not quoting or not published, for one brand line. The one place market status is worked out.';

grant execute on function public.market_status(uuid, uuid, timestamptz, uuid) to anon, authenticated;

create function public.set_quoting(
  p_segment_id  uuid,
  p_quoting     boolean,
  p_seller_id   uuid default null,
  -- TRANSITIONAL: empty = Regular (until brands step 11).
  p_brand_id    uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller   uuid := public.status_actor(p_seller_id);
  v_brand    uuid := coalesce(p_brand_id, (select b.id from public.brands b where b.is_regular));
  v_current  boolean;
begin
  if p_quoting is null then
    raise exception 'Say whether the family is quoting (true) or not (false)';
  end if;
  if not exists (
    select 1 from public.seller_brands sb
     where sb.seller_id = v_seller and sb.brand_id = v_brand and sb.segment_id = p_segment_id and sb.is_active
  ) then
    raise exception 'The seller does not sell % yet', coalesce(public.brand_line_label(v_brand, p_segment_id), 'this');
  end if;

  select st.is_quoting into v_current
    from public.seller_family_status st
   where st.seller_id = v_seller and st.brand_id = v_brand and st.segment_id = p_segment_id;
  if coalesce(v_current, true) = p_quoting then
    return p_quoting;
  end if;

  insert into public.seller_family_status (seller_id, brand_id, segment_id, is_quoting)
  values (v_seller, v_brand, p_segment_id, p_quoting)
  on conflict (seller_id, brand_id, segment_id) do update set is_quoting = excluded.is_quoting;

  insert into public.seller_family_status_history (seller_id, brand_id, segment_id, event, done_by, by_admin)
  values (v_seller, v_brand, p_segment_id,
          case when p_quoting then 'resumed_quoting' else 'stopped_quoting' end::public.family_status_event,
          auth.uid(), v_seller <> auth.uid());

  return p_quoting;
end;
$$;

-- Closes the given families (all if none named), for the given brands (all
-- if none named), straight away. Only brand lines currently open are
-- closed and recorded. Returns how many closed.
create function public.close_market_now(
  p_segment_ids  uuid[] default null,
  p_seller_id    uuid default null,
  p_brand_ids    uuid[] default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller  uuid := public.status_actor(p_seller_id);
  v_at      timestamptz := clock_timestamp();
  ln        record;
  v_count   integer := 0;
begin
  for ln in
    select sb.brand_id, sb.segment_id from public.seller_brands sb
     where sb.seller_id = v_seller and sb.is_active
       and (p_segment_ids is null or sb.segment_id = any (p_segment_ids))
       and (p_brand_ids is null or sb.brand_id = any (p_brand_ids))
  loop
    if (select m.status from public.market_status(v_seller, ln.segment_id, v_at, ln.brand_id) m) = 'open' then
      update public.seller_family_status set closed_early_at = v_at
       where seller_id = v_seller and brand_id = ln.brand_id and segment_id = ln.segment_id;
      insert into public.seller_family_status_history (seller_id, brand_id, segment_id, event, happened_at, done_by, by_admin)
      values (v_seller, ln.brand_id, ln.segment_id, 'closed_early', v_at, auth.uid(), v_seller <> auth.uid());
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.set_quoting(uuid, boolean, uuid, uuid) from public, anon;
revoke execute on function public.close_market_now(uuid[], uuid, uuid[]) from public, anon;
grant execute on function public.set_quoting(uuid, boolean, uuid, uuid) to authenticated;
grant execute on function public.close_market_now(uuid[], uuid, uuid[]) to authenticated;

-- Rebuilding a publish uses only that brand's pinned chart versions ---------------------
-- Same as 20261017124924, except the pinned chart versions are read for
-- the brand being looked up.

create or replace function public.resolve_size_figures(
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
     where pi.publish_id = p_publish_id and pi.segment_id = p_segment_id
       and p.seller_id = p_seller_id and pi.brand_id = v_brand;
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
       and pcv.publish_id = p_publish_id and pcv.segment_id = p_segment_id and pcv.brand_id = v_brand
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
