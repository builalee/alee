-- ============================================================
-- Checks: publishing, current rates, not quoting, market open / closed.
-- Covers: one publish for several families; time set by the database;
-- basic rate above zero and exact; area settings and chart versions pinned;
-- charts marked used; latest publish found after several; a past rate
-- rebuilt exactly after the seller changes charts and settings; publishes
-- never edited or deleted, even with the master key; corrections; nobody
-- but the seller and admins reads a basic rate; admin publishes recorded
-- as such; "not quoting" and "close now" recorded and reversed; publishing
-- reopens a closed market; the daily closing time in Indian time.
-- Tables: publishes, publish_items, publish_chart_versions,
-- seller_family_status, seller_family_status_history.
-- Functions: publish_rates, market_status, set_quoting, close_market_now,
-- resolve_size_figures (as published).
--
-- Test people (temporary logins, rolled back):
--   A ...a1  seller: TMT and MS Channels (area settings saved), MS Angles
--            (no area settings yet); closes 6 pm
--   B ...b2  another seller (TMT)
--   E ...e5  buyer (no seller profile)
--   C ...c3  admin
-- ============================================================

-- Test data -------------------------------------------------------------------

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', '919800000005', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'distributor', r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Asha', '+919800000001'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala', '+919800000002'),
               ('00000000-0000-0000-0000-0000000000e5', 'Esha', '+919800000005')) as x (id, name, phone)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_profiles (account_id, store_name, region_id, is_public, market_close_time)
select x.id::uuid, x.store, r.id, true, '18:00'
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Asha Steels'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala Traders')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'TMT Bars'),
               ('00000000-0000-0000-0000-0000000000a1', 'MS Channels'),
               ('00000000-0000-0000-0000-0000000000a1', 'MS Angles'),
               ('00000000-0000-0000-0000-0000000000b2', 'TMT Bars')) as x (id, segment)
  join segments s on s.name = x.segment;

-- A product family A does not deal in.
insert into segments (name, sort_order) values ('Check Pipes', 999);

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from segments where name = 'MS Channels') as channels,
       (select id from segments where name = 'MS Angles') as angles,
       (select id from segments where name = 'Check Pipes') as pipes,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'state' and name = 'Goa') as goa,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '8mm') as s8,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '10mm') as s10;
grant select on k to public;

-- A's charts and area settings, made the normal way.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into charts (seller_id, segment_id, chart_type, name)
select '00000000-0000-0000-0000-0000000000a1', (select tmt from k), x.type::chart_type, x.name
  from (values ('size', 'A sizes'), ('loading', 'A loading'), ('size', 'A extra sizes')) as x (type, name);
select save_chart_version((select id from charts where name = 'A sizes'), 'tonne', jsonb_build_array(
  jsonb_build_object('size_id', (select s8 from k), 'amount', 500),
  jsonb_build_object('size_id', (select s10 from k), 'amount', 400)));
select save_chart_version((select id from charts where name = 'A loading'), 'tonne',
  '[{"size_id": null, "amount": 250}]');
select save_chart_version((select id from charts where name = 'A extra sizes'), 'tonne', jsonb_build_array(
  jsonb_build_object('size_id', (select s8 from k), 'amount', 100)));

create temp table setup as
select jsonb_build_array(jsonb_build_object('region_id', (select mh from k), 'area_difference', 200,
         'size_chart_id', (select id from charts where name = 'A sizes'),
         'loading_chart_id', (select id from charts where name = 'A loading'))) as tmt_v1,
       jsonb_build_array(jsonb_build_object('region_id', (select mh from k), 'area_difference', 300,
         'size_chart_id', (select id from charts where name = 'A sizes'),
         'loading_chart_id', (select id from charts where name = 'A loading'))) as tmt_v2;
grant select on setup to public;

select save_area_settings((select tmt from k), (select tmt_v1 from setup));
select save_area_settings((select channels from k), '[{"everywhere": true, "area_difference": 100}]');

-- B has one publish of his own.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]');
select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 40000)));
select pg_temp.as_owner();
create temp table bpub as select id from publishes where seller_id = '00000000-0000-0000-0000-0000000000b2';
grant select on bpub to public;

