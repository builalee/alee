-- ============================================================
-- Checks: charts (size, loading, discount), their versions and templates.
-- Covers: sellers see and change only their own charts; old versions can
-- never be edited or added to; zero is stored as zero; exact money; only
-- the chart's own product family sizes; loading and discount rules;
-- templates visible to sellers, changed only by admins, copied as fully
-- separate charts; a used chart switched off only with a replacement;
-- deleting a seller's login removes his charts.
-- Tables: charts, chart_versions, chart_version_figures,
-- chart_version_discounts. Functions: save_chart_version, copy_template.
--
-- Test people (temporary logins, rolled back):
--   A ...a1  seller (TMT)
--   B ...b2  seller (TMT)
--   C ...c3  admin
--   E ...e5  buyer with no seller profile
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

-- Both sellers deal in TMT, per tonne (the family default).
insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id
  from (values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2')) as x (id)
 cross join (select id from segments where name = 'TMT Bars') s;

-- An active, verified size in MS Angles, to prove other families' sizes
-- are refused on a TMT chart.
insert into sizes (segment_id, display_name, sort_order, weight_per_metre_kg, piece_length_m,
                   weight_source, is_verified, is_active)
select id, 'Check angle', 999, 1, 6, 'check', true, true from segments where name = 'MS Angles';

create temp table ids as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '8mm')  as s8,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '10mm') as s10,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '12mm') as s12,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '32mm') as s32,
       (select id from sizes where display_name = 'Check angle') as angle;
grant select on ids to public;

-- Structure -------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on',
  'chart_version_discounts=true, chart_version_figures=true, chart_versions=true, charts=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace
       and relname in ('charts', 'chart_versions', 'chart_version_figures', 'chart_version_discounts')$q$);
select pg_temp.expect_value('Money is stored as exact rupees and percentages',
  'flat_amount=rupees, percent=percentage, amount=rupees',
  $q$select string_agg(column_name || '=' || domain_name, ', ' order by table_name, column_name)
     from information_schema.columns
     where table_schema = 'public' and table_name in ('chart_version_figures', 'chart_version_discounts')
       and column_name in ('amount', 'flat_amount', 'percent')$q$);

-- A creates his charts ----------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_rows('A creates a TMT size chart', 1,
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'size', 'A Size')$q$);
select pg_temp.expect_rows('A creates a second TMT size chart', 1,
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'size', 'A Size 2')$q$);
select pg_temp.expect_rows('A creates a TMT loading chart', 1,
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'loading', 'A Loading')$q$);
select pg_temp.expect_rows('A creates a TMT discount chart', 1,
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'discount', 'A Discount')$q$);
select pg_temp.expect_rows('A creates a spare chart', 1,
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'size', 'A Spare')$q$);
select pg_temp.expect_refused('A creates a second active loading chart with the same name',
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'loading', 'a loading')$q$);
select pg_temp.expect_refused('A creates a chart for B',
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000b2', (select tmt from ids), 'size', 'Fake')$q$);
select pg_temp.expect_refused('A creates a template',
  $q$insert into charts (seller_id, is_template, segment_id, chart_type, name)
     values (null, true, (select tmt from ids), 'size', 'Fake template')$q$);
select pg_temp.expect_refused('A creates a chart already marked as used',
  $q$insert into charts (seller_id, segment_id, chart_type, name, in_use_since)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'size', 'Fake used', now())$q$);

-- Keep the chart ids so other people can try to reach them directly.
select pg_temp.as_owner();
create temp table cid as
select (select id from charts where name = 'A Size')     as a_size,
       (select id from charts where name = 'A Size 2')   as a_size2,
       (select id from charts where name = 'A Loading')  as a_loading,
       (select id from charts where name = 'A Discount') as a_discount,
       (select id from charts where name = 'A Spare')    as a_spare;
grant select on cid to public;

-- A saves size chart versions -------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_value('A saves version 1 of his size chart (8mm +500, 10mm -200, 12mm 0)', 'saved',
  $q$select case when save_chart_version((select a_size from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids),  'amount', 500),
       jsonb_build_object('size_id', (select s10 from ids), 'amount', -200),
       jsonb_build_object('size_id', (select s12 from ids), 'amount', 0))) is not null then 'saved' end$q$);
