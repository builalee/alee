-- ============================================================
-- Checks: area settings (CLAUDE.md sections 8 and 9).
-- Covers: carry-down from state to district and below; zero at district
-- never replaced by the state figure; "not set" and zero stored
-- differently; exclusion beating the state (and "everywhere"); "everywhere"
-- working only when explicitly chosen; grade premium, grade size chart and
-- grades not sold; old versions unchangeable; nobody but the seller and
-- admins can read settings (not buyers, not other sellers, not visitors).
-- Tables: area_setting_versions, area_settings, area_grade_settings.
-- Functions: save_area_settings, resolve_area_settings.
--
-- Test people (temporary logins, rolled back):
--   A ...a1  seller, TMT per tonne
--   B ...b2  seller, TMT per kg
--   E ...e5  buyer (no seller profile)
--   C ...c3  admin
--
-- A's setup, version 1 (TMT):
--   Maharashtra           +200, size "A sizes", loading, discount, unit tonne,
--                         Fe550D premium 300, Fe500D premium 150
--   Pune (district)       +0 (a real zero), Fe550D premium 0 (a real zero)
--   Check Haveli (taluka in Pune)   display unit kg, area difference NOT SET
--   Kolhapur (district)   EXCLUDED
--   Check Kolhapur City (city in Kolhapur)  +50
--   Sangli (district)     Fe500 not sold; Fe550D uses size chart "A sizes Fe550D"
--   (no "everywhere")
-- Version 2 = version 1 plus "everywhere" +500.
-- ============================================================

-- Test data -------------------------------------------------------------------

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', '919800000005', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'distributor', r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Asha', '+919800000001'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala', '+919800000002'),
               ('00000000-0000-0000-0000-0000000000e5', 'Esha', '+919800000005')) as x (id, name, phone)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_profiles (account_id, store_name, region_id, is_public)
select x.id::uuid, x.store, r.id, true
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Asha Steels'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala Traders')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_segments (seller_id, segment_id, base_unit)
select x.id::uuid, s.id, x.unit::unit
  from (values ('00000000-0000-0000-0000-0000000000a1', 'tonne'),
               ('00000000-0000-0000-0000-0000000000b2', 'kg')) as x (id, unit)
 cross join (select id from segments where name = 'TMT Bars') s;

-- A taluka and city inside Pune, a city inside Kolhapur, and an unapproved city.
insert into regions (name, level, parent_id, is_approved)
select 'Check Haveli', 'taluka', id, true from regions where level = 'district' and name = 'Pune';
insert into regions (name, level, parent_id, is_approved)
select 'Checkwadi', 'city', id, true from regions where name = 'Check Haveli';
insert into regions (name, level, parent_id, is_approved)
select 'Check Kolhapur City', 'city', id, true from regions where level = 'district' and name = 'Kolhapur';
insert into regions (name, level, parent_id, is_approved)
select 'Check Unapproved', 'city', id, false from regions where level = 'district' and name = 'Pune';

-- An active angle size, for a chart in the wrong product family.
insert into sizes (segment_id, display_name, sort_order, weight_per_metre_kg, piece_length_m,
                   weight_source, is_verified, is_active)
select id, 'Check angle', 999, 1, 6, 'check', true, true from segments where name = 'MS Angles';

-- Charts, created and filled the normal way by their sellers.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into charts (seller_id, segment_id, chart_type, name)
select '00000000-0000-0000-0000-0000000000a1', s.id, x.type::chart_type, x.name
  from (values ('TMT Bars', 'size', 'A sizes'), ('TMT Bars', 'size', 'A sizes Fe550D'),
               ('TMT Bars', 'loading', 'A loading'), ('TMT Bars', 'discount', 'A discount'),
               ('TMT Bars', 'size', 'A spare'), ('TMT Bars', 'size', 'A empty'),
               ('MS Angles', 'size', 'A angle sizes')) as x (segment, type, name)
  join segments s on s.name = x.segment;
select save_chart_version(c.id, 'tonne',
         jsonb_build_array(jsonb_build_object('size_id',
           (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '8mm'),
           'amount', 500)))
  from charts c where c.name in ('A sizes', 'A sizes Fe550D', 'A spare');
select save_chart_version((select id from charts where name = 'A loading'), 'tonne',
         jsonb_build_array(jsonb_build_object('size_id', null, 'amount', 250)));
select save_chart_version((select id from charts where name = 'A discount'), 'tonne', null, '{"kind": "flat", "amount": 500}');
select save_chart_version((select id from charts where name = 'A angle sizes'), 'tonne',
         jsonb_build_array(jsonb_build_object('size_id', (select id from sizes where display_name = 'Check angle'), 'amount', 100)));
