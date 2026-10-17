-- ============================================================
-- Checks: grades and sizes chosen per brand line.
-- Covers: a seller's choices for one brand are independent of another;
-- "select all" for one brand leaves the other untouched; history records
-- the brand; choosing needs an active brand line (plain message); the
-- per-size lookup uses the Regular line until brands step 5; a choice
-- saved without a brand is Regular (transitional, until step 11).
-- Tables: seller_grades, seller_sizes, seller_offering_history.
-- Function: select_all_in_family.
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller: TMT, selling Regular TMT and Check Tiscon TMT
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');
insert into accounts (id, full_name, phone, signup_role, region_id)
select '00000000-0000-0000-0000-0000000000a1', 'Sunil', '+919800000001', 'retailer', id
  from regions where level = 'district' and name = 'Pune';
insert into seller_profiles (account_id, store_name, region_id, is_public)
select '00000000-0000-0000-0000-0000000000a1', 'Sunil Steel', id, true
  from regions where level = 'district' and name = 'Pune';
insert into seller_segments (seller_id, segment_id)
select '00000000-0000-0000-0000-0000000000a1', id from segments where name = 'TMT Bars';

insert into brands (name, status) values ('Check Tiscon', 'approved'), ('Check Rods', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s where b.name in ('Check Tiscon', 'Check Rods') and s.name = 'TMT Bars';
insert into seller_brands (seller_id, brand_id, segment_id)
select '00000000-0000-0000-0000-0000000000a1', b.id, s.id from brands b, segments s
 where b.name = 'Check Tiscon' and s.name = 'TMT Bars';

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from brands where is_regular) as regular,
       (select id from brands where name = 'Check Tiscon') as tiscon,
       (select id from brands where name = 'Check Rods') as rods,
       (select id from regions where level = 'district' and name = 'Pune') as pune,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '8mm') as s8,
       (select z.id from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.display_name = '32mm') as s32,
       (select id from products where name = 'Fe550D') as fe550d,
       (select count(*) from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars' and z.is_active) as tmt_sizes;
grant select on k to public;

create function pg_temp.offered(p_brand uuid) returns text language sql as $$
  select coalesce((select count(*) filter (where is_selected) from seller_grades
                    where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = p_brand), 0) || ' grades, '
      || coalesce((select count(*) filter (where is_selected) from seller_sizes
                    where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = p_brand), 0) || ' sizes'
$$;

select pg_temp.expect_value('Every choice carries a brand', 'brand_id required in grades, sizes and history',
  $q$select case when count(*) = 3 then 'brand_id required in grades, sizes and history' else count(*) || ' of 3' end
     from information_schema.columns where table_schema = 'public' and column_name = 'brand_id' and is_nullable = 'NO'
      and table_name in ('seller_grades', 'seller_sizes', 'seller_offering_history')$q$);

-- Independent per brand -----------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('Select all sizes for Check Tiscon TMT', (select tmt_sizes::text from k),
  $q$select select_all_in_family((select tmt from k), 'sizes', true, null, (select tiscon from k))::text$q$);
select pg_temp.expect_value('Check Tiscon has every size; Regular still has none',
  (select 'Tiscon: 0 grades, ' || tmt_sizes || ' sizes | Regular: 0 grades, 0 sizes' from k),
  $q$select 'Tiscon: ' || pg_temp.offered((select tiscon from k)) || ' | Regular: ' || pg_temp.offered((select regular from k))$q$);
select pg_temp.expect_rows('S selects Fe550D for Regular only (saved without a brand = Regular)', 1,
  $q$insert into seller_grades (seller_id, product_id, is_selected) values ('00000000-0000-0000-0000-0000000000a1', (select fe550d from k), true)$q$);
select pg_temp.expect_rows('S selects 8mm for Regular', 1,
  $q$insert into seller_sizes (seller_id, brand_id, size_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select s8 from k), true)$q$);
select pg_temp.expect_value('Regular: Fe550D and 8mm; Tiscon unchanged',
  (select 'Tiscon: 0 grades, ' || tmt_sizes || ' sizes | Regular: 1 grades, 1 sizes' from k),
  $q$select 'Tiscon: ' || pg_temp.offered((select tiscon from k)) || ' | Regular: ' || pg_temp.offered((select regular from k))$q$);
select pg_temp.expect_rows('S unselects 32mm for Tiscon only', 1,
  $q$update seller_sizes set is_selected = false
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k) and size_id = (select s32 from k)$q$);
select pg_temp.expect_value('Unselect all Regular sizes leaves Tiscon untouched',
  (select '1 changed; Tiscon: 0 grades, ' || (tmt_sizes - 1) || ' sizes' from k),
  $q$select select_all_in_family((select tmt from k), 'sizes', false, null, (select regular from k)) || ' changed; Tiscon: '
            || pg_temp.offered((select tiscon from k))$q$);

-- History records the brand ---------------------------------------------------------

select pg_temp.expect_value('History of 32mm per brand', 'Check Tiscon: selected, unselected | Regular TMT: none',
  $q$select 'Check Tiscon: ' || string_agg(case when h.is_selected then 'selected' else 'unselected' end, ', ' order by h.changed_at)
         filter (where h.brand_id = (select tiscon from k))
         || ' | Regular TMT: ' || coalesce(string_agg('x', '') filter (where h.brand_id = (select regular from k)), 'none')
     from seller_offering_history h
     where h.seller_id = '00000000-0000-0000-0000-0000000000a1' and h.size_id = (select s32 from k)$q$);

-- Choosing needs an active brand line -----------------------------------------------

select pg_temp.expect_message('Choosing sizes for a brand he does not sell', 'Add Check Rods to the brands you sell first.',
  $q$insert into seller_sizes (seller_id, brand_id, size_id, is_selected)
     values ('00000000-0000-0000-0000-0000000000a1', (select rods from k), (select s8 from k), true)$q$);
select pg_temp.expect_rows('S stops selling Check Tiscon', 1,
  $q$update seller_brands set is_active = false where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k)$q$);
select pg_temp.expect_message('Choosing more for a switched-off brand line', 'Add Check Tiscon to the brands you sell first.',
  $q$update seller_sizes set is_selected = true
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k) and size_id = (select s32 from k)$q$);
select pg_temp.expect_rows('...but unselecting is always allowed', 1,
  $q$update seller_sizes set is_selected = false
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k) and size_id = (select s8 from k)$q$);
select pg_temp.expect_refused('A choice cannot be moved to another brand',
  $q$update seller_sizes set brand_id = (select regular from k)
     where seller_id = '00000000-0000-0000-0000-0000000000a1' and brand_id = (select tiscon from k) and size_id = (select s8 from k)$q$);

-- The per-size lookup reads the Regular line (until step 5) --------------------------------

select pg_temp.expect_rows('S selects 8mm for Regular again', 1,
  $q$update seller_sizes set is_selected = true where seller_id = '00000000-0000-0000-0000-0000000000a1'
       and brand_id = (select regular from k) and size_id = (select s8 from k)$q$);
select pg_temp.expect_value('S saves Regular TMT area settings (everywhere, no charts)', 'saved',
  $q$select case when save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]') is not null then 'saved' end$q$);
select pg_temp.expect_value('The lookup lists each size once, offered as Regular says (8mm only)', (select tmt_sizes || ' sizes, offered: 8mm' from k),
  $q$select count(*) || ' sizes, offered: ' || string_agg(display_name, ', ') filter (where is_offered)
     from resolve_size_figures('00000000-0000-0000-0000-0000000000a1', (select tmt from k), (select pune from k))$q$);
