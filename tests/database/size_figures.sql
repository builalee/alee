-- ============================================================
-- Checks: size differences and loading, looked up one size at a time.
-- Covers the owner's example: Maharashtra 8mm +6500, 10mm and 12mm +5500;
-- Satara only 10mm and 12mm +5000. A Satara buyer gets 8mm +6500 from
-- Maharashtra and 10mm/12mm +5000 from Satara. Also: zero is a real figure
-- and never carries down; a size the seller offers with no figure anywhere
-- is MISSING, never zero; a grade's own chart is looked at before the
-- family chart at each area; loading per size; older versions still look
-- up as they were; nobody but the seller and admins can look figures up.
-- Function: resolve_size_figures.
--
-- Test people (temporary logins, rolled back):
--   D ...d4  seller, TMT per tonne, offers 8mm, 10mm, 12mm, 16mm
--   B ...b2  another seller
--   E ...e5  buyer (no seller profile)
--   C ...c3  admin
--
-- D's setup (TMT), version 1:
--   Maharashtra  sizes:   8mm 6500, 10mm 5500, 12mm 5500
--                Fe550D's own chart: 8mm 7000
--                loading: all sizes 250, 32mm 300
--   Satara       sizes:   10mm 5000, 12mm 5000
--                Fe550D's own chart: 12mm 5200
--                loading: all sizes 200
--   Pune         sizes:   8mm 0   (a real zero)
--   Kolhapur     EXCLUDED
--   No size has a figure for 16mm anywhere.
-- ============================================================

-- Test data -------------------------------------------------------------------

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000d4', '919800000004', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', '919800000005', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'wholesaler', r.id
  from (values ('00000000-0000-0000-0000-0000000000d4', 'Dinesh', '+919800000004'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala', '+919800000002'),
               ('00000000-0000-0000-0000-0000000000e5', 'Esha', '+919800000005')) as x (id, name, phone)
 cross join (select id from regions where level = 'district' and name = 'Satara') r;

insert into seller_profiles (account_id, store_name, region_id, is_public)
select x.id::uuid, x.store, r.id, true
  from (values ('00000000-0000-0000-0000-0000000000d4', 'Dinesh Steel'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala Traders')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Satara') r;

insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id
  from (values ('00000000-0000-0000-0000-0000000000d4'), ('00000000-0000-0000-0000-0000000000b2')) as x (id)
 cross join (select id from segments where name = 'TMT Bars') s;

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select id from regions where level = 'district' and name = 'Kolhapur') as kolhapur,
       (select id from products where name = 'Fe500D') as fe500d,
       (select id from products where name = 'Fe550D') as fe550d;
grant select on k to public;

-- D builds his charts and setup the normal way.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');

insert into seller_sizes (seller_id, size_id, is_selected)
select '00000000-0000-0000-0000-0000000000d4', z.id, true
  from sizes z join segments s on s.id = z.segment_id
 where s.name = 'TMT Bars' and z.display_name in ('8mm', '10mm', '12mm', '16mm');

insert into charts (seller_id, segment_id, chart_type, name)
select '00000000-0000-0000-0000-0000000000d4', (select tmt from k), x.type::chart_type, x.name
  from (values ('size', 'D Maharashtra sizes'), ('size', 'D Satara sizes'), ('size', 'D Pune sizes'),
               ('size', 'D Fe550D Maharashtra'), ('size', 'D Fe550D Satara'),
               ('loading', 'D Maharashtra loading'), ('loading', 'D Satara loading')) as x (type, name);

create temp table figs (chart text, size text, amount numeric);
grant all on figs to public;
insert into figs values
  ('D Maharashtra sizes', '8mm', 6500), ('D Maharashtra sizes', '10mm', 5500), ('D Maharashtra sizes', '12mm', 5500),
  ('D Satara sizes', '10mm', 5000), ('D Satara sizes', '12mm', 5000),
  ('D Pune sizes', '8mm', 0),
  ('D Fe550D Maharashtra', '8mm', 7000),
  ('D Fe550D Satara', '12mm', 5200),
  ('D Maharashtra loading', null, 250), ('D Maharashtra loading', '32mm', 300),
  ('D Satara loading', null, 200);

select save_chart_version(c.id, 'tonne',
         (select jsonb_agg(jsonb_build_object('size_id',
                   (select z.id from sizes z where z.segment_id = c.segment_id and z.display_name = f.size),
                   'amount', f.amount))
            from figs f where f.chart = c.name))
  from charts c where c.seller_id = '00000000-0000-0000-0000-0000000000d4';

create temp table chart_ids as
select name, id from charts where seller_id = '00000000-0000-0000-0000-0000000000d4';
grant select on chart_ids to public;

create temp table setup as
select jsonb_build_array(
  jsonb_build_object('region_id', (select mh from k),
    'size_chart_id', (select id from chart_ids where name = 'D Maharashtra sizes'),
    'loading_chart_id', (select id from chart_ids where name = 'D Maharashtra loading'),
    'grades', jsonb_build_array(jsonb_build_object('product_id', (select fe550d from k),
                'size_chart_id', (select id from chart_ids where name = 'D Fe550D Maharashtra')))),
  jsonb_build_object('region_id', (select satara from k),
    'size_chart_id', (select id from chart_ids where name = 'D Satara sizes'),
    'loading_chart_id', (select id from chart_ids where name = 'D Satara loading'),
    'grades', jsonb_build_array(jsonb_build_object('product_id', (select fe550d from k),
                'size_chart_id', (select id from chart_ids where name = 'D Fe550D Satara')))),
  jsonb_build_object('region_id', (select pune from k),
    'size_chart_id', (select id from chart_ids where name = 'D Pune sizes')),
  jsonb_build_object('region_id', (select kolhapur from k), 'excluded', true)
) as v1;
grant select on setup to public;

select save_area_settings((select tmt from k), (select v1 from setup));

-- One readable line per lookup: each size D offers, its figure and where it
-- came from, or MISSING.
create function pg_temp.sizes_for(p_region uuid, p_grade uuid default null, p_version uuid default null)
returns text language sql as $$
  select coalesce(string_agg(
           r.display_name || ' ' ||
           case when r.is_missing then 'MISSING'
                else r.size_difference || ' from ' || r.size_difference_from
                     || case when p_grade is null then '' else ' (' || r.size_difference_chart || ')' end
           end, ', ' order by z.sort_order), '(no sizes: not served)')
    from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), p_region, p_grade, p_version) r
    join sizes z on z.id = r.size_id
   where r.is_offered
