-- ============================================================
-- Checks: the rate engine (buyer_rate, seller_rate, rate_preview, and the
-- internal rate_engine they share).
-- Covers every rate engine case in CLAUDE.md section 20, and: factory
-- selection; Type A pointer with no ex-works; Type B tag and the
-- distributor's own rate hidden; another seller of the brand unaffected; a
-- free retailer seen from inside and outside his taluka; a distributor's
-- and a manufacturer's reach; an approved outside buyer's own-area rate,
-- labelled only "[area] rate"; a paid plan widening reach and a lapse
-- shrinking it, with settings kept; area setup beyond reach refused;
-- ex-works off by default ("Price on request"), switched on per state, only
-- in areas not set up, never beside an area rate, never outside reach,
-- not blocked by a missing setting; a factory that left selling as an
-- ordinary seller; a past day with no record; per kg and per piece with
-- rounding to the paisa; flat and percentage discount; a past publish
-- rebuilt exactly; the buyer's answer never holding the basic rate or any
-- individual difference; who may ask.
--
-- Test people (temporary logins, rolled back):
--   W ...a1  Wagh Steel, wholesaler (approved), at Check Karad City.
--            TMT per tonne. Brand lines: Regular, Check Shakti, Check Flat.
--   T ...a2  Tara Hardware, retailer (free plan), at Check Karad City.
--   P ...a3  Prakash, a buyer in Pune (no seller profile).
--   O ...b1  Om Steel, manufacturer, owns Check Shakti.
--   F ...b2  Farid Steel, Check Shakti factory covering Maharashtra.
--   G ...b3  Gopal Steel, Check Shakti factory covering Pune.
--   D ...b4  Dev Traders, distributor: Sangli and Check Kagal, Type A.
--   B ...b5  Bala Traders, distributor: Kolhapur, Type B.
--   C ...c3  admin.
--
-- Places added for the checks: Check Karad (taluka in Satara), Check Karad
-- City (city in Check Karad), Check Haveli (taluka in Pune), Check Kolhapur
-- City (city in Kolhapur), Check Kagal (taluka in Kolhapur).
--
-- W's Regular TMT setup (basic rate 50,000 per tonne):
--   Maharashtra   sizes: 8mm 6500, 10mm 5500, 12mm 5500 (16mm: no figure)
--                 loading 250, area difference 200, discount 500 per tonne
--                 grade premium Fe500 0, Fe500D 500
--   Satara        sizes: 10mm 5000, 12mm 5000
--   Check Karad   area difference 750
--   Pune          area difference 0, loading 0, discount 1.5%, shown per kg
--   Check Haveli  shown per piece
--   Kolhapur      EXCLUDED;  Check Kolhapur City  area difference 400
--   Sangli        Fe500D not sold there
--   Offers Fe500 and Fe500D (not Fe550D); 8, 10, 12, 16mm (not 20mm up).
-- ============================================================

-- People and places -------------------------------------------------------------

insert into auth.users (id, phone, aud, role)
select x.id::uuid, x.phone, 'authenticated', 'authenticated'
  from (values ('00000000-0000-0000-0000-0000000000a1', '919800000001'), ('00000000-0000-0000-0000-0000000000a2', '919800000002'),
               ('00000000-0000-0000-0000-0000000000a3', '919800000003'), ('00000000-0000-0000-0000-0000000000b1', '919800000011'),
               ('00000000-0000-0000-0000-0000000000b2', '919800000012'), ('00000000-0000-0000-0000-0000000000b3', '919800000013'),
               ('00000000-0000-0000-0000-0000000000b4', '919800000014'), ('00000000-0000-0000-0000-0000000000b5', '919800000015'),
               ('00000000-0000-0000-0000-0000000000c3', '919800000033')) as x (id, phone);

insert into regions (name, level, parent_id, is_approved)
select 'Check Karad', 'taluka', id, true from regions where level = 'district' and name = 'Satara';
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad City', 'city', id, true from regions where name = 'Check Karad';
insert into regions (name, level, parent_id, is_approved)
select 'Check Haveli', 'taluka', id, true from regions where level = 'district' and name = 'Pune';
insert into regions (name, level, parent_id, is_approved)
select 'Check Kolhapur City', 'city', id, true from regions where level = 'district' and name = 'Kolhapur';
insert into regions (name, level, parent_id, is_approved)
select 'Check Kagal', 'taluka', id, true from regions where level = 'district' and name = 'Kolhapur';
-- A state beyond everyone's reach.
insert into regions (name, level, is_approved) values ('Check Gujarat', 'state', true);
insert into regions (name, level, parent_id, is_approved)
select 'Check Surat', 'district', id, true from regions where name = 'Check Gujarat';

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, '+' || u.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Wagh', 'wholesaler', 'Check Karad City'),
               ('00000000-0000-0000-0000-0000000000a2', 'Tara', 'retailer', 'Check Karad City'),
               ('00000000-0000-0000-0000-0000000000a3', 'Prakash', 'retailer', 'Pune'),
               ('00000000-0000-0000-0000-0000000000b1', 'Om', 'manufacturer', 'Satara'),
               ('00000000-0000-0000-0000-0000000000b2', 'Farid', 'manufacturer', 'Satara'),
               ('00000000-0000-0000-0000-0000000000b3', 'Gopal', 'manufacturer', 'Pune'),
               ('00000000-0000-0000-0000-0000000000b4', 'Dev', 'distributor', 'Sangli'),
               ('00000000-0000-0000-0000-0000000000b5', 'Bala', 'distributor', 'Kolhapur')) as x (id, name, role, place)
  join auth.users u on u.id = x.id::uuid
  join regions r on r.name = x.place and r.level in ('district', 'city');

insert into seller_profiles (account_id, store_name, region_id, is_public, market_close_time)
select a.id, x.store, a.region_id, true, '18:00'
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Wagh Steel'), ('00000000-0000-0000-0000-0000000000a2', 'Tara Hardware'),
               ('00000000-0000-0000-0000-0000000000b1', 'Om Steel'), ('00000000-0000-0000-0000-0000000000b2', 'Farid Steel'),
               ('00000000-0000-0000-0000-0000000000b3', 'Gopal Steel'), ('00000000-0000-0000-0000-0000000000b4', 'Dev Traders'),
               ('00000000-0000-0000-0000-0000000000b5', 'Bala Traders')) as x (id, store)
  join accounts a on a.id = x.id::uuid;

insert into seller_segments (seller_id, segment_id)
select sp.account_id, s.id from seller_profiles sp, segments s
 where s.name = 'TMT Bars' and sp.account_id::text like '00000000-0000-0000-0000-%';

