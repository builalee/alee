-- ============================================================
-- Checks: plans and reach (plans, seller_plans, seller_plan_areas,
-- seller_plan_at, seller_reach, within_reach, client_book_limit,
-- switch_on_plan, end_plan_early).
-- Covers: free reach for every role, from settings (retailer: taluka;
-- wholesaler and distributor: district; manufacturer: state); a higher role
-- not yet approved reaches like a retailer; a city with no taluka above it;
-- a paid reach plan widening reach and adding named states, up to its
-- number; client-book plans separate from reach plans, and a seller holding
-- both; the free client book limit (20) from settings; plans hold no price;
-- only admins add, change and switch on plans; a seller sees only his own;
-- ending early; nothing deleted.
--
-- Test people (temporary logins, rolled back):
--   T ...a1  retailer at Check Karad City (in Check Karad taluka, Satara)
--   U ...a2  retailer at Check Lonar City (a city directly under Satara)
--   W ...a3  wholesaler (approved) at Satara
--   D ...a4  distributor (approved) at Check Karad City
--   M ...a5  manufacturer (approved) at Pune
--   N ...a6  asked to be a manufacturer, not yet approved, at Pune
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role)
select x.id::uuid, x.phone, 'authenticated', 'authenticated'
  from (values ('00000000-0000-0000-0000-0000000000a1', '919800000001'), ('00000000-0000-0000-0000-0000000000a2', '919800000002'),
               ('00000000-0000-0000-0000-0000000000a3', '919800000003'), ('00000000-0000-0000-0000-0000000000a4', '919800000004'),
               ('00000000-0000-0000-0000-0000000000a5', '919800000005'), ('00000000-0000-0000-0000-0000000000a6', '919800000006'),
               ('00000000-0000-0000-0000-0000000000c3', '919800000033')) as x (id, phone);
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad', 'taluka', id, true from regions where level = 'district' and name = 'Satara';
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad City', 'city', id, true from regions where name = 'Check Karad';
insert into regions (name, level, parent_id, is_approved)
select 'Check Lonar City', 'city', id, true from regions where level = 'district' and name = 'Satara';

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, '+' || u.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Tara', 'retailer', 'Check Karad City'),
               ('00000000-0000-0000-0000-0000000000a2', 'Usha', 'retailer', 'Check Lonar City'),
               ('00000000-0000-0000-0000-0000000000a3', 'Wagh', 'wholesaler', 'Satara'),
               ('00000000-0000-0000-0000-0000000000a4', 'Dev', 'distributor', 'Check Karad City'),
               ('00000000-0000-0000-0000-0000000000a5', 'Mahesh', 'manufacturer', 'Pune'),
               ('00000000-0000-0000-0000-0000000000a6', 'Nitin', 'manufacturer', 'Pune')) as x (id, name, role, place)
  join auth.users u on u.id = x.id::uuid
  join regions r on r.name = x.place and r.level in ('district', 'city');
insert into seller_profiles (account_id, store_name, region_id, is_public)
select a.id, a.full_name || ' Steel', a.region_id, true from accounts a where a.id::text like '00000000-0000-0000-0000-%';

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_role_request(id, true) from role_requests
 where status = 'requested' and account_id <> '00000000-0000-0000-0000-0000000000a6';
select pg_temp.as_owner();

create temp table k as
select (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'state' and name = 'Goa') as goa,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from regions where level = 'district' and name = 'Kolhapur') as kolhapur,
       (select id from regions where level = 'district' and name = 'North Goa') as north_goa;
grant select on k to public;

create function pg_temp.reach(p_seller uuid) returns text language sql as $$
  select 'reaches ' || r.reach_area_names || ', home ' || r.home_area_name
         || ', plan ' || coalesce((select name from plans where id = r.reach_plan_id), 'free')
         || ', outside buyers ' || coalesce(r.outside_buyer_limit::text, 'no limit')
    from seller_reach(p_seller) r
$$;

