-- ============================================================
-- Checks: copying a brand's setup from another brand.
-- Covers: grades, sizes and area settings copied in one call; "not set"
-- and zero kept apart; the same charts are shared, not duplicated; the two
-- brands are separate afterwards; amounts converted exactly if the seller's
-- unit changed since the source was saved; refusals in plain words; only
-- the seller (or an admin) can copy.
-- Function: copy_brand_setup.
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller: TMT, sells Regular TMT (set up), Check Tiscon TMT and
--            Check Rods TMT (empty)
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
insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id from (values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2')) as x (id)
 cross join (select id from segments where name = 'TMT Bars') s;

insert into brands (name, status) values ('Check Tiscon', 'approved'), ('Check Rods', 'approved'), ('Check Kamdhenu', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s where b.name like 'Check %' and s.name = 'TMT Bars'
   and b.name in ('Check Tiscon', 'Check Rods', 'Check Kamdhenu');
insert into seller_brands (seller_id, brand_id, segment_id)
select '00000000-0000-0000-0000-0000000000a1', b.id, s.id from brands b, segments s
 where b.name in ('Check Tiscon', 'Check Rods') and s.name = 'TMT Bars';

-- Test sellers sell Regular in each family they deal in.
select pg_temp.sell_regular();

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from brands where is_regular) as regular,
       (select id from brands where name = 'Check Tiscon') as tiscon,
       (select id from brands where name = 'Check Rods') as rods,
       (select id from brands where name = 'Check Kamdhenu') as kamdhenu,
       (select id from regions where level = 'state' and name = 'Maharashtra') as mh,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from products where name = 'Fe550D') as fe550d;
grant select on k to public;

-- S's Regular TMT setup: Fe550D and 8mm/10mm offered; Maharashtra +200 with
-- a shared size chart and Fe550D premium 300; Pune 0 (a real zero); Satara
-- with only a display unit (area difference NOT SET).
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into charts (seller_id, segment_id, chart_type, name) values ('00000000-0000-0000-0000-0000000000a1', (select tmt from k), 'size', 'S sizes');
select save_chart_version((select id from charts where name = 'S sizes'), 'tonne', jsonb_build_array(jsonb_build_object('size_id',
  (select z.id from sizes z where z.segment_id = (select tmt from k) and z.display_name = '8mm'), 'amount', 500)));
