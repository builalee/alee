-- ============================================================
-- OBJECTIVE:      Ex-works is switched on per state, only within the
--                 seller's reach, and his plant city is kept separately.
--                 Every change is kept. Replaces the single on/off switch.
-- WHY:            Owner decision 2026-11-01 (docs/decisions.md 14.2), which
--                 replaces every earlier ex-works visibility rule: off by
--                 default; switched on per state within reach; shown only
--                 in areas he has not set up.
-- CHANGES:        New tables public.seller_plant_cities and
--                 public.seller_ex_works_states. New functions
--                 public.set_plant_city, public.set_ex_works (new
--                 arguments), public.ex_works_for. Dropped: the table
--                 public.seller_ex_works_versions and its functions
--                 set_ex_works(boolean, uuid, uuid) and ex_works_at.
-- DEPENDS ON:     20261101100100_reach_for_every_role (seller_reach),
--                 20261029100300_create_ex_works_settings.
-- TOUCHES EXISTING DATA: Yes: drops public.seller_ex_works_versions. It has
--                 no rows on alee-dev and never reached live; this
--                 migration refuses to run if it holds any row, so no
--                 setting can be lost.
-- REVERSIBLE:     Yes, by recreating the old table and functions from
--                 20261029100300 (it was empty). The new history would be
--                 lost.
-- TESTED:         On alee-dev 2026-11-01: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/ex_works.sql.
-- DATE:           2026-11-01
-- ============================================================

do $$
begin
  if exists (select 1 from public.seller_ex_works_versions) then
    raise exception 'seller_ex_works_versions holds settings; move them before dropping it';
  end if;
end;
$$;

drop function public.set_ex_works(boolean, uuid, uuid);
drop function public.ex_works_at(uuid, timestamptz);
drop table public.seller_ex_works_versions;

-- His plant city: each change is a new row. No row = his profile location.
create table public.seller_plant_cities (
  id               uuid primary key default gen_random_uuid(),
  seller_id        uuid not null references public.accounts (id) on delete cascade,
  plant_region_id  uuid not null references public.regions (id),
  set_at           timestamptz not null default clock_timestamp(),
  set_by           uuid not null,
  by_admin         boolean not null
);
create index seller_plant_cities_by_seller on public.seller_plant_cities (seller_id, set_at desc);

-- Ex-works on or off in one state: each change is a new row. No row = off.
create table public.seller_ex_works_states (
  id         uuid primary key default gen_random_uuid(),
  seller_id  uuid not null references public.accounts (id) on delete cascade,
  state_id   uuid not null references public.regions (id),
  is_on      boolean not null,
  set_at     timestamptz not null default clock_timestamp(),
  set_by     uuid not null,
  by_admin   boolean not null
);
create index seller_ex_works_states_by_seller on public.seller_ex_works_states (seller_id, state_id, set_at desc);

create trigger seller_plant_cities_prevent_update before update on public.seller_plant_cities
  for each row execute function public.prevent_update();
create trigger seller_plant_cities_prevent_delete before delete on public.seller_plant_cities
  for each row execute function public.prevent_direct_delete();
create trigger seller_ex_works_states_prevent_update before update on public.seller_ex_works_states
  for each row execute function public.prevent_update();
create trigger seller_ex_works_states_prevent_delete before delete on public.seller_ex_works_states
  for each row execute function public.prevent_direct_delete();

-- For a buyer's area: is ex-works on in its state, and where is the plant?
create function public.ex_works_for(p_seller_id uuid, p_region_id uuid)
returns table (is_on boolean, state_id uuid, plant_region_id uuid, plant_name text)
language sql
stable
security definer
set search_path = ''
as $$
  with recursive chain as (
    select r.id, r.parent_id, r.level from public.regions r where r.id = p_region_id
    union all
    select p.id, p.parent_id, p.level from chain c join public.regions p on p.id = c.parent_id
  ),
  st as (select c.id from chain c where c.level = 'state' limit 1),
  plant as (
    select coalesce(
      (select pc.plant_region_id from public.seller_plant_cities pc
        where pc.seller_id = p_seller_id order by pc.set_at desc limit 1),
      (select sp.region_id from public.seller_profiles sp where sp.account_id = p_seller_id)) as id
  )
  select coalesce((select x.is_on from public.seller_ex_works_states x
                    where x.seller_id = p_seller_id and x.state_id = (select id from st)
                    order by x.set_at desc limit 1), false),
         (select id from st),
         (select id from plant),
         (select r.name from public.regions r where r.id = (select id from plant));
$$;

create function public.set_plant_city(p_plant_region_id uuid, p_seller_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller uuid := coalesce(p_seller_id, auth.uid());
begin
  if v_seller <> auth.uid() and not public.is_admin() then
    raise exception 'You can only change your own plant city.';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = v_seller) then
    raise exception 'Set up your seller profile first.';
  end if;
  if not exists (select 1 from public.regions r where r.id = p_plant_region_id and r.is_active and r.is_approved) then
    raise exception 'Choose your plant city from the list of places.';
  end if;
  insert into public.seller_plant_cities (seller_id, plant_region_id, set_by, by_admin)
  values (v_seller, p_plant_region_id, auth.uid(), v_seller <> auth.uid());
end;
$$;

-- Switch ex-works on or off in one state. On only where his reach touches
-- that state; buyers outside his reach never see it anyway.
create function public.set_ex_works(p_state_id uuid, p_on boolean, p_seller_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller uuid := coalesce(p_seller_id, auth.uid());
begin
  if v_seller <> auth.uid() and not public.is_admin() then
    raise exception 'You can only change your own ex-works setting.';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = v_seller) then
    raise exception 'Set up your seller profile first.';
  end if;
  if not exists (select 1 from public.regions r where r.id = p_state_id and r.level = 'state') then
    raise exception 'Ex-works is switched on for a whole state.';
  end if;
  if p_on and not exists (
       select 1 from public.seller_reach(v_seller) sr, unnest(sr.reach_region_ids) a
        where public.region_within(a, p_state_id) or public.region_within(p_state_id, a)) then
    raise exception 'Ex-works can be switched on only where you reach. Upgrade to reach more areas.';
  end if;
  insert into public.seller_ex_works_states (seller_id, state_id, is_on, set_by, by_admin)
  values (v_seller, p_state_id, p_on, auth.uid(), v_seller <> auth.uid());
end;
$$;

-- Access ---------------------------------------------------------------------

alter table public.seller_plant_cities enable row level security;
alter table public.seller_ex_works_states enable row level security;

create policy "Sellers see their own plant city; admins see all"
  on public.seller_plant_cities for select to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));
create policy "Sellers see their own ex-works switches; admins see all"
  on public.seller_ex_works_states for select to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

grant select on public.seller_plant_cities, public.seller_ex_works_states to authenticated;

revoke execute on function public.ex_works_for(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.set_plant_city(uuid, uuid) from public, anon;
revoke execute on function public.set_ex_works(uuid, boolean, uuid) from public, anon;
grant execute on function public.set_plant_city(uuid, uuid) to authenticated;
grant execute on function public.set_ex_works(uuid, boolean, uuid) to authenticated;
