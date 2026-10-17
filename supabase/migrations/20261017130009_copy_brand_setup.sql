-- ============================================================
-- OBJECTIVE:      Copy one brand line's setup to another brand of the same
--                 seller and family in one tap: grades and sizes chosen,
--                 and area settings (as a new version pointing at the same
--                 charts).
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.40).
--                 Brands differ but are often similar; copying keeps a
--                 seller's work to a minimum. Charts are shared, not
--                 duplicated. After copying, the two brands are fully
--                 separate.
-- CHANGES:        New function public.copy_brand_setup(...).
-- DEPENDS ON:     20261017125428_publishing_per_brand.
--                 20261017063130_copy_template_converts_unit (convert_per_unit).
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the function.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/brand_copy.sql (19).
--                 Grades, sizes and area settings copied in one call; zero
--                 kept as 0 and not set kept not set; the chart shared, not
--                 duplicated; the brands separate afterwards; copying again
--                 matches the source and keeps old versions; 250 per tonne
--                 converted to 0.25 per kg after a unit change; plain
--                 refusals; only the seller or an admin can copy.
-- DATE:           2026-10-17
-- ============================================================

-- Makes the target brand's grades and sizes match the source brand's, and
-- saves the source's latest area settings as a new version for the target
-- (same areas, same charts). "Not set" and zero are kept apart. If the
-- seller's unit for the family has changed since the source was saved,
-- amounts are converted exactly into the current unit, or the copy is
-- refused. Runs with the caller's rights: a seller copies his own brands;
-- an admin may copy for a seller. Returns the new area-settings version
-- (empty if the source had no area settings).
create function public.copy_brand_setup(
  p_segment_id  uuid,
  p_from_brand  uuid,
  p_to_brand    uuid,
  p_seller_id   uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_seller  uuid := coalesce(p_seller_id, auth.uid());
  v_src     record;
  v_unit    public.unit;
  v_areas   jsonb;
begin
  if v_seller is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if v_seller is distinct from auth.uid() and not public.is_admin() then
    raise exception 'You can only copy your own brands'' setup' using errcode = '42501';
  end if;
  if p_from_brand = p_to_brand then
    raise exception 'Choose a different brand to copy from.';
  end if;
  if not exists (
    select 1 from public.seller_brands sb
     where sb.seller_id = v_seller and sb.brand_id = p_from_brand and sb.segment_id = p_segment_id
  ) then
    raise exception 'There is nothing to copy from %.',
      coalesce(public.brand_line_label(p_from_brand, p_segment_id), 'that brand');
  end if;
  if not exists (
    select 1 from public.seller_brands sb
     where sb.seller_id = v_seller and sb.brand_id = p_to_brand and sb.segment_id = p_segment_id and sb.is_active
  ) then
    raise exception 'Add % to the brands you sell first.',
      coalesce(public.brand_line_label(p_to_brand, p_segment_id), 'that brand');
  end if;

  -- Grades and sizes: the target ends up offering exactly what the source
  -- offers (switched-on items only).
  insert into public.seller_grades (seller_id, brand_id, product_id, is_selected)
  select v_seller, p_to_brand, g.product_id, g.is_selected
    from public.seller_grades g join public.products p on p.id = g.product_id
   where g.seller_id = v_seller and g.brand_id = p_from_brand and p.segment_id = p_segment_id and p.is_active
  on conflict (seller_id, brand_id, product_id) do update set is_selected = excluded.is_selected
    where public.seller_grades.is_selected is distinct from excluded.is_selected;
  update public.seller_grades t set is_selected = false
    from public.products p
   where p.id = t.product_id and p.segment_id = p_segment_id
     and t.seller_id = v_seller and t.brand_id = p_to_brand and t.is_selected
     and not exists (select 1 from public.seller_grades s where s.seller_id = v_seller and s.brand_id = p_from_brand
                      and s.product_id = t.product_id and s.is_selected);

  insert into public.seller_sizes (seller_id, brand_id, size_id, is_selected)
  select v_seller, p_to_brand, z.size_id, z.is_selected
    from public.seller_sizes z join public.sizes s on s.id = z.size_id
   where z.seller_id = v_seller and z.brand_id = p_from_brand and s.segment_id = p_segment_id and s.is_active
  on conflict (seller_id, brand_id, size_id) do update set is_selected = excluded.is_selected
    where public.seller_sizes.is_selected is distinct from excluded.is_selected;
  update public.seller_sizes t set is_selected = false
    from public.sizes s
   where s.id = t.size_id and s.segment_id = p_segment_id
     and t.seller_id = v_seller and t.brand_id = p_to_brand and t.is_selected
     and not exists (select 1 from public.seller_sizes x where x.seller_id = v_seller and x.brand_id = p_from_brand
                      and x.size_id = t.size_id and x.is_selected);

  -- Area settings: the source's latest version, rebuilt as a save request.
  select av.id, av.unit into v_src from public.area_setting_versions av
   where av.seller_id = v_seller and av.brand_id = p_from_brand and av.segment_id = p_segment_id
   order by av.version_number desc limit 1;
  if v_src.id is null then
    return null;
  end if;

  select ss.base_unit into v_unit from public.seller_segments ss
   where ss.seller_id = v_seller and ss.segment_id = p_segment_id;

  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'region_id',         s.region_id,
           'everywhere',        case when s.region_id is null then true end,
           'excluded',          case when s.is_excluded then true end,
           'area_difference',   public.convert_per_unit(s.area_difference, v_src.unit, v_unit),
           'size_chart_id',     s.size_chart_id,
           'loading_chart_id',  s.loading_chart_id,
           'discount_chart_id', s.discount_chart_id,
           'display_unit',      s.display_unit,
           'grades', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                 'product_id',    g.product_id,
                                 'premium',       public.convert_per_unit(g.grade_premium, v_src.unit, v_unit),
                                 'size_chart_id', g.size_chart_id,
                                 'sold',          g.is_sold)))
                        from public.area_grade_settings g where g.area_setting_id = s.id)
         ))), '[]'::jsonb)
    into v_areas
    from public.area_settings s
   where s.version_id = v_src.id;

  return public.save_area_settings(p_segment_id, v_areas, v_seller, p_to_brand);
end;
$$;

comment on function public.copy_brand_setup(uuid, uuid, uuid, uuid) is
  'Copies one brand line''s grades, sizes and area settings to another of the seller''s brands in the same family. Charts are shared, not duplicated.';

revoke execute on function public.copy_brand_setup(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.copy_brand_setup(uuid, uuid, uuid, uuid) to authenticated;
