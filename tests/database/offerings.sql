-- ============================================================
-- Checks: what each seller offers (grades and sizes), and missing figures.
-- Covers: nothing selected by default; select one, select all, unselect;
-- only active grades and sizes in a family the seller deals in; unselecting
-- never deletes; every change kept as history that cannot be changed;
-- sizes switched on later start unselected; other sellers cannot see or
-- change a seller's choices or history; a selected size with no figure in
-- the size chart is reported as missing, never treated as zero.
-- Tables: seller_grades, seller_sizes, seller_offering_history.
-- Functions: select_all_in_family, size_chart_missing_figures.
--
-- Test people (temporary logins, rolled back):
--   A ...a1  seller, deals in TMT only
--   B ...b2  seller
--   C ...c3  admin
-- ============================================================

-- Test data -------------------------------------------------------------------

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'distributor', r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Asha', '+919800000001'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala', '+919800000002')) as x (id, name, phone)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_profiles (account_id, store_name, region_id, is_public)
select x.id::uuid, x.store, r.id, true
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Asha Steels'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala Traders')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id
  from (values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2')) as x (id)
 cross join (select id from segments where name = 'TMT Bars') s;

-- A TMT size that is not yet switched on in the catalogue.
insert into sizes (segment_id, display_name, sort_order, weight_per_metre_kg, piece_length_m,
                   weight_source, is_verified, is_active)
select id, 'Check 40mm', 80, 9.865, 12, 'check', false, false from segments where name = 'TMT Bars';

create temp table ids as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from products where name = 'Fe500D') as fe500d,
       (select id from products where name = 'MS Equal Angle') as angle_grade,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '12mm') as s12,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '32mm') as s32,
       (select id from sizes where display_name = 'Check 40mm') as s40,
       (select count(*) from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.is_active)::text as tmt_active_sizes,
       (select count(*) from products p join segments s on s.id = p.segment_id where s.name = 'TMT Bars' and p.is_active)::text as tmt_active_grades;
grant select on ids to public;

-- Structure -------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on',
  'seller_grades=true, seller_offering_history=true, seller_sizes=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace
       and relname in ('seller_grades', 'seller_sizes', 'seller_offering_history')$q$);

-- A chooses what he sells -----------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_value('Nothing is selected by default', '0 grades, 0 sizes',
  $q$select (select count(*) from seller_grades where seller_id = '00000000-0000-0000-0000-0000000000a1' and is_selected)
            || ' grades, ' ||
            (select count(*) from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1' and is_selected)
            || ' sizes'$q$);
select pg_temp.expect_rows('A selects grade Fe500D', 1,
  $q$insert into seller_grades (seller_id, product_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select fe500d from ids), true)$q$);
select pg_temp.expect_rows('A selects size 12mm', 1,
  $q$insert into seller_sizes (seller_id, size_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select s12 from ids), true)$q$);
select pg_temp.expect_refused('A selects an angle grade (he does not deal in angles)',
  $q$insert into seller_grades (seller_id, product_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select angle_grade from ids), true)$q$);
select pg_temp.expect_refused('A selects a size not yet switched on in the catalogue',
  $q$insert into seller_sizes (seller_id, size_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select s40 from ids), true)$q$);

select pg_temp.expect_value('Select all TMT grades selects every active grade not already chosen',
  (select (tmt_active_grades::int - 1)::text from ids),
  $q$select select_all_in_family((select tmt from ids), 'grades')::text$q$);
select pg_temp.expect_value('Select all TMT sizes selects every active size not already chosen',
  (select (tmt_active_sizes::int - 1)::text from ids),
  $q$select select_all_in_family((select tmt from ids), 'sizes')::text$q$);