-- Structure -------------------------------------------------------------------

select pg_temp.as_owner();
select pg_temp.expect_value('Row Level Security is on',
  'publish_chart_versions=true, publish_items=true, publishes=true, seller_family_status=true, seller_family_status_history=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace
       and relname in ('publishes', 'publish_items', 'publish_chart_versions', 'seller_family_status', 'seller_family_status_history')$q$);
select pg_temp.expect_value('The public status table holds no rate', '0',
  $q$select count(*)::text from information_schema.columns
     where table_schema = 'public' and table_name in ('seller_family_status', 'seller_family_status_history')
       and (column_name like '%rate%' or column_name like '%amount%' or column_name like '%price%')$q$);
select pg_temp.expect_value('The basic rate is an exact rupee amount', 'rupees',
  $q$select domain_name from information_schema.columns
     where table_schema = 'public' and table_name = 'publish_items' and column_name = 'base_rate'$q$);

-- A publishes -------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_value('Before any publish, TMT is "not published"', 'not_published',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);
select pg_temp.expect_value('A publishes TMT 41000 and Channels 52000 in one action', 'published',
  $q$select case when publish_rates(jsonb_build_array(
       jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41000),
       jsonb_build_object('segment_id', (select channels from k), 'base_rate', 52000))) is not null then 'published' end$q$);
select pg_temp.expect_value('It is one publish covering both families', '1 publish, 2 families',
  $q$select count(distinct p.id) || ' publish, ' || count(*) || ' families'
     from publishes p join publish_items pi on pi.publish_id = p.id
     where p.seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Basic rates and their units recorded', 'MS Channels 52000 per tonne, TMT Bars 41000 per tonne',
  $q$select string_agg(s.name || ' ' || pi.base_rate || ' per ' || pi.unit, ', ' order by s.name)
     from publish_items pi join segments s on s.id = pi.segment_id
     join publishes p on p.id = pi.publish_id where p.seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Time set by the database: today, by A himself, not an admin', 'today, by A, not admin',
  $q$select case when published_at::date = current_date then 'today' else published_at::text end || ', by '
            || case when published_by = '00000000-0000-0000-0000-0000000000a1' then 'A' else 'someone else' end
            || ', ' || case when by_admin then 'ADMIN' else 'not admin' end
     from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('The area-settings version used is pinned', 'TMT area settings v1',
  $q$select 'TMT area settings v' || av.version_number from publish_items pi
     join area_setting_versions av on av.id = pi.area_setting_version_id
     where pi.segment_id = (select tmt from k)
       and pi.publish_id in (select id from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('Every chart version used is pinned', 'A loading v1, A sizes v1',
  $q$select string_agg(c.name || ' v' || cv.version_number, ', ' order by c.name)
     from publish_chart_versions pcv join charts c on c.id = pcv.chart_id join chart_versions cv on cv.id = pcv.chart_version_id
     where pcv.publish_id in (select id from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('Charts the publish used are now marked "used since"', 'A extra sizes unused, A loading used, A sizes used',
  $q$select string_agg(name || case when in_use_since is null then ' unused' else ' used' end, ', ' order by name)
     from charts where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Right after publishing, TMT is open', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);

-- What a publish refuses ----------------------------------------------------------

select pg_temp.expect_refused('Basic rate of zero',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 0)))$q$);
select pg_temp.expect_refused('Negative basic rate',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', -5)))$q$);
select pg_temp.expect_refused('Basic rate finer than 4 decimal places (refused, not rounded)',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41000.12345)))$q$);
select pg_temp.expect_refused('No basic rate given',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k))))$q$);
select pg_temp.expect_refused('A family A does not deal in',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select pipes from k), 'base_rate', 1000)))$q$);
select pg_temp.expect_refused('A family with no area settings yet (MS Angles)',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select angles from k), 'base_rate', 1000)))$q$);
select pg_temp.expect_refused('The same family twice in one publish',
  $q$select publish_rates(jsonb_build_array(
       jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41000),
       jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 42000)))$q$);
