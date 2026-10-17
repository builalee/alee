-- ============================================================
-- Checks: accounts, consents, seller profiles, seller product families.
-- Covers: phone and personal details private to the person and admins,
-- phone must be the login phone, consents add-only, public seller profiles,
-- seller units starting from the family default, admin set-up of sellers,
-- and that deleting a login removes everything personal.
-- Tables: accounts, consents, seller_profiles, seller_segments.
-- Functions: current_login_phone.
--
-- Test people (temporary logins, rolled back):
--   A ...a1  ordinary user, retailer, sells TMT (tonne) and angles (kg)
--   B ...b2  ordinary user, distributor, private profile
--   C ...c3  admin
--   D ...d4  seller set up by the admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d4', '919800000004', 'authenticated', 'authenticated');

create temp table ids as
select (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select id from segments where name = 'TMT Bars') as tmt,
       (select id from segments where name = 'MS Angles') as angles;
grant select on ids to public;

-- Structure -------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on',
  'accounts=true, consents=true, seller_profiles=true, seller_segments=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace
       and relname in ('accounts', 'consents', 'seller_profiles', 'seller_segments')$q$);
select pg_temp.expect_value('Seller profiles hold no phone or contact column', '0',
  $q$select count(*)::text from information_schema.columns
     where table_schema = 'public' and table_name = 'seller_profiles'
       and (column_name like '%phone%' or column_name like '%contact%' or column_name like '%email%')$q$);

-- A signs up ------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_refused('A creates own account with a phone that is not her login phone',
  $q$insert into accounts (id, full_name, phone, signup_role, region_id)
     values ('00000000-0000-0000-0000-0000000000a1', 'Asha', '+919811111111', 'retailer', (select pune from ids))$q$);
select pg_temp.expect_refused('A creates an account for B',
  $q$insert into accounts (id, full_name, phone, signup_role, region_id)
     values ('00000000-0000-0000-0000-0000000000b2', 'Fake', '+919800000002', 'retailer', (select pune from ids))$q$);
select pg_temp.expect_rows('A creates own account with her login phone', 1,
  $q$insert into accounts (id, full_name, phone, firm_name, gst_number, signup_role, region_id)
     values ('00000000-0000-0000-0000-0000000000a1', 'Asha', '+919800000001', 'Asha Steels',
             ' 27abcde1234f1z5 ', 'retailer', (select pune from ids))$q$);
select pg_temp.expect_value('GST is tidied but not checked', '27ABCDE1234F1Z5',
  $q$select gst_number from accounts where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_rows('A records her own consent', 1,
  $q$insert into consents (account_id, purpose, notice_version)
     values ('00000000-0000-0000-0000-0000000000a1', 'privacy_notice', 'v1')$q$);
select pg_temp.expect_rows('A tries to back-date a consent (saved, but with the real time)', 1,
  $q$insert into consents (account_id, purpose, notice_version, recorded_at)
     values ('00000000-0000-0000-0000-0000000000a1', 'terms_of_use', 'v1', '2020-01-01')$q$);
select pg_temp.expect_value('The back-dated consent carries today''s date', current_date::text,
  $q$select recorded_at::date::text from consents
     where account_id = '00000000-0000-0000-0000-0000000000a1' and purpose = 'terms_of_use'$q$);
select pg_temp.expect_rows('A creates her own seller profile', 1,
  $q$insert into seller_profiles (account_id, store_name, description, region_id, market_close_time, is_public)
     values ('00000000-0000-0000-0000-0000000000a1', 'Asha Steels', 'TMT and angles',
             (select pune from ids), '18:30', true)$q$);
select pg_temp.expect_rows('A adds TMT without choosing a unit', 1,
  $q$insert into seller_segments (seller_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids))$q$);
select pg_temp.expect_value('A''s TMT unit starts as the family default', 'tonne',
  $q$select base_unit::text from seller_segments
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and segment_id = (select tmt from ids)$q$);
select pg_temp.expect_rows('A adds MS Angles per kg', 1,
  $q$insert into seller_segments (seller_id, segment_id, base_unit)
     values ('00000000-0000-0000-0000-0000000000a1', (select angles from ids), 'kg')$q$);