update charts set is_active = false where name = 'A spare';

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
insert into charts (seller_id, segment_id, chart_type, name)
select '00000000-0000-0000-0000-0000000000b2', id, 'size', 'B sizes' from segments where name = 'TMT Bars';
select save_chart_version((select id from charts where name = 'B sizes'), 'kg',
         jsonb_build_array(jsonb_build_object('size_id',
           (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '8mm'),
           'amount', 0.5)));

-- Ids everyone in the checks can refer to.
select pg_temp.as_owner();
create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from segments where name = 'MS Angles') as angles,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from regions where level = 'district' and name = 'Kolhapur') as kolhapur,
       (select id from regions where level = 'district' and name = 'Sangli') as sangli,
       (select id from regions where level = 'district' and name = 'North Goa') as north_goa,
       (select id from regions where name = 'Check Haveli') as haveli,
       (select id from regions where name = 'Checkwadi') as checkwadi,
       (select id from regions where name = 'Check Kolhapur City') as kolhapur_city,
       (select id from regions where name = 'Check Unapproved') as unapproved,
       (select id from products where name = 'Fe500') as fe500,
       (select id from products where name = 'Fe500D') as fe500d,
       (select id from products where name = 'Fe550D') as fe550d,
       (select id from products where name = 'MS Equal Angle') as angle_grade,
       (select id from charts where name = 'A sizes') as a_sizes,
       (select id from charts where name = 'A sizes Fe550D') as a_sizes_550,
       (select id from charts where name = 'A loading') as a_loading,
       (select id from charts where name = 'A discount') as a_discount,
       (select id from charts where name = 'A spare') as a_spare,
       (select id from charts where name = 'A empty') as a_empty,
       (select id from charts where name = 'A angle sizes') as a_angle,
       (select id from charts where name = 'B sizes') as b_sizes;
grant select on k to public;

-- A's version 1 setup, as the list save_area_settings takes.
create temp table setup as
select jsonb_build_array(
  jsonb_build_object('region_id', mh, 'area_difference', 200, 'size_chart_id', a_sizes,
    'loading_chart_id', a_loading, 'discount_chart_id', a_discount, 'display_unit', 'tonne',
    'grades', jsonb_build_array(jsonb_build_object('product_id', fe550d, 'premium', 300),
                                jsonb_build_object('product_id', fe500d, 'premium', 150))),
  jsonb_build_object('region_id', pune, 'area_difference', 0,
    'grades', jsonb_build_array(jsonb_build_object('product_id', fe550d, 'premium', 0))),
  jsonb_build_object('region_id', haveli, 'display_unit', 'kg'),
  jsonb_build_object('region_id', kolhapur, 'excluded', true),
  jsonb_build_object('region_id', kolhapur_city, 'area_difference', 50),
  jsonb_build_object('region_id', sangli,
    'grades', jsonb_build_array(jsonb_build_object('product_id', fe500, 'sold', false),
                                jsonb_build_object('product_id', fe550d, 'size_chart_id', a_sizes_550)))
) as v1
from k;
grant select on setup to public;

-- One readable line per lookup: served or not, then each setting ("-" = none).
create function pg_temp.res(p_region uuid, p_grade uuid default null, p_version uuid default null)
returns text language sql as $$
  select case when r.is_served then 'served' else 'not served' end
      || ' | diff '     || coalesce(r.area_difference::text, '-')
      || ' | size '     || coalesce(sc.name, '-')
      || ' | loading '  || coalesce(lc.name, '-')
      || ' | discount ' || coalesce(dc.name, '-')
      || ' | unit '     || coalesce(r.display_unit::text, '-')
      || case when p_grade is null then '' else
           ' | premium ' || coalesce(r.grade_premium::text, '-') || ' | sold ' || coalesce(r.grade_sold_here::text, '-') end
    from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), p_region, p_grade, p_version) r
    left join charts sc on sc.id = r.size_chart_id
    left join charts lc on lc.id = r.loading_chart_id
    left join charts dc on dc.id = r.discount_chart_id
$$;

-- Structure -------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on',
  'area_grade_settings=true, area_setting_versions=true, area_settings=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace
       and relname in ('area_setting_versions', 'area_settings', 'area_grade_settings')$q$);
select pg_temp.expect_value('Amounts are stored as exact rupees', 'area_difference=rupees, grade_premium=rupees',
  $q$select string_agg(column_name || '=' || domain_name, ', ' order by column_name) from information_schema.columns
     where table_schema = 'public' and column_name in ('area_difference', 'grade_premium')$q$);