$$;

create function pg_temp.loading_for(p_region uuid, p_size text)
returns text language sql as $$
  select coalesce(r.loading::text, '-') || ' from ' || coalesce(r.loading_from, '-')
    from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), p_region) r
   where r.display_name = p_size
$$;

-- The owner's example -----------------------------------------------------------

select pg_temp.expect_value('Satara buyer: 8mm from Maharashtra, 10mm and 12mm from Satara',
  '8mm 6500 from Maharashtra, 10mm 5000 from Satara, 12mm 5000 from Satara, 16mm MISSING',
  $q$select pg_temp.sizes_for((select satara from k))$q$);
select pg_temp.expect_value('Maharashtra buyer elsewhere (Nashik): all from Maharashtra',
  '8mm 6500 from Maharashtra, 10mm 5500 from Maharashtra, 12mm 5500 from Maharashtra, 16mm MISSING',
  $q$select pg_temp.sizes_for((select id from regions where level = 'district' and name = 'Nashik'))$q$);
select pg_temp.expect_value('Figures are in the chart''s unit', 'tonne',
  $q$select string_agg(distinct size_difference_unit::text, ',')
     from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k))
     where size_difference is not null$q$);

-- Zero and missing ----------------------------------------------------------------

select pg_temp.expect_value('Zero never carries down: Pune 8mm is 0 from Pune, not 6500 from Maharashtra',
  '8mm 0 from Pune, 10mm 5500 from Maharashtra, 12mm 5500 from Maharashtra, 16mm MISSING',
  $q$select pg_temp.sizes_for((select pune from k))$q$);
select pg_temp.expect_value('An offered size with no figure anywhere is missing, with no figure', '16mm: missing, figure empty',
  $q$select display_name || ': ' || case when is_missing then 'missing' else 'NOT missing' end
            || ', figure ' || coalesce(size_difference::text, 'empty')
     from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k))
     where display_name = '16mm'$q$);