select pg_temp.expect_value('Zero is stored as 0, not left empty', '0',
  $q$select coalesce(f.amount::text, 'EMPTY') from chart_version_figures f
     join chart_versions v on v.id = f.version_id
     where v.chart_id = (select a_size from cid) and v.version_number = 1 and f.size_id = (select s12 from ids)$q$);
select pg_temp.expect_value('Version 1 holds all three figures, including the negative one', '8mm=500, 10mm=-200, 12mm=0',
  $q$select string_agg(z.display_name || '=' || f.amount, ', ' order by z.sort_order)
     from chart_version_figures f join chart_versions v on v.id = f.version_id join sizes z on z.id = f.size_id
     where v.chart_id = (select a_size from cid) and v.version_number = 1$q$);
select pg_temp.expect_value('Version 1 records its unit and when it was saved', 'tonne, today',
  $q$select unit || ', ' || case when created_at::date = current_date then 'today' else created_at::text end
     from chart_versions where chart_id = (select a_size from cid) and version_number = 1$q$);

select pg_temp.expect_refused('A saves a figure with no amount',
  $q$select save_chart_version((select a_size from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids))))$q$);
select pg_temp.expect_refused('A saves a figure with no size on a size chart',
  $q$select save_chart_version((select a_size from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', null, 'amount', 100)))$q$);
select pg_temp.expect_refused('A puts an MS Angles size on his TMT chart',
  $q$select save_chart_version((select a_size from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select angle from ids), 'amount', 100)))$q$);
select pg_temp.expect_refused('A gives the same size twice',
  $q$select save_chart_version((select a_size from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 100),
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 200)))$q$);
select pg_temp.expect_refused('A saves figures per piece',
  $q$select save_chart_version((select a_size from cid), 'piece', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 100)))$q$);
select pg_temp.expect_refused('A saves an amount finer than 4 decimal places (refused, not rounded)',
  $q$select save_chart_version((select a_size from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 10.12345)))$q$);
select pg_temp.expect_value('A saves a per-kg figure with paise (6.5330)', 'saved',
  $q$select case when save_chart_version((select a_spare from cid), 'kg', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 6.5330))) is not null then 'saved' end$q$);
select pg_temp.expect_value('The per-kg figure is stored exactly, in kg', '6.5330 per kg',
  $q$select f.amount || ' per ' || v.unit from chart_version_figures f join chart_versions v on v.id = f.version_id
     where v.chart_id = (select a_spare from cid)$q$);

select pg_temp.expect_value('A saves version 2 (12mm changed to +50)', 'saved',
  $q$select case when save_chart_version((select a_size from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids),  'amount', 500),
       jsonb_build_object('size_id', (select s10 from ids), 'amount', -200),
       jsonb_build_object('size_id', (select s12 from ids), 'amount', 50))) is not null then 'saved' end$q$);
select pg_temp.expect_value('The chart now has versions 1 and 2', '1, 2',
  $q$select string_agg(version_number::text, ', ' order by version_number) from chart_versions
     where chart_id = (select a_size from cid)$q$);
select pg_temp.expect_value('Version 1 is unchanged: 12mm is still 0', '0',
  $q$select f.amount::text from chart_version_figures f join chart_versions v on v.id = f.version_id
     where v.chart_id = (select a_size from cid) and v.version_number = 1 and f.size_id = (select s12 from ids)$q$);

-- Trying to edit an old version -----------------------------------------------

select pg_temp.expect_refused('A changes a figure in version 1',
  $q$update chart_version_figures set amount = 999
     where version_id = (select id from chart_versions where chart_id = (select a_size from cid) and version_number = 1)$q$);
select pg_temp.expect_refused('A adds a figure to version 1',
  $q$insert into chart_version_figures (version_id, size_id, amount)
     values ((select id from chart_versions where chart_id = (select a_size from cid) and version_number = 1),
             (select s32 from ids), 100)$q$);
