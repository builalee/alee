-- ============================================================
-- Checks: brand factories and factory coverage.
-- Covers: only the brand's owner (or an admin) links factories; a link
-- takes effect only when the factory accepts; a factory can decline and
-- leave later; coverage per brand and family, one factory per area, closer
-- area wins, "everywhere" only when chosen; different factories for TMT
-- and angles in the same area; coverage only with linked factories that
-- sell that brand line; a factory that left is reported, never a quiet
-- fall-back; who sees links and coverage; history never changed.
-- Tables: brand_factories, brand_factory_events, factory_coverage_versions,
-- factory_coverage_areas.
--
-- Test people (temporary logins, rolled back):
--   O  ...a1  owner of Check Steel (TMT and Angles)
--   F1 ...b2  factory account "Farid Steel" (sells Check Steel TMT)
--   F2 ...d4  factory account "Dev Rolling" (sells Check Steel TMT and Angles)
--   X  ...f6  another seller of Check Steel (not a factory)
--   E  ...e5  buyer      C ...c3 admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d4', '919800000004', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000f6', '919800000006', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', '919800000005', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Om',    '+919800000001', 'manufacturer'),
               ('00000000-0000-0000-0000-0000000000b2', 'Farid', '+919800000002', 'manufacturer'),
               ('00000000-0000-0000-0000-0000000000d4', 'Dev',   '+919800000004', 'manufacturer'),
               ('00000000-0000-0000-0000-0000000000f6', 'Xavier','+919800000006', 'retailer'),
               ('00000000-0000-0000-0000-0000000000e5', 'Esha',  '+919800000005', 'retailer')) as x (id, name, phone, role)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_profiles (account_id, store_name, region_id, is_public, market_close_time)
select x.id::uuid, x.store, r.id, true, '18:00'
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Om Steel HQ'),
               ('00000000-0000-0000-0000-0000000000b2', 'Farid Steel'),
               ('00000000-0000-0000-0000-0000000000d4', 'Dev Rolling'),
               ('00000000-0000-0000-0000-0000000000f6', 'Xavier Hardware')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'TMT Bars'),
               ('00000000-0000-0000-0000-0000000000b2', 'TMT Bars'),
               ('00000000-0000-0000-0000-0000000000d4', 'TMT Bars'),
               ('00000000-0000-0000-0000-0000000000d4', 'MS Angles'),
               ('00000000-0000-0000-0000-0000000000f6', 'TMT Bars')) as x (id, segment)
  join segments s on s.name = x.segment;

insert into brands (name, status) values ('Check Steel', 'approved'), ('Check Unowned', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s
 where (b.name = 'Check Steel' and s.name in ('TMT Bars', 'MS Angles')) or (b.name = 'Check Unowned' and s.name = 'TMT Bars');

insert into seller_brands (seller_id, brand_id, segment_id)
select x.id::uuid, b.id, s.id
  from (values ('00000000-0000-0000-0000-0000000000b2', 'TMT Bars'),
               ('00000000-0000-0000-0000-0000000000d4', 'TMT Bars'),
               ('00000000-0000-0000-0000-0000000000d4', 'MS Angles'),
               ('00000000-0000-0000-0000-0000000000f6', 'TMT Bars')) as x (id, segment)
  join segments s on s.name = x.segment
 cross join (select id from brands where name = 'Check Steel') b;

-- O owns Check Steel (claimed and approved the normal way).
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select claim_brand((select id from brands where name = 'Check Steel'));
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_brand_claim(id, true) from brand_claims where brand_id = (select id from brands where name = 'Check Steel');

select pg_temp.as_owner();
create temp table k as
select (select id from brands where name = 'Check Steel') as steel,
       (select id from brands where name = 'Check Unowned') as unowned,
       (select id from segments where name = 'TMT Bars') as tmt,
       (select id from segments where name = 'MS Angles') as angles,
       (select id from segments where name = 'MS Channels') as channels,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from regions where level = 'district' and name = 'North Goa') as north_goa;
grant select on k to public;

