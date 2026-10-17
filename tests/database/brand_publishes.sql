-- ============================================================
-- Checks: publishing and status per brand line.
-- Covers: one publish covering several brands and families (one
-- notification); each item records its brand; latest publish per brand
-- line; refusals name the brand in plain words; not quoting, close market
-- now and open / closed per brand line; publishing one brand reopens and
-- resumes only that brand; "close market now" with nothing named closes
-- every open brand line; a brand's publish rebuilds exactly from its own
-- pinned chart versions; an item, switch or status that names no brand is
-- refused (Regular must be named too).
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller, closes 6 pm. TMT: Regular, Check Tiscon (both set up),
--            Check Rods (no area settings). Channels: Regular.
-- ============================================================

insert into auth.users (id, phone, aud, role)
values ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated');
insert into accounts (id, full_name, phone, signup_role, region_id)
select '00000000-0000-0000-0000-0000000000a1', 'Sunil', '+919800000001', 'distributor', id
  from regions where level = 'district' and name = 'Pune';
insert into seller_profiles (account_id, store_name, region_id, is_public, market_close_time)
select '00000000-0000-0000-0000-0000000000a1', 'Sunil Steel', id, true, '18:00'
  from regions where level = 'district' and name = 'Pune';
insert into seller_segments (seller_id, segment_id)
select '00000000-0000-0000-0000-0000000000a1', id from segments where name in ('TMT Bars', 'MS Channels');

insert into brands (name, status) values ('Check Tiscon', 'approved'), ('Check Rods', 'approved'), ('Check Kamdhenu', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s
 where b.name in ('Check Tiscon', 'Check Rods', 'Check Kamdhenu') and s.name = 'TMT Bars';
insert into seller_brands (seller_id, brand_id, segment_id)
select '00000000-0000-0000-0000-0000000000a1', b.id, s.id from brands b, segments s
 where b.name in ('Check Tiscon', 'Check Rods') and s.name = 'TMT Bars';

-- Test sellers sell Regular in each family they deal in.
select pg_temp.sell_regular();

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from segments where name = 'MS Channels') as channels,
       (select id from brands where is_regular) as regular,
       (select id from brands where name = 'Check Tiscon') as tiscon,
       (select id from brands where name = 'Check Rods') as rods,
       (select id from brands where name = 'Check Kamdhenu') as kamdhenu,
       (select id from regions where level = 'state' and name = 'Goa') as goa,
       (select id from regions where level = 'district' and name = 'Pune') as pune;
grant select on k to public;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into charts (seller_id, segment_id, chart_type, name) values
  ('00000000-0000-0000-0000-0000000000a1', (select tmt from k), 'loading', 'S loading'),
  ('00000000-0000-0000-0000-0000000000a1', (select tmt from k), 'size', 'S extra');
select save_chart_version((select id from charts where name = 'S loading'), 'tonne', '[{"size_id": null, "amount": 250}]');
select save_chart_version((select id from charts where name = 'S extra'), 'tonne', jsonb_build_array(jsonb_build_object('size_id',
  (select z.id from sizes z where z.segment_id = (select tmt from k) and z.display_name = '8mm'), 'amount', 100)));

create temp table setup as
select jsonb_build_array(jsonb_build_object('everywhere', true, 'area_difference', 0,
         'loading_chart_id', (select id from charts where name = 'S loading'))) as regular_tmt,
       jsonb_build_array(jsonb_build_object('everywhere', true, 'area_difference', 100,
         'loading_chart_id', (select id from charts where name = 'S loading'))) as tiscon_tmt;
grant select on setup to public;

select save_area_settings((select tmt from k), (select regular_tmt from setup), null, (select id from brands where is_regular));
select save_area_settings((select tmt from k), (select tiscon_tmt from setup), null, (select tiscon from k));
select save_area_settings((select channels from k), '[{"everywhere": true, "area_difference": 0}]', null, (select id from brands where is_regular));

-- Shows each brand line's latest basic rate.
create function pg_temp.latest() returns text language sql as $$
  select string_agg(brand_display_name(st.brand_id, st.segment_id) || ' ' || pi.base_rate, ', '
                    order by brand_display_name(st.brand_id, st.segment_id))
    from seller_family_status st
    join publish_items pi on pi.publish_id = st.latest_publish_id and pi.brand_id = st.brand_id and pi.segment_id = st.segment_id
   where st.seller_id = '00000000-0000-0000-0000-0000000000a1'
