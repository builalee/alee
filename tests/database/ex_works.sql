-- ============================================================
-- Checks: the ex-works setting (seller_ex_works_versions, set_ex_works,
-- ex_works_at).
-- Covers: off by default; a wholesaler switches it on and the plant city
-- defaults to his profile location; naming another plant city; switching
-- off keeps the plant city; the setting at an earlier moment; a free
-- retailer cannot switch it on, a paid one can; only the seller (or an
-- admin, recorded as admin) changes it; each seller sees only his own;
-- nothing is changed or deleted.
--
-- Test people (temporary logins, rolled back):
--   W ...a1  wholesaler (approved) at Satara
--   T ...a2  retailer at Satara (free plan, then paid)
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

create function pg_temp.xw(p_seller uuid, p_at timestamptz default null) returns text language sql as $$
  select case when x.is_on then 'on' else 'off' end || coalesce(' at ' || x.plant_name, '') from ex_works_at(p_seller, p_at) x
$$;

select pg_temp.expect_value('Row Level Security is on', 'true',
  $q$select relrowsecurity::text from pg_class where oid = 'public.seller_ex_works_versions'::regclass$q$);
select pg_temp.expect_value('Off by default', 'off', $q$select pg_temp.xw('00000000-0000-0000-0000-0000000000a1')$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('W switches it on', 1, $q$select set_ex_works(true)$q$);
select pg_temp.as_owner();
create temp table moment as select clock_timestamp() as at;
grant select on moment to public;
select pg_temp.expect_value('The plant city defaults to his profile location', 'on at Satara',
  $q$select pg_temp.xw('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('He names Pune as his plant city', 1,
  $q$select set_ex_works(true, (select id from regions where level = 'district' and name = 'Pune'))$q$);
select pg_temp.expect_rows('He switches it off', 1, $q$select set_ex_works(false)$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('Off, and the plant city is kept for next time', 'off at Pune',
  $q$select pg_temp.xw('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('The setting at an earlier moment is kept', 'on at Satara',
  $q$select pg_temp.xw('00000000-0000-0000-0000-0000000000a1', (select at from moment))$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('A place that does not exist', 'Choose your plant city from the list of places.',
  $q$select set_ex_works(true, gen_random_uuid())$q$);
select pg_temp.expect_message('He cannot change another seller''s setting', 'You can only change your own ex-works setting.',
  $q$select set_ex_works(true, null, '00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.expect_refused('He cannot write the setting directly',
  $q$insert into seller_ex_works_versions (seller_id, is_on, plant_region_id, set_by, by_admin)
     select '00000000-0000-0000-0000-0000000000a2', true, id, '00000000-0000-0000-0000-0000000000a1', false from regions where name = 'Pune' limit 1$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_message('A free retailer cannot switch it on', 'Ex-works rates come with a paid plan. Contact ALEE to upgrade.',
  $q$select set_ex_works(true)$q$);
select pg_temp.expect_rows('A free retailer sees none of W''s setting', 0, $q$select * from seller_ex_works_versions$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
insert into plans (name, reach_level) values ('Check District', 'district');
select switch_on_plan('00000000-0000-0000-0000-0000000000a2', (select id from plans where name = 'Check District'),
                      now() - interval '1 day', now() + interval '30 days');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('A paid retailer can switch it on', 1, $q$select set_ex_works(true)$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('An admin switches it off for him', 1,
  $q$select set_ex_works(false, null, '00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('Recorded as done by an admin', 'by admin',
  $q$select 'by admin' from seller_ex_works_versions where seller_id = '00000000-0000-0000-0000-0000000000a2' and by_admin and not is_on$q$);

select pg_temp.expect_refused('Not even the database owner can change a saved setting', $q$update seller_ex_works_versions set is_on = true$q$);
select pg_temp.expect_refused('Not even the database owner can delete one', $q$delete from seller_ex_works_versions$q$);