insert into brands (name, status) values ('Check Shakti', 'approved'), ('Check Flat', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s where b.name in ('Check Shakti', 'Check Flat') and s.name = 'TMT Bars';
insert into seller_brands (seller_id, brand_id, segment_id)
select x.id::uuid, b.id, s.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Check Shakti'), ('00000000-0000-0000-0000-0000000000a1', 'Check Flat'),
               ('00000000-0000-0000-0000-0000000000b2', 'Check Shakti'), ('00000000-0000-0000-0000-0000000000b3', 'Check Shakti'),
               ('00000000-0000-0000-0000-0000000000b4', 'Check Shakti'), ('00000000-0000-0000-0000-0000000000b5', 'Check Shakti')) as x (id, brand)
  join brands b on b.name = x.brand
 cross join (select id from segments where name = 'TMT Bars') s;

-- Test sellers sell Regular in each family they deal in.
select pg_temp.sell_regular();

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from brands where is_regular) as regular,
       (select id from brands where name = 'Check Shakti') as shakti,
       (select id from brands where name = 'Check Flat') as flat,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'state' and name = 'Goa') as goa,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select id from regions where level = 'district' and name = 'Kolhapur') as kolhapur,
       (select id from regions where level = 'district' and name = 'Sangli') as sangli,
       (select id from regions where level = 'district' and name = 'Nashik') as nashik,
       (select id from regions where name = 'Check Karad') as karad,
       (select id from regions where name = 'Check Karad City') as karad_city,
       (select id from regions where name = 'Check Haveli') as haveli,
       (select id from regions where name = 'Check Kolhapur City') as kolhapur_city,
       (select id from regions where name = 'Check Kagal') as kagal,
       (select id from regions where name = 'Check Gujarat') as gujarat,
       (select id from regions where name = 'Check Surat') as surat;
grant select on k to public;

-- Grades and sizes by name.
create function pg_temp.grade(p_name text) returns uuid language sql as $$
  select p.id from products p where p.segment_id = (select tmt from k) and p.name = p_name $$;
create function pg_temp.size(p_name text) returns uuid language sql as $$
  select z.id from sizes z where z.segment_id = (select tmt from k) and z.display_name = p_name $$;

-- What a buyer sees for one grade and size, in one line. Asked as an admin
-- unless someone else is acting.
create function pg_temp.q(p_seller uuid, p_brand uuid, p_region uuid, p_grade text, p_size text,
                          p_buyer uuid default null, p_publish uuid default null)
returns text language sql as $$
  select concat_ws(' | ', b.status, b.area_rate_text, b.area_rate_label, b.area_discount_text,
                   b.ex_works_label || ' ' || b.ex_works_text, b.ex_works_discount_text, b.message, b.tag)
    from buyer_rate(p_seller, p_brand, (select tmt from k), p_region, pg_temp.grade(p_grade), pg_temp.size(p_size),
                    p_buyer, p_publish) b
$$;

-- Higher roles approved by ALEE. Tara stays a retailer.
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_role_request(id, true) from role_requests where status = 'requested';
-- W, a wholesaler, reaches his district for free; his plan reaches all of
-- Maharashtra and adds Goa.
insert into plans (name, reach_level, extra_states) values ('Check State', 'state', 1);
select switch_on_plan('00000000-0000-0000-0000-0000000000a1', (select id from plans where name = 'Check State'),
                      now() - interval '1 day', now() + interval '1 year', array[(select goa from k)]);

-- W sets up three brand lines --------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

insert into seller_grades (seller_id, brand_id, product_id, is_selected)
select '00000000-0000-0000-0000-0000000000a1', x.brand, pg_temp.grade(x.grade), true
  from (values ((select regular from k), 'Fe500'), ((select regular from k), 'Fe500D'),
               ((select shakti from k), 'Fe500'), ((select shakti from k), 'Fe500D'),
               ((select flat from k), 'Fe500')) as x (brand, grade);
insert into seller_sizes (seller_id, brand_id, size_id, is_selected)
select '00000000-0000-0000-0000-0000000000a1', x.brand, pg_temp.size(x.size), true
  from (values ((select regular from k), '8mm'), ((select regular from k), '10mm'), ((select regular from k), '12mm'),
               ((select regular from k), '16mm'), ((select shakti from k), '12mm'),
               ((select flat from k), '8mm'), ((select flat from k), '12mm')) as x (brand, size);

insert into charts (seller_id, segment_id, chart_type, name)
select '00000000-0000-0000-0000-0000000000a1', (select tmt from k), x.type::chart_type, x.name
  from (values ('size', 'W MH sizes'), ('size', 'W Satara sizes'), ('loading', 'W loading'),
               ('loading', 'W zero loading'), ('discount', 'W flat'), ('discount', 'W pct')) as x (type, name);
select save_chart_version((select id from charts where name = 'W MH sizes'), 'tonne', jsonb_build_array(
  jsonb_build_object('size_id', pg_temp.size('8mm'), 'amount', 6500),
  jsonb_build_object('size_id', pg_temp.size('10mm'), 'amount', 5500),
  jsonb_build_object('size_id', pg_temp.size('12mm'), 'amount', 5500)));
select save_chart_version((select id from charts where name = 'W Satara sizes'), 'tonne', jsonb_build_array(
  jsonb_build_object('size_id', pg_temp.size('10mm'), 'amount', 5000),
  jsonb_build_object('size_id', pg_temp.size('12mm'), 'amount', 5000)));
select save_chart_version((select id from charts where name = 'W loading'), 'tonne', '[{"size_id": null, "amount": 250}]');
select save_chart_version((select id from charts where name = 'W zero loading'), 'tonne', '[{"size_id": null, "amount": 0}]');
select save_chart_version((select id from charts where name = 'W flat'), 'tonne', null, '{"kind": "flat", "amount": 500}');
select save_chart_version((select id from charts where name = 'W pct'), 'tonne', null, '{"kind": "percent", "percent": 1.5}');

create temp table wc as select name, id from charts where seller_id = '00000000-0000-0000-0000-0000000000a1';
grant select on wc to public;

