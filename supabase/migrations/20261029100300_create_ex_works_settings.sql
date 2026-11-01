-- ============================================================
-- OBJECTIVE:      Let a seller switch his ex-works rate on or off and name
--                 his plant city. Off unless he switches it on. Every
--                 change is kept, so what buyers were shown at any moment
--                 can be rebuilt.
-- WHY:            Owner decision 2026-10-29 (docs/decisions.md 12.2): the
--                 ex-works rate is off by default; manufacturers,
--                 distributors and wholesalers can switch it on; paid
--                 retailers can, but it shows only inside their paid reach;
--                 free retailers don't have it. The plant city defaults to
--                 his profile location.
-- CHANGES:        New table public.seller_ex_works_versions. New functions
--                 public.set_ex_works, public.ex_works_at.
-- DEPENDS ON:     20261029100100_create_plans (seller_reach).
-- TOUCHES EXISTING DATA: No. No seller has a row, so ex-works is off for
--                 everyone.
-- REVERSIBLE:     Yes, by dropping the functions and table. The history of
--                 the setting would be lost.
-- TESTED:         On alee-dev 2026-10-29: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/ex_works.sql.
-- DATE:           2026-10-29
-- ============================================================

-- Each change of the setting is a new row; the latest row at a moment is
-- the setting at that moment. No row = off.
create table public.seller_ex_works_versions (
  id               uuid primary key default gen_random_uuid(),
  seller_id        uuid not null references public.accounts (id) on delete cascade,
  is_on            boolean not null,
  plant_region_id  uuid not null references public.regions (id),
  set_at           timestamptz not null default clock_timestamp(),
  set_by           uuid not null references auth.users (id),
  by_admin         boolean not null
);

create index seller_ex_works_by_seller on public.seller_ex_works_versions (seller_id, set_at desc);

create trigger seller_ex_works_prevent_update
  before update on public.seller_ex_works_versions
  for each row execute function public.prevent_update();
create trigger seller_ex_works_prevent_delete
  before delete on public.seller_ex_works_versions
  for each row execute function public.prevent_direct_delete();

-- The setting in force at a moment (now if not given). Off when never set.
create function public.ex_works_at(p_seller_id uuid, p_at timestamptz default null)
returns table (is_on boolean, plant_region_id uuid, plant_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(v.is_on, false), v.plant_region_id, r.name
    from (select 1) one
    left join lateral (
      select x.is_on, x.plant_region_id from public.seller_ex_works_versions x
       where x.seller_id = p_seller_id and x.set_at <= coalesce(p_at, clock_timestamp())
       order by x.set_at desc limit 1) v on true
    left join public.regions r on r.id = v.plant_region_id;
$$;

-- Switch ex-works on or off, and optionally name the plant city. With no
-- plant city named, the last one is kept, or his profile location is used.
-- A seller acts for himself; an admin may act for a seller.
create function public.set_ex_works(p_on boolean, p_plant_region_id uuid default null, p_seller_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller uuid := coalesce(p_seller_id, auth.uid());
  v_plant  uuid;
  v_reach  record;
begin
  if v_seller <> auth.uid() and not public.is_admin() then
    raise exception 'You can only change your own ex-works setting.';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = v_seller) then
    raise exception 'Set up your seller profile first.';
  end if;

  if p_on then
    select * into v_reach from public.seller_reach(v_seller);
    if v_reach.is_limited and v_reach.plan_is_free then
      raise exception 'Ex-works rates come with a paid plan. Contact ALEE to upgrade.';
    end if;
  end if;

  v_plant := coalesce(
    p_plant_region_id,
    (select x.plant_region_id from public.seller_ex_works_versions x
      where x.seller_id = v_seller order by x.set_at desc limit 1),
    (select sp.region_id from public.seller_profiles sp where sp.account_id = v_seller));
  if not exists (select 1 from public.regions r where r.id = v_plant and r.is_active and r.is_approved) then
    raise exception 'Choose your plant city from the list of places.';
  end if;

  insert into public.seller_ex_works_versions (seller_id, is_on, plant_region_id, set_by, by_admin)
  values (v_seller, p_on, v_plant, auth.uid(), v_seller <> auth.uid());
end;
$$;

-- Access ---------------------------------------------------------------------

alter table public.seller_ex_works_versions enable row level security;

create policy "Sellers see their own ex-works setting; admins see all"
  on public.seller_ex_works_versions for select to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

grant select on public.seller_ex_works_versions to authenticated;

revoke execute on function public.ex_works_at(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.set_ex_works(boolean, uuid, uuid) from public, anon;
grant execute on function public.set_ex_works(boolean, uuid, uuid) to authenticated;