select pg_temp.expect_refused('A changes version 1''s unit',
  $q$update chart_versions set unit = 'kg' where chart_id = (select a_size from cid) and version_number = 1$q$);
select pg_temp.expect_refused('A deletes version 1',
  $q$delete from chart_versions where chart_id = (select a_size from cid) and version_number = 1$q$);
select pg_temp.expect_refused('A writes a version directly, bypassing the save function',
  $q$insert into chart_versions (chart_id, version_number, unit) values ((select a_size from cid), 9, 'tonne')$q$);

select pg_temp.as_owner();
select pg_temp.expect_refused('Even the database owner cannot change a figure in version 1',
  $q$update chart_version_figures set amount = 999
     where version_id = (select id from chart_versions where chart_id = (select a_size from cid) and version_number = 1)$q$);
select pg_temp.expect_refused('Even the database owner cannot add a figure to version 1',
  $q$insert into chart_version_figures (version_id, size_id, amount)
     values ((select id from chart_versions where chart_id = (select a_size from cid) and version_number = 1),
             (select s32 from ids), 100)$q$);
select pg_temp.expect_refused('Even the database owner cannot delete version 1',
  $q$delete from chart_versions where chart_id = (select a_size from cid) and version_number = 1$q$);

-- Loading and discount charts -------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_value('A saves loading: 250 for all sizes, 300 for 32mm', 'saved',
  $q$select case when save_chart_version((select a_loading from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', null, 'amount', 250),
       jsonb_build_object('size_id', (select s32 from ids), 'amount', 300))) is not null then 'saved' end$q$);
select pg_temp.expect_value('Loading figures stored', 'all sizes=250, 32mm=300',
  $q$select string_agg(coalesce(z.display_name, 'all sizes') || '=' || f.amount, ', ' order by z.sort_order nulls first)
     from chart_version_figures f join chart_versions v on v.id = f.version_id left join sizes z on z.id = f.size_id
     where v.chart_id = (select a_loading from cid)$q$);
select pg_temp.expect_refused('A saves loading with no all-sizes figure',
  $q$select save_chart_version((select a_loading from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s32 from ids), 'amount', 300)))$q$);
select pg_temp.expect_refused('A saves loading with two all-sizes figures',
  $q$select save_chart_version((select a_loading from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', null, 'amount', 250),
       jsonb_build_object('size_id', null, 'amount', 260)))$q$);