-- Structure ----------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on', 'plans=true, seller_plan_areas=true, seller_plans=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where oid in ('public.plans'::regclass, 'public.seller_plans'::regclass, 'public.seller_plan_areas'::regclass)$q$);
select pg_temp.expect_value('Plans hold no price, cost or commission', 'none',
  $q$select coalesce(string_agg(column_name, ', '), 'none') from information_schema.columns
     where table_schema = 'public' and table_name in ('plans', 'seller_plans', 'seller_plan_areas', 'settings')
       and (column_name ~ 'price|cost|amount|fee|commission|rate')$q$);
select pg_temp.expect_value('The old free plan row is switched off: free limits are settings now', 'Free (replaced by settings): off',
  $q$select name || ': ' || case when is_active then 'on' else 'off' end from plans where is_free$q$);

-- Free reach for every role --------------------------------------------------------------

select pg_temp.expect_value('A retailer reaches his own taluka', 'reaches Check Karad, home Check Karad, plan free, outside buyers 10',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('A retailer at a city with no taluka above it reaches his city', 'reaches Check Lonar City, home Check Lonar City, plan free, outside buyers 10',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.expect_value('A wholesaler reaches his own district', 'reaches Satara, home Satara, plan free, outside buyers 10',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a3')$q$);
select pg_temp.expect_value('A distributor reaches his own district (from a city in it)', 'reaches Satara, home Satara, plan free, outside buyers 10',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a4')$q$);
select pg_temp.expect_value('A manufacturer reaches his own state', 'reaches Maharashtra, home Maharashtra, plan free, outside buyers 10',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a5')$q$);
select pg_temp.expect_value('A manufacturer not yet approved reaches like a retailer (Pune has no taluka here, so Pune)',
  'reaches Pune, home Pune, plan free, outside buyers 10',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a6')$q$);
select pg_temp.expect_value('Inside and outside reach', 'Satara city inside the wholesaler''s reach: true, Kolhapur: false',
  $q$select 'Satara city inside the wholesaler''s reach: ' || within_reach('00000000-0000-0000-0000-0000000000a3',
              (select id from regions where name = 'Check Lonar City'))
         || ', Kolhapur: ' || within_reach('00000000-0000-0000-0000-0000000000a3', (select kolhapur from k))$q$);
select pg_temp.expect_value('Free client book holds 20 customers (from settings)', '20',
  $q$select client_book_limit('00000000-0000-0000-0000-0000000000a1')::text$q$);

-- Who can do what ---------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('A logged-in user can see the plans', 1, $q$select * from plans$q$);
select pg_temp.expect_refused('A user cannot add a plan',
  $q$insert into plans (name, reach_level) values ('Mine', 'state')$q$);
select pg_temp.expect_rows('A user cannot change a plan', 0, $q$update plans set customer_limit = 9999$q$);
select pg_temp.expect_message('A user cannot switch a plan on', 'Only ALEE can switch plans on.',
  $q$select switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans limit 1), now(), now() + interval '1 day')$q$);
select pg_temp.expect_refused('A user cannot record a plan directly',
  $q$insert into seller_plans (seller_id, plan_id, starts_at, ends_at, switched_on_by)
     select '00000000-0000-0000-0000-0000000000a1', id, now(), now() + interval '1 year', '00000000-0000-0000-0000-0000000000a1' from plans limit 1$q$);
select pg_temp.expect_refused('A user cannot read another seller''s reach through the lookup',
  $q$select * from seller_reach('00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.expect_refused('...or his client book limit', $q$select client_book_limit('00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('A visitor sees no plans', $q$select * from plans$q$);

-- Paid plans ------------------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('An admin adds reach plans and a client-book plan', 3,
  $q$insert into plans (name, kind, reach_level, extra_states, customer_limit, outside_buyer_limit) values
       ('Check District', 'reach', 'district', null, null, 50),
       ('Check More States', 'reach', 'state', 2, null, null),
       ('Check Client Book', 'client_book', null, null, 100, null)$q$);
select pg_temp.expect_refused('A client-book plan carries no reach',
  $q$insert into plans (name, kind, reach_level, customer_limit) values ('Check Muddled', 'client_book', 'state', 100)$q$);
select pg_temp.expect_refused('A plan reaching only a city is refused',
  $q$insert into plans (name, reach_level) values ('Check City', 'city')$q$);

create temp table sp as
select switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans where name = 'Check District'),
                      now() - interval '1 day', now() + interval '30 days') as retailer_reach,
       switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans where name = 'Check Client Book'),
                      now() - interval '1 day', now() + interval '30 days') as retailer_book,
       switch_on_plan('00000000-0000-0000-0000-0000000000a5', (select id from plans where name = 'Check More States'),
                      now() - interval '1 day', now() + interval '30 days', array[(select goa from k)]) as maker_states;
grant select on sp to public;
select pg_temp.expect_message('Two reach plans cannot overlap', 'This seller already has a plan of this kind during those dates.',
  $q$select switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans where name = 'Check District'),
                           now() + interval '10 days', now() + interval '60 days')$q$);
