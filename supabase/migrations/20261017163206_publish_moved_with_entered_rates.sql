-- ============================================================
-- OBJECTIVE:      "Move everything" never silently skips a brand line. The
--                 pre-fill list says, for each line, whether it will be
--                 moved, needs a rate entered (no rate yet, or its family's
--                 unit changed), or is not quoting. The move publish accepts
--                 the entered rates alongside the moved ones, in the same
--                 single publish, and refuses if a line that needs a rate
--                 has none.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.42 as
--                 updated): lines with no rate yet, and families needing a
--                 fresh rate after a unit change, must be listed with a place
--                 to enter the rate, so they go out in the same publish - one
--                 publish, one notification. Paused lines are listed as "not
--                 quoting" and left untouched.
-- CHANGES:        public.publish_prefill(...) recreated with a new column
--                 move_status.
--                 public.publish_moved(...) recreated with a new last
--                 argument p_entered (rates typed in for lines that need
--                 one).
-- DEPENDS ON:     20261017131337_publish_moved.
--                 20261017131658_brands_required.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by restoring both functions from 20261017131337.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/publish_moved.sql (28).
--                 Pre-fill marks each line move / needs_rate / unit_changed /
--                 not_quoting; a line needing a rate is never skipped: the
--                 move is refused naming it until its rate is entered; moved
--                 and entered rates go out in one publish; paused lines left
--                 untouched and cannot be given a rate; fresh per-kg rates
--                 after a unit change go out with the moved family.
-- DATE:           2026-10-17
-- ============================================================

drop function public.publish_moved(jsonb, uuid);
drop function public.publish_prefill(uuid);

-- Every brand line the seller sells, for the publish screen:
--   move_status  'move'         last rate known, same unit: moved by the
--                               family's amount
--                'needs_rate'   no rate yet: the seller enters today's rate
--                'unit_changed' his unit for the family changed since the
--                               last publish: he enters today's rate
--                'not_quoting'  paused: listed, left untouched
create function public.publish_prefill(p_seller_id uuid default null)
returns table (
  brand_id          uuid,
  segment_id        uuid,
  line_name         text,
  last_base_rate    numeric,
  last_unit         public.unit,
  current_unit      public.unit,
  is_quoting        boolean,
  last_published_at timestamptz,
  move_status       text
)
language sql
stable
security invoker
set search_path = ''
as $$
  select sb.brand_id, sb.segment_id,
         public.brand_display_name(sb.brand_id, sb.segment_id),
         pi.base_rate::numeric, pi.unit, ss.base_unit,
         coalesce(st.is_quoting, true), st.last_published_at,
         case
           when not coalesce(st.is_quoting, true) then 'not_quoting'
           when pi.base_rate is null then 'needs_rate'
           when pi.unit is distinct from ss.base_unit then 'unit_changed'
           else 'move'
         end
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

-- One publish for the named families: every 'move' line at its last rate
-- plus the family's amount, and every 'needs_rate' / 'unit_changed' line at
-- the rate entered for it. p_moves: [{"segment_id", "amount"}], one amount
-- per family. p_entered: [{"segment_id", "brand_id", "base_rate"}].
-- 'not_quoting' lines are left untouched. Refused, in plain words, if a
-- named family has a line needing a rate that was not entered (never a
-- silent skip), if a rate is entered for a paused line or for a line being
-- moved, if a family has nothing at all, or if a move takes a rate to zero
-- or below.
create function public.publish_moved(
  p_moves      jsonb,
  p_seller_id  uuid default null,
  p_entered    jsonb default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_seller   uuid := coalesce(p_seller_id, auth.uid());
  v_entered  jsonb := coalesce(p_entered, '[]'::jsonb);
  m          jsonb;
  e          jsonb;
  k          text;
  v_seg      uuid;
  v_amount   numeric;
  v_family   text;
  ln         record;
  v_items    jsonb := '[]'::jsonb;
  v_lines    integer;
  v_missing  text;
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
  if jsonb_typeof(v_entered) <> 'array' then
    raise exception 'Entered rates must be a list.';
  end if;
  if (select count(*) from jsonb_array_elements(p_moves) x)
     <> (select count(distinct x ->> 'segment_id') from jsonb_array_elements(p_moves) x) then
    raise exception 'Give one amount per product family.';
  end if;

  -- Entered rates: only for lines that need one.
  for e in select * from jsonb_array_elements(v_entered) loop
    for k in select jsonb_object_keys(e) loop
      if k not in ('segment_id', 'brand_id', 'base_rate') then
        raise exception 'Unknown field "%"', k;
      end if;
    end loop;
    select p.line_name, p.move_status into ln
      from public.publish_prefill(v_seller) p
     where p.segment_id = (e ->> 'segment_id')::uuid and p.brand_id = (e ->> 'brand_id')::uuid;
    if ln.move_status = 'not_quoting' then
      raise exception '% is not quoting today. Switch it back on first, or leave it out.', ln.line_name;
    end if;
    if ln.move_status = 'move' then
      raise exception '% is already being moved; enter a rate only for lines that need one.', ln.line_name;
    end if;
  end loop;

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

    select count(*) into v_lines from public.publish_prefill(v_seller) p where p.segment_id = v_seg;
    if v_lines = 0 then
      raise exception 'There is nothing in % to move: add a brand to it first.', coalesce(v_family, 'that family');
    end if;

    -- Never a silent skip: every line needing a rate must have one entered.
    select string_agg(p.line_name, ', ' order by p.line_name) into v_missing
      from public.publish_prefill(v_seller) p
     where p.segment_id = v_seg and p.move_status in ('needs_rate', 'unit_changed')
       and not exists (select 1 from jsonb_array_elements(v_entered) x
                        where (x ->> 'segment_id')::uuid = p.segment_id and (x ->> 'brand_id')::uuid = p.brand_id);
    if v_missing is not null then
      raise exception 'Enter today''s rate for % before publishing.', v_missing;
    end if;

    for ln in
      select p.brand_id, p.line_name, p.last_base_rate
        from public.publish_prefill(v_seller) p
       where p.segment_id = v_seg and p.move_status = 'move'
    loop
      if ln.last_base_rate + v_amount <= 0 then
        raise exception 'Moving % by % would take % to zero or below.', v_family, v_amount, ln.line_name;
      end if;
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'segment_id', v_seg, 'brand_id', ln.brand_id, 'base_rate', ln.last_base_rate + v_amount));
    end loop;
  end loop;

  -- Entered rates go into the same publish.
  v_items := v_items || v_entered;
  if jsonb_array_length(v_items) = 0 then
    raise exception 'Nothing to publish: every line in these families is not quoting.';
  end if;

  return public.publish_rates(v_items, false, null, v_seller);
end;
$$;

comment on function public.publish_moved(jsonb, uuid, jsonb) is
  'Four-tap publishing: moved lines plus rates entered for lines that need one, as one publish. Never skips a line silently.';

revoke execute on function public.publish_moved(jsonb, uuid, jsonb) from public, anon;
grant execute on function public.publish_moved(jsonb, uuid, jsonb) to authenticated;
