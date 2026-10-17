-- ============================================================
-- OBJECTIVE:      Add publish_rates: the only way to publish. One call is
--                 one publish for one or more product families. It records
--                 the basic rates, pins the area-settings version and every
--                 chart version in use, marks those charts as used, and
--                 updates the seller's current status (which reopens a
--                 closed market).
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.25 to
--                 2.29). A seller publishes only for himself; an admin may
--                 publish on his behalf during setup, recorded as such.
-- CHANGES:        New function public.publish_rates(...).
-- DEPENDS ON:     20261017084616_create_publishes.
--                 20261017084716_create_seller_family_status.
-- TOUCHES EXISTING DATA: No (only new publishes, and the "used since" mark
--                 on charts when they are first published).
-- REVERSIBLE:     Yes, by dropping the function.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/publishes.sql (88).
--                 Rate must be above zero and exact; family must be dealt in
--                 with area settings and no switched-off chart; versions
--                 pinned; charts marked used; latest publish found after
--                 several; corrections only of own publishes; admin publish
--                 recorded as by admin.
-- DATE:           2026-10-17
-- ============================================================

-- p_items: [{"segment_id": "...", "base_rate": 41000}, ...]
-- Each family must be one the seller deals in, with area settings saved,
-- and every chart those settings use still switched on. The basic rate is
-- in the seller's unit for that family and must be above zero.
create function public.publish_rates(
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
  v_unit     public.unit;
  v_version  uuid;
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

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Give at least one product family to publish';
  end if;
  if (select count(*) from jsonb_array_elements(p_items) e)
     <> (select count(distinct e ->> 'segment_id') from jsonb_array_elements(p_items) e) then
    raise exception 'Each product family can appear only once in a publish';
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
    if coalesce(jsonb_typeof(it -> 'base_rate'), 'null') <> 'number' then
      raise exception 'Each product family needs a basic rate';
    end if;
    v_seg := (it ->> 'segment_id')::uuid;

    if not exists (
      select 1 from public.seller_segments ss
       where ss.seller_id = v_seller and ss.segment_id = v_seg and ss.is_active
    ) then
      raise exception 'The seller does not deal in this product family';
    end if;

    select av.id into v_version from public.area_setting_versions av
     where av.seller_id = v_seller and av.segment_id = v_seg
     order by av.version_number desc limit 1;
    if v_version is null then
      raise exception 'Set up the areas you serve for this product family before publishing';
    end if;

    if exists (
      select 1 from public.charts c
       where c.id in (select s.size_chart_id from public.area_settings s where s.version_id = v_version
                      union select s.loading_chart_id from public.area_settings s where s.version_id = v_version
                      union select s.discount_chart_id from public.area_settings s where s.version_id = v_version
                      union select g.size_chart_id from public.area_grade_settings g
                              join public.area_settings s on s.id = g.area_setting_id where s.version_id = v_version)
         and not c.is_active
    ) then
      raise exception 'Your area settings use a chart that is switched off; update them before publishing';
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

    -- Current status: this is now the latest publish, which also reopens a
    -- market closed earlier. "Not quoting" is left as it is: it stays off
    -- until the seller switches it back on.
    insert into public.seller_family_status (seller_id, segment_id, latest_publish_id, last_published_at)
    values (v_seller, v_seg, v_publish, v_at)
    on conflict (seller_id, segment_id) do update
      set latest_publish_id = excluded.latest_publish_id,
          last_published_at = excluded.last_published_at;
  end loop;

  perform set_config('alee.publishing', '', true);
  return v_publish;
end;
$$;

comment on function public.publish_rates(jsonb, boolean, uuid, uuid) is
  'The only way to publish. One call = one publish for one or more families, with every version used pinned.';

revoke execute on function public.publish_rates(jsonb, boolean, uuid, uuid) from public, anon;
grant execute on function public.publish_rates(jsonb, boolean, uuid, uuid) to authenticated;
