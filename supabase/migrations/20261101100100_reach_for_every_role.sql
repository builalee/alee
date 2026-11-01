-- ============================================================
-- OBJECTIVE:      Every seller has a reach, not only retailers. Free reach
--                 follows his role (retailer: his taluka; wholesaler and
--                 distributor: his district; manufacturer: his state), read
--                 from settings. Paid reach plans widen it to a larger level
--                 and/or add named states. Client-book plans are a separate
--                 kind, independent of reach; a seller can hold either,
--                 both or neither.
-- WHY:            Owner decisions 2026-11-01 (docs/decisions.md 14.1, 14.4).
-- CHANGES:        New enum public.plan_kind. public.plans: new columns kind,
--                 extra_states; reach_level may be empty. New table
--                 public.seller_plan_areas (the states a plan adds). The
--                 old free plan row is switched off: free limits now live
--                 in settings. Replaced: seller_plan_at (now per kind),
--                 switch_on_plan (now names extra states), seller_reach
--                 (now for every role, several areas), plans_before_update,
--                 request_rates, decide_rate_request. New:
--                 public.within_reach, public.client_book_limit.
-- DEPENDS ON:     20261101100000_create_settings,
--                 20261029100100_create_plans,
--                 20261029100200_create_rate_requests.
-- TOUCHES EXISTING DATA: Yes, one row: the plan named "Free" is switched off
--                 and renamed "Free (replaced by settings)". It was never
--                 recorded against any seller. No seller plan changes.
-- REVERSIBLE:     Partly: the old functions can be recreated from
--                 20261029100100 and the Free row switched back on. Named
--                 extra states would be lost.
-- TESTED:         On alee-dev 2026-11-01: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/plans.sql and
--                 tests/database/rate_requests.sql.
-- DATE:           2026-11-01
-- ============================================================

create type public.plan_kind as enum ('reach', 'client_book');

alter table public.plans
  add column kind public.plan_kind not null default 'reach',
  -- How many states, beyond his own reach, the admin names when switching
  -- this plan on. Empty = none.
  add column extra_states integer check (extra_states > 0),
  alter column reach_level drop not null,
  add constraint plans_client_book_has_no_reach
    check (kind <> 'client_book' or (reach_level is null and extra_states is null and outside_buyer_limit is null));

-- The free plan row is no longer what applies by default: free limits are
-- settings, per role. Plans can now be switched off, the free flag still
-- never changes.
create or replace function public.plans_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_free <> old.is_free or new.kind <> old.kind then
    raise exception 'A plan''s kind never changes';
  end if;
  return new;
end;
$$;

update public.plans set is_active = false, name = 'Free (replaced by settings)' where is_free;

-- The states a reach plan adds, named by the admin when switching it on.
create table public.seller_plan_areas (
  seller_plan_id  uuid not null references public.seller_plans (id) on delete cascade,
  region_id       uuid not null references public.regions (id),
  primary key (seller_plan_id, region_id)
);

create function public.seller_plan_areas_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.regions r where r.id = new.region_id and r.level = 'state') then
    raise exception 'A plan adds whole states';
  end if;
  return new;
end;
$$;

create trigger seller_plan_areas_before_insert
  before insert on public.seller_plan_areas
  for each row execute function public.seller_plan_areas_before_insert();
create trigger seller_plan_areas_prevent_update
  before update on public.seller_plan_areas
  for each row execute function public.prevent_update();
create trigger seller_plan_areas_prevent_delete
  before delete on public.seller_plan_areas
  for each row execute function public.prevent_direct_delete();

-- The paid plan of one kind in effect for a seller now, if any.
drop function public.seller_plan_at(uuid, timestamptz);
create function public.seller_plan_at(p_seller_id uuid, p_kind public.plan_kind, p_at timestamptz default null)
returns table (seller_plan_id uuid, plan_id uuid, plan_name text, reach_level public.region_level,
               customer_limit integer, outside_buyer_limit integer)
language sql
stable
security definer
set search_path = ''
as $$
  select sp.id, pl.id, pl.name, pl.reach_level, pl.customer_limit, pl.outside_buyer_limit
    from public.seller_plans sp join public.plans pl on pl.id = sp.plan_id
   where sp.seller_id = p_seller_id and pl.kind = p_kind
     and sp.starts_at <= coalesce(p_at, clock_timestamp())
     and coalesce(p_at, clock_timestamp()) < least(sp.ends_at, coalesce(sp.ended_early_at, 'infinity'))
   order by sp.starts_at desc limit 1;