-- B signs up with a private profile -------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');

select pg_temp.expect_rows('B creates his own account', 1,
  $q$insert into accounts (id, full_name, phone, firm_name, gst_number, signup_role, region_id)
     values ('00000000-0000-0000-0000-0000000000b2', 'Bala', '+919800000002', 'Bala Traders',
             '27BBBBB2222B2Z2', 'distributor', (select pune from ids))$q$);
select pg_temp.expect_rows('B records his own consent', 1,
  $q$insert into consents (account_id, purpose, notice_version)
     values ('00000000-0000-0000-0000-0000000000b2', 'privacy_notice', 'v1')$q$);
select pg_temp.expect_rows('B creates his own private seller profile', 1,
  $q$insert into seller_profiles (account_id, store_name, region_id, is_public)
     values ('00000000-0000-0000-0000-0000000000b2', 'Bala Traders', (select pune from ids), false)$q$);
select pg_temp.expect_rows('B adds TMT', 1,
  $q$insert into seller_segments (seller_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000b2', (select tmt from ids))$q$);

-- A, an ordinary user, goes after B's details ---------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_value('A reads B''s phone number: nothing comes back', '(nothing)',
  $q$select string_agg(phone, ',') from accounts where id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_value('A lists every phone number: only her own comes back', '+919800000001',
  $q$select string_agg(phone, ',') from accounts$q$);
select pg_temp.expect_value('A reads B''s firm name and GST: nothing comes back', '(nothing)',
  $q$select string_agg(coalesce(firm_name, '-') || '/' || coalesce(gst_number, '-'), ',') from accounts
     where id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_value('A reads B''s consents: none come back', '0',
  $q$select count(*)::text from consents where account_id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_value('Login-phone lookup gives A only her own number', '+919800000001',
  $q$select current_login_phone()$q$);
select pg_temp.expect_rows('A changes B''s name', 0,
  $q$update accounts set full_name = 'X' where id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_refused('A changes her phone to an unverified number',
  $q$update accounts set phone = '+919811111111' where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A moves her account onto B''s login',
  $q$update accounts set id = '00000000-0000-0000-0000-0000000000b2' where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_rows('A changes her own name', 1,
  $q$update accounts set full_name = 'Asha K' where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A records a consent for B',
  $q$insert into consents (account_id, purpose, notice_version)
     values ('00000000-0000-0000-0000-0000000000b2', 'privacy_notice', 'v1')$q$);
select pg_temp.expect_refused('A edits her own consent',
  $q$update consents set granted = false where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A deletes her own consent',
  $q$delete from consents where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_rows('A changes B''s store name', 0,
  $q$update seller_profiles set store_name = 'X' where account_id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_refused('A creates a seller profile for D',
  $q$insert into seller_profiles (account_id, store_name, region_id, is_public)
     values ('00000000-0000-0000-0000-0000000000d4', 'X', (select pune from ids), true)$q$);
select pg_temp.expect_refused('A adds a product family to B',
  $q$insert into seller_segments (seller_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000b2', (select angles from ids))$q$);
select pg_temp.expect_rows('A changes B''s TMT unit', 0,
  $q$update seller_segments set base_unit = 'kg' where seller_id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_refused('A deletes her own seller profile',
  $q$delete from seller_profiles where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A prices a family per piece',
  $q$update seller_segments set base_unit = 'piece' where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Visitor, not logged in ------------------------------------------------

select pg_temp.as_visitor();

select pg_temp.expect_refused('Visitor reads accounts (phone numbers)',
  $q$select phone from accounts$q$);
select pg_temp.expect_refused('Visitor reads consents',
  $q$select * from consents$q$);
select pg_temp.expect_refused('Visitor uses the login-phone lookup',
  $q$select current_login_phone()$q$);
select pg_temp.expect_value('Visitor sees both test stores, public and private',
  'Asha Steels (public), Bala Traders (private)',
  $q$select string_agg(store_name || case when is_public then ' (public)' else ' (private)' end, ', ' order by store_name)
     from seller_profiles
     where account_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2')$q$);
select pg_temp.expect_value('Visitor sees the test sellers'' product families', '3',
  $q$select count(*)::text from seller_segments
     where seller_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2')$q$);
select pg_temp.expect_refused('Visitor creates a seller profile',
  $q$insert into seller_profiles (account_id, store_name, region_id, is_public)
     values ('00000000-0000-0000-0000-0000000000d4', 'X', (select pune from ids), true)$q$);

-- Admin -------------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

select pg_temp.expect_value('Admin sees the test phone numbers', '+919800000001, +919800000002',
  $q$select string_agg(phone, ', ' order by phone) from accounts
     where id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2')$q$);
select pg_temp.expect_rows('Admin sets up an account for D, with any phone', 1,
  $q$insert into accounts (id, full_name, phone, signup_role, region_id)
     values ('00000000-0000-0000-0000-0000000000d4', 'Dev', '+919822222222', 'manufacturer', (select pune from ids))$q$);
select pg_temp.expect_rows('Admin sets up D''s seller profile', 1,
  $q$insert into seller_profiles (account_id, store_name, region_id, is_public)
     values ('00000000-0000-0000-0000-0000000000d4', 'Dev Steel Mills', (select pune from ids), true)$q$);
select pg_temp.expect_rows('Admin adds a product family for D', 1,
  $q$insert into seller_segments (seller_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000d4', (select tmt from ids))$q$);
select pg_temp.expect_rows('Admin changes A''s firm name', 1,
  $q$update accounts set firm_name = 'Asha Steel Co' where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_rows('Admin changes B''s store description', 1,
  $q$update seller_profiles set description = 'Set by admin' where account_id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_refused('Admin records a consent on A''s behalf',
  $q$insert into consents (account_id, purpose, notice_version)
     values ('00000000-0000-0000-0000-0000000000a1', 'marketing', 'v1')$q$);
select pg_temp.expect_refused('Admin edits a consent',
  $q$update consents set granted = false where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Database owner (same power as the server's secret key) ------------------

select pg_temp.as_owner();

select pg_temp.expect_refused('Even the database owner cannot edit a consent',
  $q$update consents set granted = false where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A consent cannot be deleted on its own',
  $q$delete from consents where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A seller profile cannot be deleted on its own',
  $q$delete from seller_profiles where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A seller''s product family cannot be deleted on its own',
  $q$delete from seller_segments where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

update segments set is_active = false where name = 'MS Channels';
select pg_temp.expect_refused('A seller cannot add a switched-off product family',
  $q$insert into seller_segments (seller_id, segment_id)
     select '00000000-0000-0000-0000-0000000000a1', id from segments where name = 'MS Channels'$q$);

-- Deleting a login removes everything personal --------------------------

select pg_temp.expect_rows('Delete A''s login', 1,
  $q$delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Left for A: account / consents / profile / families', '0/0/0/0',
  $q$select (select count(*) from accounts where id = '00000000-0000-0000-0000-0000000000a1') || '/' ||
            (select count(*) from consents where account_id = '00000000-0000-0000-0000-0000000000a1') || '/' ||
            (select count(*) from seller_profiles where account_id = '00000000-0000-0000-0000-0000000000a1') || '/' ||
            (select count(*) from seller_segments where seller_id = '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('B is untouched: account / consents / profile / families', '1/1/1/1',
  $q$select (select count(*) from accounts where id = '00000000-0000-0000-0000-0000000000b2') || '/' ||
            (select count(*) from consents where account_id = '00000000-0000-0000-0000-0000000000b2') || '/' ||
            (select count(*) from seller_profiles where account_id = '00000000-0000-0000-0000-0000000000b2') || '/' ||
            (select count(*) from seller_segments where seller_id = '00000000-0000-0000-0000-0000000000b2')$q$);
