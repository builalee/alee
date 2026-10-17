-- ============================================================
-- OBJECTIVE:      Add the only two ways chart figures are written:
--                 save_chart_version (save a new version of a chart) and
--                 copy_template (copy an ALEE template into a seller's own
--                 chart).
-- WHY:            A version and its figures must be written together and
--                 never added to later. A template copy must be a fully
--                 separate chart, so changing a template never changes a
--                 seller's chart (decision 2.5).
-- CHANGES:        New functions public.save_chart_version(...) and
--                 public.copy_template(...).
-- DEPENDS ON:     20261017055742_create_chart_versions.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping both functions. Charts could then no
--                 longer be saved until they are restored.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; saved checks in tests/database/charts.sql (105) pass.
--                 Saving always adds a new version. Sellers save only their
--                 own charts, admins only for templates. A template copy is
--                 the seller's own; later template changes leave it as it
--                 was. Visitors cannot call either function.
-- DATE:           2026-10-17
-- ============================================================

-- Saves a new version of a chart and returns its id.
--
--   size chart:     p_figures = [{"size_id": "...", "amount": 500}, ...]
--   loading chart:  p_figures = [{"size_id": null, "amount": 250},      <- all sizes, required
--                                {"size_id": "...", "amount": 300}]     <- optional per size
--   discount chart: p_discount = {"kind": "flat", "amount": 500}
--                             or {"kind": "percent", "percent": 1.5}
--
-- Every figure needs an amount; 0 means "same as base" and is stored as 0.
-- Runs with owner rights so it can write the figures, and therefore checks
-- permission itself: a seller may save only his own charts, only admins may
-- save templates.
create function public.save_chart_version(
  p_chart_id  uuid,
  p_unit      public.unit,
  p_figures   jsonb default null,
  p_discount  jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c          public.charts%rowtype;
  v_id       uuid;
  v_number   integer;
  all_sizes  integer;
  kind       text;
begin
  select * into c from public.charts where id = p_chart_id for update;
  if not found then
    raise exception 'Chart not found';
  end if;

  if c.is_template then
    if not public.is_admin() then
      raise exception 'Only admins can change templates' using errcode = '42501';
    end if;
  elsif c.seller_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'You can only change your own charts' using errcode = '42501';
  end if;

  if not c.is_active then
    raise exception 'This chart is switched off';
  end if;
  if p_unit is null or p_unit not in ('tonne', 'kg') then
    raise exception 'Chart figures must be per tonne or per kg';
  end if;

  -- Shape of the input for each chart type.
  if c.chart_type in ('size', 'loading') then
    if p_discount is not null then
      raise exception 'Only a discount chart has a discount';
    end if;
    if p_figures is null or jsonb_typeof(p_figures) <> 'array' or jsonb_array_length(p_figures) = 0 then
      raise exception 'Give at least one figure';
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_figures) e
       where jsonb_typeof(e) <> 'object' or coalesce(jsonb_typeof(e -> 'amount'), 'null') = 'null'
    ) then
      raise exception 'Every figure needs an amount. Use 0 for "same as base"';
    end if;
    if c.chart_type = 'loading' then
      select count(*) into all_sizes
        from jsonb_array_elements(p_figures) e
       where coalesce(jsonb_typeof(e -> 'size_id'), 'null') = 'null';
      if all_sizes <> 1 then
        raise exception 'A loading chart needs exactly one figure for all sizes';
      end if;
    end if;
  else
    if p_figures is not null and jsonb_array_length(p_figures) > 0 then
      raise exception 'A discount chart has no per-size figures';
    end if;
    kind := p_discount ->> 'kind';
    if kind is null or kind not in ('flat', 'percent') then
      raise exception 'A discount must be "flat" or "percent"';
    end if;
  end if;

  -- Mark this chart as being saved, so the guards on the version tables
  -- accept these rows and no others.
  perform set_config('alee.saving_chart', c.id::text, true);

  select coalesce(max(v.version_number), 0) + 1 into v_number
    from public.chart_versions v where v.chart_id = c.id;

  insert into public.chart_versions (chart_id, version_number, unit)
  values (c.id, v_number, p_unit)
  returning id into v_id;

  if c.chart_type in ('size', 'loading') then
    insert into public.chart_version_figures (version_id, size_id, amount)
    select v_id, (e ->> 'size_id')::uuid, (e ->> 'amount')::numeric
      from jsonb_array_elements(p_figures) e;
  else
    insert into public.chart_version_discounts (version_id, kind, flat_amount, percent)
    values (
      v_id,
      kind::public.discount_kind,
      case when kind = 'flat' then (p_discount ->> 'amount')::numeric end,
      case when kind = 'percent' then (p_discount ->> 'percent')::numeric end
    );
  end if;

  perform set_config('alee.saving_chart', '', true);
  return v_id;
end;
$$;

comment on function public.save_chart_version(uuid, public.unit, jsonb, jsonb) is
  'The only way to save chart figures. Always creates a new version; never edits one.';

-- Copies an active template into a seller's own chart (version 1 = the
-- template's latest version, same unit and figures) and returns the new
-- chart's id. A seller copies for himself; an admin may copy for any
-- seller (p_seller_id), for setting sellers up.
create function public.copy_template(
  p_template_id  uuid,
  p_name         text default null,
  p_seller_id    uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  t          public.charts%rowtype;
  tv         public.chart_versions%rowtype;
  v_seller   uuid := coalesce(p_seller_id, auth.uid());
  v_chart    uuid;
  v_version  uuid;
begin
  if v_seller is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if v_seller is distinct from auth.uid() and not public.is_admin() then
    raise exception 'You can only copy templates into your own charts' using errcode = '42501';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = v_seller) then
    raise exception 'Only sellers can have charts';
  end if;

  select * into t from public.charts where id = p_template_id;
  if not found or not t.is_template or not t.is_active then
    raise exception 'This template is not available';
  end if;

  select * into tv from public.chart_versions v
   where v.chart_id = t.id order by v.version_number desc limit 1;
  if not found then
    raise exception 'This template has no figures yet';
  end if;

  insert into public.charts (seller_id, segment_id, chart_type, name, copied_from_template_id)
  values (v_seller, t.segment_id, t.chart_type,
          coalesce(nullif(btrim(p_name), ''), t.name), t.id)
  returning id into v_chart;

  perform set_config('alee.saving_chart', v_chart::text, true);

  insert into public.chart_versions (chart_id, version_number, unit)
  values (v_chart, 1, tv.unit)
  returning id into v_version;

  insert into public.chart_version_figures (version_id, size_id, amount)
  select v_version, f.size_id, f.amount
    from public.chart_version_figures f where f.version_id = tv.id;

  insert into public.chart_version_discounts (version_id, kind, flat_amount, percent)
  select v_version, d.kind, d.flat_amount, d.percent
    from public.chart_version_discounts d where d.version_id = tv.id;

  perform set_config('alee.saving_chart', '', true);
  return v_chart;
end;
$$;

comment on function public.copy_template(uuid, text, uuid) is
  'Copies a template into a seller''s own, fully separate chart.';

revoke execute on function public.save_chart_version(uuid, public.unit, jsonb, jsonb) from public, anon;
revoke execute on function public.copy_template(uuid, text, uuid) from public, anon;
grant execute on function public.save_chart_version(uuid, public.unit, jsonb, jsonb) to authenticated;
grant execute on function public.copy_template(uuid, text, uuid) to authenticated;
