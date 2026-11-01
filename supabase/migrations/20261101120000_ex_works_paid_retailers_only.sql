-- ============================================================
-- OBJECTIVE:      Free retailers don't have ex-works. A retailer can switch
--                 it on only while he has a paid reach plan, and only for
--                 his own state; it shows only inside his paid reach. If his
--                 plan lapses, his switch stays saved but stops applying.
-- WHY:            Owner decision (docs/decisions.md 12.2, confirmed
--                 2026-11-01 in 14.2): the per-state ex-works rule did not
--                 change this. 20261101100300 let any seller switch it on,
--                 which was wrong for free retailers.
-- CHANGES:        Replaced: public.set_ex_works (refuses a free retailer,
--                 and a retailer outside his own state),
--                 public.ex_works_for (off for a retailer without a paid
--                 reach plan, whatever his saved switch says).
-- DEPENDS ON:     20261101100300_ex_works_per_state,
--                 20261101100100_reach_for_every_role.
-- TOUCHES EXISTING DATA: No. Saved switches are kept as they are.
-- REVERSIBLE:     Yes, by recreating both functions from 20261101100300.
-- TESTED:         On alee-dev 2026-11-01: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/ex_works.sql and
--                 tests/database/rate_engine.sql.
-- DATE:           2026-11-01
-- ============================================================

-- A retailer has ex-works only while a paid reach plan is in force.
create or replace function public.ex_works_for(p_seller_id uuid, p_region_id uuid)
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
                    order by x.set_at desc limit 1), false)
         and (public.approved_role(p_seller_id) <> 'retailer'
              or exists (select 1 from public.seller_plan_at(p_seller_id, 'reach'))),
         (select id from st),
         (select id from plant),
         (select r.name from public.regions r where r.id = (select id from plant));
$$;

create or replace function public.set_ex_works(p_state_id uuid, p_on boolean, p_seller_id uuid default null)
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
  if p_on and public.approved_role(v_seller) = 'retailer' then
    if not exists (select 1 from public.seller_plan_at(v_seller, 'reach')) then
      raise exception 'Ex-works rates come with a paid plan. Contact ALEE to upgrade.';
    end if;
    if not exists (select 1 from public.seller_profiles sp
                    where sp.account_id = v_seller and public.region_within(sp.region_id, p_state_id)) then
      raise exception 'As a retailer you can switch ex-works on only in your own state.';
    end if;
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
