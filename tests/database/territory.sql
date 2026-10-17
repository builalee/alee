-- ============================================================
-- Checks: territory allocation.
-- Covers: an offer has no effect until accepted; a decline leaves no
-- allocation; the closer area wins (Satara district to D1, Karad taluka to
-- D2); a second distributor cannot be given the same area and family; a
-- different family in the same area can go to another distributor; both
-- types; the type can change only while an offer; ending (by either side)
-- restores the manufacturer; withdrawing an offer; who may do what; admin
-- actions recorded as admin; allocations in effect are public, offers are
-- not; the manufacturer cannot read the distributor's rates through any
-- route; history and allocations cannot be changed or deleted.
-- Tables: territory_allocations, territory_allocation_events.
-- Functions: offer_territory, change_territory_type, respond_to_territory,
-- end_territory, resolve_territory, territory_effect.
-- Territory is per brand (decisions 2.43): M owns Check Steel (TMT and
-- Angles) and allocates it. Check Rods has no owner.
--
-- Test people (temporary logins, rolled back):
--   M  ...a1  manufacturer: TMT and MS Angles; serves all of Maharashtra
--   D1 ...b2  distributor: TMT; has published his own rates
--   D2 ...d4  distributor
--   E  ...e5  buyer (no seller profile)
--   C  ...c3  admin
-- Areas: Satara district > Check Karad (taluka) > Check Karad City (city);
--        Check Satara City (city directly in Satara district).
-- ============================================================

-- Test data -------------------------------------------------------------------

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d4', '919800000004', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', '919800000005', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Mohan', '+919800000001', 'manufacturer'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala',  '+919800000002', 'distributor'),
               ('00000000-0000-0000-0000-0000000000d4', 'Dev',   '+919800000004', 'distributor'),
               ('00000000-0000-0000-0000-0000000000e5', 'Esha',  '+919800000005', 'retailer')) as x (id, name, phone, role)
 cross join (select id from regions where level = 'district' and name = 'Satara') r;

insert into seller_profiles (account_id, store_name, region_id, is_public, market_close_time)
select x.id::uuid, x.store, r.id, true, '18:00'
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Mohan Steel Mills'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala Traders'),
               ('00000000-0000-0000-0000-0000000000d4', 'Dev Distributors')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Satara') r;

insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'TMT Bars'),
               ('00000000-0000-0000-0000-0000000000a1', 'MS Angles'),
               ('00000000-0000-0000-0000-0000000000b2', 'TMT Bars'),
               ('00000000-0000-0000-0000-0000000000d4', 'TMT Bars')) as x (id, segment)
  join segments s on s.name = x.segment;

insert into regions (name, level, parent_id, is_approved)
select 'Check Karad', 'taluka', id, true from regions where level = 'district' and name = 'Satara';
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad City', 'city', id, true from regions where name = 'Check Karad';
insert into regions (name, level, parent_id, is_approved)
select 'Check Satara City', 'city', id, true from regions where level = 'district' and name = 'Satara';
insert into regions (name, level, parent_id, is_approved)
select 'Check Unapproved', 'city', id, false from regions where level = 'district' and name = 'Satara';

-- M owns Check Steel, claimed and approved the normal way.
insert into brands (name, status) values ('Check Steel', 'approved'), ('Check Rods', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s
 where (b.name = 'Check Steel' and s.name in ('TMT Bars', 'MS Angles')) or (b.name = 'Check Rods' and s.name = 'TMT Bars');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select claim_brand((select id from brands where name = 'Check Steel'));
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_brand_claim(id, true) from brand_claims where brand_id = (select id from brands where name = 'Check Steel');
select pg_temp.as_owner();

-- Test sellers sell Regular in each family they deal in.
select pg_temp.sell_regular();

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from brands where name = 'Check Steel') as steel,
       (select id from brands where name = 'Check Rods') as rods,
       (select id from brands where is_regular) as regular,
       (select id from segments where name = 'MS Angles') as angles,
       (select id from segments where name = 'MS Channels') as channels,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select id from regions where name = 'Check Karad') as karad,
       (select id from regions where name = 'Check Karad City') as karad_city,
       (select id from regions where name = 'Check Satara City') as satara_city,
       (select id from regions where name = 'Check Unapproved') as unapproved;
grant select on k to public;