select pg_temp.expect_message('A plan names no more states than it allows', 'Check District adds up to 0 extra states.',
  $q$select switch_on_plan('00000000-0000-0000-0000-0000000000a3', (select id from plans where name = 'Check District'),
                           now(), now() + interval '30 days', array[(select goa from k)])$q$);
select pg_temp.expect_refused('A plan adds whole states, never a district',
  $q$select switch_on_plan('00000000-0000-0000-0000-0000000000a3', (select id from plans where name = 'Check More States'),
                           now(), now() + interval '30 days', array[(select north_goa from k)])$q$);

select pg_temp.as_owner();
select pg_temp.expect_value('A paid reach plan widens a retailer''s reach to his district', 'reaches Satara, home Check Karad, plan Check District, outside buyers 50',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('...and his client-book plan, held alongside it, allows more customers', '100',
  $q$select client_book_limit('00000000-0000-0000-0000-0000000000a1')::text$q$);
select pg_temp.expect_value('A manufacturer''s plan adds a named state', 'reaches Maharashtra and Goa, home Maharashtra, plan Check More States, outside buyers no limit',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a5')$q$);
select pg_temp.expect_value('A North Goa buyer is now inside his reach', 'true',
  $q$select within_reach('00000000-0000-0000-0000-0000000000a5', (select north_goa from k))::text$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('The seller sees his own plans', 2, $q$select * from seller_plans$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a5');
select pg_temp.expect_rows('...and the states his plan adds', 1, $q$select * from seller_plan_areas$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('Another seller sees none of them', 0, $q$select * from seller_plans$q$);
select pg_temp.expect_rows('...nor the states they add', 0, $q$select * from seller_plan_areas$q$);

-- Ending, and the free level again ---------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('An admin ends the reach plan early', 1, $q$select end_plan_early((select retailer_reach from sp))$q$);
select pg_temp.expect_message('...only once', 'That plan has already ended.', $q$select end_plan_early((select retailer_reach from sp))$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('After it ends, reach returns to his taluka; his client-book plan is unaffected', 'reaches Check Karad, home Check Karad, plan free, outside buyers 10 | book 100',
  $q$select pg_temp.reach('00000000-0000-0000-0000-0000000000a1') || ' | book ' || client_book_limit('00000000-0000-0000-0000-0000000000a1')$q$);

-- Never changed, never deleted ---------------------------------------------------------

select pg_temp.expect_refused('Not even the database owner can change a plan record''s dates',
  $q$update seller_plans set ends_at = ends_at + interval '1 year'$q$);
select pg_temp.expect_refused('Not even the database owner can delete a plan record', $q$delete from seller_plans$q$);
select pg_temp.expect_refused('...or the states a plan added', $q$delete from seller_plan_areas$q$);
select pg_temp.expect_refused('...or change them', $q$update seller_plan_areas set region_id = (select mh from k)$q$);
select pg_temp.expect_refused('Not even the database owner can delete a plan', $q$delete from plans where name = 'Check District'$q$);
select pg_temp.expect_refused('A plan''s kind never changes', $q$update plans set kind = 'client_book', reach_level = null, outside_buyer_limit = null where name = 'Check District'$q$);