insert into seller_grades (seller_id, brand_id, product_id, is_selected)
values ('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select fe550d from k), true);
insert into seller_sizes (seller_id, brand_id, size_id, is_selected)
select '00000000-0000-0000-0000-0000000000a1', (select regular from k), z.id, true
  from sizes z where z.segment_id = (select tmt from k) and z.display_name in ('8mm', '10mm');
select save_area_settings((select tmt from k), jsonb_build_array(
  jsonb_build_object('region_id', (select mh from k), 'area_difference', 200, 'size_chart_id', (select id from charts where name = 'S sizes'),
    'grades', jsonb_build_array(jsonb_build_object('product_id', (select fe550d from k), 'premium', 300))),
  jsonb_build_object('region_id', (select pune from k), 'area_difference', 0),
  jsonb_build_object('region_id', (select satara from k), 'display_unit', 'kg')), null, (select id from brands where is_regular));

-- One line describing a brand's setup.
create function pg_temp.setup_of(p_brand uuid) returns text language sql as $$
  select 'grades: ' || coalesce((select string_agg(p.name, ',') from seller_grades g join products p on p.id = g.product_id
                                  where g.seller_id = '00000000-0000-0000-0000-0000000000a1' and g.brand_id = p_brand and g.is_selected), '-')
      || ' | sizes: ' || coalesce((select string_agg(z.display_name, ',' order by z.sort_order) from seller_sizes x join sizes z on z.id = x.size_id
                                  where x.seller_id = '00000000-0000-0000-0000-0000000000a1' and x.brand_id = p_brand and x.is_selected), '-')
      || ' | ' || coalesce((
           select string_agg(coalesce(r.name, 'everywhere') || ' ' || coalesce(s.area_difference::text, 'NOT SET')
                             || coalesce(' ' || c.name, '') || coalesce(' Fe550D+' || g.grade_premium, ''), ', ' order by r.name)
             from area_setting_versions av
             join area_settings s on s.version_id = av.id
             left join regions r on r.id = s.region_id
             left join charts c on c.id = s.size_chart_id
             left join area_grade_settings g on g.area_setting_id = s.id
            where av.seller_id = '00000000-0000-0000-0000-0000000000a1' and av.brand_id = p_brand
              and av.version_number = (select max(version_number) from area_setting_versions
                                        where seller_id = av.seller_id and brand_id = av.brand_id and segment_id = av.segment_id)
           ), 'no area settings')
$$;

-- Copying ---------------------------------------------------------------------------

select pg_temp.expect_value('Check Tiscon starts empty', 'grades: - | sizes: - | no area settings',
  $q$select pg_temp.setup_of((select tiscon from k))$q$);
select pg_temp.expect_value('S copies Regular TMT''s setup to Check Tiscon TMT in one call', 'copied',
  $q$select case when copy_brand_setup((select tmt from k), (select regular from k), (select tiscon from k)) is not null then 'copied' end$q$);
select pg_temp.expect_value('Tiscon now matches Regular exactly: zero kept as 0, not set kept not set, the same chart',
  (select pg_temp.setup_of((select regular from k))),
  $q$select pg_temp.setup_of((select tiscon from k))$q$);
select pg_temp.expect_value('...which is', 'grades: Fe550D | sizes: 8mm,10mm | Maharashtra 200 S sizes Fe550D+300, Pune 0, Satara NOT SET',
  $q$select pg_temp.setup_of((select tiscon from k))$q$);
select pg_temp.expect_value('The chart is shared, not duplicated', '1 chart',
  $q$select count(*) || ' chart' from charts where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Separate afterwards ---------------------------------------------------------------

select pg_temp.expect_value('S changes Regular: Maharashtra +250, drops 10mm', 'changed',
  $q$select case when save_area_settings((select tmt from k), jsonb_build_array(
       jsonb_build_object('region_id', (select mh from k), 'area_difference', 250)), null, (select id from brands where is_regular)) is not null
     and select_all_in_family((select tmt from k), 'sizes', false, null, (select regular from k)) >= 0
     then 'changed' end$q$);
select pg_temp.expect_value('Tiscon is unchanged', 'grades: Fe550D | sizes: 8mm,10mm | Maharashtra 200 S sizes Fe550D+300, Pune 0, Satara NOT SET',
  $q$select pg_temp.setup_of((select tiscon from k))$q$);

-- Copying again overwrites the target to match (old versions kept) ------------------

select pg_temp.expect_value('S copies Regular to Tiscon again', 'copied',
  $q$select case when copy_brand_setup((select tmt from k), (select regular from k), (select tiscon from k)) is not null then 'copied' end$q$);
select pg_temp.expect_value('Tiscon now matches the new Regular, sizes included', 'grades: Fe550D | sizes: - | Maharashtra 250',
  $q$select pg_temp.setup_of((select tiscon from k))$q$);
select pg_temp.expect_value('Tiscon''s earlier version is kept', '1, 2',
  $q$select string_agg(version_number::text, ', ' order by version_number) from area_setting_versions
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k)$q$);

-- Unit changed since the source was saved: converted exactly --------------------------

select pg_temp.expect_rows('S now prices TMT per kg', 1,
  $q$update seller_segments set base_unit = 'kg' where seller_id = '00000000-0000-0000-0000-0000000000a1' and segment_id = (select tmt from k)$q$);
select pg_temp.expect_value('S copies Tiscon (saved per tonne) to Rods', 'copied',
  $q$select case when copy_brand_setup((select tmt from k), (select tiscon from k), (select rods from k)) is not null then 'copied' end$q$);
select pg_temp.expect_value('Rods'' copy is converted to per kg: 250 per tonne became 0.25 per kg', 'Rods: Maharashtra 0.25 per kg',
  $q$select 'Rods: ' || r.name || ' ' || s.area_difference || ' per ' || av.unit
     from area_setting_versions av
     join area_settings s on s.version_id = av.id
     join regions r on r.id = s.region_id
    where av.seller_id = '00000000-0000-0000-0000-0000000000a1' and av.brand_id = (select rods from k)$q$);

-- Refusals --------------------------------------------------------------------------

select pg_temp.expect_message('Copying to a brand he does not sell', 'Add Check Kamdhenu TMT to the brands you sell first.',
  $q$select copy_brand_setup((select tmt from k), (select regular from k), (select kamdhenu from k))$q$);
select pg_temp.expect_message('Copying from a brand he does not sell', 'There is nothing to copy from Check Kamdhenu TMT.',
  $q$select copy_brand_setup((select tmt from k), (select kamdhenu from k), (select tiscon from k))$q$);
select pg_temp.expect_message('Copying a brand onto itself', 'Choose a different brand to copy from.',
  $q$select copy_brand_setup((select tmt from k), (select tiscon from k), (select tiscon from k))$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('Another seller copies S''s brands',
  $q$select copy_brand_setup((select tmt from k), (select regular from k), (select tiscon from k), '00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('A visitor copies', $q$select copy_brand_setup((select tmt from k), (select regular from k), (select tiscon from k))$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('An admin copies for S (setting him up)', 'copied',
  $q$select case when copy_brand_setup((select tmt from k), (select tiscon from k), (select rods from k),
                                       '00000000-0000-0000-0000-0000000000a1') is not null then 'copied' end$q$);
