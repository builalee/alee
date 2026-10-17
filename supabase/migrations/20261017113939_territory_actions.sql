-- ============================================================
-- OBJECTIVE:      Add the only ways a territory allocation changes: the
--                 manufacturer offers it (and may change its type while it
--                 is still an offer, or withdraw it); the distributor
--                 accepts or declines; either side ends it. Admins can do
--                 any of these, recorded as admin. Every step is recorded in
--                 the history.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.33 to
--                 2.36).
-- CHANGES:        New functions public.offer_territory(...),
--                 public.change_territory_type(...),
--                 public.respond_to_territory(...), public.end_territory(...).
-- DEPENDS ON:     20261017113839_create_territory_allocations.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the four functions.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/territory.sql (77).
--                 Only the manufacturer offers or changes, only the
--                 distributor accepts or declines, either ends; admins any,
--                 recorded as admin. Type changes only while an offer. A
--                 second distributor for the same area and family refused
--                 with a plain message; re-offering after a decline or an
--                 ending works.
-- DATE:           2026-10-17
-- ============================================================

create function public.territory_record(
  p_allocation_id  uuid,
  p_event          public.territory_event,
  p_type           public.territory_type,
  p_on_behalf_of   uuid
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.territory_allocation_events (allocation_id, event, allocation_type, done_by, by_admin)
  values (p_allocation_id, p_event, p_type, auth.uid(), auth.uid() is distinct from p_on_behalf_of);
$$;

revoke execute on function public.territory_record(uuid, public.territory_event, public.territory_type, uuid)
  from public, anon, authenticated;

-- The manufacturer offers an area, for one product family, to a
-- distributor. It has no effect until the distributor accepts.
create function public.offer_territory(
  p_distributor_id   uuid,
  p_segment_id       uuid,
  p_region_id        uuid,
  p_type             public.territory_type,
  p_manufacturer_id  uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_maker   uuid := coalesce(p_manufacturer_id, auth.uid());
  v_id      uuid;
  v_holder  text;
  v_area    text;
  v_family  text;
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if v_maker is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the manufacturer can offer his territory' using errcode = '42501';
  end if;
  if p_type is null then
    raise exception 'Choose who sets the price in this area: the distributor, or you.';
  end if;
  if v_maker = p_distributor_id then
    raise exception 'You cannot allocate an area to yourself.';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = p_distributor_id) then
    raise exception 'That distributor is not a seller on ALEE.';
  end if;

  select s.name into v_family from public.segments s where s.id = p_segment_id;
  if not exists (
    select 1 from public.seller_segments ss
     where ss.seller_id = v_maker and ss.segment_id = p_segment_id and ss.is_active
  ) then
    raise exception 'You don''t sell % yet, so you cannot allocate it.', coalesce(v_family, 'this product family');
  end if;

  select r.name into v_area from public.regions r
   where r.id = p_region_id and r.is_active and r.is_approved;
  if v_area is null then
    raise exception 'That area is not available.';
  end if;

  select sp.store_name into v_holder
    from public.territory_allocations a
    join public.seller_profiles sp on sp.account_id = a.distributor_id
   where a.manufacturer_id = v_maker and a.segment_id = p_segment_id and a.region_id = p_region_id
     and a.status in ('offered', 'active');
  if v_holder is not null then
    raise exception '% % is already offered to or held by %. End that first.', v_area, v_family, v_holder;
  end if;

  insert into public.territory_allocations (manufacturer_id, distributor_id, segment_id, region_id, allocation_type)
  values (v_maker, p_distributor_id, p_segment_id, p_region_id, p_type)
  returning id into v_id;

  perform public.territory_record(v_id, 'offered', p_type, v_maker);
  return v_id;
end;
$$;

-- The manufacturer changes the type while it is still an offer. Once
-- accepted, the type is fixed: end it and offer again.
create function public.change_territory_type(
  p_allocation_id  uuid,
  p_type           public.territory_type
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.territory_allocations%rowtype;
begin
  select * into a from public.territory_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'Allocation not found';
  end if;
  if a.manufacturer_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the manufacturer can change an allocation' using errcode = '42501';
  end if;
  if a.status <> 'offered' then
    raise exception 'Only an offer can be changed. To change an accepted allocation, end it and offer a new one.';
  end if;
  if a.allocation_type = p_type then
    return;
  end if;

  update public.territory_allocations set allocation_type = p_type where id = p_allocation_id;
  perform public.territory_record(p_allocation_id, 'type_changed', p_type, a.manufacturer_id);
end;
$$;

-- The distributor accepts (true) or declines (false) an offer.
create function public.respond_to_territory(
  p_allocation_id  uuid,
  p_accept         boolean
)
returns public.territory_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.territory_allocations%rowtype;
begin
  select * into a from public.territory_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'Allocation not found';
  end if;
  if a.distributor_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the distributor can accept or decline an offer' using errcode = '42501';
  end if;
  if a.status <> 'offered' then
    raise exception 'This is no longer an open offer.';
  end if;
  if p_accept is null then
    raise exception 'Say whether you accept (true) or decline (false).';
  end if;

  if p_accept then
    update public.territory_allocations set status = 'active', accepted_at = clock_timestamp()
     where id = p_allocation_id;
    perform public.territory_record(p_allocation_id, 'accepted', a.allocation_type, a.distributor_id);
    return 'active';
  else
    update public.territory_allocations set status = 'declined', closed_at = clock_timestamp()
     where id = p_allocation_id;
    perform public.territory_record(p_allocation_id, 'declined', a.allocation_type, a.distributor_id);
    return 'declined';
  end if;
end;
$$;

-- Either side ends an active allocation. The manufacturer can also
-- withdraw an offer not yet accepted. The manufacturer's own rate then
-- shows again in that area, if he serves it.
create function public.end_territory(p_allocation_id uuid)
returns public.territory_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.territory_allocations%rowtype;
begin
  select * into a from public.territory_allocations where id = p_allocation_id for update;
  if not found then
    raise exception 'Allocation not found';
  end if;
  if auth.uid() is distinct from a.manufacturer_id and auth.uid() is distinct from a.distributor_id
     and not public.is_admin() then
    raise exception 'Only the manufacturer or the distributor can end an allocation' using errcode = '42501';
  end if;

  if a.status = 'active' then
    update public.territory_allocations set status = 'ended', closed_at = clock_timestamp()
     where id = p_allocation_id;
    perform public.territory_record(p_allocation_id, 'ended', a.allocation_type,
      case when auth.uid() = a.distributor_id then a.distributor_id else a.manufacturer_id end);
    return 'ended';
  elsif a.status = 'offered' then
    if auth.uid() = a.distributor_id then
      raise exception 'To turn down an offer, decline it.';
    end if;
    update public.territory_allocations set status = 'withdrawn', closed_at = clock_timestamp()
     where id = p_allocation_id;
    perform public.territory_record(p_allocation_id, 'withdrawn', a.allocation_type, a.manufacturer_id);
    return 'withdrawn';
  else
    raise exception 'This allocation has already finished (%).', a.status;
  end if;
end;
$$;

revoke execute on function public.offer_territory(uuid, uuid, uuid, public.territory_type, uuid) from public, anon;
revoke execute on function public.change_territory_type(uuid, public.territory_type) from public, anon;
revoke execute on function public.respond_to_territory(uuid, boolean) from public, anon;
revoke execute on function public.end_territory(uuid) from public, anon;
grant execute on function public.offer_territory(uuid, uuid, uuid, public.territory_type, uuid) to authenticated;
grant execute on function public.change_territory_type(uuid, public.territory_type) to authenticated;
grant execute on function public.respond_to_territory(uuid, boolean) to authenticated;
grant execute on function public.end_territory(uuid) to authenticated;
