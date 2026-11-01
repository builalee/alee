-- ============================================================
-- Checks: settings (settings, settings_history, setting_text, setting_int,
-- change_setting).
-- Covers: the seeded values; logged-in users read them, visitors don't;
-- only admins change them, and every change is kept with who and when; a
-- value of the wrong kind is refused; lowering the free customer limit
-- changes the limit (nothing else is touched); nothing is deleted.
--
-- Test people (temporary logins, rolled back):
--   U ...a1  ordinary user
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000033', 'authenticated', 'authenticated');

select pg_temp.expect_value('Row Level Security is on', 'settings=true, settings_history=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where oid in ('public.settings'::regclass, 'public.settings_history'::regclass)$q$);
select pg_temp.expect_value('The seeded settings',
  'free_customer_limit=20, free_outside_buyer_limit=10, free_reach_distributor=district, free_reach_manufacturer=state, free_reach_retailer=taluka, free_reach_wholesaler=district',
  $q$select string_agg(key || '=' || value, ', ' order by key) from settings$q$);

select pg_temp.as_visitor();
select pg_temp.expect_refused('A visitor cannot read settings', $q$select * from settings$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('A logged-in user can read settings', 6, $q$select * from settings$q$);
select pg_temp.expect_message('A user cannot change a setting', 'Only ALEE can change settings.',
  $q$select change_setting('free_customer_limit', '999')$q$);
select pg_temp.expect_refused('...nor write it directly', $q$update settings set value = '999' where key = 'free_customer_limit'$q$);
select pg_temp.expect_rows('A user sees no history of changes', 0, $q$select * from settings_history$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('An admin lowers the free customer limit to 15', 1, $q$select change_setting('free_customer_limit', '15')$q$);
select pg_temp.expect_message('A limit must be a whole number', 'free_customer_limit must be a whole number.',
  $q$select change_setting('free_customer_limit', 'lots')$q$);
select pg_temp.expect_message('A reach must be taluka, district or state', 'free_reach_retailer must be taluka, district or state.',
  $q$select change_setting('free_reach_retailer', 'city')$q$);
select pg_temp.expect_message('An unknown setting', 'That setting does not exist.',
  $q$select change_setting('free_lunch', '1')$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('The new value is read everywhere it is used', '15',
  $q$select setting_int('free_customer_limit')::text$q$);
select pg_temp.expect_value('The change is kept: old value, new value, by the admin', '20 -> 15 by admin',
  $q$select old_value || ' -> ' || new_value || ' by admin' from settings_history
      where key = 'free_customer_limit' and changed_by = '00000000-0000-0000-0000-0000000000c3'$q$);

select pg_temp.expect_refused('Not even the database owner can delete a setting', $q$delete from settings where key = 'free_customer_limit'$q$);
select pg_temp.expect_refused('...or change its history', $q$update settings_history set new_value = '99'$q$);
select pg_temp.expect_refused('...or delete it', $q$delete from settings_history$q$);