select save_area_settings((select tmt from k), jsonb_build_array(
  jsonb_build_object('region_id', (select mh from k), 'size_chart_id', (select id from wc where name = 'W MH sizes'),
    'loading_chart_id', (select id from wc where name = 'W loading'), 'area_difference', 200,
    'discount_chart_id', (select id from wc where name = 'W flat'),
    'grades', jsonb_build_array(jsonb_build_object('product_id', pg_temp.grade('Fe500'), 'premium', 0),
                                jsonb_build_object('product_id', pg_temp.grade('Fe500D'), 'premium', 500))),
  jsonb_build_object('region_id', (select satara from k), 'size_chart_id', (select id from wc where name = 'W Satara sizes')),
  jsonb_build_object('region_id', (select karad from k), 'area_difference', 750),
  jsonb_build_object('region_id', (select pune from k), 'area_difference', 0, 'display_unit', 'kg',
    'loading_chart_id', (select id from wc where name = 'W zero loading'),
    'discount_chart_id', (select id from wc where name = 'W pct')),
  jsonb_build_object('region_id', (select haveli from k), 'display_unit', 'piece'),
  jsonb_build_object('region_id', (select kolhapur from k), 'excluded', true),
  jsonb_build_object('region_id', (select kolhapur_city from k), 'area_difference', 400),
  jsonb_build_object('region_id', (select sangli from k),
    'grades', jsonb_build_array(jsonb_build_object('product_id', pg_temp.grade('Fe500D'), 'sold', false)))
), null, (select regular from k));

-- Check Shakti, W as an ordinary seller of the brand: MH sizes everywhere,
-- Fe500D +300 (Fe500's premium never set); loading and area difference
-- only in Satara and Kolhapur.
select save_area_settings((select tmt from k), jsonb_build_array(
  jsonb_build_object('everywhere', true, 'size_chart_id', (select id from wc where name = 'W MH sizes'),
    'grades', jsonb_build_array(jsonb_build_object('product_id', pg_temp.grade('Fe500D'), 'premium', 300))),
  jsonb_build_object('region_id', (select satara from k), 'area_difference', 100,
    'loading_chart_id', (select id from wc where name = 'W loading')),
  jsonb_build_object('region_id', (select kolhapur from k), 'area_difference', 150,
    'loading_chart_id', (select id from wc where name = 'W loading'))
), null, (select shakti from k));

-- Check Flat: one flat rate everywhere, no area configuration, no discount.
select save_area_settings((select tmt from k), jsonb_build_array(
  jsonb_build_object('everywhere', true, 'size_chart_id', (select id from wc where name = 'W MH sizes'),
    'loading_chart_id', (select id from wc where name = 'W zero loading'), 'area_difference', 0,
    'grades', jsonb_build_array(jsonb_build_object('product_id', pg_temp.grade('Fe500'), 'premium', 0)))
), null, (select flat from k));

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

-- No base rate ---------------------------------------------------------------------

select pg_temp.expect_value('No base rate: nothing published yet, no price shown', 'not_published | No rate published yet',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad from k), 'Fe500D', '12mm')$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
create temp table pubs as
select publish_rates(jsonb_build_array(
  jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select regular from k), 'base_rate', 50000),
  jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select shakti from k), 'base_rate', 49000),
  jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select flat from k), 'base_rate', 47000))) as first;
grant select on pubs to public;
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

-- Area resolution ------------------------------------------------------------------

select pg_temp.expect_value('Karad buyer, Fe500D 12mm: 50,000 + 500 + 5,000 (Satara) + 250 + 750 (Karad), discount beneath',
  'priced | ₹56,500/tonne | Check Karad rate | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('Exact city match: Check Kolhapur City, named inside excluded Kolhapur, is served (+400)',
  'priced | ₹56,650/tonne | Check Kolhapur City rate | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select kolhapur_city from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('A Karad City buyer falls back to Karad taluka (+750)',
  'priced | ₹56,500/tonne | Check Karad City rate | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad_city from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('A Satara buyer falls back to the state''s area difference (+200)',
  'priced | ₹55,950/tonne | Satara rate | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select satara from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('A Nashik buyer gets everything from Maharashtra',
  'priced | ₹56,450/tonne | Nashik rate | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select nashik from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('Explicit exclusion overrides Maharashtra: Kolhapur district is not served, no area rate',
  'not_served | Doesn''t currently supply Kolhapur',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select kolhapur from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('A buyer in an area he has not set up (Goa, inside his reach), ex-works off: price on request',
  'price_on_request | Price on request — send enquiry',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select goa from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('Size differences per size: a Satara buyer gets 8mm +6,500 from Maharashtra and 12mm +5,000 from Satara',
  '10mm: 5000 from Satara, family chart | 12mm: 5000 from Satara, family chart | 8mm: 6500 from Maharashtra, family chart',
  $q$select string_agg(s.size || ': ' || s.size_difference || ' from ' || s.size_difference_from, ' | ' order by s.size)
     from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select satara from k),
                      pg_temp.grade('Fe500D')) s where s.status = 'priced' and s.size in ('8mm', '10mm', '12mm')$q$);