$$;

-- A seller's reach now.
--   home_*:   his own area at his role's free level (a retailer's taluka, a
--             wholesaler's district, a manufacturer's state); his location
--             itself if it has no area at that level above it. An approved
--             outside buyer sees the rate for this area.
--   reach_*:  every area buyers may see his rates in: his own area at the
--             wider of the free level and his reach plan's level, plus any
--             states the plan adds.
drop function public.seller_reach(uuid, timestamptz);
create function public.seller_reach(p_seller_id uuid)
returns table (
  home_region_id       uuid,
  home_area_name       text,
  reach_region_ids     uuid[],
  reach_area_names     text,
  reach_plan_id        uuid,
  outside_buyer_limit  integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_free   public.region_level;
  v_level  public.region_level;
  v_plan   record;
  v_home   text[];
  v_main   text[];
  v_ids    uuid[];
  v_names  text[];
begin
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = p_seller_id) then
    return;
  end if;
  v_free := public.setting_text('free_reach_' || public.approved_role(p_seller_id))::public.region_level;
  select * into v_plan from public.seller_plan_at(p_seller_id, 'reach');
  v_level := case when v_plan.reach_level is not null
                   and array_position(array['taluka', 'district', 'state']::text[], v_plan.reach_level::text)
                     > array_position(array['taluka', 'district', 'state']::text[], v_free::text)
                  then v_plan.reach_level else v_free end;

  with recursive chain as (
    select r.id, r.parent_id, r.name, r.level, 1 as depth
      from public.seller_profiles sp join public.regions r on r.id = sp.region_id
     where sp.account_id = p_seller_id
    union all
    select p.id, p.parent_id, p.name, p.level, c.depth + 1
      from chain c join public.regions p on p.id = c.parent_id
  )
  select coalesce((select array[c.id::text, c.name] from chain c where c.level = v_free order by c.depth limit 1),
                  (select array[c.id::text, c.name] from chain c where c.depth = 1)),
         coalesce((select array[c.id::text, c.name] from chain c where c.level = v_level order by c.depth limit 1),
                  (select array[c.id::text, c.name] from chain c where c.depth = 1))
    into v_home, v_main;

  v_ids := array[v_main[1]::uuid];
  v_names := array[v_main[2]];
  select v_ids || coalesce(array_agg(r.id order by r.name), '{}'),
         v_names || coalesce(array_agg(r.name order by r.name), '{}')
    into v_ids, v_names
    from public.seller_plan_areas a join public.regions r on r.id = a.region_id
   where a.seller_plan_id = v_plan.seller_plan_id and r.id <> v_main[1]::uuid;

  return query select
    v_home[1]::uuid, v_home[2],
    v_ids,
    case when cardinality(v_names) = 1 then v_names[1]
         else array_to_string(v_names[1:cardinality(v_names) - 1], ', ') || ' and ' || v_names[cardinality(v_names)] end,
    v_plan.plan_id,
    case when v_plan.plan_id is not null then v_plan.outside_buyer_limit
         else public.setting_int('free_outside_buyer_limit') end;
end;
$$;

-- Is a buyer's area inside a seller's reach?
create function public.within_reach(p_seller_id uuid, p_region_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select bool_or(public.region_within(p_region_id, a))
                     from public.seller_reach(p_seller_id) sr, unnest(sr.reach_region_ids) a), false);
$$;