create function pg_temp.served_by(p_seg uuid, p_region uuid) returns text language sql as $$
  select coalesce((select f.factory_name || ' (for ' || f.covering_area || ')'
                          || case when f.factory_is_linked then '' else ', NO LONGER LINKED' end
                     from resolve_brand_factory((select steel from k), p_seg, p_region) f), 'no factory')
$$;

select pg_temp.expect_value('Row Level Security is on',
  'brand_factories=true, brand_factory_events=true, factory_coverage_areas=true, factory_coverage_versions=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace
       and relname in ('brand_factories', 'brand_factory_events', 'factory_coverage_versions', 'factory_coverage_areas')$q$);

-- Linking factories ----------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f6');
select pg_temp.expect_message('A seller who is not the owner links a factory', 'Only the owner of Check Steel can link factories.',
  $q$select offer_factory_link((select steel from k), '00000000-0000-0000-0000-0000000000b2')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('A brand with no owner', 'That brand has no owner on ALEE yet.',
  $q$select offer_factory_link((select unowned from k), '00000000-0000-0000-0000-0000000000b2')$q$);
select pg_temp.expect_value('O offers to link Farid Steel', 'offered',
  $q$select case when offer_factory_link((select steel from k), '00000000-0000-0000-0000-0000000000b2') is not null then 'offered' end$q$);
select pg_temp.expect_message('Coverage cannot use Farid before he accepts', 'Farid Steel is not a linked factory of Check Steel.',
  $q$select save_factory_coverage((select steel from k), (select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select mh from k), 'factory_id', '00000000-0000-0000-0000-0000000000b2')))$q$);
select pg_temp.expect_message('The same factory offered twice', 'That factory is already linked to Check Steel, or has an offer waiting.',
  $q$select offer_factory_link((select steel from k), '00000000-0000-0000-0000-0000000000b2')$q$);