-- M serves all of Maharashtra for TMT.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select save_area_settings((select tmt from k), jsonb_build_array(jsonb_build_object('region_id', (select mh from k), 'area_difference', 0)), null, (select id from brands where is_regular));

-- D1 has his own area settings, chart and a publish (his rates).
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
insert into charts (seller_id, segment_id, chart_type, name)
values ('00000000-0000-0000-0000-0000000000b2', (select tmt from k), 'loading', 'D1 loading');
select save_chart_version((select id from charts where name = 'D1 loading'), 'tonne', '[{"size_id": null, "amount": 180}]');
select save_area_settings((select tmt from k), jsonb_build_array(jsonb_build_object('region_id', (select satara from k),
  'area_difference', 150, 'loading_chart_id', (select id from charts where name = 'D1 loading'))), null, (select id from brands where is_regular));
select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 44000, 'brand_id', (select id from brands where is_regular))));

select pg_temp.as_owner();
create temp table d1 as
select (select id from publishes where seller_id = '00000000-0000-0000-0000-0000000000b2') as publish_id,
       (select id from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000b2') as area_version,
       (select id from charts where name = 'D1 loading') as chart_id;
grant select on d1 to public;

-- One readable line per lookup.
create function pg_temp.who(p_segment uuid, p_region uuid)
returns text language sql as $$
  select coalesce((select t.distributor_name || ', ' || t.allocation_type || ', for ' || t.area_name
                     from resolve_territory((select steel from k), p_segment, p_region) t),
                  'no allocation')
$$;

-- Structure ---------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on', 'territory_allocation_events=true, territory_allocations=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace and relname in ('territory_allocations', 'territory_allocation_events')$q$);
select pg_temp.expect_value('Nothing about territory holds a rate, amount or margin', '0',
  $q$select count(*)::text from information_schema.columns
     where table_schema = 'public' and table_name in ('territory_allocations', 'territory_allocation_events')
       and (column_name like '%rate%' or column_name like '%amount%' or column_name like '%margin%' or column_name like '%price%')$q$);

-- An offer has no effect until accepted ---------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('M offers Satara TMT to D1, D1 to set the price', 'offered',
  $q$select case when offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select satara from k),
                                      'distributor_prices') is not null then 'offered' end$q$);
select pg_temp.expect_value('An offer has no effect: a Satara buyer belongs to nobody yet', 'no allocation',
  $q$select pg_temp.who((select tmt from k), (select satara_city from k))$q$);

select pg_temp.as_owner();
create temp table t1 as select id from territory_allocations where distributor_id = '00000000-0000-0000-0000-0000000000b2';
grant select on t1 to public;

select pg_temp.as_visitor();
select pg_temp.expect_value('Visitors cannot see an offer', '0',
  $q$select count(*)::text from territory_allocations where id = (select id from t1)$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_refused('Another distributor accepts D1''s offer',
  $q$select respond_to_territory((select id from t1), true)$q$);
select pg_temp.expect_value('Another distributor cannot see D1''s offer', '0',
  $q$select count(*)::text from territory_allocations where id = (select id from t1)$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_refused('M accepts his own offer', $q$select respond_to_territory((select id from t1), true)$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('D1 sees the offer made to him', 'offered, distributor_prices',
  $q$select status || ', ' || allocation_type from territory_allocations where id = (select id from t1)$q$);
select pg_temp.expect_refused('D1 changes the type (only the manufacturer can)',
  $q$select change_territory_type((select id from t1), 'manufacturer_prices')$q$);
select pg_temp.expect_value('D1 accepts', 'active', $q$select respond_to_territory((select id from t1), true)::text$q$);
select pg_temp.expect_value('Now a Satara buyer belongs to D1', 'Bala Traders, distributor_prices, for Satara',
  $q$select pg_temp.who((select tmt from k), (select satara_city from k))$q$);
select pg_temp.expect_value('Including a buyer in Karad city, inside Satara', 'Bala Traders, distributor_prices, for Satara',
  $q$select pg_temp.who((select tmt from k), (select karad_city from k))$q$);
select pg_temp.expect_value('Pune is not allocated', 'no allocation', $q$select pg_temp.who((select tmt from k), (select pune from k))$q$);
select pg_temp.expect_refused('D1 accepts again', $q$select respond_to_territory((select id from t1), true)$q$);

select pg_temp.as_visitor();
select pg_temp.expect_value('An allocation in effect is public', 'Bala Traders for Satara',
  $q$select sp.store_name || ' for ' || r.name from territory_allocations a
     join seller_profiles sp on sp.account_id = a.distributor_id join regions r on r.id = a.region_id
     where a.id = (select id from t1)$q$);
select pg_temp.expect_value('Visitors can use the lookup', 'Bala Traders, distributor_prices, for Satara',
  $q$select pg_temp.who((select tmt from k), (select satara_city from k))$q$);

-- One distributor per area, per family ---------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('A second distributor cannot be given Satara TMT',
  'Satara Check Steel TMT is already offered to or held by Bala Traders. End that first.',
  $q$select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k), 'distributor_prices')$q$);
select pg_temp.expect_value('Satara angles can go to a different distributor (D2, M sets the price)', 'offered',
  $q$select case when offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000d4', (select angles from k), (select satara from k),
                                      'manufacturer_prices') is not null then 'offered' end$q$);

