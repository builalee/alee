-- ============================================================
-- Checks: brand lines (which brands each seller sells, per family).
-- Covers: adding a family gives a Regular line (transitional, until brands
-- step 11); a seller adds an approved brand for a family it covers; refused
-- in plain words for unapproved brands, families the brand doesn't cover,
-- and families he doesn't deal in; any seller can sell an unowned brand;
-- only the seller (or an admin) adds or changes his lines; lines are public
-- when active; switched off, never deleted.
-- Table: seller_brands.
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller (TMT)    T ...b2  another seller    C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'retailer', r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Sunil', '+919800000001'),
               ('00000000-0000-0000-0000-0000000000b2', 'Tara',  '+919800000002')) as x (id, name, phone)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_profiles (account_id, store_name, region_id, is_public)
select x.id::uuid, x.store, r.id, true
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Sunil Steel'),
               ('00000000-0000-0000-0000-0000000000b2', 'Tara Traders')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into brands (name, status) values ('Check Tiscon', 'approved'), ('Check Pending', 'requested');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s
 where b.name in ('Check Tiscon', 'Check Pending') and s.name = 'TMT Bars';

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from segments where name = 'MS Angles') as angles,
       (select id from brands where is_regular) as regular,
       (select id from brands where name = 'Check Tiscon') as tiscon,
       (select id from brands where name = 'Check Pending') as pending;
grant select on k to public;

select pg_temp.expect_value('Row Level Security is on', 'true',
  $q$select relrowsecurity::text from pg_class where oid = 'public.seller_brands'::regclass$q$);

-- Adding a family gives a Regular line (transitional) --------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('S adds TMT to his product families', 1,
  $q$insert into seller_segments (seller_id, segment_id) values ('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);
select pg_temp.expect_value('He now sells Regular TMT', 'Regular TMT',
  $q$select string_agg(brand_display_name(brand_id, segment_id), ', ')
     from seller_brands where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Adding brands -------------------------------------------------------------------------

select pg_temp.expect_rows('S adds Check Tiscon TMT (no owner on ALEE yet)', 1,
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select tiscon from k), (select tmt from k))$q$);
select pg_temp.expect_value('He sells Check Tiscon TMT and Regular TMT', 'Check Tiscon, Regular TMT',
  $q$select string_agg(brand_display_name(brand_id, segment_id), ', ' order by brand_display_name(brand_id, segment_id))
     from seller_brands where seller_id = '00000000-0000-0000-0000-0000000000a1' and is_active$q$);
select pg_temp.expect_message('A brand not yet approved', 'That brand is not available yet.',
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select pending from k), (select tmt from k))$q$);
select pg_temp.expect_message('A family the brand does not cover', 'Check Tiscon is not listed for MS Angles.',
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select tiscon from k), (select angles from k))$q$);
select pg_temp.expect_message('A family he does not deal in (Regular Angles)', 'Add MS Angles to your product families first.',
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select angles from k))$q$);
select pg_temp.expect_refused('The same brand line twice',
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select tiscon from k), (select tmt from k))$q$);

-- Who may change what -------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('Another seller adds a brand line for S',
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k))$q$);
select pg_temp.expect_rows('Another seller switches off S''s line (nothing changes)', 0,
  $q$update seller_brands set is_active = false where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.as_visitor();
select pg_temp.expect_value('Anyone can see the brands S sells', 'Check Tiscon, Regular TMT',
  $q$select string_agg(brand_display_name(brand_id, segment_id), ', ' order by brand_display_name(brand_id, segment_id))
     from seller_brands where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('Visitors cannot add brand lines',
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select tiscon from k), (select tmt from k))$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('Admin adds TMT for T (setting him up)', 1,
  $q$insert into seller_segments (seller_id, segment_id) values ('00000000-0000-0000-0000-0000000000b2', (select tmt from k))$q$);
select pg_temp.expect_rows('...and Check Tiscon TMT', 1,
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000b2', (select tiscon from k), (select tmt from k))$q$);

-- Switched off, never deleted ---------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('S stops selling Check Tiscon (switched off)', 1,
  $q$update seller_brands set is_active = false where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k)$q$);
select pg_temp.expect_value('It is kept, switched off', 'kept, off',
  $q$select case when count(*) = 1 then 'kept, ' else 'GONE, ' end || case when bool_or(is_active) then 'on' else 'off' end
     from seller_brands where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k)$q$);
select pg_temp.as_visitor();
select pg_temp.expect_value('Visitors no longer see it', 'Regular TMT',
  $q$select string_agg(brand_display_name(brand_id, segment_id), ', ') from seller_brands where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('S sells it again (switched back on)', 1,
  $q$update seller_brands set is_active = true where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k)$q$);
select pg_temp.expect_refused('S deletes a brand line', $q$delete from seller_brands where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('S turns his Tiscon line into a different brand',
  $q$update seller_brands set brand_id = (select regular from k) where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k)$q$);
select pg_temp.as_owner();
select pg_temp.expect_refused('Even with the master key: delete a brand line',
  $q$delete from seller_brands where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_rows('Deleting S''s login removes his brand lines', 1,
  $q$delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('None left', '0',
  $q$select count(*)::text from seller_brands where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