$$;
create function pg_temp.status(p_seg uuid, p_brand uuid) returns text language sql as $$
  select status from market_status('00000000-0000-0000-0000-0000000000a1', p_seg, null, p_brand)
$$;

-- One publish, many brands ---------------------------------------------------------

select pg_temp.expect_value('S publishes Regular TMT, Check Tiscon TMT and Regular Channels in one action', 'published',
  $q$select case when publish_rates(jsonb_build_array(
       jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41000, 'brand_id', (select id from brands where is_regular)),
       jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select tiscon from k), 'base_rate', 43000),
       jsonb_build_object('segment_id', (select channels from k), 'brand_id', (select regular from k), 'base_rate', 52000)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('It is one publish (one notification) with three brand lines', '1 publish, 3 items',
  $q$select count(distinct p.id) || ' publish, ' || count(*) || ' items'
     from publishes p join publish_items pi on pi.publish_id = p.id where p.seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Each item records its brand', 'Check Tiscon 43000, Regular Channels 52000, Regular TMT 41000',
  $q$select pg_temp.latest()$q$);
select pg_temp.expect_value('Each brand line pinned its own area settings and the shared chart',
  'Check Tiscon: area v1, S loading v1 | Regular TMT: area v1, S loading v1',
  $q$select string_agg(brand_display_name(pi.brand_id, pi.segment_id) || ': area v' || av.version_number || ', ' ||
            (select string_agg(c.name || ' v' || cv.version_number, ', ') from publish_chart_versions pcv
               join charts c on c.id = pcv.chart_id join chart_versions cv on cv.id = pcv.chart_version_id
              where pcv.publish_id = pi.publish_id and pcv.brand_id = pi.brand_id and pcv.segment_id = pi.segment_id),
            ' | ' order by brand_display_name(pi.brand_id, pi.segment_id))
     from publish_items pi join area_setting_versions av on av.id = pi.area_setting_version_id
     where pi.segment_id = (select tmt from k)$q$);

select pg_temp.expect_value('S publishes Check Tiscon TMT alone (43500)', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k),
       'brand_id', (select tiscon from k), 'base_rate', 43500))) is not null then 'published' end$q$);
select pg_temp.expect_value('Latest per brand line: only Tiscon moved', 'Check Tiscon 43500, Regular Channels 52000, Regular TMT 41000',
  $q$select pg_temp.latest()$q$);

-- Refusals name the brand ------------------------------------------------------------

select pg_temp.expect_message('An item that names no brand', 'Choose which brand of TMT Bars you are publishing.',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41000)))$q$);
select pg_temp.expect_message('Not quoting without naming a brand', 'Name the brand (Regular is a brand too).',
  $q$select set_quoting((select tmt from k), false)$q$);
select pg_temp.expect_message('Market status without naming a brand', 'Name the brand (Regular is a brand too).',
  $q$select * from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);

select pg_temp.expect_message('A brand with no area settings', 'Choose where you sell Check Rods TMT before publishing.',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select rods from k), 'base_rate', 1)))$q$);
select pg_temp.expect_message('A brand he does not sell', 'Add Check Kamdhenu TMT to the brands you sell before publishing it.',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select kamdhenu from k), 'base_rate', 1)))$q$);
select pg_temp.expect_message('No basic rate for a brand', 'Enter your basic rate for Check Tiscon TMT.',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select tiscon from k))))$q$);
select pg_temp.expect_message('The same brand and family twice', 'Each brand of each product family can appear only once in a publish.',
  $q$select publish_rates(jsonb_build_array(
       jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select tiscon from k), 'base_rate', 1),
       jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select tiscon from k), 'base_rate', 2)))$q$);

select save_area_settings((select tmt from k), (select tiscon_tmt from setup) || jsonb_build_array(
  jsonb_build_object('region_id', (select goa from k), 'size_chart_id', (select id from charts where name = 'S extra'))),
  null, (select tiscon from k));
update charts set is_active = false where name = 'S extra';
select pg_temp.expect_message('A switched-off chart, on a branded line, names the brand first',
  'Check Tiscon TMT: Goa still uses ''S extra'', which you switched off. Choose a chart for Goa.',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select tiscon from k), 'base_rate', 1)))$q$);
select pg_temp.expect_value('Regular TMT is not held up by Tiscon''s problem', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41100, 'brand_id', (select id from brands where is_regular))))
     is not null then 'published' end$q$);
select save_area_settings((select tmt from k), (select tiscon_tmt from setup), null, (select tiscon from k));

-- Not quoting, per brand line --------------------------------------------------------