select pg_temp.as_owner();
create temp table t2 as select id from territory_allocations
 where distributor_id = '00000000-0000-0000-0000-0000000000d4' and segment_id = (select angles from k);
grant select on t2 to public;

-- A decline leaves no allocation ------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_value('D2 declines Satara angles', 'declined', $q$select respond_to_territory((select id from t2), false)::text$q$);
select pg_temp.expect_value('A decline leaves no allocation', 'no allocation',
  $q$select pg_temp.who((select angles from k), (select satara_city from k))$q$);
select pg_temp.expect_refused('D2 accepts after declining', $q$select respond_to_territory((select id from t2), true)$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('After a decline M can offer Satara angles again', 'offered',
  $q$select case when offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000d4', (select angles from k), (select satara from k),
                                      'manufacturer_prices') is not null then 'offered' end$q$);

-- The closer area wins ------------------------------------------------------------------

select pg_temp.expect_value('M offers Karad taluka TMT to D2, M sets the price', 'offered',
  $q$select case when offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select karad from k),
                                      'manufacturer_prices') is not null then 'offered' end$q$);
select pg_temp.as_owner();
create temp table t3 as select id from territory_allocations
 where distributor_id = '00000000-0000-0000-0000-0000000000d4' and region_id = (select karad from k);
grant select on t3 to public;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_value('D2 accepts Karad', 'active', $q$select respond_to_territory((select id from t3), true)::text$q$);
select pg_temp.expect_value('A Karad city buyer belongs to D2 (the closer area)', 'Dev Distributors, manufacturer_prices, for Check Karad',
  $q$select pg_temp.who((select tmt from k), (select karad_city from k))$q$);
select pg_temp.expect_value('Elsewhere in Satara still belongs to D1', 'Bala Traders, distributor_prices, for Satara',
  $q$select pg_temp.who((select tmt from k), (select satara_city from k))$q$);

-- Changing the type: only while an offer ------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('M offers Pune TMT to D2 (D2 sets the price)', 'offered',
  $q$select case when offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select pune from k),
                                      'distributor_prices') is not null then 'offered' end$q$);
select pg_temp.as_owner();
create temp table t4 as select id from territory_allocations
 where distributor_id = '00000000-0000-0000-0000-0000000000d4' and region_id = (select pune from k);
grant select on t4 to public;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('M changes the Pune offer to "M sets the price"', 'changed',
  $q$select 'changed' from (select change_territory_type((select id from t4), 'manufacturer_prices')) x$q$);
select pg_temp.expect_value('The Pune offer is now "M sets the price", still an offer', 'offered, manufacturer_prices',
  $q$select status || ', ' || allocation_type from territory_allocations where id = (select id from t4)$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_value('D2 accepts Pune', 'active', $q$select respond_to_territory((select id from t4), true)::text$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('Once accepted, the type cannot be changed',
  'Only an offer can be changed. To change an accepted allocation, end it and offer a new one.',
  $q$select change_territory_type((select id from t4), 'distributor_prices')$q$);

-- What an offer refuses -------------------------------------------------------------------

select pg_temp.expect_message('Allocating to himself', 'You cannot allocate an area to yourself.',
  $q$select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select mh from k), 'distributor_prices')$q$);
select pg_temp.expect_message('A family the brand is not listed for', 'Check Steel is not listed for MS Channels.',
  $q$select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000b2', (select channels from k), (select satara from k), 'distributor_prices')$q$);
select pg_temp.expect_message('An unapproved area', 'That area is not available.',
  $q$select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select unapproved from k), 'distributor_prices')$q$);
