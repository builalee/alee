-- ============================================================
-- Checks: product catalogue (families, grades, sizes).
-- Covers: seeded families and TMT weights, sizes shared per family, no
-- unit on grades, derived piece weight, unverified sizes kept off, who can
-- read and change the catalogue, and that nothing is deleted.
-- Tables: segments, products, sizes. View: sizes_with_piece_weight.
-- ============================================================

-- Structure and seed data ---------------------------------------------------

select pg_temp.expect_value('Row Level Security is on for the catalogue', 'products=true, segments=true, sizes=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace and relname in ('segments', 'products', 'sizes')$q$);

select pg_temp.expect_value('Product families, in order', 'TMT Bars, MS Angles, MS Channels',
  $q$select string_agg(name, ', ' order by sort_order) from segments$q$);
select pg_temp.expect_value('Every family defaults to per tonne', 'tonne, tonne, tonne',
  $q$select string_agg(default_base_unit::text, ', ' order by sort_order) from segments$q$);
select pg_temp.expect_value('TMT grades', 'Fe500, Fe500D, Fe550D',
  $q$select string_agg(p.name, ', ' order by p.name) from products p join segments s on s.id = p.segment_id
     where s.name = 'TMT Bars'$q$);

select pg_temp.expect_value('Grades carry no unit of their own', 'false',
  $q$select exists (select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'products' and column_name = 'base_unit')::text$q$);
select pg_temp.expect_value('Sizes belong to the family, not the grade', 'false',
  $q$select exists (select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'sizes' and column_name = 'product_id')::text$q$);

select pg_temp.expect_value('TMT weights per metre match IS 1786',
  '8mm=0.3950, 10mm=0.6170, 12mm=0.8880, 16mm=1.5800, 20mm=2.4660, 25mm=3.8530, 32mm=6.3130',
  $q$select string_agg(z.display_name || '=' || z.weight_per_metre_kg, ', ' order by z.sort_order)
     from sizes z join segments s on s.id = z.segment_id where s.name = 'TMT Bars'$q$);
select pg_temp.expect_value('Weight per piece is calculated: 12mm = 0.888 x 12 m', '10.656000',
  $q$select w.weight_per_piece_kg::text from sizes_with_piece_weight w join segments s on s.id = w.segment_id
     where s.name = 'TMT Bars' and w.display_name = '12mm'$q$);
select pg_temp.expect_value('No unverified size is switched on', '0',
  $q$select count(*)::text from sizes where is_active and not is_verified$q$);

-- Test data (rolled back) ---------------------------------------------------

insert into sizes (segment_id, display_name, sort_order, weight_per_metre_kg, piece_length_m,
                   weight_source, is_verified, is_active)
select id, 'Check size', 999, 1, 1, 'check', false, false from segments where name = 'TMT Bars';

create temp table snap as
select (select count(*) from sizes where is_active)::text as active_sizes,
       (select count(*) from sizes)::text as all_sizes;
grant select on snap to public;

-- Visitor, not logged in ----------------------------------------------------

select pg_temp.as_visitor();

select pg_temp.expect_value('Visitor sees only switched-on sizes', (select active_sizes from snap),
  $q$select count(*)::text from sizes$q$);
select pg_temp.expect_value('Visitor sees only switched-on sizes in the piece-weight view', (select active_sizes from snap),
  $q$select count(*)::text from sizes_with_piece_weight$q$);
select pg_temp.expect_refused('Visitor adds a family',
  $q$insert into segments (name) values ('X')$q$);

-- Ordinary logged-in user ---------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');

select pg_temp.expect_refused('Ordinary user adds a family',
  $q$insert into segments (name) values ('X')$q$);
select pg_temp.expect_refused('Ordinary user adds a grade',
  $q$insert into products (segment_id, name) select id, 'X' from segments where name = 'TMT Bars'$q$);
select pg_temp.expect_refused('Ordinary user adds a size',
  $q$insert into sizes (segment_id, display_name, weight_per_metre_kg, piece_length_m, weight_source)
     select id, 'X', 1, 1, 'x' from segments where name = 'TMT Bars'$q$);
select pg_temp.expect_rows('Ordinary user renames a family', 0,
  $q$update segments set name = name || '!'$q$);
select pg_temp.expect_rows('Ordinary user renames a grade', 0,
  $q$update products set name = name || '!'$q$);
select pg_temp.expect_rows('Ordinary user changes a size weight', 0,
  $q$update sizes set weight_per_metre_kg = 99$q$);
select pg_temp.expect_refused('Ordinary user deletes sizes',
  $q$delete from sizes$q$);

-- Admin ---------------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

select pg_temp.expect_value('Admin sees every size, including switched-off ones', (select all_sizes from snap),
  $q$select count(*)::text from sizes$q$);
select pg_temp.expect_rows('Admin adds a family', 1,
  $q$insert into segments (name, sort_order) values ('Check Segment', 999)$q$);
select pg_temp.expect_rows('Admin adds a grade without giving a unit', 1,
  $q$insert into products (segment_id, name) select id, 'Fe600' from segments where name = 'TMT Bars'$q$);
select pg_temp.expect_refused('Admin switches on an unverified size',
  $q$update sizes set is_active = true where display_name = 'Check size'$q$);
select pg_temp.expect_rows('Admin verifies a size, then switches it on', 1,
  $q$update sizes set is_verified = true, is_active = true where display_name = 'Check size'$q$);
select pg_temp.expect_refused('Admin adds "12MM" to TMT when 12mm exists',
  $q$insert into sizes (segment_id, display_name, weight_per_metre_kg, piece_length_m, weight_source, is_verified)
     select id, '12MM', 1, 1, 'x', true from segments where name = 'TMT Bars'$q$);
select pg_temp.expect_refused('Admin deletes a family',
  $q$delete from segments where name = 'Check Segment'$q$);

-- Database owner (same power as the server's secret key) --------------------

select pg_temp.as_owner();

select pg_temp.expect_refused('Even the database owner cannot delete a size',
  $q$delete from sizes where display_name = 'Check size'$q$);
select pg_temp.expect_refused('Even the database owner cannot delete a grade',
  $q$delete from products where name = 'Fe600'$q$);
select pg_temp.expect_refused('A family cannot default to per piece',
  $q$update segments set default_base_unit = 'piece' where name = 'Check Segment'$q$);