select pg_temp.expect_refused('A gives a loading chart a discount',
  $q$select save_chart_version((select a_loading from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', null, 'amount', 250)), '{"kind": "flat", "amount": 100}')$q$);

select pg_temp.expect_value('A saves a flat discount of 500 per tonne', 'saved',
  $q$select case when save_chart_version((select a_discount from cid), 'tonne', null,
       '{"kind": "flat", "amount": 500}') is not null then 'saved' end$q$);
select pg_temp.expect_value('A saves a 1.5% discount as version 2', 'saved',
  $q$select case when save_chart_version((select a_discount from cid), 'tonne', null,
       '{"kind": "percent", "percent": 1.5}') is not null then 'saved' end$q$);
select pg_temp.expect_value('Both discount versions stored as given', 'v1 flat 500 per tonne, v2 percent 1.5',
  $q$select string_agg('v' || v.version_number || ' ' || d.kind || ' ' ||
       case when d.kind = 'flat' then d.flat_amount || ' per ' || v.unit else d.percent::text end,
       ', ' order by v.version_number)
     from chart_version_discounts d join chart_versions v on v.id = d.version_id
     where v.chart_id = (select a_discount from cid)$q$);
select pg_temp.expect_refused('A saves a 120% discount',
  $q$select save_chart_version((select a_discount from cid), 'tonne', null, '{"kind": "percent", "percent": 120}')$q$);
select pg_temp.expect_refused('A saves a negative percentage',
  $q$select save_chart_version((select a_discount from cid), 'tonne', null, '{"kind": "percent", "percent": -1}')$q$);
select pg_temp.expect_refused('A saves a negative flat discount',
  $q$select save_chart_version((select a_discount from cid), 'tonne', null, '{"kind": "flat", "amount": -10}')$q$);
select pg_temp.expect_refused('A saves a percent discount with no percentage',
  $q$select save_chart_version((select a_discount from cid), 'tonne', null, '{"kind": "percent"}')$q$);
select pg_temp.expect_refused('A gives a discount chart per-size figures',
  $q$select save_chart_version((select a_discount from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 100)), '{"kind": "flat", "amount": 500}')$q$);

-- A changes his own charts ----------------------------------------------------

select pg_temp.expect_rows('A renames his own chart', 1,
  $q$update charts set name = 'A Size (main)' where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A moves a chart to another product family',
  $q$update charts set segment_id = (select id from segments where name = 'MS Angles') where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A turns a size chart into a loading chart',
  $q$update charts set chart_type = 'loading' where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A hands his chart to B',
  $q$update charts set seller_id = '00000000-0000-0000-0000-0000000000b2' where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A marks his own chart as used',
  $q$update charts set in_use_since = now() where id = (select a_size from cid)$q$);
select pg_temp.expect_rows('A switches off a chart no publish has used', 1,
  $q$update charts set is_active = false where id = (select a_spare from cid)$q$);
select pg_temp.expect_refused('A saves a version on a switched-off chart',
  $q$select save_chart_version((select a_spare from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 100)))$q$);

-- B, another seller, goes after A's charts ------------------------------------

-- Keep A's version ids so B can ask for them directly.
select pg_temp.as_owner();
create temp table avid as
select v.id from chart_versions v join charts c on c.id = v.chart_id
 where c.seller_id = '00000000-0000-0000-0000-0000000000a1';
grant select on avid to public;
select pg_temp.expect_value('A has saved chart versions for B to go after', 'yes',
  $q$select case when count(*) >= 5 then 'yes' else 'only ' || count(*) end from avid$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');

select pg_temp.expect_value('B reads A''s charts: none come back', '0',
  $q$select count(*)::text from charts where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('B reads A''s chart by its id: nothing comes back', '0',
  $q$select count(*)::text from charts where id = (select a_size from cid)$q$);
select pg_temp.expect_value('B reads A''s versions by their ids: none come back', '0',
  $q$select count(*)::text from chart_versions where id in (select id from avid)$q$);
select pg_temp.expect_value('B reads A''s figures by version id: none come back', '0',
  $q$select count(*)::text from chart_version_figures where version_id in (select id from avid)$q$);
select pg_temp.expect_value('B reads A''s discounts by version id: none come back', '0',
  $q$select count(*)::text from chart_version_discounts where version_id in (select id from avid)$q$);
select pg_temp.expect_rows('B renames A''s chart', 0,
  $q$update charts set name = 'Hacked' where id = (select a_size from cid)$q$);
select pg_temp.expect_rows('B switches off A''s chart', 0,
  $q$update charts set is_active = false where id = (select a_loading from cid)$q$);
select pg_temp.expect_refused('B saves a new version of A''s chart',
  $q$select save_chart_version((select a_size from cid), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 1)))$q$);
select pg_temp.expect_refused('B copies something into A''s charts',
  $q$select copy_template((select a_size from cid), 'x', '00000000-0000-0000-0000-0000000000a1')$q$);

-- Visitor, not logged in --------------------------------------------------------

select pg_temp.as_visitor();

select pg_temp.expect_refused('Visitor reads charts', $q$select * from charts$q$);
select pg_temp.expect_refused('Visitor reads chart versions', $q$select * from chart_versions$q$);
select pg_temp.expect_refused('Visitor reads chart figures', $q$select * from chart_version_figures$q$);
select pg_temp.expect_refused('Visitor saves a chart version',
  $q$select save_chart_version((select a_size from cid), 'tonne', '[]')$q$);
select pg_temp.expect_refused('Visitor copies a template',
  $q$select copy_template((select a_size from cid))$q$);

-- Admin creates templates -----------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

select pg_temp.expect_rows('Admin creates a TMT size template', 1,
  $q$insert into charts (seller_id, is_template, segment_id, chart_type, name)
     values (null, true, (select tmt from ids), 'size', 'Check TMT template')$q$);
select pg_temp.expect_value('Admin saves the template''s figures (8mm 400, 12mm 0)', 'saved',
  $q$select case when save_chart_version((select id from charts where name = 'Check TMT template'), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids),  'amount', 400),
       jsonb_build_object('size_id', (select s12 from ids), 'amount', 0))) is not null then 'saved' end$q$);
