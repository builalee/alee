-- ============================================================
-- OBJECTIVE:      Support four-tap publishing: a pre-fill list of every
--                 brand line with its last published rate, and one action
--                 that publishes them all moved by one amount per product
--                 family (+ or -), as one publish.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.42):
--                 publishing stays four taps; all brands pre-filled from
--                 yesterday; "move everything by +/- Rs X" is one amount per
--                 product family, never across families (families may be
--                 priced in different units); one publish, one notification.
-- CHANGES:        New functions public.publish_prefill(...) and
--                 public.publish_moved(...).
-- DEPENDS ON:     20261017125428_publishing_per_brand.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping both functions.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/publish_moved.sql (22).
--                 Pre-fill lists every brand line with its last rate; TMT
--                 +200 per tonne and Channels +0.5 per kg in one publish;
--                 never-published and not-quoting lines left out; a move of
--                 0 republishes; plain refusals for nothing to move, unit
--                 changed, zero or below, two amounts per family; admin
--                 moves recorded as admin.
-- DATE:           2026-10-17
-- ============================================================

-- Every brand line the seller sells, with its last published basic rate
-- and unit (empty if never published), whether it is quoting, and his
-- current unit for the family. For the publish screen's pre-fill. Runs with
-- the caller's rights: a seller sees his own; an admin any.
create function public.publish_prefill(p_seller_id uuid default null)
returns table (
  brand_id        uuid,
  segment_id      uuid,
  line_name       text,
  last_base_rate  numeric,
  last_unit       public.unit,
  current_unit    public.unit,
  is_quoting      boolean,
  last_published_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
  select sb.brand_id, sb.segment_id,
         public.brand_display_name(sb.brand_id, sb.segment_id),
         pi.base_rate::numeric, pi.unit, ss.base_unit,
         coalesce(st.is_quoting, true), st.last_published_at
    from public.seller_brands sb
    join public.seller_segments ss on ss.seller_id = sb.seller_id and ss.segment_id = sb.segment_id and ss.is_active
    left join public.seller_family_status st
      on st.seller_id = sb.seller_id and st.brand_id = sb.brand_id and st.segment_id = sb.segment_id
    left join public.publish_items pi
      on pi.publish_id = st.latest_publish_id and pi.brand_id = sb.brand_id and pi.segment_id = sb.segment_id
   where sb.seller_id = coalesce(p_seller_id, auth.uid()) and sb.is_active
   order by sb.segment_id, public.brand_display_name(sb.brand_id, sb.segment_id);
$$;

revoke execute on function public.publish_prefill(uuid) from public, anon;
grant execute on function public.publish_prefill(uuid) to authenticated;

-- Publishes every brand line of the named families at its last basic rate
-- moved by that family's amount, as ONE publish. p_moves:
-- [{"segment_id": "...", "amount": 200}, {"segment_id": "...", "amount": -0.5}]
-- (each amount in that family's unit; 0 republishes unchanged).
-- Left out: brand lines never published (nothing to move from) and brand
-- lines switched to "not quoting" (moving them would switch them back on).
-- Refused, in plain words: a family with nothing to move, a family whose
-- unit changed since its last publish, and a move taking a rate to zero or
-- below. Returns the publish.
create function public.publish_moved(
  p_moves      jsonb,
  p_seller_id  uuid default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_seller  uuid := coalesce(p_seller_id, auth.uid());
  m         jsonb;
  k         text;
  v_seg     uuid;
  v_amount  numeric;
  v_family  text;
  ln        record;
  v_items   jsonb := '[]'::jsonb;
  v_count   integer;
begin
  if v_seller is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if v_seller is distinct from auth.uid() and not public.is_admin() then
    raise exception 'You can only publish your own rates' using errcode = '42501';
  end if;
  if p_moves is null or jsonb_typeof(p_moves) <> 'array' or jsonb_array_length(p_moves) = 0 then
    raise exception 'Choose at least one product family to move.';
  end if;
  if (select count(*) from jsonb_array_elements(p_moves) e)
     <> (select count(distinct e ->> 'segment_id') from jsonb_array_elements(p_moves) e) then
    raise exception 'Give one amount per product family.';
  end if;

  for m in select * from jsonb_array_elements(p_moves) loop
    for k in select jsonb_object_keys(m) loop
      if k not in ('segment_id', 'amount') then
        raise exception 'Unknown field "%"', k;
      end if;
    end loop;
    v_seg := (m ->> 'segment_id')::uuid;
    select s.name into v_family from public.segments s where s.id = v_seg;
    if coalesce(jsonb_typeof(m -> 'amount'), 'null') <> 'number' then
      raise exception 'Enter the amount to move % by (0 to keep it unchanged).', coalesce(v_family, 'this family');
    end if;
    v_amount := (m ->> 'amount')::numeric;
    v_count := 0;

    for ln in
      select p.brand_id, p.line_name, p.last_base_rate, p.last_unit, p.current_unit
        from public.publish_prefill(v_seller) p
       where p.segment_id = v_seg and p.is_quoting and p.last_base_rate is not null
    loop
      if ln.last_unit is distinct from ln.current_unit then
        raise exception 'You now price % per % but last published it per %. Enter today''s rates instead.',
          v_family, ln.current_unit, ln.last_unit;
      end if;
      if ln.last_base_rate + v_amount <= 0 then
        raise exception 'Moving % by % would take % to zero or below.', v_family, v_amount, ln.line_name;
      end if;
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'segment_id', v_seg, 'brand_id', ln.brand_id, 'base_rate', ln.last_base_rate + v_amount));
      v_count := v_count + 1;
    end loop;

    if v_count = 0 then
      raise exception 'There is nothing in % to move: publish its rates first.', coalesce(v_family, 'that family');
    end if;
  end loop;

  return public.publish_rates(v_items, false, null, v_seller);
end;
$$;

comment on function public.publish_moved(jsonb, uuid) is
  'Four-tap publishing: every quoting brand line of the named families at its last rate moved by one amount per family, as one publish.';

revoke execute on function public.publish_moved(jsonb, uuid) from public, anon;
grant execute on function public.publish_moved(jsonb, uuid) to authenticated;
