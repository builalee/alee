-- ============================================================
-- Checks: the ex-works switches and plant city (seller_ex_works_states,
-- seller_plant_cities, set_ex_works, set_plant_city, ex_works_for).
-- Covers: off by default in every state; switched on per state; only
-- where his reach touches that state; the plant city defaults to his
-- profile location and can be changed; switching off; only the seller (or
-- an admin, recorded as admin) changes them; each seller sees only his
-- own; nothing is changed or deleted.
--
-- Test people (temporary logins, rolled back):
--   W ...a1  wholesaler (approved) at Satara (reaches Satara district)
--   T ...a2  retailer at Satara
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000033', 'authenticated', 'authenticated');
insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Wagh', '+919800000001', 'wholesaler'),
               ('00000000-0000-0000-0000-0000000000a2', 'Tara', '+919800000002', 'retailer')) as x (id, name, phone, role)
 cross join (select id from regions where level = 'district' and name = 'Satara') r;
insert into seller_profiles (account_id, store_name, region_id, is_public)
select a.id, a.full_name || ' Steel', a.region_id, true from accounts a where a.id::text like '00000000-0000-0000-0000-%';
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_role_request(id, true) from role_requests where status = 'requested';
select pg_temp.as_owner();

create temp table k as
select (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'state' and name = 'Goa') as goa,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select id from regions where level = 'district' and name = 'North Goa') as north_goa;
grant select on k to public;

create function pg_temp.xw(p_seller uuid, p_region uuid) returns text language sql as $$
  select case when x.is_on then 'on' else 'off' end || ', plant ' || x.plant_name from ex_works_for(p_seller, p_region) x
$$;

select pg_temp.expect_value('Row Level Security is on', 'seller_ex_works_states=true, seller_plant_cities=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where oid in ('public.seller_ex_works_states'::regclass, 'public.seller_plant_cities'::regclass)$q$);
select pg_temp.expect_value('Off by default; the plant city defaults to his profile location', 'off, plant Satara',
  $q$select pg_temp.xw('00000000-0000-0000-0000-0000000000a1', (select pune from k))$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('W switches ex-works on in Maharashtra, where his reach is', 1,
  $q$select set_ex_works((select mh from k), true)$q$);
select pg_temp.expect_message('...not in Goa, beyond his reach', 'Ex-works can be switched on only where you reach. Upgrade to reach more areas.',
  $q$select set_ex_works((select goa from k), true)$q$);
select pg_temp.expect_message('It is switched per state, never a district', 'Ex-works is switched on for a whole state.',
  $q$select set_ex_works((select satara from k), true)$q$);
select pg_temp.expect_rows('He names Pune as his plant city', 1, $q$select set_plant_city((select pune from k))$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('On for every area of Maharashtra, with the new plant city', 'on, plant Pune',
  $q$select pg_temp.xw('00000000-0000-0000-0000-0000000000a1', (select satara from k))$q$);
select pg_temp.expect_value('...still off in Goa', 'off, plant Pune',
  $q$select pg_temp.xw('00000000-0000-0000-0000-0000000000a1', (select north_goa from k))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('He switches it off; switching off is always allowed', 1,
  $q$select set_ex_works((select mh from k), false)$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('Off again; every change is kept', 'off, plant Pune, 2 changes',
  $q$select pg_temp.xw('00000000-0000-0000-0000-0000000000a1', (select satara from k)) || ', '
         || (select count(*) from seller_ex_works_states where seller_id = '00000000-0000-0000-0000-0000000000a1') || ' changes'$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('A place that does not exist', 'Choose your plant city from the list of places.',
  $q$select set_plant_city(gen_random_uuid())$q$);
select pg_temp.expect_message('He cannot change another seller''s setting', 'You can only change your own ex-works setting.',
  $q$select set_ex_works((select mh from k), true, '00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.expect_message('...or plant city', 'You can only change your own plant city.',
  $q$select set_plant_city((select pune from k), '00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.expect_refused('He cannot write a switch directly',
  $q$insert into seller_ex_works_states (seller_id, state_id, is_on, set_by, by_admin)
     values ('00000000-0000-0000-0000-0000000000a2', (select mh from k), true, '00000000-0000-0000-0000-0000000000a1', false)$q$);
select pg_temp.expect_refused('He cannot read the lookup for another seller',
  $q$select * from ex_works_for('00000000-0000-0000-0000-0000000000a2', (select satara from k))$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('A retailer can switch it on in his state too (it shows only inside his reach)', 1,
  $q$select set_ex_works((select mh from k), true)$q$);
select pg_temp.expect_rows('He sees only his own switch, none of W''s', 1, $q$select * from seller_ex_works_states$q$);
select pg_temp.expect_rows('...nor W''s plant city', 0, $q$select * from seller_plant_cities$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('An admin switches it off for him', 1,
  $q$select set_ex_works((select mh from k), false, '00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('Recorded as done by an admin', 'by admin',
  $q$select 'by admin' from seller_ex_works_states where seller_id = '00000000-0000-0000-0000-0000000000a2' and by_admin and not is_on$q$);

select pg_temp.expect_refused('Not even the database owner can change a saved switch', $q$update seller_ex_works_states set is_on = true$q$);
select pg_temp.expect_refused('...or delete one', $q$delete from seller_ex_works_states$q$);
select pg_temp.expect_refused('...or change a plant city', $q$update seller_plant_cities set plant_region_id = (select mh from k)$q$);
select pg_temp.expect_refused('...or delete one', $q$delete from seller_plant_cities$q$);