-- How many customers his client book may hold: his client-book plan's
-- limit, otherwise the free limit. Empty = no limit.
create function public.client_book_limit(p_seller_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case when cb.plan_id is not null then cb.customer_limit
              else public.setting_int('free_customer_limit') end
    from (select 1) one
    left join public.seller_plan_at(p_seller_id, 'client_book') cb on true;
$$;

-- Admins switch a plan on, naming the states a reach plan adds.
drop function public.switch_on_plan(uuid, uuid, timestamptz, timestamptz);
create function public.switch_on_plan(
  p_seller_id     uuid,
  p_plan_id       uuid,
  p_starts_at     timestamptz,
  p_ends_at       timestamptz,
  p_extra_states  uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan record;
  v_id   uuid;
begin
  if not public.is_admin() then
    raise exception 'Only ALEE can switch plans on.';
  end if;
  select * into v_plan from public.plans pl where pl.id = p_plan_id and pl.is_active and not pl.is_free;
  if not found then
    raise exception 'Choose an active paid plan.';
  end if;
  if p_ends_at <= p_starts_at then
    raise exception 'A plan must end after it starts.';
  end if;
  if cardinality(coalesce(p_extra_states, '{}')) > coalesce(v_plan.extra_states, 0) then
    raise exception '%', format('%s adds up to %s extra states.', v_plan.name, coalesce(v_plan.extra_states, 0));
  end if;
  if exists (select 1 from public.seller_plans sp join public.plans pl on pl.id = sp.plan_id
              where sp.seller_id = p_seller_id and pl.kind = v_plan.kind
                and sp.starts_at < p_ends_at
                and p_starts_at < least(sp.ends_at, coalesce(sp.ended_early_at, 'infinity'))) then
    raise exception 'This seller already has a plan of this kind during those dates.';
  end if;
  insert into public.seller_plans (seller_id, plan_id, starts_at, ends_at, switched_on_by)
  values (p_seller_id, p_plan_id, p_starts_at, p_ends_at, auth.uid())
  returning id into v_id;
  insert into public.seller_plan_areas (seller_plan_id, region_id)
  select v_id, x from unnest(coalesce(p_extra_states, '{}')) x;
  return v_id;
end;
$$;

-- Outside-buyer requests now apply to every seller, since every seller has
-- a reach.
create or replace function public.request_rates(p_seller_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_region uuid;
  v_id     uuid;
begin
  select a.region_id into v_region from public.accounts a where a.id = auth.uid();
  if v_region is null then
    raise exception 'Create your account first.';
  end if;
  if p_seller_id = auth.uid() then
    raise exception 'These are your own rates.';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = p_seller_id) then
    raise exception 'That seller was not found.';
  end if;
  if public.within_reach(p_seller_id, v_region) then
    raise exception 'You can already see this seller''s rates for your area.';
  end if;
  if exists (select 1 from public.rate_requests rr where rr.seller_id = p_seller_id and rr.buyer_id = auth.uid()
               and rr.status in ('requested', 'approved')) then
    raise exception 'You have already asked this seller for his rates.';
  end if;
  insert into public.rate_requests (seller_id, buyer_id) values (p_seller_id, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.decide_rate_request(p_request_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_limit integer;
begin
  select * into r from public.rate_requests rr where rr.id = p_request_id for update;
  if not found or (r.seller_id <> auth.uid() and not public.is_admin()) then
    raise exception 'That request was not found.';
  end if;
  if r.status <> 'requested' then
    raise exception 'That request is not waiting for a decision.';
  end if;
  if p_approve then
    select sr.outside_buyer_limit into v_limit from public.seller_reach(r.seller_id) sr;
    if v_limit is not null and (select count(*) from public.rate_requests x
                                 where x.seller_id = r.seller_id and x.status = 'approved') >= v_limit then
      raise exception '%', format('You can approve up to %s outside buyers on your plan. Upgrade to approve more.', v_limit);
    end if;
  end if;
  update public.rate_requests
     set status = case when p_approve then 'approved'::public.rate_request_status else 'declined' end,
         decided_at = clock_timestamp()
   where id = p_request_id;
end;
$$;

-- Access ---------------------------------------------------------------------

alter table public.seller_plan_areas enable row level security;

create policy "Sellers see the states their own plans add; admins see all"
  on public.seller_plan_areas for select to authenticated
  using (exists (select 1 from public.seller_plans sp where sp.id = seller_plan_id
                  and (sp.seller_id = (select auth.uid()) or (select public.is_admin()))));

grant select on public.seller_plan_areas to authenticated;

revoke execute on function public.seller_plan_at(uuid, public.plan_kind, timestamptz) from public, anon, authenticated;
revoke execute on function public.seller_reach(uuid) from public, anon, authenticated;
revoke execute on function public.within_reach(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.client_book_limit(uuid) from public, anon, authenticated;
revoke execute on function public.switch_on_plan(uuid, uuid, timestamptz, timestamptz, uuid[]) from public, anon;
grant execute on function public.switch_on_plan(uuid, uuid, timestamptz, timestamptz, uuid[]) to authenticated;