select pg_temp.expect_rows('Admin creates a second template', 1,
  $q$insert into charts (seller_id, is_template, segment_id, chart_type, name)
     values (null, true, (select tmt from ids), 'size', 'Check old template')$q$);
select pg_temp.expect_value('Admin gives it figures', 'saved',
  $q$select case when save_chart_version((select id from charts where name = 'Check old template'), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 100))) is not null then 'saved' end$q$);
select pg_temp.expect_rows('Admin switches the second template off', 1,
  $q$update charts set is_active = false where name = 'Check old template'$q$);
select pg_temp.expect_value('Admin sees A''s charts', '5',
  $q$select count(*)::text from charts where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Templates: who sees them and copying ----------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_value('A buyer who is not a seller sees no templates', '0',
  $q$select count(*)::text from charts where is_template$q$);
select pg_temp.expect_refused('A buyer who is not a seller copies a template',
  $q$select copy_template((select id from charts where name = 'Check TMT template'))$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('Seller A sees the active template, not the switched-off one', 'Check TMT template',
  $q$select string_agg(name, ', ') from charts where is_template and name like 'Check%template'$q$);
select pg_temp.expect_value('A reads the template''s figures', '8mm=400, 12mm=0',
  $q$select string_agg(z.display_name || '=' || f.amount, ', ' order by z.sort_order)
     from chart_version_figures f join chart_versions v on v.id = f.version_id
     join charts c on c.id = v.chart_id join sizes z on z.id = f.size_id
     where c.name = 'Check TMT template'$q$);
select pg_temp.expect_rows('A changes the template''s name (nothing changes)', 0,
  $q$update charts set name = 'Mine now' where name = 'Check TMT template'$q$);
select pg_temp.expect_rows('A switches the template off (nothing changes)', 0,
  $q$update charts set is_active = false where name = 'Check TMT template'$q$);
select pg_temp.expect_refused('A saves a new version of the template',
  $q$select save_chart_version((select id from charts where name = 'Check TMT template'), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids), 'amount', 1)))$q$);
select pg_temp.expect_value('A copies the template into his own chart', 'copied',
  $q$select case when copy_template((select id from charts where name = 'Check TMT template'), 'A From Template') is not null
     then 'copied' end$q$);
select pg_temp.expect_value('The copy is A''s, records its template, and has version 1 with the template''s figures',
  'A / Check TMT template / v1 / tonne / 8mm=400, 12mm=0',
  $q$select case when c.seller_id = '00000000-0000-0000-0000-0000000000a1' then 'A' else 'NOT A' end
            || ' / ' || t.name || ' / v' || v.version_number || ' / ' || v.unit || ' / '
            || (select string_agg(z.display_name || '=' || f.amount, ', ' order by z.sort_order)
                  from chart_version_figures f join sizes z on z.id = f.size_id where f.version_id = v.id)
     from charts c join charts t on t.id = c.copied_from_template_id
     join chart_versions v on v.chart_id = c.id
     where c.name = 'A From Template'$q$);
select pg_temp.expect_refused('A copies a switched-off template',
  $q$select copy_template((select id from charts where name = 'Check old template' and is_template), 'x')$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_refused('A switched-off template cannot be copied, even by an admin using its id',
  $q$select copy_template(id, 'x', '00000000-0000-0000-0000-0000000000a1') from charts where name = 'Check old template'$q$);

-- Changing the template never changes A's copy
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin saves template version 2 (8mm 999)', 'saved',
  $q$select case when save_chart_version((select id from charts where name = 'Check TMT template'), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids),  'amount', 999),
       jsonb_build_object('size_id', (select s12 from ids), 'amount', 0))) is not null then 'saved' end$q$);
