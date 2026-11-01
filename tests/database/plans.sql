-- ============================================================
-- Checks: plans, seller plans and reach (plans, seller_plans,
-- seller_plan_at, seller_reach, switch_on_plan, end_plan_early).
-- Covers: one free plan, seeded with the stated limits and no price; only
-- admins add or change plans and switch them on; a seller sees only his own
-- plan; plans cannot overlap; ending early is the only change; nothing is
-- deleted; reach: a free retailer's own taluka, a paid plan's district, the
-- free plan again after a lapse; other roles are not reach-limited; a
-- retailer at a city with no taluka above it.
--
-- Test people (temporary logins, rolled back):
--   T ...a1  retailer at Check Karad City (in Check Karad taluka, Satara)
--   U ...a2  retailer at Check Lonar City (a city directly under Satara)
--   W ...a3  wholesaler (approved) at Satara
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a3', '919800000003', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000033', 'authenticated', 'authenticated');
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad', 'taluka', id, true from regions where level = 'district' and name = 'Satara';
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad City', 'city', id, true from regions where name = 'Check Karad';
insert into regions (name, level, parent_id, is_approved)
select 'Check Lonar City', 'city', id, true from regions where level = 'district' and name = 'Satara';

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Tara', '+919800000001', 'retailer', 'Check Karad City'),
               ('00000000-0000-0000-0000-0000000000a2', 'Usha', '+919800000002', 'retailer', 'Check Lonar City'),
               ('00000000-0000-0000-0000-0000000000a3', 'Wagh', '+919800000003', 'wholesaler', 'Satara')) as x (id, name, phone, role, place)
  join regions r on r.name = x.place and r.level in ('district', 'city');
insert into seller_profiles (account_id, store_name, region_id, is_public)
select a.id, a.full_name || ' Steel', a.region_id, true from accounts a where a.id::text like '00000000-0000-0000-0000-%';

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_role_request(id, true) from role_requests where status = 'requested';
select pg_temp.as_owner();

create function pg_temp.reach(p_seller uuid) returns text language sql as $$
  select case when r.is_limited then 'limited to ' || r.reach_area_name else 'not limited' end || ', home ' || r.home_area_name
         || ', plan ' || (select name from plans where id = r.plan_id)
    from seller_reach(p_seller) r
$$;

-- Structure ----------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on', 'plans=true, seller_plans=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where oid in ('public.plans'::regclass, 'public.seller_plans'::regclass)$q$);
select pg_temp.expect_value('One free plan, with the stated limits', 'Free: taluka, 30 customers, 10 outside buyers',
  $q$select name || ': ' || reach_level || ', ' || customer_limit || ' customers, ' || outside_buyer_limit || ' outside buyers'
     from plans where is_free$q$);
select pg_temp.expect_value('Plans hold no price, cost or commission', 'none',
  $q$select coalesce(string_agg(column_name, ', '), 'none') from information_schema.columns
     where table_schema = 'public' and table_name in ('plans', 'seller_plans')
       and (column_name ~ 'price|cost|amount|fee|commission|rate')$q$);

-- Reach on the free plan -------------------------------------------------------------

select pg_temp.expect_value('A free retailer reaches his own taluka', 'limited to Check Karad, home Check Karad, plan Free',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('A retailer at a city with no taluka above it reaches only his city', 'limited to Check Lonar City, home Check Lonar City, plan Free',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.expect_value('A wholesaler is not reach-limited', 'not limited, home Satara, plan Free',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a3')$q$);

-- Who can do what ---------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('A logged-in user can see the plans', 1, $q$select * from plans$q$);
select pg_temp.expect_refused('A user cannot add a plan',
  $q$insert into plans (name, reach_level) values ('Mine', 'state')$q$);
select pg_temp.expect_rows('A user cannot change the free plan''s limits', 0,
  $q$update plans set customer_limit = 9999 where is_free$q$);
select pg_temp.expect_message('A user cannot switch a plan on', 'Only ALEE can switch plans on.',
  $q$select switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans where is_free), now(), now() + interval '1 day')$q$);
select pg_temp.expect_refused('A user cannot record a plan directly',
  $q$insert into seller_plans (seller_id, plan_id, starts_at, ends_at, switched_on_by)
     select '00000000-0000-0000-0000-0000000000a1', id, now(), now() + interval '1 year', '00000000-0000-0000-0000-0000000000a1' from plans where is_free$q$);
select pg_temp.expect_refused('A user cannot read a seller''s reach through the lookup',
  $q$select * from seller_reach('00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('A visitor sees no plans', $q$select * from plans$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('An admin adds a paid plan reaching the district', 1,
  $q$insert into plans (name, reach_level, customer_limit, outside_buyer_limit) values ('Check District', 'district', 100, 50)$q$);
select pg_temp.expect_rows('An admin changes a limit (limits are settings)', 1,
  $q$update plans set customer_limit = 120 where name = 'Check District'$q$);
select pg_temp.expect_refused('The free plan cannot be switched off', $q$update plans set is_active = false where is_free$q$);
select pg_temp.expect_refused('A plan reaching only a city is refused',
  $q$insert into plans (name, reach_level) values ('Check City', 'city')$q$);
select pg_temp.expect_message('The free plan is not switched on for anyone', 'Choose an active paid plan.',
  $q$select switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans where is_free), now(), now() + interval '1 day')$q$);
create temp table sp as
select switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans where name = 'Check District'),
                      now() - interval '1 day', now() + interval '30 days') as id;
grant select on sp to public;
select pg_temp.expect_message('Two plans cannot overlap', 'This seller already has a plan during those dates.',
  $q$select switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans where name = 'Check District'),
                           now() + interval '10 days', now() + interval '60 days')$q$);

select pg_temp.as_owner();
select pg_temp.expect_value('A paid plan widens reach to his district', 'limited to Satara, home Check Karad, plan Check District',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('The plan in effect is read at a moment: before it started, the free plan', 'Free',
  $q$select name from seller_plan_at('00000000-0000-0000-0000-0000000000a1', now() - interval '2 days')$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('The seller sees his own plan', 1, $q$select * from seller_plans$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('Another seller sees none of it', 0, $q$select * from seller_plans$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('An admin ends the plan early', 1, $q$select end_plan_early((select id from sp))$q$);
select pg_temp.expect_message('...only once', 'That plan has already ended.', $q$select end_plan_early((select id from sp))$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('After the plan ends, reach returns to his taluka', 'limited to Check Karad, home Check Karad, plan Free',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('...and the plan record is kept', '1 record, ended early',
  $q$select count(*) || ' record, ended early' from seller_plans where ended_early_at is not null$q$);

-- Never changed, never deleted ---------------------------------------------------------

select pg_temp.expect_refused('Not even the database owner can change a plan record''s dates',
  $q$update seller_plans set ends_at = ends_at + interval '1 year'$q$);
select pg_temp.expect_refused('Not even the database owner can delete a plan record', $q$delete from seller_plans$q$);
select pg_temp.expect_refused('Not even the database owner can delete a plan', $q$delete from plans where name = 'Check District'$q$);