select pg_temp.expect_value('A size D does not offer is listed as not offered, not missing', '20mm: not offered, not missing',
  $q$select display_name || ': ' || case when is_offered then 'offered' else 'not offered' end
            || ', ' || case when is_missing then 'MISSING' else 'not missing' end
     from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k))
     where display_name = '20mm'$q$);
select pg_temp.expect_value('An excluded area returns no sizes at all', '(no sizes: not served)',
  $q$select pg_temp.sizes_for((select kolhapur from k))$q$);

-- A grade's own size chart ----------------------------------------------------------

select pg_temp.expect_value('Fe550D in Satara: at each area its own chart first, then the family chart',
  '8mm 7000 from Maharashtra (grade), 10mm 5000 from Satara (family), 12mm 5200 from Satara (grade), 16mm MISSING',
  $q$select pg_temp.sizes_for((select satara from k), (select fe550d from k))$q$);
select pg_temp.expect_value('Fe500D in Satara (no chart of its own) uses the family figures',
  '8mm 6500 from Maharashtra (family), 10mm 5000 from Satara (family), 12mm 5000 from Satara (family), 16mm MISSING',
  $q$select pg_temp.sizes_for((select satara from k), (select fe500d from k))$q$);
select pg_temp.expect_value('Fe550D in Pune: Pune''s family 0 for 8mm beats Maharashtra''s Fe550D chart (closer area wins)',
  '8mm 0 from Pune (family), 10mm 5500 from Maharashtra (family), 12mm 5500 from Maharashtra (family), 16mm MISSING',
  $q$select pg_temp.sizes_for((select pune from k), (select fe550d from k))$q$);

-- Loading per size --------------------------------------------------------------------

select pg_temp.expect_value('Loading in Satara, 8mm: Satara''s all-sizes figure', '200 from Satara',
  $q$select pg_temp.loading_for((select satara from k), '8mm')$q$);
select pg_temp.expect_value('Loading in Satara, 32mm: Satara''s chart answers for every size, so 200 (not Maharashtra''s 300)',
  '200 from Satara',
  $q$select pg_temp.loading_for((select satara from k), '32mm')$q$);
select pg_temp.expect_value('Loading in Pune (no loading chart of its own), 8mm: Maharashtra''s all-sizes figure', '250 from Maharashtra',
  $q$select pg_temp.loading_for((select pune from k), '8mm')$q$);
select pg_temp.expect_value('Loading in Pune, 32mm: Maharashtra''s 32mm figure beats its all-sizes figure', '300 from Maharashtra',
  $q$select pg_temp.loading_for((select pune from k), '32mm')$q$);

-- Changes and versions ----------------------------------------------------------------

select pg_temp.expect_value('D gives 16mm a figure of 0 in his Satara chart', 'saved',
  $q$select case when save_chart_version((select id from chart_ids where name = 'D Satara sizes'), 'tonne',
       (select jsonb_agg(jsonb_build_object('size_id', z.id, 'amount',
                case z.display_name when '16mm' then 0 else 5000 end))
          from sizes z where z.segment_id = (select tmt from k) and z.display_name in ('10mm', '12mm', '16mm'))) is not null
     then 'saved' end$q$);
select pg_temp.expect_value('Satara 16mm is now 0, a real figure, and no longer missing',
  '8mm 6500 from Maharashtra, 10mm 5000 from Satara, 12mm 5000 from Satara, 16mm 0 from Satara',
  $q$select pg_temp.sizes_for((select satara from k))$q$);
select pg_temp.expect_value('Elsewhere 16mm is still missing (the 0 is Satara''s only)', '16mm MISSING',
  $q$select split_part(pg_temp.sizes_for((select pune from k)), ', ', 4)$q$);

select pg_temp.expect_value('D saves version 2 without Satara''s size chart', 'saved',
  $q$select case when save_area_settings((select tmt from k), jsonb_build_array(
       (select v1 from setup) -> 0,
       jsonb_build_object('region_id', (select satara from k),
         'loading_chart_id', (select id from chart_ids where name = 'D Satara loading')),
       (select v1 from setup) -> 2,
       (select v1 from setup) -> 3)) is not null then 'saved' end$q$);