select pg_temp.expect_value('Admin copies the template for seller B (setting B up)', 'copied',
  $q$select case when copy_template((select id from charts where name = 'Check TMT template'), 'B From Template',
       '00000000-0000-0000-0000-0000000000b2') is not null then 'copied' end$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('A''s copy still says 8mm = 400 after the template changed', '400',
  $q$select f.amount::text from chart_version_figures f join chart_versions v on v.id = f.version_id
     join charts c on c.id = v.chart_id
     where c.name = 'A From Template' and f.size_id = (select s8 from ids)$q$);
select pg_temp.expect_value('A changes his copy (8mm 450)', 'saved',
  $q$select case when save_chart_version((select id from charts where name = 'A From Template'), 'tonne', jsonb_build_array(
       jsonb_build_object('size_id', (select s8 from ids),  'amount', 450),
       jsonb_build_object('size_id', (select s12 from ids), 'amount', 0))) is not null then 'saved' end$q$);
select pg_temp.expect_value('The template''s latest 8mm is still 999', '999',
  $q$select f.amount::text from chart_version_figures f join chart_versions v on v.id = f.version_id
     join charts c on c.id = v.chart_id
     where c.name = 'Check TMT template' and f.size_id = (select s8 from ids)
     order by v.version_number desc limit 1$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('B sees the copy the admin made for him, at the new template figure', 'B From Template: 8mm=999',
  $q$select c.name || ': 8mm=' || f.amount from charts c join chart_versions v on v.chart_id = c.id
     join chart_version_figures f on f.version_id = v.id
     where c.seller_id = '00000000-0000-0000-0000-0000000000b2' and f.size_id = (select s8 from ids)$q$);

-- A chart a publish has used --------------------------------------------------

-- The publish engine (server side) marks A's size chart as used.
select pg_temp.as_owner();
select pg_temp.expect_rows('The publish engine marks A''s size chart as used', 1,
  $q$update charts set in_use_since = now() where id = (select a_size from cid)$q$);
create temp table bcid as
select (select id from charts where name = 'B From Template') as b_copy;
grant select on bcid to public;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_refused('A switches off the used chart without a replacement',
  $q$update charts set is_active = false where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A names B''s chart as the replacement',
  $q$update charts set is_active = false, replaced_by_id = (select b_copy from bcid) where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A names his loading chart as the replacement (wrong type)',
  $q$update charts set is_active = false, replaced_by_id = (select a_loading from cid) where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A names a switched-off chart as the replacement',
  $q$update charts set is_active = false, replaced_by_id = (select a_spare from cid) where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A clears the used mark',
  $q$update charts set in_use_since = null where id = (select a_size from cid)$q$);
select pg_temp.expect_rows('A switches off the used chart, replaced by his other size chart', 1,
  $q$update charts set is_active = false, replaced_by_id = (select a_size2 from cid) where id = (select a_size from cid)$q$);
select pg_temp.expect_refused('A deletes a chart',
  $q$delete from charts where id = (select a_size from cid)$q$);

select pg_temp.as_owner();
select pg_temp.expect_refused('Even the database owner cannot delete a chart on its own',
  $q$delete from charts where id = (select a_spare from cid)$q$);
select pg_temp.expect_refused('Even the database owner cannot unmark a used chart',
  $q$update charts set in_use_since = null where id = (select a_size from cid)$q$);

-- Deleting a seller's login removes his charts --------------------------------

select pg_temp.expect_rows('Delete A''s login', 1,
  $q$delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Left for A: charts / versions', '0/0',
  $q$select (select count(*) from charts where seller_id = '00000000-0000-0000-0000-0000000000a1') || '/' ||
            (select count(*) from chart_versions where chart_id in (select a_size from cid union all
               select a_loading from cid union all select a_discount from cid))$q$);
select pg_temp.expect_value('The template is untouched: 2 versions', '2',
  $q$select count(*)::text from chart_versions v join charts c on c.id = v.chart_id
     where c.name = 'Check TMT template'$q$);