select pg_temp.expect_value('Different charts in different areas of one state: Pune 12mm uses the Maharashtra chart (5,500), Satara its own (5,000)',
  'Pune 5500, Satara 5000',
  $q$select 'Pune ' || (select size_difference from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                         (select pune from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm')))
         || ', Satara ' || (select size_difference from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                         (select satara from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm')))$q$);

-- Zero is a real value; missing is never zero ------------------------------------------

select pg_temp.expect_value('Zero area difference and zero loading in Pune are used, not replaced by 200 and 250',
  'area difference 0 from Pune, loading 0 from Pune, rate 56000 per tonne',
  $q$select 'area difference ' || area_difference || ' from ' || area_difference_from || ', loading ' || loading || ' from ' || loading_from
         || ', rate ' || (base_rate + grade_premium + size_difference + loading + area_difference) || ' per ' || pricing_unit
     from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select pune from k),
                      pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('Grade premium entered as 0 (Fe500, base grade) is used',
  'priced | ₹56,000/tonne | Check Karad rate | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('A selected size with no size-chart figure is left out and flagged, never quoted at zero',
  'missing | Rate not available',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad from k), 'Fe500D', '16mm')$q$);
select pg_temp.expect_value('The seller is told exactly what is missing for 16mm',
  'Size difference for 16mm is not set for Check Karad.',
  $q$select array_to_string(missing, ' / ') from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
       (select karad from k), pg_temp.grade('Fe500D'), pg_temp.size('16mm'))$q$);
select pg_temp.expect_value('A grade the seller has not selected (Fe550D) is not offered', 'not_offered | Not offered',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad from k), 'Fe550D', '12mm')$q$);
select pg_temp.expect_value('A size the seller has not selected (20mm) is not offered', 'not_offered | Not offered',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad from k), 'Fe500D', '20mm')$q$);
select pg_temp.expect_value('A grade not sold in an area (Fe500D in Sangli) is not offered there', 'not_offered | Fe500D is not sold in Sangli',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select sangli from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('...while Fe500 is sold in Sangli', 'priced | ₹55,950/tonne | Sangli rate | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select sangli from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Grade premium not set (Check Shakti Fe500): flagged and left out', 'missing | Rate not available',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select shakti from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('...and the seller is told', 'Grade premium for Fe500 is not set for Satara. If Fe500 is your base grade, enter 0.',
  $q$select array_to_string(missing, ' / ') from seller_rate('00000000-0000-0000-0000-0000000000a1', (select shakti from k), (select tmt from k),
       (select satara from k), pg_temp.grade('Fe500'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('Loading and area difference not set anywhere (Check Shakti in Pune): flagged, no price',
  'missing | Rate not available',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select shakti from k), (select pune from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('...naming both',
  'Loading for 12mm is not set for Pune. If you don''t charge loading, enter 0. / Area difference is not set for Pune. If the price there is your basic rate, enter 0.',
  $q$select array_to_string(missing, ' / ') from seller_rate('00000000-0000-0000-0000-0000000000a1', (select shakti from k), (select tmt from k),
       (select pune from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);

-- Brands, flat rate, discounts, units -------------------------------------------------

select pg_temp.expect_value('Two brands of one seller in one area use their own settings and publishes (Satara: Regular 55,950; Shakti 55,150)',
  'Regular 55950.00, Shakti 55150.00',
  $q$select 'Regular ' || (select area_rate from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                            (select satara from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm')))
         || ', Shakti ' || (select area_rate from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select shakti from k), (select tmt from k),
                            (select satara from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm')))$q$);
select pg_temp.expect_value('Flat-rate seller with no area configuration is served everywhere he sells, even Goa; no discount set: none shown, nothing flagged',
  'priced | ₹52,500/tonne | Goa rate | flagged: 0',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select flat from k), (select goa from k), 'Fe500', '12mm')
         || ' | flagged: ' || (select cardinality(missing) from seller_rate('00000000-0000-0000-0000-0000000000a1', (select flat from k),
                               (select tmt from k), (select goa from k), pg_temp.grade('Fe500'), pg_temp.size('12mm')))$q$);
select pg_temp.expect_value('Per kg with a percentage discount: Pune 56,000 per tonne is ₹56/kg, less 1.5% = ₹0.84',
  'priced | ₹56/kg | Pune rate | less 1.5% (₹0.84/kg)',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select pune from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('Per piece, rounded once to the paisa: 56,000 x 10.656 kg / 1000 = 596.736 -> ₹596.74; 1.5% = 8.951 -> ₹8.95',
  'priced | ₹596.74/piece | Check Haveli rate | less 1.5% (₹8.95/piece)',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select haveli from k), 'Fe500D', '12mm')$q$);

-- Ex-works -----------------------------------------------------------------------------

select pg_temp.expect_value('Ex-works is off by default: an area he has not set up (Goa) shows price on request',
  'price_on_request | Price on request — send enquiry',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select goa from k), 'Fe500D', '12mm')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('W switches ex-works on in Goa', 1, $q$select set_ex_works((select goa from k), true)$q$);
select pg_temp.expect_rows('...and in Maharashtra', 1, $q$select set_ex_works((select mh from k), true)$q$);
select pg_temp.expect_message('...but not in a state beyond his reach', 'Ex-works can be switched on only where you reach. Upgrade to reach more areas.',
  $q$select set_ex_works((select gujarat from k), true)$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('An area not set up, ex-works on: Ex-Check Karad City = 50,000 + 500 + 5,000 + 250, from the plant city''s settings',
  'ex_works | Ex-Check Karad City ₹55,750/tonne | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select goa from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('An area he has set up shows its own rate only, never ex-works beside it',
  'priced | ₹56,500/tonne | Check Karad rate | less ₹500/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('...in any unit (Pune, per kg)', 'priced | ₹56/kg | Pune rate | less 1.5% (₹0.84/kg)',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select pune from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('An area he excluded is not supplied, with no ex-works', 'not_served | Doesn''t currently supply Kolhapur',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select kolhapur from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('A missing setting for the buyer''s area does not block ex-works when the plant city''s figures are complete (Check Shakti, Pune)',
  'ex_works | Ex-Check Karad City ₹55,050/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select shakti from k), (select pune from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('...and the seller is still told what is missing for Pune',
  'Loading for 12mm is not set for Pune. If you don''t charge loading, enter 0. / Area difference is not set for Pune. If the price there is your basic rate, enter 0.',
  $q$select array_to_string(missing, ' / ') from seller_rate('00000000-0000-0000-0000-0000000000a1', (select shakti from k), (select tmt from k),
       (select pune from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('Neither complete (16mm has no size figure anywhere): no price', 'missing | Rate not available',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select karad from k), 'Fe500D', '16mm')$q$);
select pg_temp.expect_value('Ex-works never shows outside his reach', 'reach_limited | Wagh Steel shares rates with buyers in Maharashtra and Goa.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select surat from k), 'Fe500D', '12mm')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select set_plant_city((select goa from k));
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('A plant city his settings don''t cover: no ex-works, price on request',
  'price_on_request | Price on request — send enquiry',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select goa from k), 'Fe500D', '12mm')$q$);
select pg_temp.expect_value('...and the seller is told why', 'Ex-works needs your settings to cover Goa, your plant city.',
  $q$select array_to_string(missing, ' / ') from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
       (select goa from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select set_plant_city((select karad_city from k));
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

-- The buyer's answer and the seller's answer ---------------------------------------------

select pg_temp.expect_value('A buyer''s answer has no basic rate, grade premium, size difference, loading or area difference',
  'none',
  $q$select coalesce(string_agg(a.attname, ', '), 'none') from pg_attribute a
      where a.attrelid = 'public.buyer_rate_line'::regclass and a.attnum > 0
        and (a.attname like '%base%' or a.attname like '%premium%' or a.attname like '%size_difference%'
             or a.attname like '%loading%' or a.attname like '%area_difference%' or a.attname like '%missing%')$q$);
select pg_temp.expect_value('...and no figure in it is the basic rate or a difference: only final figures and the discount',
  '56500.00, 500.00',
  $q$select concat_ws(', ', area_rate, area_discount, ex_works_rate, ex_works_discount)
     from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                     (select karad from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('The seller''s answer has every component and where it came from',
  'base 50000 per tonne | premium 500 from Maharashtra | size 5000 from Satara, family chart | loading 250 from Maharashtra | area 750 from Check Karad | discount ₹500 per tonne from Maharashtra',
  $q$select 'base ' || base_rate || ' per ' || pricing_unit || ' | premium ' || grade_premium || ' from ' || grade_premium_from
         || ' | size ' || size_difference || ' from ' || size_difference_from || ' | loading ' || loading || ' from ' || loading_from
         || ' | area ' || area_difference || ' from ' || area_difference_from || ' | discount ' || discount || ' from ' || discount_from
     from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                      (select karad from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('Open, with when it was published (today), and not a correction', 'open, published today, not a correction',
  $q$select market || case when published_at is not null and published_today then ', published today' end
         || case when is_correction then ', correction' else ', not a correction' end
     from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                     (select karad from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);

-- A past publish rebuilds exactly --------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select save_chart_version((select id from wc where name = 'W Satara sizes'), 'tonne', jsonb_build_array(
  jsonb_build_object('size_id', pg_temp.size('10mm'), 'amount', 4800),
  jsonb_build_object('size_id', pg_temp.size('12mm'), 'amount', 4800)));
select publish_rates(jsonb_build_array(
  jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select regular from k), 'base_rate', 50500)), true, (select first from pubs));
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('The new publish, a correction, uses the changed chart: 50,500 + 500 + 4,800 + 250 + 750',
  '₹56,800/tonne, correction',
  $q$select area_rate_text || case when is_correction then ', correction' end
     from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                     (select karad from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('The first publish rebuilds exactly as it was shown, after the chart changed',
  'past | ₹56,500/tonne | less ₹500/tonne',
  $q$select concat_ws(' | ', market, area_rate_text, area_discount_text)
     from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                     (select karad from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'), null, (select first from pubs))$q$);

-- Not quoting, market closed ----------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select set_quoting((select tmt from k), false, null, (select flat from k));
select close_market_now(null, null, null);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Not quoting: no rate', 'not_quoting | Not quoting today',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select flat from k), (select goa from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Market closed: his last rate still shows, tagged closed with the closing time', 'closed, with closing time, ₹56,800/tonne',
  $q$select market || case when closed_at is not null then ', with closing time' end || ', ' || area_rate_text
     from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                     (select karad from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);

-- Factories and territory -------------------------------------------------------------

-- O owns Check Shakti; Farid covers Maharashtra and Gopal covers Pune.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select claim_brand((select shakti from k));
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_brand_claim(id, true) from brand_claims where brand_id = (select shakti from k);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select offer_factory_link((select shakti from k), x.id::uuid)
  from (values ('00000000-0000-0000-0000-0000000000b2'), ('00000000-0000-0000-0000-0000000000b3')) as x (id);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select respond_to_factory_link(id, true) from brand_factories where factory_id = '00000000-0000-0000-0000-0000000000b2';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select respond_to_factory_link(id, true) from brand_factories where factory_id = '00000000-0000-0000-0000-0000000000b3';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select save_factory_coverage((select shakti from k), (select tmt from k), jsonb_build_array(
  jsonb_build_object('region_id', (select mh from k), 'factory_id', '00000000-0000-0000-0000-0000000000b2'),
  jsonb_build_object('region_id', (select pune from k), 'factory_id', '00000000-0000-0000-0000-0000000000b3')));
-- Territory: Sangli and Check Kagal to Dev (Type A), Kolhapur to Bala
-- (Type B), Nashik offered to Dev but not accepted.
create temp table alloc as
select offer_territory((select shakti from k), '00000000-0000-0000-0000-0000000000b4', (select tmt from k), (select sangli from k), 'distributor_prices') as sangli,
       offer_territory((select shakti from k), '00000000-0000-0000-0000-0000000000b4', (select tmt from k), (select kagal from k), 'distributor_prices') as kagal,
       offer_territory((select shakti from k), '00000000-0000-0000-0000-0000000000b5', (select tmt from k), (select kolhapur from k), 'manufacturer_prices') as kolhapur,
       offer_territory((select shakti from k), '00000000-0000-0000-0000-0000000000b4', (select tmt from k), (select nashik from k), 'distributor_prices') as nashik;
grant select on alloc to public;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b4');
select respond_to_territory((select sangli from alloc), true), respond_to_territory((select kagal from alloc), true);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b5');
select respond_to_territory((select kolhapur from alloc), true);

-- One simple line for a seller: Fe500 12mm, size +5,000, no loading, no
-- area difference, everywhere; published at the given basic rate.
create function pg_temp.simple_line(p_seller uuid, p_brand uuid, p_base numeric) returns void language plpgsql as $$
begin
  perform pg_temp.as_user(p_seller);
  insert into seller_grades (seller_id, brand_id, product_id, is_selected) values (p_seller, p_brand, pg_temp.grade('Fe500'), true)
    on conflict do nothing;
  insert into seller_sizes (seller_id, brand_id, size_id, is_selected) values (p_seller, p_brand, pg_temp.size('12mm'), true)
    on conflict do nothing;
  if not exists (select 1 from charts where seller_id = p_seller) then
    insert into charts (seller_id, segment_id, chart_type, name) values
      (p_seller, (select tmt from k), 'size', 'sizes ' || p_seller), (p_seller, (select tmt from k), 'loading', 'loading ' || p_seller);
    perform save_chart_version((select id from charts where name = 'sizes ' || p_seller), 'tonne',
      jsonb_build_array(jsonb_build_object('size_id', pg_temp.size('12mm'), 'amount', 5000)));
    perform save_chart_version((select id from charts where name = 'loading ' || p_seller), 'tonne', '[{"size_id": null, "amount": 0}]');
  end if;
  perform save_area_settings((select tmt from k), jsonb_build_array(jsonb_build_object('everywhere', true,
    'size_chart_id', (select id from charts where name = 'sizes ' || p_seller),
    'loading_chart_id', (select id from charts where name = 'loading ' || p_seller), 'area_difference', 0,
    'grades', jsonb_build_array(jsonb_build_object('product_id', pg_temp.grade('Fe500'), 'premium', 0))
  )), null, p_brand);
  perform publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', p_brand, 'base_rate', p_base)));
end;
$$;

select pg_temp.simple_line('00000000-0000-0000-0000-0000000000b2', (select shakti from k), 48000);
select pg_temp.simple_line('00000000-0000-0000-0000-0000000000b3', (select shakti from k), 49000);
select pg_temp.simple_line('00000000-0000-0000-0000-0000000000b5', (select shakti from k), 50000);
select pg_temp.simple_line('00000000-0000-0000-0000-0000000000b5', (select regular from k), 46000);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select set_ex_works((select mh from k), true);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

select pg_temp.expect_value('Factory selection: Farid''s rate in Satara (he covers Maharashtra)',
  'priced | ₹53,000/tonne | Satara rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('The closer area wins: a Pune buyer gets Gopal''s rate', 'priced | ₹54,000/tonne | Pune rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b3', (select shakti from k), (select pune from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('...and Farid''s rate is not offered in Pune', 'served_by_factory | Check Shakti in Pune is supplied by Gopal Steel',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select pune from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('The owner himself is not the factory for Satara', 'served_by_factory | Check Shakti in Satara is supplied by Farid Steel',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b1', (select shakti from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('No factory covers Goa: not offered from the owner, and no ex-works', 'not_served | Doesn''t currently supply Goa',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select goa from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Type A: Farid''s rate is not shown in Sangli; the buyer is pointed to Dev, with no ex-works',
  'buy_from_distributor | For Check Shakti in Sangli, buy from Dev Traders, the authorised distributor.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select sangli from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Type B: Farid''s own rate in Kolhapur, tagged with the authorised distributor',
  'priced | ₹53,000/tonne | Kolhapur rate | Authorised distributor for Kolhapur: Bala Traders',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select kolhapur from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('The closer allocated area wins: Check Kagal (Type A to Dev) inside Kolhapur (Type B to Bala)',
  'buy_from_distributor | For Check Shakti in Check Kagal, buy from Dev Traders, the authorised distributor.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select kagal from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('An offer not yet accepted (Nashik) has no effect: Farid''s own settings decide',
  'priced | ₹53,000/tonne | Nashik rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select nashik from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Type B hides Bala''s own Check Shakti rate in Kolhapur, with no figure',
  'priced_by_brand_owner | Authorised distributor for Kolhapur. Check Shakti is sold there at the brand owner''s rate.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b5', (select shakti from k), (select kolhapur from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('...but not his other brands there (Regular)', 'priced | ₹51,000/tonne | Kolhapur rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b5', (select regular from k), (select kolhapur from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('...nor his Check Shakti rate where his allocation doesn''t apply (Check Kagal, Dev''s Type A)', 'priced | ₹55,000/tonne | Check Kagal rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b5', (select shakti from k), (select kagal from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('A distributor reaches his own district for free: Bala''s rate is not shown in Satara',
  'reach_limited | Bala Traders shares rates with buyers in Kolhapur.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b5', (select regular from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('A past publish returns only what Farid published: today''s territory is not applied to it (Sangli)',
  'past | ₹53,000/tonne',
  $q$select concat_ws(' | ', market, area_rate_text) from buyer_rate('00000000-0000-0000-0000-0000000000b2', (select shakti from k),
       (select tmt from k), (select sangli from k), pg_temp.grade('Fe500'), pg_temp.size('12mm'), null,
       (select id from publishes where seller_id = '00000000-0000-0000-0000-0000000000b2'))$q$);
select pg_temp.expect_value('Another seller of the brand (W) is unaffected by territory in Kolhapur',
  'priced | ₹55,200/tonne | Kolhapur rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a1', (select shakti from k), (select kolhapur from k), 'Fe500D', '12mm')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select end_factory_link(id) from brand_factories where factory_id = '00000000-0000-0000-0000-0000000000b3';
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('A factory that left: the brand owner''s rate is not offered in Pune, never another factory''s',
  'not_served | Doesn''t currently supply Pune',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select pune from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('A factory that leaves the brand but keeps selling it is shown as an ordinary seller of that brand',
  'priced | ₹54,000/tonne | Pune rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b3', (select shakti from k), (select pune from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('A manufacturer reaches his own state for free: Gopal''s rate is not shown in Goa',
  'reach_limited | Gopal Steel shares rates with buyers in Maharashtra.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b3', (select shakti from k), (select goa from k), 'Fe500', '12mm')$q$);

-- A free retailer's reach -------------------------------------------------------------

-- Tara sets up her own taluka only: Fe500 12mm in Check Karad, size +5,000,
-- no loading, area difference +500.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
insert into seller_grades (seller_id, brand_id, product_id, is_selected)
values ('00000000-0000-0000-0000-0000000000a2', (select regular from k), pg_temp.grade('Fe500'), true);
insert into seller_sizes (seller_id, brand_id, size_id, is_selected)
values ('00000000-0000-0000-0000-0000000000a2', (select regular from k), pg_temp.size('12mm'), true);
insert into charts (seller_id, segment_id, chart_type, name) values
  ('00000000-0000-0000-0000-0000000000a2', (select tmt from k), 'size', 'T sizes'),
  ('00000000-0000-0000-0000-0000000000a2', (select tmt from k), 'loading', 'T loading');
select save_chart_version((select id from charts where name = 'T sizes'), 'tonne',
  jsonb_build_array(jsonb_build_object('size_id', pg_temp.size('12mm'), 'amount', 5000)));
select save_chart_version((select id from charts where name = 'T loading'), 'tonne', '[{"size_id": null, "amount": 0}]');
create function pg_temp.t_area(p_region uuid, p_diff numeric) returns jsonb language sql as $$
  select jsonb_build_object('region_id', p_region, 'size_chart_id', (select id from charts where name = 'T sizes'),
    'loading_chart_id', (select id from charts where name = 'T loading'), 'area_difference', p_diff,
    'grades', jsonb_build_array(jsonb_build_object('product_id', pg_temp.grade('Fe500'), 'premium', 0))) $$;
select pg_temp.expect_message('A free retailer cannot set up Maharashtra, beyond her taluka', 'Upgrade to reach more areas. Maharashtra is outside your reach.',
  $q$select save_area_settings((select tmt from k), jsonb_build_array(pg_temp.t_area((select mh from k), 0)), null, (select regular from k))$q$);
select save_area_settings((select tmt from k), jsonb_build_array(pg_temp.t_area((select karad from k), 500)), null, (select regular from k));
select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select regular from k), 'base_rate', 50000)));
select pg_temp.expect_message('A free retailer does not have ex-works', 'Ex-works rates come with a paid plan. Contact ALEE to upgrade.',
  $q$select set_ex_works((select mh from k), true)$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

select pg_temp.expect_value('Free retailer, buyer inside her taluka: her rate only', 'priced | ₹55,500/tonne | Check Karad City rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select karad_city from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Free retailer, buyer outside her taluka (Satara): no figure, no ex-works',
  'reach_limited | Tara Hardware shares rates with buyers in Check Karad.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('A buyer outside reach is a distinct status the "What you''re missing" message can count', 'reach_limited',
  $q$select status from buyer_rate('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select tmt from k),
       (select pune from k), pg_temp.grade('Fe500'), pg_temp.size('12mm'), '00000000-0000-0000-0000-0000000000a3')$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select request_rates('00000000-0000-0000-0000-0000000000a2');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select decide_rate_request(id, true) from rate_requests where seller_id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('An approved outside buyer in Pune gets her own-area rate, labelled only "[area] rate"',
  'priced | ₹55,500/tonne | Check Karad rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select pune from k), 'Fe500', '12mm',
                      '00000000-0000-0000-0000-0000000000a3')$q$);
select pg_temp.expect_value('...but another Pune buyer (not approved) still sees none', 'reach_limited',
  $q$select status from buyer_rate('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select tmt from k),
       (select pune from k), pg_temp.grade('Fe500'), pg_temp.size('12mm'), '00000000-0000-0000-0000-0000000000b1')$q$);

-- Paid plan: reach widens to Satara district.
insert into plans (name, reach_level, outside_buyer_limit) values ('Check District', 'district', 50);
create temp table tp as
select switch_on_plan('00000000-0000-0000-0000-0000000000a2', (select id from plans where name = 'Check District'),
                      now() - interval '1 day', now() + interval '30 days') as id;
grant select on tp to public;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('A paid retailer switches ex-works on in her own state', 1, $q$select set_ex_works((select mh from k), true)$q$);
select pg_temp.expect_message('...not in another state', 'As a retailer you can switch ex-works on only in your own state.',
  $q$select set_ex_works((select goa from k), true)$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('A paid plan widens reach to Satara; she has not set Satara up, so the buyer sees her ex-works rate',
  'ex_works | Ex-Check Karad City ₹55,000/tonne',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('Inside her paid reach she can now set Satara up', 1,
  $q$select save_area_settings((select tmt from k), jsonb_build_array(pg_temp.t_area((select karad from k), 500),
       pg_temp.t_area((select satara from k), 0)), null, (select regular from k))$q$);
select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'brand_id', (select regular from k), 'base_rate', 50000)));
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Once Satara is set up, the buyer sees her Satara rate only, never ex-works beside it', 'priced | ₹55,000/tonne | Satara rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Outside her paid reach (Pune): no figure, no ex-works', 'reach_limited | Tara Hardware shares rates with buyers in Satara.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select pune from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('An approved outside buyer still gets her own-area rate, without ex-works', 'priced | ₹55,500/tonne | Check Karad rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select pune from k), 'Fe500', '12mm',
                      '00000000-0000-0000-0000-0000000000a3')$q$);

-- The plan lapses.
select end_plan_early((select id from tp));
select pg_temp.as_owner();
select pg_temp.expect_value('After the lapse she has no ex-works anywhere, though her switch stays saved', 'off',
  $q$select case when is_on then 'on' else 'off' end from ex_works_for('00000000-0000-0000-0000-0000000000a2', (select karad_city from k))$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('A lapsed plan shrinks reach again: a Satara buyer sees no rate', 'reach_limited | Tara Hardware shares rates with buyers in Check Karad.',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000a2', (select regular from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('After the lapse she can still save, keeping Satara (saved, not applied)', 1,
  $q$select save_area_settings((select tmt from k), jsonb_build_array(pg_temp.t_area((select karad from k), 600),
       pg_temp.t_area((select satara from k), 0)), null, (select regular from k))$q$);
select pg_temp.expect_message('...but cannot add a new area beyond her reach', 'Upgrade to reach more areas. Pune is outside your reach.',
  $q$select save_area_settings((select tmt from k), jsonb_build_array(pg_temp.t_area((select karad from k), 600),
       pg_temp.t_area((select satara from k), 0), pg_temp.t_area((select pune from k), 0)), null, (select regular from k))$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Settings beyond her taluka stay saved but stop applying ("saved, not applied on your plan")',
  'Check Karad: priced | Satara: not_on_plan, Saved, not applied on your plan',
  $q$select string_agg(distinct p.area_name || ': ' || concat_ws(', ', p.status, case when p.status <> 'priced' then p.message end), ' | ')
     from rate_preview((select regular from k), (select tmt from k), null, '00000000-0000-0000-0000-0000000000a2') p
    where p.grade = 'Fe500' and p.size = '12mm'$q$);

-- The seller's preview -----------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('Preview: every area in his setup, worked out with the rate he is about to publish (51,000)',
  'Maharashtra ₹57,450/tonne | Kolhapur not_served | Pune ₹57/kg | Sangli not_offered | Satara ₹56,750/tonne | Check Haveli ₹607.39/piece | Check Karad ₹57,300/tonne | Check Kolhapur City ₹57,650/tonne',
  $q$select string_agg(p.area_name || ' ' || coalesce(p.area_rate_text, p.status), ' | ' order by n)
     from (select *, row_number() over () as n from rate_preview((select regular from k), (select tmt from k), 51000)) p
    where p.grade = 'Fe500D' and p.size = '12mm'$q$);
select pg_temp.expect_value('Preview with the current settings: Satara 12mm uses the new 4,800 figure', '4800',
  $q$select size_difference::text from rate_preview((select regular from k), (select tmt from k), 51000) p
     where p.area_name = 'Satara' and p.grade = 'Fe500D' and p.size = '12mm'$q$);
select pg_temp.expect_value('Preview shows ex-works where it is on, and what is not offered and missing, in one go',
  'ex-works rows: 0, not offered: 108, missing: 13',
  $q$select 'ex-works rows: ' || count(*) filter (where p.ex_works_rate is not null)
         || ', not offered: ' || count(*) filter (where p.status = 'not_offered')
         || ', missing: ' || count(*) filter (where p.status = 'missing')
     from rate_preview((select regular from k), (select tmt from k), 51000) p$q$);
select pg_temp.expect_value('Preview without a rate uses his latest published basic rate (50,500)', '₹57,950/tonne',
  $q$select area_rate_text from rate_preview((select regular from k), (select tmt from k)) p
     where p.area_name = 'Satara' and p.grade = 'Fe500D' and p.size = '8mm'$q$);
select pg_temp.expect_value('Ex-works preview for Goa, which he has not set up: every district sees his ex-works rate',
  'North Goa: Ex-Check Karad City ₹56,050/tonne | South Goa: Ex-Check Karad City ₹56,050/tonne',
  $q$select string_agg(area_name || ': ' || shows, ' | ') from ex_works_preview((select regular from k), (select tmt from k),
       (select goa from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('Ex-works preview for Maharashtra: areas he has set up keep their own rate',
  'Kolhapur: Doesn''t currently supply Kolhapur | Nashik: Nashik rate ₹56,950/tonne | Satara: Satara rate ₹56,250/tonne | Check Karad: Check Karad rate ₹56,800/tonne',
  $q$select string_agg(area_name || ': ' || shows, ' | ') from ex_works_preview((select regular from k), (select tmt from k),
       (select mh from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))
     where area_name in ('Kolhapur', 'Nashik', 'Satara', 'Check Karad')$q$);

-- Rates on a past day ----------------------------------------------------------------

select pg_temp.expect_value('Today''s rates for Karad: both of today''s publishes, exactly as published',
  'past ₹56,500/tonne | past ₹56,800/tonne',
  $q$select string_agg(market || ' ' || area_rate_text, ' | ' order by published_at)
     from rates_on_day('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select karad from k),
                       (now() at time zone 'Asia/Kolkata')::date, pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('A day with no publish: no data, never recreated', 'no_data | No data available for that day',
  $q$select concat_ws(' | ', status, message)
     from rates_on_day('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select karad from k),
                       (now() at time zone 'Asia/Kolkata')::date - 1, pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_value('An area that publish did not cover (Goa): no data, never an ex-works figure made up afterwards',
  'no_data | No data available for that day',
  $q$select concat_ws(' | ', status, area_rate_text, ex_works_text, message)
     from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select goa from k),
                     pg_temp.grade('Fe500D'), pg_temp.size('12mm'), null, (select first from pubs))$q$);

-- Who may ask -------------------------------------------------------------------------

select pg_temp.as_visitor();
select pg_temp.expect_message('A visitor who isn''t logged in is told to log in', 'Log in to see rates.',
  $q$select * from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select karad from k))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select pg_temp.expect_message('Another user cannot ask yet (buyers come with subscriptions)', 'Only the seller and ALEE can see these rates for now.',
  $q$select * from buyer_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select karad from k))$q$);
select pg_temp.expect_message('Another user cannot see a seller''s breakdown', 'You can only see the breakdown of your own rates.',
  $q$select * from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select karad from k))$q$);
select pg_temp.expect_message('Another user cannot preview a seller''s rates', 'You can only preview your own rates.',
  $q$select * from rate_preview((select regular from k), (select tmt from k), 50000, '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_refused('Nobody can call the engine directly',
  $q$select * from rate_engine('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), (select karad from k))$q$);
select pg_temp.expect_refused('Nobody can read another seller''s ex-works setting or plan by calling the lookups',
  $q$select * from ex_works_for('00000000-0000-0000-0000-0000000000a1', (select karad from k))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('The seller sees his own breakdown', '50500',
  $q$select base_rate::text from seller_rate('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
       (select karad from k), pg_temp.grade('Fe500D'), pg_temp.size('12mm'))$q$);
select pg_temp.expect_message('Brand must be named', 'Name the brand (Regular is a brand too).',
  $q$select * from seller_rate('00000000-0000-0000-0000-0000000000a1', null, (select tmt from k), (select karad from k))$q$);

-- Money and units ---------------------------------------------------------------------

select pg_temp.as_owner();
select pg_temp.expect_value('Rupees in Indian grouping, paise only when needed',
  '₹56,500 | ₹1,23,456.50 | ₹6.50 | ₹0.84 | ₹1,00,00,000 | -₹500 | ₹596.74 | ₹5.33',
  $q$select concat_ws(' | ', format_rupees(56500), format_rupees(123456.5), format_rupees(6.5), format_rupees(0.84),
                      format_rupees(10000000), format_rupees(-500), format_rupees(596.736),
                      format_rupees(convert_rate(500, 'tonne', 'piece', pg_temp.size('12mm'))))$q$);
select pg_temp.expect_value('Half a paisa rounds up', '₹0.01 | ₹10.13',
  $q$select format_rupees(0.005) || ' | ' || format_rupees(10.125)$q$);
select pg_temp.expect_value('Conversion through weight: 56,000/tonne is 56/kg, 49.728/metre and 596.736/piece for 12mm',
  '56 | 49.728 | 596.736',
  $q$select trim_scale(convert_rate(56000, 'tonne', 'kg')) || ' | ' || trim_scale(convert_rate(56000, 'tonne', 'metre', pg_temp.size('12mm')))
         || ' | ' || trim_scale(convert_rate(56000, 'tonne', 'piece', pg_temp.size('12mm')))$q$);
select pg_temp.expect_refused('A size whose weight is not verified is never used to convert',
  $q$select convert_rate(56000, 'tonne', 'piece', (select z.id from sizes z where not z.is_verified limit 1))$q$);

-- Only approved distributors count, in the buyer's own answer ------------------------------

-- Appointments held by Tara, a retailer, as could exist before the rule.
select pg_temp.as_owner();
insert into territory_allocations (manufacturer_id, distributor_id, brand_id, segment_id, region_id, allocation_type, status, accepted_at)
select '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a2', (select shakti from k), (select tmt from k), x.region, x.kind::territory_type, 'active', now()
  from (values ((select satara from k), 'distributor_prices'), ((select pune from k), 'manufacturer_prices')) as x (region, kind);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Type A held by someone not approved: the buyer sees Farid''s rate, and is not pointed to her',
  'priced | ₹53,000/tonne | Satara rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select satara from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Type B held by someone not approved: Gopal''s rate, with no tag',
  'priced | ₹54,000/tonne | Pune rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b3', (select shakti from k), (select pune from k), 'Fe500', '12mm')$q$);

select remove_role('00000000-0000-0000-0000-0000000000b4', 'distributor', 'Check reason');
select remove_role('00000000-0000-0000-0000-0000000000b5', 'distributor', 'Check reason');
select pg_temp.expect_value('Dev''s approval removed (Type A): Farid''s own rate shows again in Sangli',
  'priced | ₹53,000/tonne | Sangli rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select sangli from k), 'Fe500', '12mm')$q$);
select pg_temp.expect_value('Bala''s approval removed (Type B): Farid''s rate in Kolhapur, and the tag is gone',
  'priced | ₹53,000/tonne | Kolhapur rate',
  $q$select pg_temp.q('00000000-0000-0000-0000-0000000000b2', (select shakti from k), (select kolhapur from k), 'Fe500', '12mm')$q$);