select pg_temp.expect_message('To someone who is not a seller', 'That distributor is not a seller on ALEE.',
  $q$select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000e5', (select tmt from k), (select pune from k), 'distributor_prices')$q$);

-- Who may do what ---------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('A distributor offers M''s territory',
  $q$select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select mh from k),
                            'distributor_prices', '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_refused('A buyer ends an allocation', $q$select end_territory((select id from t1))$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('A visitor offers territory',
  $q$select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select mh from k), 'distributor_prices')$q$);

-- Who sees what ----------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('M sees all his allocations, every status', 'active 3, declined 1, offered 1',
  $q$select string_agg(status || ' ' || n, ', ' order by status::text) from
     (select status, count(*) n from territory_allocations where manufacturer_id = '00000000-0000-0000-0000-0000000000a1' group by status) x$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_value('D2 sees only allocations offered to or held by him', 'active 2, declined 1, offered 1',
  $q$select string_agg(status || ' ' || n, ', ' order by status::text) from
     (select status, count(*) n from territory_allocations
       where distributor_id = '00000000-0000-0000-0000-0000000000d4' group by status) x$q$);
select pg_temp.expect_value('D2 sees D1''s allocation only because it is in effect (public), not its history', 'active, 0 history',
  $q$select string_agg(status::text, ',') || ', ' ||
            (select count(*) from territory_allocation_events where allocation_id = (select id from t1)) || ' history'
     from territory_allocations where id = (select id from t1)$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_value('A buyer sees only allocations in effect', 'active 3',
  $q$select string_agg(status || ' ' || n, ', ') from
     (select status, count(*) n from territory_allocations where manufacturer_id = '00000000-0000-0000-0000-0000000000a1' group by status) x$q$);
select pg_temp.expect_value('A buyer sees no territory history', '0', $q$select count(*)::text from territory_allocation_events$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('A visitor reads territory history', $q$select * from territory_allocation_events$q$);

-- The manufacturer cannot read the distributor's rates, by any route ------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('M reads D1''s publish: nothing', '0',
  $q$select count(*)::text from publishes where id = (select publish_id from d1)$q$);
select pg_temp.expect_value('M reads D1''s basic rate: nothing', '0',
  $q$select count(*)::text from publish_items where publish_id = (select publish_id from d1)$q$);
select pg_temp.expect_value('M reads D1''s area settings (his margins): nothing', '0',
  $q$select (select count(*) from area_setting_versions where id = (select area_version from d1))
          + (select count(*) from area_settings where version_id = (select area_version from d1))$q$);
select pg_temp.expect_value('M reads D1''s charts: nothing', '0',
  $q$select (select count(*) from charts where id = (select chart_id from d1))
          + (select count(*) from chart_versions where chart_id = (select chart_id from d1))$q$);
select pg_temp.expect_refused('M looks up D1''s settings for Satara',
  $q$select * from resolve_area_settings('00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select satara from k), null, null, (select id from brands where is_regular))$q$);
select pg_temp.expect_refused('M rebuilds D1''s published figures',
  $q$select * from resolve_size_figures('00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select satara from k),
                                       null, null, (select publish_id from d1), (select id from brands where is_regular))$q$);
select pg_temp.expect_value('The territory lookup returns who and which type, never a rate',
  'allocation_id, distributor_id, distributor_name, allocation_type, region_id, area_name',
  $q$select string_agg(parameter_name, ', ' order by ordinal_position) from information_schema.parameters
     where specific_name like 'resolve_territory%' and parameter_mode = 'OUT'$q$);
select pg_temp.expect_value('D1''s public status shows no rate', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000b2', (select tmt from k), null, (select id from brands where is_regular))$q$);

-- Ending restores the manufacturer ---------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('D1 ends Satara (either side can)', 'ended', $q$select end_territory((select id from t1))::text$q$);
select pg_temp.expect_value('A Satara buyer belongs to nobody again', 'no allocation',
  $q$select pg_temp.who((select tmt from k), (select satara_city from k))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('...and M serves Satara again with his own rate', 'served',
  $q$select case when is_served then 'served' else 'not served' end
     from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select satara_city from k), null, null, (select id from brands where is_regular))$q$);
select pg_temp.expect_value('Karad is unaffected (still D2)', 'Dev Distributors, manufacturer_prices, for Check Karad',
  $q$select pg_temp.who((select tmt from k), (select karad_city from k))$q$);
select pg_temp.expect_value('M ends Karad', 'ended', $q$select end_territory((select id from t3))::text$q$);
select pg_temp.expect_value('Karad city now belongs to nobody', 'no allocation',
  $q$select pg_temp.who((select tmt from k), (select karad_city from k))$q$);
select pg_temp.expect_message('An ended allocation cannot be ended again', 'This allocation has already finished (ended).',
  $q$select end_territory((select id from t1))$q$);
select pg_temp.expect_value('After ending, Satara TMT can be offered again', 'offered',
  $q$select case when offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k),
                                      'distributor_prices') is not null then 'offered' end$q$);
select pg_temp.expect_value('M withdraws that offer before it is accepted', 'withdrawn',
  $q$select end_territory(id)::text from territory_allocations
     where distributor_id = '00000000-0000-0000-0000-0000000000d4' and region_id = (select satara from k)
       and segment_id = (select tmt from k) and status = 'offered'$q$);

-- Admin manages any, recorded as admin --------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin offers Satara TMT to D1 for M', 'offered',
  $q$select case when offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select satara from k),
                                      'distributor_prices', '00000000-0000-0000-0000-0000000000a1') is not null then 'offered' end$q$);
