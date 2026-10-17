-- ============================================================
-- Checks: area settings per brand line.
-- Covers: two brands of one seller in one family keep separate area
-- settings and version numbers; both can share one chart; each brand's
-- lookups use its own settings and its own offered sizes; saving for a
-- brand he doesn't sell is refused in plain words; a save or lookup without
-- a brand means Regular (transitional, until brands step 11); publishing
-- uses the Regular line until step 6.
-- Functions: save_area_settings, resolve_area_settings,
-- resolve_size_figures, publish_rates.
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller: TMT, sells Regular TMT and Check Tiscon TMT; closes 6 pm
--   T ...b2  another seller
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated');
insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'distributor', r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Sunil', '+919800000001'),
               ('00000000-0000-0000-0000-0000000000b2', 'Tara',  '+919800000002')) as x (id, name, phone)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;
insert into seller_profiles (account_id, store_name, region_id, is_public, market_close_time)
select x.id::uuid, x.store, r.id, true, '18:00'
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Sunil Steel'),
               ('00000000-0000-0000-0000-0000000000b2', 'Tara Traders')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;
insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id from (values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2')) as x (id)
 cross join (select id from segments where name = 'TMT Bars') s;

insert into brands (name, status) values ('Check Tiscon', 'approved'), ('Check Rods', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s where b.name in ('Check Tiscon', 'Check Rods') and s.name = 'TMT Bars';
insert into seller_brands (seller_id, brand_id, segment_id)
select '00000000-0000-0000-0000-0000000000a1', b.id, s.id from brands b, segments s
 where b.name = 'Check Tiscon' and s.name = 'TMT Bars';

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from brands where is_regular) as regular,
       (select id from brands where name = 'Check Tiscon') as tiscon,
       (select id from brands where name = 'Check Rods') as rods,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '8mm') as s8,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '10mm') as s10;
grant select on k to public;

-- S's one shared size chart and his two brands' sizes.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into charts (seller_id, segment_id, chart_type, name)
values ('00000000-0000-0000-0000-0000000000a1', (select tmt from k), 'size', 'S shared sizes');
select save_chart_version((select id from charts where name = 'S shared sizes'), 'tonne', jsonb_build_array(
  jsonb_build_object('size_id', (select s8 from k), 'amount', 500),
  jsonb_build_object('size_id', (select s10 from k), 'amount', 400)));
insert into seller_sizes (seller_id, brand_id, size_id, is_selected) values
  ('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select s8 from k), true),
  ('00000000-0000-0000-0000-0000000000a1', (select tiscon from k), (select s10 from k), true);

-- Separate settings per brand, sharing one chart --------------------------------------------

select pg_temp.expect_value('S saves Regular TMT: Maharashtra +200, shared chart (no brand given = Regular)', 'saved',
  $q$select case when save_area_settings((select tmt from k), jsonb_build_array(jsonb_build_object('region_id', (select mh from k),
       'area_difference', 200, 'size_chart_id', (select id from charts where name = 'S shared sizes')))) is not null then 'saved' end$q$);
select pg_temp.expect_value('S saves Check Tiscon TMT: Maharashtra +350, the same shared chart', 'saved',
  $q$select case when save_area_settings((select tmt from k), jsonb_build_array(jsonb_build_object('region_id', (select mh from k),
       'area_difference', 350, 'size_chart_id', (select id from charts where name = 'S shared sizes'))), null, (select tiscon from k))
       is not null then 'saved' end$q$);
select pg_temp.expect_value('S saves Check Tiscon again (+375)', 'saved',
  $q$select case when save_area_settings((select tmt from k), jsonb_build_array(jsonb_build_object('region_id', (select mh from k),
       'area_difference', 375, 'size_chart_id', (select id from charts where name = 'S shared sizes'))), null, (select tiscon from k))
       is not null then 'saved' end$q$);
select pg_temp.expect_value('Version numbers are counted per brand', 'Check Tiscon: v1, v2 | Regular TMT: v1',
  $q$select string_agg(x, ' | ' order by x) from (
       select brand_display_name(brand_id, segment_id) || ': ' || string_agg('v' || version_number, ', ' order by version_number) as x
         from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a1' group by brand_id, segment_id) t$q$);
select pg_temp.expect_value('Pune lookup per brand: each its own area difference', 'Regular 200, Tiscon 375',
  $q$select 'Regular ' || (select area_difference from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k)))
         || ', Tiscon ' || (select area_difference from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k),
                                                                              (select pune from k), null, null, (select tiscon from k)))$q$);
select pg_temp.expect_value('Both brands read the one shared chart; each offers its own sizes',
  'Regular: 8mm 500 | Tiscon: 10mm 400',
  $q$select 'Regular: ' || (select string_agg(display_name || ' ' || size_difference, ', ')
              from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k)) where is_offered)
         || ' | Tiscon: ' || (select string_agg(display_name || ' ' || size_difference, ', ')
              from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k),
                                        null, null, null, (select tiscon from k)) where is_offered)$q$);

-- Refusals --------------------------------------------------------------------------------

select pg_temp.expect_message('Saving for a brand he does not sell', 'Add Check Rods to the brands you sell first.',
  $q$select save_area_settings((select tmt from k), '[{"everywhere": true}]', null, (select rods from k))$q$);
select pg_temp.expect_message('Looking up a brand with no settings', 'No area settings found for this seller and product family',
  $q$select * from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k),
                                        null, null, (select rods from k))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('Another seller looks up S''s Tiscon settings',
  $q$select * from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k),
                                        null, null, (select tiscon from k))$q$);
select pg_temp.expect_refused('Another seller saves S''s Tiscon settings',
  $q$select save_area_settings((select tmt from k), '[{"everywhere": true}]', '00000000-0000-0000-0000-0000000000a1', (select tiscon from k))$q$);

-- Publishing uses the Regular line until step 6 ---------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('S publishes TMT 41000', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41000)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('The publish pinned the Regular line''s area settings, not Tiscon''s', 'Regular TMT v1',
  $q$select brand_display_name(av.brand_id, av.segment_id) || ' v' || av.version_number
     from publish_items pi join area_setting_versions av on av.id = pi.area_setting_version_id
     join publishes p on p.id = pi.publish_id where p.seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