select pg_temp.expect_refused('A misspelt field',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rat', 41000)))$q$);
select pg_temp.expect_refused('An empty publish', $q$select publish_rates('[]')$q$);
select pg_temp.expect_value('Refused publishes left nothing behind: still 1 publish', '1',
  $q$select count(*)::text from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Latest publish after several --------------------------------------------------

select pg_temp.expect_value('A publishes TMT again: 41500, then 42000', 'published twice',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41500))) is not null
                  and publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 42000))) is not null
             then 'published twice' end$q$);
select pg_temp.expect_value('Latest publish: TMT 42000 (the third); Channels still 52000 (the first)',
  'MS Channels 52000 (publish 1), TMT Bars 42000 (publish 3)',
  $q$select string_agg(s.name || ' ' || pi.base_rate || ' (publish ' ||
              (select count(*) from publishes p2 where p2.seller_id = st.seller_id and p2.publish_number <= p.publish_number) || ')',
              ', ' order by s.name)
     from seller_family_status st
     join publishes p on p.id = st.latest_publish_id
     join publish_items pi on pi.publish_id = st.latest_publish_id and pi.segment_id = st.segment_id
     join segments s on s.id = st.segment_id
     where st.seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Keep the third publish (TMT 42000) for later checks.
select pg_temp.as_owner();
create temp table p3 as
select id from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1' order by publish_number desc limit 1;
grant select on p3 to public;

-- A past rate rebuilds exactly after later changes ---------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

create function pg_temp.rate_inputs(p_publish uuid)
returns text language sql as $$
  select coalesce('base ' || (select pi.base_rate || ' per ' || pi.unit from publish_items pi
                              where pi.publish_id = p_publish and pi.segment_id = (select tmt from k)) || ' | ', '')
      || 'Pune diff ' || coalesce(a.area_difference::text, '-')
      || ' | ' || (select string_agg(f.display_name || ' ' || coalesce(f.size_difference::text, '-'), ', ' order by f.display_name desc)
                     from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k),
                                               null, null, p_publish) f
                    where f.display_name in ('8mm', '10mm'))
      || ' | loading ' || (select f.loading::text
                     from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k),
                                               null, null, p_publish) f where f.display_name = '8mm')
    from resolve_area_settings('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k), null,
           (select pi.area_setting_version_id from publish_items pi
             where pi.publish_id = p_publish and pi.segment_id = (select tmt from k))) a
$$;

select pg_temp.expect_value('Publish 3 as published', 'base 42000 per tonne | Pune diff 200 | 8mm 500, 10mm 400 | loading 250',
  $q$select pg_temp.rate_inputs((select id from p3))$q$);
select pg_temp.expect_value('A changes his size chart (8mm 900) and his area settings (Maharashtra +300)', 'changed',
  $q$select case when save_chart_version((select id from charts where name = 'A sizes'), 'tonne', jsonb_build_array(
                         jsonb_build_object('size_id', (select s8 from k), 'amount', 900),
                         jsonb_build_object('size_id', (select s10 from k), 'amount', 400))) is not null
                  and save_area_settings((select tmt from k), (select tmt_v2 from setup)) is not null
             then 'changed' end$q$);
select pg_temp.expect_value('Today''s lookup shows the new figures', 'Pune diff 300 | 8mm 900, 10mm 400 | loading 250',
  $q$select pg_temp.rate_inputs(null)$q$);
select pg_temp.expect_value('Publish 3 still rebuilds exactly as it was', 'base 42000 per tonne | Pune diff 200 | 8mm 500, 10mm 400 | loading 250',
  $q$select pg_temp.rate_inputs((select id from p3))$q$);

-- A publish using a switched-off chart is refused
select pg_temp.expect_value('A adds a Goa row using "A extra sizes", then switches that chart off', 'done',
  $q$select case when save_area_settings((select tmt from k), (select tmt_v2 from setup) || jsonb_build_array(
                         jsonb_build_object('region_id', (select goa from k),
                           'size_chart_id', (select id from charts where name = 'A extra sizes')))) is not null
             then 'done' end$q$);