select pg_temp.expect_value('Admin accepts it for D1', 'active',
  $q$select respond_to_territory(id, true)::text from territory_allocations
     where distributor_id = '00000000-0000-0000-0000-0000000000b2' and status = 'offered'$q$);
select pg_temp.expect_value('Both steps recorded as done by an admin', 'offered by admin, accepted by admin',
  $q$select string_agg(e.event || case when e.by_admin then ' by admin' else ' by the parties' end, ', ' order by e.happened_at)
     from territory_allocation_events e join territory_allocations a on a.id = e.allocation_id
     where a.distributor_id = '00000000-0000-0000-0000-0000000000b2' and a.status = 'active'$q$);

-- History ----------------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('Every step of Satara TMT with D1 is kept, with who did it',
  'offered by M, accepted by D1, ended by D1',
  $q$select string_agg(e.event || ' by ' || case e.done_by when '00000000-0000-0000-0000-0000000000a1' then 'M'
                                                         when '00000000-0000-0000-0000-0000000000b2' then 'D1' else '?' end,
                       ', ' order by e.happened_at)
     from territory_allocation_events e where e.allocation_id = (select id from t1)$q$);
select pg_temp.expect_value('The Pune type change is in the history', 'offered (distributor_prices), type_changed (manufacturer_prices), accepted (manufacturer_prices)',
  $q$select string_agg(e.event || ' (' || e.allocation_type || ')', ', ' order by e.happened_at)
     from territory_allocation_events e where e.allocation_id = (select id from t4)$q$);
select pg_temp.expect_value('A decline is in the history', 'offered, declined',
  $q$select string_agg(e.event::text, ', ' order by e.happened_at) from territory_allocation_events e where e.allocation_id = (select id from t2)$q$);

select pg_temp.expect_refused('M edits the history', $q$update territory_allocation_events set by_admin = true$q$);
select pg_temp.expect_refused('M deletes an allocation', $q$delete from territory_allocations where id = (select id from t1)$q$);
select pg_temp.expect_refused('M re-activates an ended allocation directly', $q$update territory_allocations set status = 'active' where id = (select id from t1)$q$);

select pg_temp.as_owner();
select pg_temp.expect_refused('Even with the master key: edit the history',
  $q$update territory_allocation_events set done_by = '00000000-0000-0000-0000-0000000000e5' where allocation_id = (select id from t1)$q$);
select pg_temp.expect_refused('Even with the master key: delete the history',
  $q$delete from territory_allocation_events where allocation_id = (select id from t1)$q$);
select pg_temp.expect_refused('Even with the master key: delete an allocation',
  $q$delete from territory_allocations where id = (select id from t1)$q$);
select pg_temp.expect_refused('Even with the master key: revive an ended allocation',
  $q$update territory_allocations set status = 'active' where id = (select id from t1)$q$);
select pg_temp.expect_refused('Even with the master key: give an allocation to a different distributor',
  $q$update territory_allocations set distributor_id = '00000000-0000-0000-0000-0000000000b2' where id = (select id from t3)$q$);
