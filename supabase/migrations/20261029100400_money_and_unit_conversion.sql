-- ============================================================
-- OBJECTIVE:      One place for writing rupees (₹56,500, ₹1,23,456.50,
--                 ₹6.50) and one place for converting a rate between
--                 tonne, kg, piece and metre, through the size's standard
--                 weight.
-- WHY:            CLAUDE.md sections 8 and 11: money formatting and unit
--                 conversion live in one shared place each; every
--                 conversion goes through weight; a size whose weight is
--                 not verified is never used to convert. The rate engine
--                 uses both. Decision 12.4: the figure is rounded once, at
--                 the end, to the nearest paisa; whole figures hide ".00".
-- CHANGES:        New functions public.format_rupees, public.kg_per_unit,
--                 public.convert_rate.
-- DEPENDS ON:     20261009155305_create_sizes, 20261009155938_sizes_belong_to_segment.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the functions.
-- TESTED:         On alee-dev 2026-10-29: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/rate_engine.sql (formatting and
--                 conversion).
-- DATE:           2026-10-29
-- ============================================================

-- Rupees in Indian grouping, rounded to the nearest paisa (half a paisa
-- rounds up), with ".00" hidden on whole figures:
-- 56500 -> ₹56,500; 123456.5 -> ₹1,23,456.50; 6.5 -> ₹6.50; -500 -> -₹500.
create function public.format_rupees(p_amount numeric)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_r     numeric;
  v_whole text;
  v_head  text;
  v_paise integer;
begin
  if p_amount is null then
    return null;
  end if;
  v_r := round(abs(p_amount), 2);
  v_whole := trunc(v_r)::text;
  v_paise := ((v_r - trunc(v_r)) * 100)::integer;
  if length(v_whole) > 3 then
    v_head := left(v_whole, length(v_whole) - 3);
    v_head := regexp_replace(v_head, '(\d)(?=(\d\d)+$)', '\1,', 'g');
    v_whole := v_head || ',' || right(v_whole, 3);
  end if;
  return case when p_amount < 0 and v_r > 0 then '-' else '' end
      || '₹' || v_whole
      || case when v_paise > 0 then '.' || lpad(v_paise::text, 2, '0') else '' end;
end;
$$;

-- Kilograms in one unit of a size: a tonne is 1000 kg, a kg is 1 kg, a
-- metre is the size's weight per metre, a piece is weight per metre x
-- piece length. Piece and metre need a verified size.
create function public.kg_per_unit(p_unit public.unit, p_size_id uuid default null)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  z record;
begin
  if p_unit = 'tonne' then
    return 1000;
  elsif p_unit = 'kg' then
    return 1;
  end if;
  select s.display_name, s.weight_per_metre_kg, s.piece_length_m, s.is_verified into z
    from public.sizes s where s.id = p_size_id;
  if not found then
    raise exception 'A rate per % needs a size', p_unit;
  end if;
  if not z.is_verified then
    raise exception '%', format('%s has no verified weight, so its rate cannot be shown per %s', z.display_name, p_unit);
  end if;
  return case p_unit when 'metre' then z.weight_per_metre_kg
                     else z.weight_per_metre_kg * z.piece_length_m end;
end;
$$;

-- A rate (or any amount per unit) converted from one unit to another,
-- through weight. Exact: never rounded here. Rounding happens once, when
-- the figure is shown.
create function public.convert_rate(p_amount numeric, p_from public.unit, p_to public.unit, p_size_id uuid default null)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case
    when p_amount is null then null
    when p_from = p_to then p_amount
    else p_amount * public.kg_per_unit(p_to, p_size_id) / public.kg_per_unit(p_from, p_size_id)
  end;
$$;

revoke execute on function public.format_rupees(numeric) from public, anon;
revoke execute on function public.kg_per_unit(public.unit, uuid) from public, anon;
revoke execute on function public.convert_rate(numeric, public.unit, public.unit, uuid) from public, anon;
grant execute on function public.format_rupees(numeric) to authenticated;
grant execute on function public.kg_per_unit(public.unit, uuid) to authenticated;
grant execute on function public.convert_rate(numeric, public.unit, public.unit, uuid) to authenticated;
