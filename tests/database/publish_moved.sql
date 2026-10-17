-- ============================================================
-- Checks: four-tap publishing ("move everything by +/- Rs X").
-- Covers: the pre-fill list shows every brand line with its last rate and
-- what will happen to it (move, needs a rate, unit changed, not quoting);
-- one amount per product family, in that family's unit; lines with no rate
-- yet and families whose unit changed are never silently skipped: their
-- rates are entered and go out in the same single publish; paused lines
-- are left untouched; plain refusals; only the seller or an admin.
-- Functions: publish_prefill, publish_moved.
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller, closes 6 pm. TMT per tonne: Regular (41000), Check
--            Tiscon (43000), Check Rods (no rate yet). Channels per kg:
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
select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]', null, (select regular from k));
select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]', null, (select tiscon from k));
select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]', null, (select rods from k));
select save_area_settings((select channels from k), '[{"everywhere": true, "area_difference": 0}]', null, (select regular from k));
select publish_rates(jsonb_build_array(
  jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select regular from k), 'base_rate', 41000),
  jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select tiscon from k), 'base_rate', 43000),
  jsonb_build_object('segment_id', (select channels from k), 'brand_id', (select regular from k), 'base_rate', 52)));

create function pg_temp.lines() returns text language sql as $$
  select string_agg(line_name || ' ' || coalesce(last_base_rate::text, '-') || coalesce('/' || last_unit, '') || ' [' || move_status || ']',
                    ', ' order by line_name)
    from publish_prefill('00000000-0000-0000-0000-0000000000a1')
$$;
create function pg_temp.publishes() returns bigint language sql as $$
  select count(*) from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1'
$$;
create function pg_temp.latest_lines() returns bigint language sql as $$
  select count(*) from publish_items where publish_id = (select id from publishes
    where seller_id = '00000000-0000-0000-0000-0000000000a1' order by publish_number desc limit 1)
$$;

-- The pre-fill list says what will happen to each line ------------------------------------

select pg_temp.expect_value('Pre-fill: every brand line, its last rate, and what happens to it',
  'Check Rods - [needs_rate], Check Tiscon 43000/tonne [move], Regular Channels 52/kg [move], Regular TMT 41000/tonne [move]',
  $q$select pg_temp.lines()$q$);

-- A line with no rate yet is never silently skipped ---------------------------------------

select pg_temp.expect_message('Moving TMT without entering a rate for Check Rods', 'Enter today''s rate for Check Rods before publishing.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', 200)))$q$);
select pg_temp.expect_value('Nothing was published by the refusal', '1', $q$select pg_temp.publishes()::text$q$);
select pg_temp.expect_value('S moves TMT +200, Channels +0.5, and enters Check Rods at 42000: one tap', 'published',
  $q$select case when publish_moved(
       jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', 200),
                         jsonb_build_object('segment_id', (select channels from k), 'amount', 0.5)),
       null,
       jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select rods from k), 'base_rate', 42000)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('Moved lines moved, Check Rods went out at its entered rate',
  'Check Rods 42000/tonne [move], Check Tiscon 43200/tonne [move], Regular Channels 52.5/kg [move], Regular TMT 41200/tonne [move]',
  $q$select pg_temp.lines()$q$);
select pg_temp.expect_value('All in one publish (one notification): four lines', '2 publishes, latest has 4 lines',
  $q$select pg_temp.publishes() || ' publishes, latest has ' || pg_temp.latest_lines() || ' lines'$q$);

-- Paused lines are listed and left untouched -------------------------------------------------

select pg_temp.expect_value('S pauses Check Tiscon ("not quoting")', 'false',
  $q$select set_quoting((select tmt from k), false, null, (select tiscon from k))::text$q$);
select pg_temp.expect_value('The pre-fill lists Tiscon as not quoting',
  'Check Rods 42000/tonne [move], Check Tiscon 43200/tonne [not_quoting], Regular Channels 52.5/kg [move], Regular TMT 41200/tonne [move]',
  $q$select pg_temp.lines()$q$);
