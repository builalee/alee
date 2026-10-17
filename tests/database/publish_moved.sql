-- ============================================================
-- Checks: four-tap publishing ("move everything by +/- Rs X").
-- Covers: the pre-fill list shows every brand line with its last rate; one
-- amount per product family, each in that family's unit; one publish for
-- everything moved; lines never published and lines "not quoting" are left
-- out; plain refusals (nothing to move, unit changed, rate at or below
-- zero, more than one amount per family); only the seller or an admin.
-- Functions: publish_prefill, publish_moved.
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller, closes 6 pm. TMT per tonne: Regular (41000), Check
--            Tiscon (43000), Check Rods (never published). Channels per kg:
--            Regular (52).
--   T ...b2  another seller      C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');
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
insert into seller_segments (seller_id, segment_id, base_unit)
select '00000000-0000-0000-0000-0000000000a1', s.id, x.unit::unit
  from (values ('TMT Bars', 'tonne'), ('MS Channels', 'kg')) as x (name, unit) join segments s on s.name = x.name;

insert into brands (name, status) values ('Check Tiscon', 'approved'), ('Check Rods', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s where b.name in ('Check Tiscon', 'Check Rods') and s.name = 'TMT Bars';
insert into seller_brands (seller_id, brand_id, segment_id)
select '00000000-0000-0000-0000-0000000000a1', b.id, s.id from brands b, segments s
 where b.name in ('Check Tiscon', 'Check Rods') and s.name = 'TMT Bars';

-- Test sellers sell Regular in each family they deal in.
select pg_temp.sell_regular();

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from segments where name = 'MS Channels') as channels,
       (select id from segments where name = 'MS Angles') as angles,
       (select id from brands where is_regular) as regular,
       (select id from brands where name = 'Check Tiscon') as tiscon,
       (select id from brands where name = 'Check Rods') as rods;
grant select on k to public;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]', null, (select id from brands where is_regular));
select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]', null, (select tiscon from k));
select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]', null, (select rods from k));
select save_area_settings((select channels from k), '[{"everywhere": true, "area_difference": 0}]', null, (select id from brands where is_regular));
select publish_rates(jsonb_build_array(
  jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41000, 'brand_id', (select id from brands where is_regular)),
  jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select tiscon from k), 'base_rate', 43000),
  jsonb_build_object('segment_id', (select channels from k), 'base_rate', 52, 'brand_id', (select id from brands where is_regular))));

create function pg_temp.latest() returns text language sql as $$
  select string_agg(line_name || ' ' || coalesce(last_base_rate::text, '-') || coalesce('/' || last_unit, ''), ', ' order by line_name)
    from publish_prefill('00000000-0000-0000-0000-0000000000a1')
$$;
create function pg_temp.publishes() returns bigint language sql as $$
  select count(*) from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1'
$$;

-- Pre-fill ------------------------------------------------------------------------------

select pg_temp.expect_value('The pre-fill lists every brand line with its last rate and unit',
  'Check Rods -, Check Tiscon 43000/tonne, Regular Channels 52/kg, Regular TMT 41000/tonne',
  $q$select pg_temp.latest()$q$);

-- Moving everything --------------------------------------------------------------------

select pg_temp.expect_value('S moves TMT +200 per tonne and Channels +0.5 per kg in one tap', 'published',
  $q$select case when publish_moved(jsonb_build_array(
       jsonb_build_object('segment_id', (select tmt from k), 'amount', 200),
       jsonb_build_object('segment_id', (select channels from k), 'amount', 0.5))) is not null then 'published' end$q$);
select pg_temp.expect_value('Every published line moved by its family''s amount; Rods (never published) left out',
  'Check Rods -, Check Tiscon 43200/tonne, Regular Channels 52.5/kg, Regular TMT 41200/tonne',
  $q$select pg_temp.latest()$q$);
select pg_temp.expect_value('It was one publish (one notification) covering three lines', '2 publishes, latest has 3 lines',
  $q$select pg_temp.publishes() || ' publishes, latest has ' ||
            (select count(*) from publish_items where publish_id = (select id from publishes
               where seller_id = '00000000-0000-0000-0000-0000000000a1' order by publish_number desc limit 1)) || ' lines'$q$);

select pg_temp.expect_value('S switches Check Tiscon to "not quoting"', 'false',
  $q$select set_quoting((select tmt from k), false, null, (select tiscon from k))::text$q$);
select pg_temp.expect_value('Moving TMT -500 leaves the not-quoting Tiscon out (and off)', 'published',
  $q$select case when publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', -500)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('Regular TMT moved; Tiscon unchanged and still not quoting',
  'Check Rods -, Check Tiscon 43200/tonne, Regular Channels 52.5/kg, Regular TMT 40700/tonne; Tiscon not_quoting',
  $q$select pg_temp.latest() || '; Tiscon ' || (select status from market_status('00000000-0000-0000-0000-0000000000a1',
       (select tmt from k), null, (select tiscon from k)))$q$);
select pg_temp.expect_value('S moves Channels by 0', 'published',
  $q$select case when publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'amount', 0)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('A move of 0 republishes unchanged', 'Regular Channels 52.5/kg, 4 publishes',
  $q$select 'Regular Channels ' || last_base_rate || '/' || last_unit || ', ' || pg_temp.publishes() || ' publishes'
     from publish_prefill('00000000-0000-0000-0000-0000000000a1') where line_name = 'Regular Channels'$q$);

-- Refusals ------------------------------------------------------------------------------

select pg_temp.expect_message('A move taking a rate to zero or below', 'Moving TMT Bars by -40700 would take Regular TMT to zero or below.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', -40700)))$q$);
select pg_temp.expect_message('Two amounts for one family', 'Give one amount per product family.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', 1),
                                            jsonb_build_object('segment_id', (select tmt from k), 'amount', 2)))$q$);
select pg_temp.expect_message('No amount given', 'Enter the amount to move TMT Bars by (0 to keep it unchanged).',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k))))$q$);
select pg_temp.expect_message('A family with nothing published', 'There is nothing in MS Angles to move: publish its rates first.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select angles from k), 'amount', 1)))$q$);
select pg_temp.expect_refused('An amount finer than 4 decimal places',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', 0.12345)))$q$);
select pg_temp.expect_rows('S now prices TMT per kg', 1,
  $q$update seller_segments set base_unit = 'kg' where seller_id = '00000000-0000-0000-0000-0000000000a1' and segment_id = (select tmt from k)$q$);
select pg_temp.expect_message('A family whose unit changed since its last publish',
  'You now price TMT Bars per kg but last published it per tonne. Enter today''s rates instead.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', 1)))$q$);
select pg_temp.expect_value('Refused moves published nothing', '4',
  $q$select pg_temp.publishes()::text$q$);

-- Who may move -------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('Another seller moves S''s rates',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'amount', 1)),
                          '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('Another seller''s pre-fill of S shows no rates', '(nothing)',
  $q$select string_agg(last_base_rate::text, ',') from publish_prefill('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('A visitor moves rates',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'amount', 1)))$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('An admin moves Channels for S, recorded as admin', 'published by admin',
  $q$select case when publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'amount', 1)),
                                    '00000000-0000-0000-0000-0000000000a1') is not null then 'published by admin' end$q$);
select pg_temp.expect_value('...recorded as an admin publish', 'true',
  $q$select by_admin::text from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1' order by publish_number desc limit 1$q$);