select pg_temp.expect_value('A now offers every active TMT grade and size',
  (select tmt_active_grades || ' grades, ' || tmt_active_sizes || ' sizes' from ids),
  $q$select (select count(*) from seller_grades where seller_id = '00000000-0000-0000-0000-0000000000a1' and is_selected)
            || ' grades, ' ||
            (select count(*) from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1' and is_selected)
            || ' sizes'$q$);
select pg_temp.expect_value('Select all again changes nothing', '0',
  $q$select select_all_in_family((select tmt from ids), 'sizes')::text$q$);

select pg_temp.expect_rows('A unselects 32mm', 1,
  $q$update seller_sizes set is_selected = false
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and size_id = (select s32 from ids)$q$);
select pg_temp.expect_value('Unselecting keeps the row: 32mm is still there, marked not offered', 'kept, not offered',
  $q$select case when count(*) = 1 then 'kept, ' else 'GONE, ' end ||
            case when bool_or(is_selected) then 'offered' else 'not offered' end
     from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1' and size_id = (select s32 from ids)$q$);
select pg_temp.expect_value('History of 32mm: selected, then unselected', 'selected, unselected',
  $q$select string_agg(case when is_selected then 'selected' else 'unselected' end, ', ' order by changed_at, id)
     from seller_offering_history
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and size_id = (select s32 from ids)$q$);
select pg_temp.expect_value('History records that A made the change himself', 'A',
  $q$select case when bool_and(changed_by = '00000000-0000-0000-0000-0000000000a1') then 'A' else 'someone else' end
     from seller_offering_history where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Select all did not add a second history entry for 12mm (already selected)', '1',
  $q$select count(*)::text from seller_offering_history
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and size_id = (select s12 from ids)$q$);

select pg_temp.expect_refused('A deletes a selection', $q$delete from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A writes his own history directly',
  $q$insert into seller_offering_history (seller_id, size_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select s32 from ids), true)$q$);
select pg_temp.expect_refused('A rewrites his history',
  $q$update seller_offering_history set is_selected = true where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('A deletes his history',
  $q$delete from seller_offering_history where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- A size switched on later starts unselected ------------------------------------

select pg_temp.as_owner();
update sizes set is_verified = true, is_active = true where display_name = 'Check 40mm';

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('A size switched on later starts unselected, even after "select all"', 'not offered',
  $q$select case when exists (select 1 from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1'
                                and size_id = (select s40 from ids) and is_selected)
             then 'offered' else 'not offered' end$q$);

-- B, another seller, goes after A's choices -------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');

select pg_temp.expect_rows('B unselects A''s sizes', 0,
  $q$update seller_sizes set is_selected = false where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('B selects a size for A',
  $q$insert into seller_sizes (seller_id, size_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select s40 from ids), true)$q$);
select pg_temp.expect_value('B runs "unselect all" on A''s sizes: nothing changes', '0',
  $q$select select_all_in_family((select tmt from ids), 'sizes', false, '00000000-0000-0000-0000-0000000000a1')::text$q$);
select pg_temp.expect_refused('B runs "select all" for A (would add rows for A)',
  $q$select select_all_in_family((select tmt from ids), 'grades', true, '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('A''s selected sizes are unchanged after B''s attempts',
  (select (tmt_active_sizes::int - 1)::text from ids),
  $q$select count(*)::text from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1' and is_selected$q$);
select pg_temp.expect_value('B reads A''s history: nothing comes back', '0',
  $q$select count(*)::text from seller_offering_history where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('B can see A''s 32mm only if offered (it is not)', '0',
  $q$select count(*)::text from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1' and size_id = (select s32 from ids)$q$);

-- Visitor -----------------------------------------------------------------------

select pg_temp.as_visitor();
select pg_temp.expect_value('Visitor sees the sizes A offers',
  (select (tmt_active_sizes::int - 1)::text from ids),
  $q$select count(*)::text from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('Visitor reads selection history', $q$select * from seller_offering_history$q$);
select pg_temp.expect_refused('Visitor selects a size for A',
  $q$insert into seller_sizes (seller_id, size_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select s40 from ids), true)$q$);
select pg_temp.expect_refused('Visitor runs "select all"',
  $q$select select_all_in_family((select tmt from ids), 'sizes', true, '00000000-0000-0000-0000-0000000000a1')$q$);

-- Admin sets A up ---------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('Admin selects the new 40mm for A', 1,
  $q$insert into seller_sizes (seller_id, size_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select s40 from ids), true)$q$);
select pg_temp.expect_value('History records the admin made that change', 'admin',
  $q$select case when changed_by = '00000000-0000-0000-0000-0000000000c3' then 'admin' else 'someone else' end
     from seller_offering_history
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and size_id = (select s40 from ids)$q$);
select pg_temp.expect_value('Admin unselects all of A''s TMT sizes', (select tmt_active_sizes from ids),
  $q$select select_all_in_family((select tmt from ids), 'sizes', false, '00000000-0000-0000-0000-0000000000a1')::text$q$);
select pg_temp.expect_value('Every TMT size A ever chose is still on record, none offered',
  (select (tmt_active_sizes::int + 1)::text || ' kept, 0 offered' from ids),
  $q$select count(*) || ' kept, ' || count(*) filter (where is_selected) || ' offered'
     from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Admin selects all TMT sizes for A again (now including 40mm)',
  (select (tmt_active_sizes::int + 1)::text from ids),
  $q$select select_all_in_family((select tmt from ids), 'sizes', true, '00000000-0000-0000-0000-0000000000a1')::text$q$);

-- Missing figures: a selected size with no figure is an error, never zero --------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_rows('A creates a size chart', 1,
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'size', 'A sizes')$q$);
select pg_temp.expect_value('A saves figures for 8mm (500), 10mm (0) and 12mm (300) only', 'saved',
  $q$select case when save_chart_version((select id from charts where name = 'A sizes'), 'tonne',
       (select jsonb_agg(jsonb_build_object('size_id', z.id, 'amount',
                case z.display_name when '8mm' then 500 when '10mm' then 0 else 300 end))
          from sizes z join segments s on s.id = z.segment_id
         where s.name = 'TMT Bars' and z.display_name in ('8mm', '10mm', '12mm'))) is not null
     then 'saved' end$q$);
select pg_temp.expect_value('The sizes A offers but has no figure for are reported as missing',
  '16mm, 20mm, 25mm, 32mm, Check 40mm',
  $q$select string_agg(display_name, ', ' order by display_name) from size_chart_missing_figures(
       (select id from charts where name = 'A sizes'))$q$);
select pg_temp.expect_value('10mm has a figure of 0, so it is not missing', 'not missing',
  $q$select case when exists (select 1 from size_chart_missing_figures((select id from charts where name = 'A sizes'))
                              where display_name = '10mm') then 'MISSING' else 'not missing' end$q$);

select pg_temp.expect_rows('A unselects 32mm and 40mm', 2,
  $q$update seller_sizes set is_selected = false
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and size_id in ((select s32 from ids), (select s40 from ids))$q$);
select pg_temp.expect_value('A size A no longer offers is no longer missing', '16mm, 20mm, 25mm',
  $q$select string_agg(display_name, ', ' order by display_name) from size_chart_missing_figures(
       (select id from charts where name = 'A sizes'))$q$);

select pg_temp.expect_value('A saves version 2 with every size he offers', 'saved',
  $q$select case when save_chart_version((select id from charts where name = 'A sizes'), 'tonne',
       (select jsonb_agg(jsonb_build_object('size_id', z.id, 'amount', 0))
          from seller_sizes ss join sizes z on z.id = ss.size_id
         where ss.seller_id = '00000000-0000-0000-0000-0000000000a1' and ss.is_selected)) is not null
     then 'saved' end$q$);
select pg_temp.expect_value('Nothing is missing now', '(nothing)',
  $q$select string_agg(display_name, ', ') from size_chart_missing_figures((select id from charts where name = 'A sizes'))$q$);

select pg_temp.as_owner();
create temp table achart as select id from charts where name = 'A sizes';
grant select on achart to public;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('B checks A''s chart for missing sizes, using its id',
  $q$select * from size_chart_missing_figures((select id from achart))$q$);

-- Deleting a seller's login removes his choices and their history -------------

select pg_temp.as_owner();
select pg_temp.expect_rows('Delete A''s login', 1,
  $q$delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Left for A: grades / sizes / history', '0/0/0',
  $q$select (select count(*) from seller_grades where seller_id = '00000000-0000-0000-0000-0000000000a1') || '/' ||
            (select count(*) from seller_sizes where seller_id = '00000000-0000-0000-0000-0000000000a1') || '/' ||
            (select count(*) from seller_offering_history where seller_id = '00000000-0000-0000-0000-0000000000a1')$q$);