-- A saves version 1 -----------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_refused('Before A saves any area settings he serves nowhere: there is nothing to look up',
  $q$select * from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k))$q$);
select pg_temp.expect_value('A saves version 1', 'saved',
  $q$select case when save_area_settings((select tmt from k), (select v1 from setup)) is not null then 'saved' end$q$);
select pg_temp.expect_value('Version 1 records its unit (A''s unit for TMT)', 'v1 tonne',
  $q$select string_agg('v' || version_number || ' ' || unit, ', ') from area_setting_versions
     where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('"Not set" and zero are stored differently: Pune 0, Check Haveli not set',
  'Check Haveli=NOT SET, Pune=0',
  $q$select string_agg(r.name || '=' || coalesce(s.area_difference::text, 'NOT SET'), ', ' order by r.name)
     from area_settings s join regions r on r.id = s.region_id
     where r.id in ((select pune from k), (select haveli from k))$q$);

-- Looking settings up (version 1) ---------------------------------------------

select pg_temp.expect_value('Carry-down: Satara (not mentioned) gets everything from Maharashtra',
  'served | diff 200 | size A sizes | loading A loading | discount A discount | unit tonne',
  $q$select pg_temp.res((select satara from k))$q$);
select pg_temp.expect_value('Zero at district: Pune''s 0 is kept, not replaced by Maharashtra''s 200',
  'served | diff 0 | size A sizes | loading A loading | discount A discount | unit tonne',
  $q$select pg_temp.res((select pune from k))$q$);
select pg_temp.expect_value('Carry-down through every level: a city in Haveli in Pune gets 0 from Pune and kg from Haveli',
  'served | diff 0 | size A sizes | loading A loading | discount A discount | unit kg',
  $q$select pg_temp.res((select checkwadi from k))$q$);
select pg_temp.expect_value('Exclusion beats the state: Kolhapur is not served, and nothing is revealed',
  'not served | diff - | size - | loading - | discount - | unit -',
  $q$select pg_temp.res((select kolhapur from k))$q$);
select pg_temp.expect_value('A city the seller names inside excluded Kolhapur is served (most specific wins)',
  'served | diff 50 | size A sizes | loading A loading | discount A discount | unit tonne',
  $q$select pg_temp.res((select kolhapur_city from k))$q$);
select pg_temp.expect_value('No "everywhere" chosen: North Goa is not served',
  'not served | diff - | size - | loading - | discount - | unit -',
  $q$select pg_temp.res((select north_goa from k))$q$);

select pg_temp.expect_value('Grade premium zero at Pune: Fe550D premium 0 is kept, not replaced by 300',
  'served | diff 0 | size A sizes | loading A loading | discount A discount | unit tonne | premium 0 | sold true',
  $q$select pg_temp.res((select pune from k), (select fe550d from k))$q$);
select pg_temp.expect_value('Grade premium carries down: Fe550D at Satara is 300',
  'served | diff 200 | size A sizes | loading A loading | discount A discount | unit tonne | premium 300 | sold true',
  $q$select pg_temp.res((select satara from k), (select fe550d from k))$q$);
select pg_temp.expect_value('Each setting separately: Fe500D at Pune takes premium 150 from Maharashtra but diff 0 from Pune',
  'served | diff 0 | size A sizes | loading A loading | discount A discount | unit tonne | premium 150 | sold true',
  $q$select pg_temp.res((select pune from k), (select fe500d from k))$q$);
select pg_temp.expect_value('A grade with no premium set anywhere has none (not zero)',
  'served | diff 200 | size A sizes | loading A loading | discount A discount | unit tonne | premium - | sold true',
  $q$select pg_temp.res((select satara from k), (select fe500 from k))$q$);
select pg_temp.expect_value('Grade not sold: Fe500 is not sold in Sangli',
  'served | diff 200 | size A sizes | loading A loading | discount A discount | unit tonne | premium - | sold false',
  $q$select pg_temp.res((select sangli from k), (select fe500 from k))$q$);
select pg_temp.expect_value('Grade size chart: Fe550D in Sangli uses its own size chart',
  'served | diff 200 | size A sizes Fe550D | loading A loading | discount A discount | unit tonne | premium 300 | sold true',
  $q$select pg_temp.res((select sangli from k), (select fe550d from k))$q$);
select pg_temp.expect_value('Other grades in Sangli use the family size chart',
  'served | diff 200 | size A sizes | loading A loading | discount A discount | unit tonne | premium 150 | sold true',
  $q$select pg_temp.res((select sangli from k), (select fe500d from k))$q$);

-- "Everywhere" must be chosen explicitly ---------------------------------------

select pg_temp.expect_refused('An area with neither a region nor "everywhere"',
  $q$select save_area_settings((select tmt from k), '[{"area_difference": 500}]')$q$);
select pg_temp.expect_refused('An area with an empty region (not an explicit "everywhere")',
  $q$select save_area_settings((select tmt from k), '[{"region_id": null, "area_difference": 500}]')$q$);
select pg_temp.expect_refused('An area that is both a region and "everywhere"',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('everywhere', true, 'region_id', (select pune from k))))$q$);
select pg_temp.expect_refused('"Everywhere" given twice',
  $q$select save_area_settings((select tmt from k), '[{"everywhere": true}, {"everywhere": true}]')$q$);

