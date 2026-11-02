-- ============================================================
-- OBJECTIVE:      Only ALEE-approved distributors can be appointed, and only
--                 approved manufacturers can claim a brand. An appointment
--                 counts for buyers only while its distributor is approved.
--                 If his approval is removed or refused, his appointments
--                 end at once and the manufacturer's own rate shows again.
-- WHY:            Owner decision 2026-11-02 (docs/decisions.md 16.9): the
--                 owner's test showed a manufacturer could appoint a
--                 distributor ALEE had not approved, and buyers would have
--                 been pointed to him.
-- CHANGES:        New functions public.allocation_holder_approved,
--                 public.appointable_distributors,
--                 public.close_unapproved_appointments and its two triggers.
--                 Changed public.offer_territory, public.respond_to_territory,
--                 public.claim_brand, public.resolve_territory.
-- DEPENDS ON:     20261102100000_role_removals.
--                 20261017130818_territory_per_brand.
--                 20261017123656_create_brand_ownership.
-- TOUCHES EXISTING DATA: No. On alee-dev the one appointment's distributor is
--                 approved, so it keeps counting. LIVE WARNING: anywhere an
--                 appointment's distributor isn't approved, it stops counting
--                 for buyers the moment this runs.
-- REVERSIBLE:     Yes: restore the four functions from the migrations named
--                 above and drop the new ones. Appointments already ended
--                 stay ended, and are not revived.
-- TESTED:         On alee-dev 2026-11-02: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass, including
--                 tests/database/territory.sql, rate_engine.sql and
--                 brand_ownership.sql.
-- DATE:           2026-11-02
-- ============================================================

-- Whether an allocation's distributor is approved now. Takes an allocation,
-- not a person, so nobody can use it to look up an account's role. Public,
-- because anyone can run the territory lookup below.
create function public.allocation_holder_approved(p_allocation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.territory_allocations a
     where a.id = p_allocation_id and public.holds_role(a.distributor_id, 'distributor'));
$$;

revoke execute on function public.allocation_holder_approved(uuid) from public;
grant execute on function public.allocation_holder_approved(uuid) to anon, authenticated;