select pg_temp.expect_value('S stops quoting Check Tiscon TMT', 'false',
  $q$select set_quoting((select tmt from k), false, null, (select tiscon from k))::text$q$);
select pg_temp.expect_value('Tiscon not quoting; Regular TMT open', 'not_quoting / open',
  $q$select pg_temp.status((select tmt from k), (select tiscon from k)) || ' / ' || pg_temp.status((select tmt from k), (select regular from k))$q$);
select pg_temp.expect_value('Publishing Regular TMT does not switch Tiscon back on', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41200, 'brand_id', (select id from brands where is_regular))))
     is not null then 'published' end$q$);
select pg_temp.expect_value('Tiscon still not quoting', 'not_quoting', $q$select pg_temp.status((select tmt from k), (select tiscon from k))$q$);
select pg_temp.expect_value('Publishing Tiscon switches Tiscon back on', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k),
       'brand_id', (select tiscon from k), 'base_rate', 43600))) is not null then 'published' end$q$);
select pg_temp.expect_value('Tiscon open again; history kept for Tiscon only', 'open; Check Tiscon: stopped_quoting, resumed_quoting',
  $q$select pg_temp.status((select tmt from k), (select tiscon from k)) || '; ' ||
            string_agg(brand_display_name(brand_id, segment_id) || ': ' || x, '; ')
     from (select brand_id, segment_id, string_agg(event::text, ', ' order by happened_at) x
             from seller_family_status_history where seller_id = '00000000-0000-0000-0000-0000000000a1'
            group by brand_id, segment_id) h$q$);

-- Close market now, per brand line ----------------------------------------------------

select pg_temp.expect_value('S closes Check Tiscon TMT only', '1',
  $q$select close_market_now(array[(select tmt from k)], null, array[(select tiscon from k)])::text$q$);
select pg_temp.expect_value('Tiscon closed; Regular TMT and Channels still open', 'closed / open / open',
  $q$select pg_temp.status((select tmt from k), (select tiscon from k)) || ' / ' || pg_temp.status((select tmt from k), (select regular from k))
            || ' / ' || pg_temp.status((select channels from k), (select regular from k))$q$);
select pg_temp.expect_value('"Close market now" with nothing named closes every other open brand line', '2',
  $q$select close_market_now()::text$q$);
select pg_temp.expect_value('Everything is closed (Rods never published)', 'closed / closed / closed / not_published',
  $q$select pg_temp.status((select tmt from k), (select tiscon from k)) || ' / ' || pg_temp.status((select tmt from k), (select regular from k))
            || ' / ' || pg_temp.status((select channels from k), (select regular from k))
            || ' / ' || pg_temp.status((select tmt from k), (select rods from k))$q$);
select pg_temp.expect_value('Publishing Regular Channels reopens only Regular Channels', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'base_rate', 52100, 'brand_id', (select id from brands where is_regular))))
     is not null then 'published' end$q$);
select pg_temp.expect_value('Channels open; TMT lines still closed', 'open / closed / closed',
  $q$select pg_temp.status((select channels from k), (select regular from k)) || ' / ' || pg_temp.status((select tmt from k), (select tiscon from k))
            || ' / ' || pg_temp.status((select tmt from k), (select regular from k))$q$);
select pg_temp.as_visitor();
select pg_temp.expect_value('Anyone can see a brand line''s status', 'closed',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k), null, (select tiscon from k))$q$);

-- A brand's publish rebuilds exactly ----------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.as_owner();
create temp table tis as
select pi.publish_id from publish_items pi join publishes p on p.id = pi.publish_id
 where p.seller_id = '00000000-0000-0000-0000-0000000000a1' and pi.brand_id = (select tiscon from k)
 order by p.publish_number desc limit 1;
grant select on tis to public;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('S changes the shared loading chart to 300', 'saved',
  $q$select case when save_chart_version((select id from charts where name = 'S loading'), 'tonne', '[{"size_id": null, "amount": 300}]')
     is not null then 'saved' end$q$);
select pg_temp.expect_value('Today Tiscon''s loading is 300; its last publish still rebuilds at 250', 'now 300, as published 250',
  $q$select 'now ' || (select loading from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k),
                                                              null, null, null, (select tiscon from k)) where display_name = '8mm')
         || ', as published ' || (select loading from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k),
                                     (select pune from k), null, null, (select publish_id from tis), (select tiscon from k)) where display_name = '8mm')$q$);
select pg_temp.expect_refused('Rebuilding the Tiscon publish as another brand (Rods) is refused',
  $q$select * from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k),
                                       null, null, (select publish_id from tis), (select rods from k))$q$);