select pg_temp.expect_value('Now Satara 10mm and 12mm carry down from Maharashtra',
  '8mm 6500 from Maharashtra, 10mm 5500 from Maharashtra, 12mm 5500 from Maharashtra, 16mm MISSING',
  $q$select pg_temp.sizes_for((select satara from k))$q$);
select pg_temp.expect_value('Looking up version 1 still uses Satara''s chart',
  '8mm 6500 from Maharashtra, 10mm 5000 from Satara, 12mm 5000 from Satara, 16mm 0 from Satara',
  $q$select pg_temp.sizes_for((select satara from k), null,
       (select id from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000d4' and version_number = 1))$q$);

-- Nobody else can look figures up -----------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('Another seller looks up D''s size figures for Satara',
  $q$select * from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k))$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_refused('A buyer in Satara looks up D''s size figures',
  $q$select * from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k))$q$);

select pg_temp.as_visitor();
select pg_temp.expect_refused('Visitor looks up D''s size figures',
  $q$select * from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k))$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin looks up D''s Satara figures', '8mm 6500 from Maharashtra',
  $q$select display_name || ' ' || size_difference || ' from ' || size_difference_from
     from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select satara from k))
     where display_name = '8mm'$q$);

-- Not set anywhere is reported empty, never as 0 ----------------------------------
-- The rate engine treats any price-raising setting that is not set in any
-- area (loading, area difference, grade premium, size difference) as
-- MISSING, never zero (docs/decisions.md 2.24). That only works if the
-- lookups report "not set" as empty. A seller who means zero enters 0.

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_value('D saves version 3: Pune only, a size chart and nothing else', 'saved',
  $q$select case when save_area_settings((select tmt from k), jsonb_build_array(
       jsonb_build_object('region_id', (select pune from k),
         'size_chart_id', (select id from chart_ids where name = 'D Pune sizes')))) is not null then 'saved' end$q$);
select pg_temp.expect_value('Area difference set nowhere: reported empty, not 0', 'served, area difference EMPTY',
  $q$select case when is_served then 'served' else 'not served' end || ', area difference '
            || coalesce(area_difference::text, 'EMPTY')
     from resolve_area_settings('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select pune from k))$q$);
select pg_temp.expect_value('Grade premium set nowhere: reported empty, not 0', 'premium EMPTY',
  $q$select 'premium ' || coalesce(grade_premium::text, 'EMPTY')
     from resolve_area_settings('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select pune from k),
                                (select fe550d from k))$q$);
select pg_temp.expect_value('Loading set nowhere: reported empty for every size, not 0', 'loading EMPTY for all sizes',
  $q$select case when bool_and(loading is null) then 'loading EMPTY for all sizes' else 'SOME SIZE HAS LOADING' end
     from resolve_size_figures('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select pune from k))$q$);
select pg_temp.expect_value('Discount set nowhere: reported empty (means no discount)', 'discount EMPTY',
  $q$select 'discount ' || coalesce(discount_chart_id::text, 'EMPTY')
     from resolve_area_settings('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select pune from k))$q$);

select pg_temp.expect_value('D saves version 4: Pune with an explicit 0 area difference and 0 premium', 'saved',
  $q$select case when save_area_settings((select tmt from k), jsonb_build_array(
       jsonb_build_object('region_id', (select pune from k), 'area_difference', 0,
         'size_chart_id', (select id from chart_ids where name = 'D Pune sizes'),
         'grades', jsonb_build_array(jsonb_build_object('product_id', (select fe550d from k), 'premium', 0))))) is not null
     then 'saved' end$q$);
select pg_temp.expect_value('A zero the seller entered is reported as 0, not empty', 'area difference 0, premium 0',
  $q$select 'area difference ' || coalesce(area_difference::text, 'EMPTY') || ', premium ' || coalesce(grade_premium::text, 'EMPTY')
     from resolve_area_settings('00000000-0000-0000-0000-0000000000d4', (select tmt from k), (select pune from k),
                                (select fe550d from k))$q$);