update charts set is_active = false where name = 'A extra sizes';
select pg_temp.expect_refused('Publishing while area settings use a switched-off chart',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 42100)))$q$);
select save_area_settings((select tmt from k), (select tmt_v2 from setup));

-- A publish can never be changed or removed ---------------------------------------

select pg_temp.expect_refused('A changes the basic rate of a publish',
  $q$update publish_items set base_rate = 1 where publish_id = (select id from p3)$q$);
select pg_temp.expect_refused('A deletes a publish',
  $q$delete from publishes where id = (select id from p3)$q$);
select pg_temp.expect_refused('A writes a publish directly, bypassing publish_rates',
  $q$insert into publishes (seller_id, published_by, by_admin)
     values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', false)$q$);

select pg_temp.as_owner();
select pg_temp.expect_refused('Even with the master key: change a basic rate',
  $q$update publish_items set base_rate = 1 where publish_id = (select id from p3)$q$);
select pg_temp.expect_refused('Even with the master key: back-date a publish',
  $q$update publishes set published_at = '2020-01-01' where id = (select id from p3)$q$);
select pg_temp.expect_refused('Even with the master key: insert a back-dated publish',
  $q$insert into publishes (seller_id, published_at, published_by, by_admin)
     values ('00000000-0000-0000-0000-0000000000a1', '2020-01-01', '00000000-0000-0000-0000-0000000000a1', false)$q$);
select pg_temp.expect_refused('Even with the master key: add a family to an old publish',
  $q$insert into publish_items (publish_id, segment_id, base_rate, unit, area_setting_version_id)
     select (select id from p3), (select channels from k), 1, 'tonne', id from area_setting_versions
      where seller_id = '00000000-0000-0000-0000-0000000000a1' and segment_id = (select channels from k)$q$);
select pg_temp.expect_refused('Even with the master key: delete a publish',
  $q$delete from publishes where id = (select id from p3)$q$);
select pg_temp.expect_refused('Even with the master key: delete a pinned chart version',
  $q$delete from publish_chart_versions where publish_id = (select id from p3)$q$);
select pg_temp.expect_value('Publish 3 is exactly as published', '42000',
  $q$select base_rate::text from publish_items where publish_id = (select id from p3)$q$);

-- Corrections --------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('A publishes 41800 as a correction of publish 3', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41800)),
                                    true, (select id from p3)) is not null then 'published' end$q$);
select pg_temp.expect_value('The correction is the latest, marked as correcting publish 3; publish 3 still says 42000',
  'latest 41800, correction of the 42000 publish',
  $q$select 'latest ' || pi.base_rate || ', ' ||
            case when p.is_correction and p.corrects_publish_id = (select id from p3) then 'correction of the ' else 'NOT a correction of the ' end
            || (select base_rate from publish_items where publish_id = (select id from p3)) || ' publish'
     from seller_family_status st join publishes p on p.id = st.latest_publish_id
     join publish_items pi on pi.publish_id = p.id and pi.segment_id = st.segment_id
     where st.seller_id = '00000000-0000-0000-0000-0000000000a1' and st.segment_id = (select tmt from k)$q$);
select pg_temp.expect_refused('A marks a publish as correcting B''s publish',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 41800)),
                          true, (select id from bpub))$q$);

-- Nobody else reads a basic rate --------------------------------------------------

select pg_temp.as_owner();
create temp table apub as select id from publishes where seller_id = '00000000-0000-0000-0000-0000000000a1';
grant select on apub to public;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('Another seller reads A''s publishes by id: nothing', '0',
  $q$select count(*)::text from publishes where id in (select id from apub)$q$);
select pg_temp.expect_value('Another seller reads A''s basic rates: nothing', '0',
  $q$select count(*)::text from publish_items where publish_id in (select id from apub)$q$);
select pg_temp.expect_value('Another seller reads A''s pinned chart versions: nothing', '0',
  $q$select count(*)::text from publish_chart_versions where publish_id in (select id from apub)$q$);
select pg_temp.expect_refused('Another seller rebuilds A''s publish',
  $q$select * from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k),
                                       null, null, (select id from p3))$q$);
