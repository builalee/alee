-- ============================================================
-- OBJECTIVE:      When a seller copies a template, convert its figures into
--                 the unit the seller prices that product family in. A
--                 per-tonne template copied by a per-kg seller is saved per
--                 kg (Rs 6,500 per tonne becomes Rs 6.5 per kg).
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.18),
--                 replacing the earlier proposal that copies keep the
--                 template's unit. A seller's charts should be in the unit he
--                 prices in, so his figures read the way he thinks.
-- CHANGES:        New function public.convert_per_unit(amount, from, to): the
--                 one place amounts are converted between per tonne and per
--                 kg. public.copy_template(...) replaced: it now requires the
--                 seller to deal in the template's product family and saves
--                 the copy in his unit for it.
-- DEPENDS ON:     20261017055842_chart_save_and_copy.
--                 20261017050259_create_seller_segments.
-- TOUCHES EXISTING DATA: No. Copies made before this change are untouched.
-- REVERSIBLE:     Yes, by restoring the previous copy_template from
--                 20261017055842 and dropping convert_per_unit.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks (npm run check:db) pass.
--                 tests/database/templates.sql: 6500 per tonne copied by a
--                 per-kg seller becomes 6.5 per kg; 6.533 per kg becomes 6533
--                 per tonne; flat discount 500 per tonne becomes 0.5 per kg;
--                 percentages unchanged; 6500.55 per tonne refused, not
--                 rounded, with no half-made copy; a seller not dealing in
--                 the family cannot copy.
-- DATE:           2026-10-17
-- ============================================================

-- Converts an amount quoted per one unit into the same amount quoted per
-- another: per tonne <-> per kg. The result must be exact to 4 decimal
-- places; if it is not, it is refused, never rounded. Piece and metre need a
-- size's weight and belong to the rate engine.
create function public.convert_per_unit(
  p_amount  numeric,
  p_from    public.unit,
  p_to      public.unit
)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  r numeric;
begin
  if p_amount is null or p_from = p_to then
    return p_amount;
  elsif p_from = 'tonne' and p_to = 'kg' then
    r := p_amount / 1000;
  elsif p_from = 'kg' and p_to = 'tonne' then
    r := p_amount * 1000;
  else
    raise exception 'Converting per % to per % needs a size''s weight', p_from, p_to;
  end if;

  if r <> round(r, 4) then
    raise exception 'Rs % per % cannot be converted to per % exactly', p_amount, p_from, p_to;
  end if;
  return trim_scale(round(r, 4));
end;
$$;

comment on function public.convert_per_unit(numeric, public.unit, public.unit) is
  'The one place amounts are converted between per tonne and per kg. Exact or refused.';

-- Same as before, except: the seller must deal in the template's product
-- family, and the copy is saved in his unit for that family, with every
-- flat amount converted. Percentages are unchanged.
create or replace function public.copy_template(
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
  v_unit     public.unit;
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

  select ss.base_unit into v_unit
    from public.seller_segments ss
   where ss.seller_id = v_seller and ss.segment_id = t.segment_id and ss.is_active;
  if not found then
    raise exception 'Add this product family to the seller before copying its template';
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
  values (v_chart, 1, v_unit)
  returning id into v_version;

  insert into public.chart_version_figures (version_id, size_id, amount)
  select v_version, f.size_id, public.convert_per_unit(f.amount, tv.unit, v_unit)
    from public.chart_version_figures f where f.version_id = tv.id;

  insert into public.chart_version_discounts (version_id, kind, flat_amount, percent)
  select v_version, d.kind, public.convert_per_unit(d.flat_amount, tv.unit, v_unit), d.percent
    from public.chart_version_discounts d where d.version_id = tv.id;

  perform set_config('alee.saving_chart', '', true);
  return v_chart;
end;
$$;

comment on function public.copy_template(uuid, text, uuid) is
  'Copies a template into a seller''s own, fully separate chart, converted into his unit for that product family.';

-- create or replace keeps the existing grants (authenticated only).