select pg_temp.expect_value('A saves version 2: version 1 plus "everywhere" +500', 'saved',
  $q$select case when save_area_settings((select tmt from k),
       (select v1 from setup) || jsonb_build_array(jsonb_build_object('everywhere', true, 'area_difference', 500,
         'size_chart_id', (select a_sizes from k), 'loading_chart_id', (select a_loading from k),
         'discount_chart_id', (select a_discount from k)))) is not null then 'saved' end$q$);
select pg_temp.expect_value('With "everywhere" chosen, North Goa is served at +500',
  'served | diff 500 | size A sizes | loading A loading | discount A discount | unit -',
  $q$select pg_temp.res((select north_goa from k))$q$);
select pg_temp.expect_value('Kolhapur''s exclusion still beats "everywhere"',
  'not served | diff - | size - | loading - | discount - | unit -',
  $q$select pg_temp.res((select kolhapur from k))$q$);
select pg_temp.expect_value('Pune''s zero still beats "everywhere"',
  'served | diff 0 | size A sizes | loading A loading | discount A discount | unit tonne',
  $q$select pg_temp.res((select pune from k))$q$);
select pg_temp.expect_value('Looking up version 1 still gives North Goa not served',
  'not served | diff - | size - | loading - | discount - | unit -',
  $q$select pg_temp.res((select north_goa from k), null,
       (select id from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a1' and version_number = 1))$q$);

-- What a save refuses ---------------------------------------------------------

select pg_temp.expect_refused('A misspelt setting name is refused, never treated as "not set"',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k), 'area_diference', 0)))$q$);
select pg_temp.expect_refused('Using another seller''s chart',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k), 'size_chart_id', (select b_sizes from k))))$q$);
select pg_temp.expect_refused('A loading chart in the size chart slot',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k), 'size_chart_id', (select a_loading from k))))$q$);
select pg_temp.expect_refused('A size chart from another product family',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k), 'size_chart_id', (select a_angle from k))))$q$);
select pg_temp.expect_refused('A switched-off chart',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k), 'size_chart_id', (select a_spare from k))))$q$);
select pg_temp.expect_refused('A chart with no figures yet',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k), 'size_chart_id', (select a_empty from k))))$q$);
select pg_temp.expect_refused('An excluded area that also sets an area difference',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select kolhapur from k), 'excluded', true, 'area_difference', 0)))$q$);
select pg_temp.expect_refused('A grade from another product family',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k),
         'grades', jsonb_build_array(jsonb_build_object('product_id', (select angle_grade from k), 'premium', 100)))))$q$);
select pg_temp.expect_refused('The same area twice',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k)), jsonb_build_object('region_id', (select pune from k))))$q$);
select pg_temp.expect_refused('An unapproved area',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select unapproved from k))))$q$);
select pg_temp.expect_refused('Display unit other than tonne, kg, piece or metre',
  $q$select save_area_settings((select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select pune from k), 'display_unit', 'quintal')))$q$);
select pg_temp.expect_refused('Settings for a product family A does not deal in',
  $q$select save_area_settings((select angles from k), '[{"everywhere": true}]')$q$);