select pg_temp.expect_message('Entering a rate for the paused line', 'Check Tiscon is not quoting today. Switch it back on first, or leave it out.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', -500)), null,
       jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select tiscon from k), 'base_rate', 43000)))$q$);
select pg_temp.expect_value('Moving TMT -500 leaves the paused Tiscon untouched', 'published',
  $q$select case when publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', -500)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('Rods and Regular moved; Tiscon unchanged and still not quoting',
  'Check Rods 41500/tonne [move], Check Tiscon 43200/tonne [not_quoting], Regular Channels 52.5/kg [move], Regular TMT 40700/tonne [move]; Tiscon not_quoting',
  $q$select pg_temp.lines() || '; Tiscon ' || (select status from market_status('00000000-0000-0000-0000-0000000000a1',
       (select tmt from k), null, (select tiscon from k)))$q$);
select pg_temp.expect_message('Entering a rate for a line that is being moved', 'Regular TMT is already being moved; enter a rate only for lines that need one.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', 1)), null,
       jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select regular from k), 'base_rate', 1)))$q$);

-- A family whose unit changed needs fresh rates, in the same publish ----------------------

select pg_temp.expect_rows('S now prices TMT per kg', 1,
  $q$update seller_segments set base_unit = 'kg' where seller_id = '00000000-0000-0000-0000-0000000000a1' and segment_id = (select tmt from k)$q$);
select pg_temp.expect_value('The pre-fill flags every quoting TMT line as needing a fresh rate',
  'Check Rods 41500/tonne [unit_changed], Check Tiscon 43200/tonne [not_quoting], Regular Channels 52.5/kg [move], Regular TMT 40700/tonne [unit_changed]',
  $q$select pg_temp.lines()$q$);
select pg_temp.expect_message('Moving TMT without fresh rates', 'Enter today''s rate for Check Rods, Regular TMT before publishing.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', 1)))$q$);
select pg_temp.expect_value('S enters fresh per-kg TMT rates and moves Channels +1 in one tap', 'published',
  $q$select case when publish_moved(
       jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'amount', 0),
                         jsonb_build_object('segment_id', (select channels from k), 'amount', 1)),
       null,
       jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select regular from k), 'base_rate', 40.7),
                         jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select rods from k), 'base_rate', 41.5)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('Fresh rates went out per kg and Channels moved, in one publish of three lines',
  'Check Rods 41.5/kg [move], Check Tiscon 43200/tonne [not_quoting], Regular Channels 53.5/kg [move], Regular TMT 40.7/kg [move]; 3 lines',
  $q$select pg_temp.lines() || '; ' || pg_temp.latest_lines() || ' lines'$q$);

-- Other refusals ------------------------------------------------------------------------------

select pg_temp.expect_message('A move taking a rate to zero or below', 'Moving MS Channels by -53.5 would take Regular Channels to zero or below.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'amount', -53.5)))$q$);
select pg_temp.expect_message('Two amounts for one family', 'Give one amount per product family.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'amount', 1),
                                            jsonb_build_object('segment_id', (select channels from k), 'amount', 2)))$q$);
select pg_temp.expect_message('No amount given', 'Enter the amount to move MS Channels by (0 to keep it unchanged).',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k))))$q$);
select pg_temp.expect_message('A family he has no brands in', 'There is nothing in MS Angles to move: add a brand to it first.',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select angles from k), 'amount', 1)))$q$);
select pg_temp.expect_refused('An amount finer than 4 decimal places',
  $q$select publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'amount', 0.12345)))$q$);
select pg_temp.expect_value('Refused moves published nothing', '4', $q$select pg_temp.publishes()::text$q$);

-- Who may move ---------------------------------------------------------------------------------

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
select pg_temp.expect_value('An admin moves Channels for S', 'published',
  $q$select case when publish_moved(jsonb_build_array(jsonb_build_object('segment_id', (select channels from k), 'amount', 1)),
                                    '00000000-0000-0000-0000-0000000000a1') is not null then 'published' end$q$);
select pg_temp.expect_value('...recorded as an admin publish', 'true',
  $q$select by_admin::text from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1' order by publish_number desc limit 1$q$);