-- The allocation in effect closest to the buyer. One held by a distributor
-- who isn't approved doesn't count, so the next closer one, or the
-- manufacturer's own settings, decide instead.
create or replace function public.resolve_territory(
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_region_id   uuid
)
returns table (
  allocation_id     uuid,
  distributor_id    uuid,
  distributor_name  text,
  allocation_type   public.territory_type,
  region_id         uuid,
  area_name         text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive chain as (
    select r.id, r.parent_id, 1 as depth
      from public.regions r where r.id = p_region_id
    union all
    select p.id, p.parent_id, c.depth + 1
      from chain c join public.regions p on p.id = c.parent_id
  )
  select a.id, a.distributor_id, sp.store_name, a.allocation_type, a.region_id, r.name
    from chain c
    join public.territory_allocations a
      on a.region_id = c.id
     and a.brand_id = p_brand_id
     and a.segment_id = p_segment_id
     and a.status = 'active'
     and public.allocation_holder_approved(a.id)
    join public.brands b on b.id = a.brand_id and b.owner_id = a.manufacturer_id
    join public.seller_profiles sp on sp.account_id = a.distributor_id
    join public.regions r on r.id = a.region_id
   order by c.depth
   limit 1;
$$;

-- The brand's owner offers an area, for one family the brand covers, to an
-- approved distributor. It has no effect until the distributor accepts. An
-- admin may offer on the owner's behalf.
create or replace function public.offer_territory(
  p_brand_id         uuid,
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
  b         public.brands%rowtype;
  v_id      uuid;
  v_holder  text;
  v_area    text;
  v_label   text;
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if v_maker is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the manufacturer can offer his territory' using errcode = '42501';
  end if;
  select * into b from public.brands where id = p_brand_id;
  if not found or b.owner_id is distinct from v_maker then
    raise exception 'You don''t own %, so you cannot allocate it.', coalesce(b.name, 'that brand');
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
  if not public.holds_role(p_distributor_id, 'distributor') then
    raise exception 'ALEE has not approved this seller as a distributor.';
  end if;
  if not public.brand_covers_family(p_brand_id, p_segment_id) then
    raise exception '% is not listed for %.', b.name,
      coalesce((select s.name from public.segments s where s.id = p_segment_id), 'that product family');
  end if;

  select r.name into v_area from public.regions r
   where r.id = p_region_id and r.is_active and r.is_approved;
  if v_area is null then
    raise exception 'That area is not available.';
  end if;

  v_label := public.brand_line_label(p_brand_id, p_segment_id);
  select sp.store_name into v_holder
    from public.territory_allocations a
    join public.seller_profiles sp on sp.account_id = a.distributor_id
   where a.brand_id = p_brand_id and a.segment_id = p_segment_id and a.region_id = p_region_id
     and a.status in ('offered', 'active');
  if v_holder is not null then
    raise exception '% % is already offered to or held by %. End that first.', v_area, v_label, v_holder;
  end if;

  insert into public.territory_allocations (manufacturer_id, distributor_id, brand_id, segment_id, region_id, allocation_type)
  values (v_maker, p_distributor_id, p_brand_id, p_segment_id, p_region_id, p_type)
  returning id into v_id;

  perform public.territory_record(v_id, 'offered', p_type, v_maker);
  return v_id;
end;
$$;

-- The distributor accepts (true) or declines (false) an offer. Only an
-- approved distributor can accept.
create or replace function public.respond_to_territory(
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
    if not public.holds_role(a.distributor_id, 'distributor') then
      raise exception 'ALEE must approve you as a distributor before you can accept.';
    end if;
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

-- A manufacturer claims to own an approved brand. It waits for an admin.
create or replace function public.claim_brand(p_brand_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  b     public.brands%rowtype;
  v_id  uuid;
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = auth.uid()) then
    raise exception 'Only a manufacturer selling on ALEE can claim a brand.';
  end if;
  if not public.holds_role(auth.uid(), 'manufacturer') then
    raise exception 'ALEE must approve you as a manufacturer before you can claim a brand.';
  end if;

  select * into b from public.brands where id = p_brand_id;
  if not found or b.status <> 'approved' or not b.is_active then
    raise exception 'That brand is not available to claim.';
  end if;
  if b.is_regular then
    raise exception 'Regular is not a brand anyone can own.';
  end if;
  if b.owner_id = auth.uid() then
    raise exception 'You already own %.', b.name;
  end if;
  if b.owner_id is not null then
    raise exception '% already has an owner. If you believe it is yours, contact ALEE.', b.name;
  end if;
  if exists (select 1 from public.brand_claims c
              where c.brand_id = p_brand_id and c.manufacturer_id = auth.uid() and c.status = 'claimed') then
    raise exception 'You have already claimed %; an admin will check it.', b.name;
  end if;

  insert into public.brand_claims (brand_id, manufacturer_id)
  values (p_brand_id, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- The appointment list: approved distributors with a seller profile, for a
-- brand owner or an admin. Everyone else gets nothing.
create function public.appointable_distributors()
returns table (account_id uuid, store_name text, region_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select sp.account_id, sp.store_name, sp.region_id
    from public.seller_profiles sp
   where sp.account_id is distinct from auth.uid()
     and public.holds_role(sp.account_id, 'distributor')
     and (public.is_admin() or exists (select 1 from public.brands b where b.owner_id = auth.uid()))
   order by sp.store_name;
$$;

revoke execute on function public.appointable_distributors() from public, anon;
grant execute on function public.appointable_distributors() to authenticated;

-- Ending an account's appointments once it is no longer an approved
-- distributor. The records stay, each step is in the history as an admin's,
-- and approving him again later doesn't bring them back: the manufacturer
-- offers afresh.
create function public.close_unapproved_appointments(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.territory_allocations%rowtype;
begin
  if public.holds_role(p_account_id, 'distributor') then
    return;
  end if;
  for a in
    select * from public.territory_allocations t
     where t.distributor_id = p_account_id and t.status in ('offered', 'active')
       for update
  loop
    if a.status = 'active' then
      update public.territory_allocations set status = 'ended', closed_at = clock_timestamp() where id = a.id;
      perform public.territory_record(a.id, 'ended', a.allocation_type, a.manufacturer_id);
    else
      update public.territory_allocations set status = 'withdrawn', closed_at = clock_timestamp() where id = a.id;
      perform public.territory_record(a.id, 'withdrawn', a.allocation_type, a.manufacturer_id);
    end if;
  end loop;
end;
$$;

create function public.role_removal_closes_appointments()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.close_unapproved_appointments(
    (select rr.account_id from public.role_requests rr
      where rr.id = new.request_id and rr.requested_role = 'distributor'));
  return null;
end;
$$;

create trigger role_removals_close_appointments
  after insert on public.role_removals
  for each row execute function public.role_removal_closes_appointments();

create function public.role_refusal_closes_appointments()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.close_unapproved_appointments(new.account_id);
  return null;
end;
$$;

create trigger role_requests_refusal_closes_appointments
  after update of status on public.role_requests
  for each row
  when (new.status = 'refused' and new.requested_role = 'distributor')
  execute function public.role_refusal_closes_appointments();

revoke execute on function public.close_unapproved_appointments(uuid) from public, anon, authenticated;
revoke execute on function public.role_removal_closes_appointments() from public, anon, authenticated;
revoke execute on function public.role_refusal_closes_appointments() from public, anon, authenticated;
