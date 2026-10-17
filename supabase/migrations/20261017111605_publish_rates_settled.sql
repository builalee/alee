-- ============================================================
-- OBJECTIVE:      Update publish_rates with the owner's settled rules:
--                 a daily closing time is required before publishing;
--                 publishing a family that is "not quoting" switches it
--                 back on (recorded in history); and a refused publish says
--                 in plain words what to fix.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.29,
--                 2.30, 2.32). Publishing reopens a closed market, so it
--                 should equally resume quoting. Messages name the product
--                 family, the area and the chart, e.g. "Satara still uses
--                 'Old TMT rates', which you switched off. Choose a chart
--                 for Satara."
-- CHANGES:        public.publish_rates(...) replaced (same arguments).
-- DEPENDS ON:     20261017084816_publish_rates.
--                 20261017084716_create_seller_family_status.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by restoring publish_rates from 20261017084816.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/publishes.sql (99).
--                 No closing time: refused with a plain message. Publishing a
--                 "not quoting" family switches it on, recorded in history at
--                 the publish time. Plain messages checked word for word: no
--                 area settings, an area's switched-off chart, a grade's
--                 switched-off chart, family not sold, no rate, empty publish.
-- DATE:           2026-10-17
-- ============================================================

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
     where av.seller_id = v_seller and av.segment_id = v_seg
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
     where av.seller_id = v_seller and av.segment_id = v_seg
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

comment on function public.publish_rates(jsonb, boolean, uuid, uuid) is
  'The only way to publish. One call = one publish for one or more families, with every version used pinned. Resumes quoting and reopens the market.';
