-- ============================================================
-- Checks: regions (state > district > taluka > city).
-- Covers: seeded districts, old-name search, who can read and change
-- regions, the parent-level rules, and that regions are never deleted.
-- Tables: regions. Functions: search_regions, is_admin.
-- ============================================================

-- Structure and seed data ---------------------------------------------------

select pg_temp.expect_value('Row Level Security is on for regions', 'true',
  $q$select relrowsecurity::text from pg_class where oid = 'public.regions'::regclass$q$);

select pg_temp.expect_value('Maharashtra has 36 districts', '36',
  $q$select count(*)::text from regions d join regions s on s.id = d.parent_id
     where s.level = 'state' and s.name = 'Maharashtra' and d.level = 'district'$q$);

select pg_temp.expect_value('Goa has 2 districts (Kushavati deliberately deferred)', '2',
  $q$select count(*)::text from regions d join regions s on s.id = d.parent_id
     where s.level = 'state' and s.name = 'Goa' and d.level = 'district'$q$);

select pg_temp.expect_value('Search "aurangabad" finds Chhatrapati Sambhajinagar', 'Chhatrapati Sambhajinagar',
  $q$select name from search_regions('aurangabad') limit 1$q$);
select pg_temp.expect_value('Search "Osmanabad" finds Dharashiv', 'Dharashiv',
  $q$select name from search_regions('Osmanabad') limit 1$q$);
select pg_temp.expect_value('Search "ahmednagar" finds Ahilyanagar', 'Ahilyanagar',
  $q$select name from search_regions('ahmednagar') limit 1$q$);

-- Test data (rolled back): a city added the way a buyer would add one ------

insert into regions (name, level, parent_id)
select 'Checkpur', 'city', id from regions where level = 'district' and name = 'Pune';

select pg_temp.expect_value('A newly added city starts unapproved', 'false',
  $q$select is_approved::text from regions where name = 'Checkpur'$q$);

create temp table snap as
select (select count(*) from regions where is_active and is_approved)::text as public_regions;
grant select on snap to public;

-- Visitor, not logged in ----------------------------------------------------

select pg_temp.as_visitor();

select pg_temp.expect_value('Visitor sees only approved, active regions', (select public_regions from snap),
  $q$select count(*)::text from regions$q$);
select pg_temp.expect_value('Visitor cannot see the unapproved city', '0',
  $q$select count(*)::text from regions where name = 'Checkpur'$q$);
select pg_temp.expect_value('Visitor search does not return the unapproved city', '0',
  $q$select count(*)::text from search_regions('checkpur')$q$);
select pg_temp.expect_refused('Visitor adds a region',
  $q$insert into regions (name, level, parent_id)
     select 'X', 'city', id from regions where level = 'district' and name = 'Pune'$q$);

-- Ordinary logged-in user ---------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_refused('Ordinary user adds a region',
  $q$insert into regions (name, level, parent_id)
     select 'X', 'city', id from regions where level = 'district' and name = 'Pune'$q$);
select pg_temp.expect_rows('Ordinary user renames a region', 0,
  $q$update regions set name = 'X' where level = 'district' and name = 'Pune'$q$);
select pg_temp.expect_rows('Ordinary user switches off a region', 0,
  $q$update regions set is_active = false where level = 'district' and name = 'Pune'$q$);
select pg_temp.expect_rows('Ordinary user approves the unapproved city', 0,
  $q$update regions set is_approved = true where name = 'Checkpur'$q$);
select pg_temp.expect_refused('Ordinary user deletes a region',
  $q$delete from regions where level = 'state' and name = 'Goa'$q$);

-- Admin ---------------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

select pg_temp.expect_value('Admin sees the unapproved city', '1',
  $q$select count(*)::text from regions where name = 'Checkpur'$q$);
select pg_temp.expect_rows('Admin approves the city', 1,
  $q$update regions set is_approved = true where name = 'Checkpur'$q$);
select pg_temp.expect_refused('Admin puts a taluka directly under a state',
  $q$insert into regions (name, level, parent_id, is_approved)
     select 'Bad', 'taluka', id, true from regions where level = 'state' and name = 'Goa'$q$);
select pg_temp.expect_refused('Admin adds a second district called "pune"',
  $q$insert into regions (name, level, parent_id, is_approved)
     select 'pune', 'district', id, true from regions where level = 'state' and name = 'Maharashtra'$q$);
select pg_temp.expect_refused('Admin deletes a region',
  $q$delete from regions where name = 'Checkpur'$q$);

-- Database owner (same power as the server's secret key) --------------------

select pg_temp.as_owner();

select pg_temp.expect_refused('Even the database owner cannot delete a region',
  $q$delete from regions where name = 'Checkpur'$q$);
select pg_temp.expect_refused('A region cannot name itself as its replacement',
  $q$update regions set is_active = false, replaced_by_id = id where name = 'Checkpur'$q$);
select pg_temp.expect_refused('An active region cannot have a replacement',
  $q$update regions set replaced_by_id = (select id from regions where level = 'district' and name = 'Pune')
     where name = 'Checkpur'$q$);