select pg_temp.expect_refused('Another seller publishes for A',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 1)),
                          false, null, '00000000-0000-0000-0000-0000000000a1')$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_value('A buyer reads any basic rates: nothing', '0',
  $q$select count(*)::text from publish_items$q$);
select pg_temp.expect_value('A buyer reads any publishes: nothing', '0',
  $q$select count(*)::text from publishes$q$);

select pg_temp.as_visitor();
select pg_temp.expect_refused('Visitor reads publishes', $q$select * from publishes$q$);
select pg_temp.expect_refused('Visitor reads basic rates', $q$select * from publish_items$q$);
select pg_temp.expect_refused('Visitor reads pinned chart versions', $q$select * from publish_chart_versions$q$);
select pg_temp.expect_refused('Visitor publishes', $q$select publish_rates('[]')$q$);
select pg_temp.expect_value('Visitor can see A''s status (no rate in it)', '2 families',
  $q$select count(*) || ' families' from seller_family_status where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Visitor can see whether A is open', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);

-- Admin publishes on A's behalf -------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin publishes TMT 43000 for A', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 43000)),
                                    false, null, '00000000-0000-0000-0000-0000000000a1') is not null then 'published' end$q$);
select pg_temp.expect_value('It is recorded as done by an admin, and who', 'for A, by admin C',
  $q$select case when p.seller_id = '00000000-0000-0000-0000-0000000000a1' then 'for A' else 'for someone else' end || ', by '
            || case when p.by_admin then 'admin' else 'the seller' end
            || case when p.published_by = '00000000-0000-0000-0000-0000000000c3' then ' C' else ' ?' end
     from publishes p where p.seller_id = '00000000-0000-0000-0000-0000000000a1' order by p.publish_number desc limit 1$q$);
select pg_temp.expect_value('Admin reads A''s basic rates', '6',
  $q$select count(*)::text from publish_items pi join publishes p on p.id = pi.publish_id
     where p.seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Not quoting today ----------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('A switches TMT off (not quoting)', 'false',
  $q$select set_quoting((select tmt from k), false)::text$q$);
select pg_temp.expect_value('TMT shows "not quoting", with no closing time', 'not_quoting, -',
  $q$select status || ', ' || coalesce(closed_at::text, '-') from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);
select pg_temp.expect_value('Channels is unaffected', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select channels from k))$q$);
select pg_temp.expect_value('Switching it off again records nothing new', 'false',
  $q$select set_quoting((select tmt from k), false)::text$q$);
select pg_temp.expect_value('A publishes TMT 43500 while not quoting', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 43500)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('It stays "not quoting" until he switches it back on', 'not_quoting',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);
select pg_temp.expect_value('A switches TMT back on', 'true',
  $q$select set_quoting((select tmt from k), true)::text$q$);
select pg_temp.expect_value('TMT is open again, at the rate published while it was off', 'open, latest 43500',
  $q$select m.status || ', latest ' || pi.base_rate
     from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k)) m,
          seller_family_status st join publish_items pi on pi.publish_id = st.latest_publish_id and pi.segment_id = st.segment_id
     where st.seller_id = '00000000-0000-0000-0000-0000000000a1' and st.segment_id = (select tmt from k)$q$);
select pg_temp.expect_value('History: switched off once, back on once, with times', 'stopped_quoting, resumed_quoting',
  $q$select string_agg(event::text, ', ' order by happened_at) from seller_family_status_history
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and segment_id = (select tmt from k)
       and happened_at is not null$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('Another seller switches A''s TMT off',
  $q$select set_quoting((select tmt from k), false, '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_refused('Another seller closes A''s market',
  $q$select close_market_now(null, '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_value('Another seller reads A''s switch history: nothing', '0',
  $q$select count(*)::text from seller_family_status_history where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('Visitor reads switch history', $q$select * from seller_family_status_history$q$);
select pg_temp.expect_refused('Visitor switches quoting', $q$select set_quoting((select tmt from k), false, '00000000-0000-0000-0000-0000000000a1')$q$);

-- Close market now, and publishing reopens ----------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('A presses "close market now" for TMT', '1',
  $q$select close_market_now(array[(select tmt from k)])::text$q$);
select pg_temp.expect_value('TMT is closed, with the closing time', 'closed, closing time recorded',
  $q$select status || ', ' || case when closed_at is not null then 'closing time recorded' else 'NO closing time' end
     from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);
select pg_temp.expect_value('Channels is still open', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select channels from k))$q$);
select pg_temp.expect_value('Closing an already closed market records nothing new', '0',
  $q$select close_market_now(array[(select tmt from k)])::text$q$);
select pg_temp.expect_value('A publishes TMT again (43600)', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 43600)))
     is not null then 'published' end$q$);
