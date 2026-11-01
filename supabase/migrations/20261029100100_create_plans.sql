-- ============================================================
-- OBJECTIVE:      Store plans and their limits as data admins set, record
--                 which plan each seller is on (with start, end and
--                 history), and give one lookup for a seller's reach: where
--                 buyers may see his rates.
-- WHY:            Owner decisions 2026-10-29 (docs/decisions.md 10.1-10.5):
--                 plans and limits are data, never hardcoded; a free
--                 retailer's rates reach his own taluka; paid plans widen
--                 that to his district or state; a lapsed plan returns to
--                 free without deleting anything. Prices and plan costs are
--                 never stored here.
-- CHANGES:        New tables public.plans, public.seller_plans. One free
--                 plan seeded (reach: taluka; customers 30; outside buyers
--                 10). New functions public.region_within,
--                 public.seller_plan_at, public.seller_reach,
--                 public.switch_on_plan, public.end_plan_early.
-- DEPENDS ON:     20261029100000_create_role_requests (approved_role),
--                 20261017050059_create_seller_profiles.
-- TOUCHES EXISTING DATA: No (new tables; one plan row seeded).
-- REVERSIBLE:     Yes, by dropping the functions and tables. Plan history
--                 would be lost.
-- TESTED:         On alee-dev 2026-10-29: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/plans.sql.
-- DATE:           2026-10-29
-- ============================================================