select pg_temp.as_owner();
create temp table l1 as select id from brand_factories where factory_id = '00000000-0000-0000-0000-0000000000b2';
grant select on l1 to public;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_refused('O accepts on Farid''s behalf', $q$select respond_to_factory_link((select id from l1), true)$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_refused('Another factory accepts Farid''s offer', $q$select respond_to_factory_link((select id from l1), true)$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('Farid sees the offer', 'offered', $q$select status::text from brand_factories where id = (select id from l1)$q$);
select pg_temp.expect_value('Farid accepts', 'active', $q$select respond_to_factory_link((select id from l1), true)::text$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('O offers Dev Rolling', 'offered',
  $q$select case when offer_factory_link((select steel from k), '00000000-0000-0000-0000-0000000000d4') is not null then 'offered' end$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_value('Dev declines', 'declined',
  $q$select respond_to_factory_link(id, false)::text from brand_factories where factory_id = '00000000-0000-0000-0000-0000000000d4' and status = 'offered'$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('After a decline O can offer again', 'offered',
  $q$select case when offer_factory_link((select steel from k), '00000000-0000-0000-0000-0000000000d4') is not null then 'offered' end$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d4');
select pg_temp.expect_value('Dev accepts this time', 'active',
  $q$select respond_to_factory_link(id, true)::text from brand_factories where factory_id = '00000000-0000-0000-0000-0000000000d4' and status = 'offered'$q$);

-- Coverage ------------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('O: TMT from Farid for Maharashtra, from Dev for Satara; Angles from Dev for Maharashtra', 'saved',
  $q$select case when save_factory_coverage((select steel from k), (select tmt from k), jsonb_build_array(
         jsonb_build_object('region_id', (select mh from k), 'factory_id', '00000000-0000-0000-0000-0000000000b2'),
         jsonb_build_object('region_id', (select satara from k), 'factory_id', '00000000-0000-0000-0000-0000000000d4'))) is not null
       and save_factory_coverage((select steel from k), (select angles from k), jsonb_build_array(
         jsonb_build_object('region_id', (select mh from k), 'factory_id', '00000000-0000-0000-0000-0000000000d4'))) is not null
     then 'saved' end$q$);
select pg_temp.expect_value('TMT in Pune: Farid (from Maharashtra)', 'Farid Steel (for Maharashtra)',
  $q$select pg_temp.served_by((select tmt from k), (select pune from k))$q$);
select pg_temp.expect_value('TMT in Satara: Dev (the closer area wins)', 'Dev Rolling (for Satara)',
  $q$select pg_temp.served_by((select tmt from k), (select satara from k))$q$);
select pg_temp.expect_value('Angles in Pune: Dev (a different factory for a different family, same area)', 'Dev Rolling (for Maharashtra)',
  $q$select pg_temp.served_by((select angles from k), (select pune from k))$q$);
select pg_temp.expect_value('TMT in North Goa: no factory (no "everywhere" chosen)', 'no factory',
  $q$select pg_temp.served_by((select tmt from k), (select north_goa from k))$q$);
select pg_temp.expect_value('O adds "everywhere": Farid, keeping Satara to Dev (version 2)', 'saved',
  $q$select case when save_factory_coverage((select steel from k), (select tmt from k), jsonb_build_array(
         jsonb_build_object('everywhere', true, 'factory_id', '00000000-0000-0000-0000-0000000000b2'),
         jsonb_build_object('region_id', (select satara from k), 'factory_id', '00000000-0000-0000-0000-0000000000d4'))) is not null
     then 'saved' end$q$);
select pg_temp.expect_value('TMT in North Goa: now Farid, for everywhere', 'Farid Steel (for everywhere)',
  $q$select pg_temp.served_by((select tmt from k), (select north_goa from k))$q$);
select pg_temp.expect_value('Coverage versions are kept', '1, 2',
  $q$select string_agg(version_number::text, ', ' order by version_number) from factory_coverage_versions
     where brand_id = (select steel from k) and segment_id = (select tmt from k)$q$);

select pg_temp.expect_message('A factory that does not sell that brand line', 'Farid Steel does not sell Check Steel Angles yet.',
  $q$select save_factory_coverage((select steel from k), (select angles from k),
       jsonb_build_array(jsonb_build_object('region_id', (select mh from k), 'factory_id', '00000000-0000-0000-0000-0000000000b2')))$q$);
select pg_temp.expect_message('A seller of the brand who is not a linked factory', 'Xavier Hardware is not a linked factory of Check Steel.',
  $q$select save_factory_coverage((select steel from k), (select tmt from k),
       jsonb_build_array(jsonb_build_object('region_id', (select mh from k), 'factory_id', '00000000-0000-0000-0000-0000000000f6')))$q$);
select pg_temp.expect_message('A family the brand is not listed for', 'Check Steel is not listed for that product family.',
  $q$select save_factory_coverage((select steel from k), (select channels from k), '[]')$q$);
select pg_temp.expect_message('An area with neither region nor "everywhere"', 'Each area must name a region, or be "everywhere": true',
  $q$select save_factory_coverage((select steel from k), (select tmt from k),
       jsonb_build_array(jsonb_build_object('factory_id', '00000000-0000-0000-0000-0000000000b2')))$q$);
select pg_temp.expect_refused('Two factories for the same area',
  $q$select save_factory_coverage((select steel from k), (select tmt from k), jsonb_build_array(
       jsonb_build_object('region_id', (select satara from k), 'factory_id', '00000000-0000-0000-0000-0000000000b2'),
       jsonb_build_object('region_id', (select satara from k), 'factory_id', '00000000-0000-0000-0000-0000000000d4')))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_message('A factory changes the coverage', 'Only the owner of Check Steel can decide which factory covers which area.',
  $q$select save_factory_coverage((select steel from k), (select tmt from k), '[]')$q$);

-- Who sees what ---------------------------------------------------------------------------

select pg_temp.expect_value('Farid sees his own link and the brand''s coverage', 'link: 1, coverage versions: 2',
  $q$select 'link: ' || (select count(*) from brand_factories where brand_id = (select steel from k))
         || ', coverage versions: ' || (select count(*) from factory_coverage_versions
                                         where brand_id = (select steel from k) and segment_id = (select tmt from k))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f6');
select pg_temp.expect_value('Another seller of the brand sees no links or coverage', '0 / 0',
  $q$select (select count(*) from brand_factories) || ' / ' || (select count(*) from factory_coverage_versions)$q$);
select pg_temp.expect_value('...and cannot look up which factory serves an area', 'no factory',
  $q$select pg_temp.served_by((select tmt from k), (select pune from k))$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_value('A buyer sees no links or coverage', '0 / 0',
  $q$select (select count(*) from brand_factories) || ' / ' || (select count(*) from factory_coverage_areas)$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('Visitors cannot read factory links', $q$select * from brand_factories$q$);
select pg_temp.expect_refused('Visitors cannot look up factories', $q$select * from resolve_brand_factory((select steel from k), (select tmt from k), (select pune from k))$q$);

-- A factory leaves -------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('Farid leaves Check Steel', 'left', $q$select end_factory_link((select id from l1))::text$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('Pune shows Farid no longer linked: not served until reassigned (no quiet fall-back)',
  'Farid Steel (for everywhere), NO LONGER LINKED',
  $q$select pg_temp.served_by((select tmt from k), (select pune from k))$q$);
select pg_temp.expect_value('Satara is still Dev', 'Dev Rolling (for Satara)',
  $q$select pg_temp.served_by((select tmt from k), (select satara from k))$q$);
select pg_temp.expect_message('Coverage can no longer name Farid', 'Farid Steel is not a linked factory of Check Steel.',
  $q$select save_factory_coverage((select steel from k), (select tmt from k),
       jsonb_build_array(jsonb_build_object('everywhere', true, 'factory_id', '00000000-0000-0000-0000-0000000000b2')))$q$);
select pg_temp.expect_value('O ends Dev''s link', 'ended',
  $q$select end_factory_link(id)::text from brand_factories where factory_id = '00000000-0000-0000-0000-0000000000d4' and status = 'active'$q$);

-- Admin, history -----------------------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin offers Farid again on O''s behalf', 'offered',
  $q$select case when offer_factory_link((select steel from k), '00000000-0000-0000-0000-0000000000b2') is not null then 'offered' end$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('Farid''s history: offered, accepted, left, offered by admin',
  'offered by O, accepted by Farid, left by Farid, offered by admin',
  $q$select string_agg(e.event || ' by ' || case when e.by_admin then 'admin'
                                                when e.done_by = '00000000-0000-0000-0000-0000000000a1' then 'O' else 'Farid' end,
                       ', ' order by e.happened_at)
     from brand_factory_events e join brand_factories f on f.id = e.link_id
     where f.factory_id = '00000000-0000-0000-0000-0000000000b2'$q$);

select pg_temp.as_owner();
select pg_temp.expect_refused('Even with the master key: bring back a factory that left',
  $q$update brand_factories set status = 'active' where id = (select id from l1)$q$);
select pg_temp.expect_refused('Even with the master key: swap the factory on a link',
  $q$update brand_factories set factory_id = '00000000-0000-0000-0000-0000000000f6' where id = (select id from l1)$q$);
select pg_temp.expect_refused('Even with the master key: edit the history',
  $q$update brand_factory_events set by_admin = true where link_id = (select id from l1)$q$);
select pg_temp.expect_refused('Even with the master key: change coverage',
  $q$update factory_coverage_areas set factory_id = '00000000-0000-0000-0000-0000000000f6'$q$);
select pg_temp.expect_refused('Even with the master key: add an area to old coverage',
  $q$insert into factory_coverage_areas (version_id, region_id, factory_id)
     select id, (select pune from k), '00000000-0000-0000-0000-0000000000d4' from factory_coverage_versions where version_number = 1
      and brand_id = (select steel from k) and segment_id = (select tmt from k)$q$);
select pg_temp.expect_refused('Even with the master key: delete coverage',
  $q$delete from factory_coverage_versions where brand_id = (select steel from k)$q$);