select pg_temp.expect_value('Publishing again reopened TMT', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select tmt from k))$q$);
select pg_temp.expect_value('The early close stays in history after reopening', 'closed_early by A',
  $q$select string_agg(event::text || case when by_admin then ' by admin' else ' by A' end, ', ')
     from seller_family_status_history
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and event = 'closed_early'$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin closes A''s whole market (both families)', '2',
  $q$select close_market_now(null, '00000000-0000-0000-0000-0000000000a1')::text$q$);
select pg_temp.expect_value('Recorded as done by an admin', 'closed_early by admin, closed_early by admin',
  $q$select string_agg(event::text || case when by_admin then ' by admin' else ' by A' end, ', ')
     from seller_family_status_history
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and event = 'closed_early' and by_admin$q$);

-- The daily closing time (Indian time) ----------------------------------------------
-- Checked "as at" chosen moments, using Channels (last published in the
-- first publish and never closed early by A himself).

select pg_temp.as_owner();
create temp table ch as
select st.last_published_at as pub from seller_family_status st
 where st.seller_id = '00000000-0000-0000-0000-0000000000a1' and st.segment_id = (select channels from k);
grant select on ch to public;
-- The admin closed Channels early above. Clear that here (test data only;
-- the real path to reopen is publishing, checked above) so these checks see
-- the daily closing time alone.
update seller_family_status set closed_early_at = null
 where seller_id = '00000000-0000-0000-0000-0000000000a1' and segment_id = (select channels from k);
update seller_profiles set market_close_time = ((select pub from ch) at time zone 'Asia/Kolkata' + interval '1 hour')::time
 where account_id = '00000000-0000-0000-0000-0000000000a1';

select pg_temp.as_visitor();
select pg_temp.expect_value('Closing time 1 hour after the publish: open 30 minutes after publishing', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select channels from k),
                                      (select pub from ch) + interval '30 minutes')$q$);
select pg_temp.expect_value('Closed 2 hours after publishing, at exactly the closing time', 'closed at publish + 1 hour',
  $q$select status || case when closed_at = (select pub from ch) + interval '1 hour' then ' at publish + 1 hour' else ' at ' || closed_at end
     from market_status('00000000-0000-0000-0000-0000000000a1', (select channels from k), (select pub from ch) + interval '2 hours')$q$);

select pg_temp.as_owner();
update seller_profiles set market_close_time = ((select pub from ch) at time zone 'Asia/Kolkata' - interval '1 hour')::time
 where account_id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.as_visitor();
select pg_temp.expect_value('Published after today''s closing time: open until tomorrow''s (22 hours later)', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select channels from k),
                                      (select pub from ch) + interval '22 hours')$q$);
select pg_temp.expect_value('Closed at tomorrow''s closing time (23 hours later)', 'closed at publish + 23 hours',
  $q$select status || case when closed_at = (select pub from ch) + interval '23 hours' then ' at publish + 23 hours' else ' at ' || closed_at end
     from market_status('00000000-0000-0000-0000-0000000000a1', (select channels from k), (select pub from ch) + interval '23 hours 1 minute')$q$);

select pg_temp.as_owner();
update seller_profiles set market_close_time = null where account_id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.as_visitor();
select pg_temp.expect_value('No closing time set: still open days later (only "close now" closes)', 'open',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select channels from k),
                                      (select pub from ch) + interval '100 hours')$q$);
select pg_temp.expect_value('A family never published shows "not published"', 'not_published',
  $q$select status from market_status('00000000-0000-0000-0000-0000000000a1', (select angles from k))$q$);