select pg_temp.expect_value('Refused saves left no half-made versions: A still has versions 1 and 2', '1, 2',
  $q$select string_agg(version_number::text, ', ' order by version_number) from area_setting_versions
     where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Old versions cannot be changed ---------------------------------------------

select pg_temp.as_owner();
create temp table avid as
select id from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a1';
grant select on avid to public;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_refused('A changes Pune''s area difference in version 1',
  $q$update area_settings set area_difference = 999 where version_id in (select id from avid)$q$);
select pg_temp.expect_refused('A changes a grade premium in version 1',
  $q$update area_grade_settings set grade_premium = 999$q$);
select pg_temp.expect_refused('A adds an area to version 1',
  $q$insert into area_settings (version_id, region_id, area_difference)
     select id, (select satara from k), 1 from area_setting_versions
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and version_number = 1$q$);
select pg_temp.expect_refused('A changes version 1''s unit',
  $q$update area_setting_versions set unit = 'kg' where id in (select id from avid)$q$);
select pg_temp.expect_refused('A deletes version 1',
  $q$delete from area_setting_versions where id in (select id from avid)$q$);

select pg_temp.as_owner();
select pg_temp.expect_refused('Even the database owner cannot change version 1',
  $q$update area_settings set area_difference = 999
     where version_id = (select id from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a1' and version_number = 1)$q$);
select pg_temp.expect_refused('Even the database owner cannot add an area to version 1',
  $q$insert into area_settings (version_id, region_id, area_difference)
     select id, (select satara from k), 1 from area_setting_versions
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and version_number = 1$q$);
select pg_temp.expect_refused('Even the database owner cannot delete version 1',
  $q$delete from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a1' and version_number = 1$q$);
select pg_temp.expect_value('Version 1 is exactly as saved: Pune still 0', '0',
  $q$select s.area_difference::text from area_settings s join area_setting_versions v on v.id = s.version_id
     where v.seller_id = '00000000-0000-0000-0000-0000000000a1' and v.version_number = 1 and s.region_id = (select pune from k)$q$);

-- Nobody else can read area settings -------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('Another seller reads A''s versions by id: nothing', '0',
  $q$select count(*)::text from area_setting_versions where id in (select id from avid)$q$);
select pg_temp.expect_value('Another seller reads A''s area settings: nothing', '0',
  $q$select count(*)::text from area_settings where version_id in (select id from avid)$q$);
select pg_temp.expect_value('Another seller reads any grade settings: nothing', '0',
  $q$select count(*)::text from area_grade_settings$q$);
select pg_temp.expect_refused('Another seller looks up A''s settings for Pune',
  $q$select * from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k))$q$);
select pg_temp.expect_refused('Another seller saves area settings for A',
  $q$select save_area_settings((select tmt from k), '[{"everywhere": true}]', '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('B saves his own settings', 'saved',
  $q$select case when save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0.2}]') is not null
     then 'saved' end$q$);
select pg_temp.expect_value('B''s version records his unit (kg)', 'v1 kg',
  $q$select 'v' || version_number || ' ' || unit from area_setting_versions
     where seller_id = '00000000-0000-0000-0000-0000000000b2'$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_value('A buyer reads A''s versions by id: nothing', '0',
  $q$select count(*)::text from area_setting_versions where id in (select id from avid)$q$);
select pg_temp.expect_value('A buyer reads any area settings: nothing', '0',
  $q$select count(*)::text from area_settings$q$);
select pg_temp.expect_refused('A buyer looks up A''s settings for his own area',
  $q$select * from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k))$q$);

select pg_temp.as_visitor();
select pg_temp.expect_refused('Visitor reads area setting versions', $q$select * from area_setting_versions$q$);
select pg_temp.expect_refused('Visitor reads area settings', $q$select * from area_settings$q$);
select pg_temp.expect_refused('Visitor reads grade settings', $q$select * from area_grade_settings$q$);
select pg_temp.expect_refused('Visitor looks up A''s settings',
  $q$select * from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k))$q$);
select pg_temp.expect_refused('Visitor saves area settings', $q$select save_area_settings((select tmt from k), '[]')$q$);

-- Admin manages any seller's settings -------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin reads A''s versions', '2',
  $q$select count(*)::text from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Admin looks up A''s settings for Pune', 'served, diff 0',
  $q$select case when is_served then 'served' else 'not served' end || ', diff ' || area_difference
     from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k))$q$);
select pg_temp.expect_value('Admin saves an empty setup for A (version 3: serves nowhere)', 'saved',
  $q$select case when save_area_settings((select tmt from k), '[]', '00000000-0000-0000-0000-0000000000a1') is not null
     then 'saved' end$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('With an empty setup, Satara is not served', 'not served | diff - | size - | loading - | discount - | unit -',
  $q$select pg_temp.res((select satara from k))$q$);

-- Deleting a seller's login removes his area settings -------------------------

select pg_temp.as_owner();
select pg_temp.expect_rows('Delete A''s login', 1,
  $q$delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Left for A: versions / areas', '0/0',
  $q$select (select count(*) from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a1') || '/' ||
            (select count(*) from area_settings where version_id in (select id from avid))$q$);