-- Plans: names and limits only. Limits are settings admins change. No
-- price, cost or commission is ever stored.
create table public.plans (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null unique check (btrim(name) <> ''),
  is_free              boolean not null default false,
  -- How far a retailer's rates reach from his profile location.
  reach_level          public.region_level not null check (reach_level in ('taluka', 'district', 'state')),
  -- Empty = no limit.
  customer_limit       integer check (customer_limit >= 0),
  outside_buyer_limit  integer check (outside_buyer_limit >= 0),
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

-- Exactly one free plan: what every seller is on when no paid plan applies.
create unique index plans_one_free on public.plans (is_free) where is_free;

create trigger plans_set_updated_at
  before update on public.plans
  for each row execute function public.set_updated_at();

create function public.plans_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_free <> old.is_free then
    raise exception 'The free plan stays the free plan';
  end if;
  if new.is_free and not new.is_active then
    raise exception 'The free plan cannot be switched off';
  end if;
  return new;
end;
$$;

create trigger plans_before_update
  before update on public.plans
  for each row execute function public.plans_before_update();

create trigger plans_prevent_delete
  before delete on public.plans
  for each row execute function public.prevent_delete();

insert into public.plans (name, is_free, reach_level, customer_limit, outside_buyer_limit)
values ('Free', true, 'taluka', 30, 10);

-- Which paid plan a seller is on, from when to when. The free plan is
-- never recorded: it is what applies when no paid plan does. Rows are
-- never changed, except that a plan can be ended early, once.
create table public.seller_plans (
  id               uuid primary key default gen_random_uuid(),
  seller_id        uuid not null references public.accounts (id) on delete cascade,
  plan_id          uuid not null references public.plans (id),
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  switched_on_by   uuid not null references auth.users (id),
  switched_on_at   timestamptz not null default clock_timestamp(),
  ended_early_at   timestamptz,
  ended_early_by   uuid references auth.users (id),
  check (ends_at > starts_at),
  check ((ended_early_at is null) = (ended_early_by is null))
);

create index seller_plans_by_seller on public.seller_plans (seller_id, starts_at desc);

create function public.seller_plans_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.ended_early_at is not null or new.ended_early_at is null
     or (new.id, new.seller_id, new.plan_id, new.starts_at, new.ends_at, new.switched_on_by, new.switched_on_at)
        is distinct from
        (old.id, old.seller_id, old.plan_id, old.starts_at, old.ends_at, old.switched_on_by, old.switched_on_at) then
    raise exception 'A seller''s plan record is never changed; it can only be ended early, once';
  end if;
  return new;
end;
$$;

create trigger seller_plans_before_update
  before update on public.seller_plans
  for each row execute function public.seller_plans_before_update();

create trigger seller_plans_prevent_delete
  before delete on public.seller_plans
  for each row execute function public.prevent_direct_delete();

-- Lookups --------------------------------------------------------------------

-- Is a region the area itself or inside it? An empty area means
-- "everywhere", which contains every region.
create function public.region_within(p_region_id uuid, p_area_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  with recursive chain as (
    select r.id, r.parent_id from public.regions r where r.id = p_region_id
    union all
    select p.id, p.parent_id from chain c join public.regions p on p.id = c.parent_id
  )
  select p_area_id is null or exists (select 1 from chain c where c.id = p_area_id);
$$;

-- The plan in effect for a seller at a moment: the paid plan running then,
-- otherwise the free plan.
create function public.seller_plan_at(p_seller_id uuid, p_at timestamptz default null)
returns setof public.plans
language sql
stable
security definer
set search_path = ''
as $$
  select pl.* from public.plans pl
   where pl.id = coalesce(
     (select sp.plan_id from public.seller_plans sp
       where sp.seller_id = p_seller_id
         and sp.starts_at <= coalesce(p_at, clock_timestamp())
         and coalesce(p_at, clock_timestamp()) < least(sp.ends_at, coalesce(sp.ended_early_at, 'infinity'))
       order by sp.starts_at desc limit 1),
     (select f.id from public.plans f where f.is_free));
$$;

-- A seller's reach at a moment.
--   is_limited:  only retailers are reach-limited.
--   home_*:      his own area, the taluka of his profile location (his
--                location itself if it has no taluka above it). An approved
--                outside buyer sees the rate for this area.
--   reach_*:     the area his plan reaches: his taluka, district or state.
create function public.seller_reach(p_seller_id uuid, p_at timestamptz default null)
returns table (
  is_limited       boolean,
  home_region_id   uuid,
  home_area_name   text,
  reach_region_id  uuid,
  reach_area_name  text,
  plan_id          uuid,
  plan_is_free     boolean,
  outside_buyer_limit integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with recursive pl as (
    select * from public.seller_plan_at(p_seller_id, p_at)
  ),
  chain as (
    select r.id, r.parent_id, r.name, r.level, 1 as depth
      from public.seller_profiles sp join public.regions r on r.id = sp.region_id
     where sp.account_id = p_seller_id
    union all
    select p.id, p.parent_id, p.name, p.level, c.depth + 1
      from chain c join public.regions p on p.id = c.parent_id
  ),
  own as (select c.id, c.name from chain c where c.depth = 1),
  home as (select c.id, c.name from chain c where c.level = 'taluka' order by c.depth limit 1),
  reach as (select c.id, c.name from chain c where c.level = (select pl.reach_level from pl) order by c.depth limit 1)
  select public.approved_role(p_seller_id) = 'retailer',
         coalesce((select id from home), (select id from own)),
         coalesce((select name from home), (select name from own)),
         coalesce((select id from reach), (select id from own)),
         coalesce((select name from reach), (select name from own)),
         (select pl.id from pl), (select pl.is_free from pl), (select pl.outside_buyer_limit from pl);
$$;

-- Actions (admins only in Phase 1: payment is made outside the app) ----------

create function public.switch_on_plan(p_seller_id uuid, p_plan_id uuid, p_starts_at timestamptz, p_ends_at timestamptz)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Only ALEE can switch plans on.';
  end if;
  if not exists (select 1 from public.plans pl where pl.id = p_plan_id and pl.is_active and not pl.is_free) then
    raise exception 'Choose an active paid plan.';
  end if;
  if p_ends_at <= p_starts_at then
    raise exception 'A plan must end after it starts.';
  end if;
  if exists (select 1 from public.seller_plans sp
              where sp.seller_id = p_seller_id
                and sp.starts_at < p_ends_at
                and p_starts_at < least(sp.ends_at, coalesce(sp.ended_early_at, 'infinity'))) then
    raise exception 'This seller already has a plan during those dates.';
  end if;
  insert into public.seller_plans (seller_id, plan_id, starts_at, ends_at, switched_on_by)
  values (p_seller_id, p_plan_id, p_starts_at, p_ends_at, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create function public.end_plan_early(p_seller_plan_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only ALEE can end a plan.';
  end if;
  update public.seller_plans
     set ended_early_at = greatest(clock_timestamp(), starts_at), ended_early_by = auth.uid()
   where id = p_seller_plan_id and ended_early_at is null and ends_at > clock_timestamp();
  if not found then
    raise exception 'That plan has already ended.';
  end if;
end;
$$;

-- Access ---------------------------------------------------------------------

alter table public.plans enable row level security;
alter table public.seller_plans enable row level security;

create policy "Logged-in users see plans"
  on public.plans for select to authenticated using (true);
create policy "Admins add plans"
  on public.plans for insert to authenticated with check ((select public.is_admin()));
create policy "Admins change plans"
  on public.plans for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "Sellers see their own plans; admins see all"
  on public.seller_plans for select to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

grant select, insert, update on public.plans to authenticated;
grant select on public.seller_plans to authenticated;

revoke execute on function public.region_within(uuid, uuid) from public, anon;
grant execute on function public.region_within(uuid, uuid) to authenticated;
revoke execute on function public.seller_plan_at(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.seller_reach(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.switch_on_plan(uuid, uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function public.end_plan_early(uuid) from public, anon;
grant execute on function public.switch_on_plan(uuid, uuid, timestamptz, timestamptz) to authenticated;
grant execute on function public.end_plan_early(uuid) to authenticated;