select pg_temp.expect_refused('Even with the master key: turn a decline into an acceptance',
  $q$update territory_allocations set status = 'active' where id = (select id from t2)$q$);

-- What territory does to each seller's rate (per brand) ---------------------------------
-- At this point: Satara TMT is held by D1 under Type A (offered by the admin
-- for M); Pune TMT is held by D2 under Type B. G becomes a factory of Check
-- Steel. D2 also sells Regular TMT.

insert into auth.users (id, phone, aud, role)
values ('00000000-0000-0000-0000-0000000000a7', '919800000007', 'authenticated', 'authenticated');
insert into accounts (id, full_name, phone, signup_role, region_id)
select '00000000-0000-0000-0000-0000000000a7', 'Gita', '+919800000007', 'manufacturer', id
  from regions where level = 'district' and name = 'Satara';
insert into seller_profiles (account_id, store_name, region_id, is_public, market_close_time)
select '00000000-0000-0000-0000-0000000000a7', 'Gita Steel Works', id, true, '18:00'
  from regions where level = 'district' and name = 'Satara';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select offer_factory_link((select steel from k), '00000000-0000-0000-0000-0000000000a7');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a7');
select respond_to_factory_link(id, true) from brand_factories where factory_id = '00000000-0000-0000-0000-0000000000a7';

create function pg_temp.effect(p_seller uuid, p_brand uuid, p_region uuid) returns text language sql as $$
  select e.effect || coalesce(' (' || e.distributor_name || ' for ' || e.area_name || ')', '')
    from territory_effect(p_seller, p_brand, (select tmt from k), p_region) e
$$;

select pg_temp.as_visitor();
select pg_temp.expect_value('Type B, the owner M in Pune: his rate shown with the tag', 'shown_with_tag (Dev Distributors for Pune)',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select pune from k))$q$);
select pg_temp.expect_value('Type B, M''s factory G in Pune: shown with the tag', 'shown_with_tag (Dev Distributors for Pune)',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000a7', (select steel from k), (select pune from k))$q$);
select pg_temp.expect_value('Type B, the distributor D2 in Pune: his Check Steel rate hidden', 'hidden (Dev Distributors for Pune)',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000d4', (select steel from k), (select pune from k))$q$);
select pg_temp.expect_value('...but D2''s other brands are unaffected (Regular TMT)', 'none',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000d4', (select regular from k), (select pune from k))$q$);
select pg_temp.expect_value('Another seller of Check Steel in Pune (D1) is unaffected', 'none (Dev Distributors for Pune)',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000b2', (select steel from k), (select pune from k))$q$);
select pg_temp.expect_value('Type A, the owner M in Satara: pointed to the distributor', 'pointed_to_distributor (Bala Traders for Satara)',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select satara_city from k))$q$);
select pg_temp.expect_value('Type A, M''s factory G in Satara: pointed to the distributor', 'pointed_to_distributor (Bala Traders for Satara)',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000a7', (select steel from k), (select satara_city from k))$q$);
select pg_temp.expect_value('Type A, the distributor D1 in Satara: shows his own rate', 'none (Bala Traders for Satara)',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000b2', (select steel from k), (select satara_city from k))$q$);
select pg_temp.expect_value('No allocation (North Goa): no effect', 'none',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000a1', (select steel from k),
       (select id from regions where level = 'district' and name = 'North Goa'))$q$);

-- Only a brand's owner allocates it ----------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('M allocates a brand he does not own', 'You don''t own Check Rods, so you cannot allocate it.',
  $q$select offer_territory((select rods from k), '00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select pune from k), 'distributor_prices')$q$);
select pg_temp.expect_message('M allocates Regular', 'You don''t own Regular, so you cannot allocate it.',
  $q$select offer_territory((select regular from k), '00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select pune from k), 'distributor_prices')$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select end_brand_ownership((select steel from k));
select pg_temp.as_visitor();
select pg_temp.expect_value('After M no longer owns Check Steel, his allocations stop counting', 'no allocation',
  $q$select pg_temp.who((select tmt from k), (select pune from k))$q$);
select pg_temp.expect_value('...and D2''s Check Steel rate is no longer hidden in Pune', 'none',
  $q$select pg_temp.effect('00000000-0000-0000-0000-0000000000d4', (select steel from k), (select pune from k))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('...and M can no longer allocate it', 'You don''t own Check Steel, so you cannot allocate it.',
  $q$select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select mh from k), 'distributor_prices')$q$);
