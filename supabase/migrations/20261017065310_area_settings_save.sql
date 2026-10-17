-- ============================================================
-- OBJECTIVE:      Add save_area_settings: the only way to save a seller's
--                 area settings for a product family. Every save creates a
--                 new, complete version.
-- WHY:            Old versions must never change (docs/decisions.md 2.20),
--                 "everywhere" must be chosen explicitly (2.19), and "not
--                 set" must never be confused with zero. Unknown setting
--                 names are refused, so a typo can never silently become
--                 "not set".
-- CHANGES:        New function public.save_area_settings(...).
-- DEPENDS ON:     20261017065210_create_area_settings.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the function.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks (npm run check:db) pass, including
--                 tests/database/area_settings.sql (71).
--                 "Everywhere" only when explicit; misspelt setting names,
--                 excluded areas with settings, the same area twice and
--                 families the seller does not deal in are refused, with no
--                 half-made version left. Version records the seller's unit
--                 (tonne for one seller, kg for another). Only the seller or
--                 an admin can save.
-- DATE:           2026-10-17
-- ============================================================

-- Saves a seller's whole area setup for one product family as a new
-- version, and returns its id. p_areas is a list, one entry per area:
--
--   {
--     "region_id": "...",            -- a state, district, taluka or city
--       or "everywhere": true,       -- the level above every state
--     "excluded": true,              -- not served (nothing else allowed)
--     "area_difference": 200,        -- 0 is a real zero; leave out = not set
--     "size_chart_id": "...",
--     "loading_chart_id": "...",
--     "discount_chart_id": "...",
--     "display_unit": "kg",          -- tonne, kg, piece or metre
--     "grades": [
--       { "product_id": "...", "premium": 300, "size_chart_id": "...", "sold": false }
--     ]
--   }
--
-- A setting that is left out, or given as null, is "not set" and carries
-- down from the area above. An empty list means the seller serves nowhere.
-- Amounts are in the seller's current unit for the family, which the
-- version records. A seller saves his own; an admin may save for any.
create function public.save_area_settings(
  p_segment_id  uuid,
  p_areas       jsonb,
  p_seller_id   uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller   uuid := coalesce(p_seller_id, auth.uid());
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

  if p_areas is null or jsonb_typeof(p_areas) <> 'array' then
    raise exception 'Give a list of areas (an empty list means serving nowhere)';
  end if;

  -- Check the shape of every entry before writing anything.
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

  perform set_config('alee.saving_area_settings', v_seller::text || '/' || p_segment_id::text, true);

  select coalesce(max(v.version_number), 0) + 1 into v_number
    from public.area_setting_versions v
   where v.seller_id = v_seller and v.segment_id = p_segment_id;

  insert into public.area_setting_versions (seller_id, segment_id, version_number, unit)
  values (v_seller, p_segment_id, v_number, v_unit)
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

comment on function public.save_area_settings(uuid, jsonb, uuid) is
  'The only way to save area settings. Always creates a new, complete version.';

revoke execute on function public.save_area_settings(uuid, jsonb, uuid) from public, anon;
grant execute on function public.save_area_settings(uuid, jsonb, uuid) to authenticated;
