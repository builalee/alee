-- ============================================================
-- Checks: area setup is limited to the seller's reach
-- (area_settings_within_reach).
-- Covers: a free retailer can set up his own taluka and places in it, but
-- not his district ("Upgrade to reach more areas."); a wholesaler his
-- district, not a neighbouring one; a manufacturer his state, not another;
-- a paid plan opens the extra states it names; "everywhere" and exclusions
-- are always allowed; after a plan lapses, areas already saved can stay in
-- the next save, new ones cannot; an admin acting for a seller is held to
-- the same reach.
--
-- Test people (temporary logins, rolled back):
--   T ...a1  retailer at Check Karad City (in Check Karad taluka, Satara)
--   W ...a2  wholesaler (approved) at Satara
--   M ...a3  manufacturer (approved) at Pune
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role)
select x.id::uuid, x.phone, 'authenticated', 'authenticated'
  from (values ('00000000-0000-0000-0000-0000000000a1', '919800000001'), ('00000000-0000-0000-0000-0000000000a2', '919800000002'),
               ('00000000-0000-0000-0000-0000000000a3', '919800000003'), ('00000000-0000-0000-0000-0000000000c3', '919800000033')) as x (id, phone);
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad', 'taluka', id, true from regions where level = 'district' and name = 'Satara';
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad City', 'city', id, true from regions where name = 'Check Karad';
insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, '+' || u.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Tara', 'retailer', 'Check Karad City'),
               ('00000000-0000-0000-0000-0000000000a2', 'Wagh', 'wholesaler', 'Satara'),
               ('00000000-0000-0000-0000-0000000000a3', 'Mahesh', 'manufacturer', 'Pune')) as x (id, name, role, place)
  join auth.users u on u.id = x.id::uuid
  join regions r on r.name = x.place and r.level in ('district', 'city');
insert into seller_profiles (account_id, store_name, region_id, is_public)
select a.id, a.full_name || ' Steel', a.region_id, true from accounts a where a.id::text like '00000000-0000-0000-0000-%';
insert into seller_segments (seller_id, segment_id)
select a.id, s.id from accounts a, segments s where s.name = 'TMT Bars' and a.id::text like '00000000-0000-0000-0000-%';
select pg_temp.sell_regular();
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_role_request(id, true) from role_requests where status = 'requested';
select pg_temp.as_owner();

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from brands where is_regular) as regular,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'state' and name = 'Goa') as goa,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from regions where level = 'district' and name = 'Sangli') as sangli,
       (select id from regions where level = 'district' and name = 'North Goa') as north_goa,
       (select id from regions where name = 'Check Karad') as karad,
       (select id from regions where name = 'Check Karad City') as karad_city;
grant select on k to public;

-- Saves one area (served, area difference 0) for the acting seller, or
-- for a named seller when an admin acts.
create function pg_temp.save(p_regions uuid[], p_seller uuid default null) returns uuid language sql as $$
  select save_area_settings((select tmt from k),
           (select jsonb_agg(jsonb_build_object('region_id', x, 'area_difference', 0)) from unnest(p_regions) x),
           p_seller, (select regular from k)) $$;

-- Retailer ------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('A free retailer sets up his own taluka and a city in it', 1,
  $q$select pg_temp.save(array[(select karad from k), (select karad_city from k)])$q$);
select pg_temp.expect_message('...but not his district', 'Upgrade to reach more areas. Satara is outside your reach.',
  $q$select pg_temp.save(array[(select karad from k), (select satara from k)])$q$);
select pg_temp.expect_message('...nor his state', 'Upgrade to reach more areas. Maharashtra is outside your reach.',
  $q$select pg_temp.save(array[(select mh from k)])$q$);
select pg_temp.expect_rows('"Everywhere" is allowed: it means every area he reaches', 1,
  $q$select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]', null, (select regular from k))$q$);
select pg_temp.expect_rows('Excluding an area beyond his reach is allowed (it shows no rate anywhere)', 1,
  $q$select save_area_settings((select tmt from k), jsonb_build_array(jsonb_build_object('region_id', (select karad from k), 'area_difference', 0),
       jsonb_build_object('region_id', (select sangli from k), 'excluded', true)), null, (select regular from k))$q$);

-- Wholesaler and manufacturer -------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('A wholesaler sets up his own district', 1, $q$select pg_temp.save(array[(select satara from k)])$q$);
select pg_temp.expect_message('...but not a neighbouring district', 'Upgrade to reach more areas. Sangli is outside your reach.',
  $q$select pg_temp.save(array[(select satara from k), (select sangli from k)])$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.expect_rows('A manufacturer sets up his whole state', 1, $q$select pg_temp.save(array[(select mh from k)])$q$);
select pg_temp.expect_message('...but not another state', 'Upgrade to reach more areas. Goa is outside your reach.',
  $q$select pg_temp.save(array[(select mh from k), (select goa from k)])$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_message('An admin acting for him is held to the same reach', 'Upgrade to reach more areas. North Goa is outside your reach.',
  $q$select pg_temp.save(array[(select mh from k), (select north_goa from k)], '00000000-0000-0000-0000-0000000000a3')$q$);
insert into plans (name, reach_level, extra_states) values ('Check More States', 'state', 1);
create temp table mp as
select switch_on_plan('00000000-0000-0000-0000-0000000000a3', (select id from plans where name = 'Check More States'),
                      now() - interval '1 day', now() + interval '30 days', array[(select goa from k)]) as id;
grant select on mp to public;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.expect_rows('With a plan adding Goa, he can set up Goa and places in it', 1,
  $q$select pg_temp.save(array[(select mh from k), (select goa from k), (select north_goa from k)])$q$);

-- A lapsed plan ---------------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select end_plan_early((select id from mp));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.expect_rows('After the plan ends, Goa and North Goa stay in his next save (saved, not applied)', 1,
  $q$select pg_temp.save(array[(select mh from k), (select goa from k), (select north_goa from k)])$q$);
select pg_temp.expect_value('...and are still saved', '3 areas',
  $q$select count(*) || ' areas' from area_settings s
      where s.version_id = (select id from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a3'
                             order by version_number desc limit 1)$q$);
select pg_temp.expect_rows('He can leave Goa out', 1, $q$select pg_temp.save(array[(select mh from k), (select north_goa from k)])$q$);
select pg_temp.expect_message('...but once left out it cannot come back without a plan', 'Upgrade to reach more areas. Goa is outside your reach.',
  $q$select pg_temp.save(array[(select mh from k), (select goa from k)])$q$);
