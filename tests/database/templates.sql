-- ============================================================
-- Checks: ALEE's shipped templates (the real ones, not test data).
-- Covers: "Standard TMT – Maharashtra & Goa" exists with the owner's exact
-- figures per tonne; a seller who copies it gets exactly those figures;
-- changing the template afterwards leaves his copy unchanged; no loading
-- template is shipped (each seller enters his own loading).
-- Tables: charts, chart_versions, chart_version_figures.
-- Functions: copy_template, save_chart_version.
--
-- Also covers: a copy is converted into the seller's unit for that family
-- (per tonne -> per kg and back), exactly or not at all; percentages are
-- unchanged; a seller who does not deal in the family cannot copy.
--
-- Test people (temporary logins, rolled back):
--   S ...51  seller, TMT per tonne
--   K ...52  seller, TMT per kg
--   N ...53  seller who does not deal in TMT
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-000000000051', '919800000051', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000052', '919800000052', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000053', '919800000053', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'wholesaler', r.id
  from (values ('00000000-0000-0000-0000-000000000051', 'Sunil', '+919800000051'),
               ('00000000-0000-0000-0000-000000000052', 'Kavya', '+919800000052'),
               ('00000000-0000-0000-0000-000000000053', 'Nitin', '+919800000053')) as x (id, name, phone)
 cross join (select id from regions where level = 'district' and name = 'Kolhapur') r;

insert into seller_profiles (account_id, store_name, region_id, is_public)
select x.id::uuid, x.store, r.id, true
  from (values ('00000000-0000-0000-0000-000000000051', 'Sunil Steel'),
               ('00000000-0000-0000-0000-000000000052', 'Kavya Hardware'),
               ('00000000-0000-0000-0000-000000000053', 'Nitin Angles')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Kolhapur') r;

insert into seller_segments (seller_id, segment_id, base_unit)
select x.id::uuid, s.id, x.unit::unit
  from (values ('00000000-0000-0000-0000-000000000051', 'TMT Bars',  'tonne'),
               ('00000000-0000-0000-0000-000000000052', 'TMT Bars',  'kg'),
               ('00000000-0000-0000-0000-000000000053', 'MS Angles', 'tonne')) as x (id, segment, unit)
  join segments s on s.name = x.segment;

-- The shipped template ----------------------------------------------------------

select pg_temp.expect_value('The TMT size template exists, active, as an ALEE template',
  'size chart for TMT Bars, template, active',
  $q$select c.chart_type || ' chart for ' || s.name || ', '
            || case when c.is_template then 'template' else 'NOT a template' end || ', '
            || case when c.is_active then 'active' else 'switched off' end
     from charts c join segments s on s.id = c.segment_id
     where c.name = 'Standard TMT – Maharashtra & Goa'$q$);

select pg_temp.expect_value('Its latest figures, per tonne, are exactly the owner''s',
  'per tonne: 8mm=6500, 10mm=5500, 12mm=5500, 16mm=5500, 20mm=5500, 25mm=5500, 32mm=6500',
  $q$select 'per ' || v.unit || ': ' ||
            string_agg(z.display_name || '=' || f.amount, ', ' order by z.sort_order)
     from charts c
     join chart_versions v on v.chart_id = c.id
      and v.version_number = (select max(version_number) from chart_versions where chart_id = c.id)
     join chart_version_figures f on f.version_id = v.id
     join sizes z on z.id = f.size_id
     where c.name = 'Standard TMT – Maharashtra & Goa'
     group by v.unit$q$);

select pg_temp.expect_value('No loading template is shipped (each seller enters his own loading)', '0',
  $q$select count(*)::text from charts where is_template and is_active and chart_type = 'loading'$q$);

-- A seller copies it ------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-000000000051');

select pg_temp.expect_value('Seller sees the template', '1',
  $q$select count(*)::text from charts where is_template and name = 'Standard TMT – Maharashtra & Goa'$q$);
select pg_temp.expect_value('Seller copies the template into his own chart', 'copied',
  $q$select case when copy_template(
       (select id from charts where is_template and name = 'Standard TMT – Maharashtra & Goa'),
       'Sunil TMT sizes') is not null then 'copied' end$q$);
select pg_temp.expect_value('His copy has exactly the template''s figures, per tonne',
  'per tonne: 8mm=6500, 10mm=5500, 12mm=5500, 16mm=5500, 20mm=5500, 25mm=5500, 32mm=6500',
  $q$select 'per ' || v.unit || ': ' ||
            string_agg(z.display_name || '=' || f.amount, ', ' order by z.sort_order)
     from charts c
     join chart_versions v on v.chart_id = c.id
     join chart_version_figures f on f.version_id = v.id
     join sizes z on z.id = f.size_id
     where c.name = 'Sunil TMT sizes'
     group by v.unit$q$);
select pg_temp.expect_value('His copy is his own and records which template it came from',
  'his own, from Standard TMT – Maharashtra & Goa',
  $q$select case when c.seller_id = '00000000-0000-0000-0000-000000000051' and not c.is_template
                 then 'his own' else 'NOT his own' end || ', from ' || t.name
     from charts c join charts t on t.id = c.copied_from_template_id
     where c.name = 'Sunil TMT sizes'$q$);

-- A per-kg seller copies it: converted into his unit -------------------------

select pg_temp.as_user('00000000-0000-0000-0000-000000000052');

select pg_temp.expect_value('Per-kg seller copies the template', 'copied',
  $q$select case when copy_template(
       (select id from charts where is_template and name = 'Standard TMT – Maharashtra & Goa'),
       'Kavya TMT sizes') is not null then 'copied' end$q$);
select pg_temp.expect_value('His copy is saved per kg: Rs 6,500 per tonne became Rs 6.5 per kg',
  'per kg: 8mm=6.5, 10mm=5.5, 12mm=5.5, 16mm=5.5, 20mm=5.5, 25mm=5.5, 32mm=6.5',
  $q$select 'per ' || v.unit || ': ' ||
            string_agg(z.display_name || '=' || f.amount, ', ' order by z.sort_order)
     from charts c
     join chart_versions v on v.chart_id = c.id
     join chart_version_figures f on f.version_id = v.id
     join sizes z on z.id = f.size_id
     where c.name = 'Kavya TMT sizes'
     group by v.unit$q$);

select pg_temp.as_user('00000000-0000-0000-0000-000000000053');
select pg_temp.expect_refused('A seller who does not deal in TMT copies the TMT template',
  $q$select copy_template(
       (select id from charts where is_template and name = 'Standard TMT – Maharashtra & Goa'), 'x')$q$);

-- Conversion rules, using test templates (rolled back)
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
insert into charts (seller_id, is_template, segment_id, chart_type, name)
select null, true, id, x.type::chart_type, x.name
  from segments,
       (values ('discount', 'Check flat discount'), ('discount', 'Check percent discount'),
               ('size', 'Check inexact sizes'), ('size', 'Check per-kg sizes')) as x (type, name)
 where segments.name = 'TMT Bars';
select pg_temp.expect_value('Admin saves test templates: flat 500/tonne, 1.5%, 6500.55/tonne, 6.533/kg', 'saved',
  $q$select case when
       save_chart_version((select id from charts where name = 'Check flat discount'), 'tonne', null,
         '{"kind": "flat", "amount": 500}') is not null
   and save_chart_version((select id from charts where name = 'Check percent discount'), 'tonne', null,
         '{"kind": "percent", "percent": 1.5}') is not null
   and save_chart_version((select id from charts where name = 'Check inexact sizes'), 'tonne',
         jsonb_build_array(jsonb_build_object('size_id',
           (select z.id from sizes z join segments s on s.id = z.segment_id
             where s.name = 'TMT Bars' and z.display_name = '8mm'), 'amount', 6500.55))) is not null
   and save_chart_version((select id from charts where name = 'Check per-kg sizes'), 'kg',
         jsonb_build_array(jsonb_build_object('size_id',
           (select z.id from sizes z join segments s on s.id = z.segment_id
             where s.name = 'TMT Bars' and z.display_name = '8mm'), 'amount', 6.533))) is not null
   then 'saved' end$q$);

select pg_temp.as_user('00000000-0000-0000-0000-000000000052');
select pg_temp.expect_value('Per-kg seller copies the flat and percentage discount templates', 'copied',
  $q$select case when copy_template((select id from charts where name = 'Check flat discount'), 'Kavya flat') is not null
                  and copy_template((select id from charts where name = 'Check percent discount'), 'Kavya percent') is not null
             then 'copied' end$q$);
select pg_temp.expect_value('Flat discount Rs 500 per tonne becomes Rs 0.5 per kg', 'flat 0.5 per kg',
  $q$select d.kind || ' ' || d.flat_amount || ' per ' || v.unit
     from chart_version_discounts d join chart_versions v on v.id = d.version_id join charts c on c.id = v.chart_id
     where c.name = 'Kavya flat'$q$);
select pg_temp.expect_value('A percentage discount is not converted', 'percent 1.5 per kg',
  $q$select d.kind || ' ' || d.percent || ' per ' || v.unit
     from chart_version_discounts d join chart_versions v on v.id = d.version_id join charts c on c.id = v.chart_id
     where c.name = 'Kavya percent'$q$);
select pg_temp.expect_refused('Rs 6,500.55 per tonne cannot be converted to per kg exactly: copy refused, not rounded',
  $q$select copy_template((select id from charts where name = 'Check inexact sizes'), 'Kavya inexact')$q$);
select pg_temp.expect_value('No half-made copy is left behind after a refused copy', '0',
  $q$select count(*)::text from charts where name = 'Kavya inexact'$q$);

select pg_temp.as_user('00000000-0000-0000-0000-000000000051');
select pg_temp.expect_value('Per-tonne seller copies a per-kg template', 'copied',
  $q$select case when copy_template((select id from charts where name = 'Check per-kg sizes'), 'Sunil from kg') is not null
             then 'copied' end$q$);
select pg_temp.expect_value('Rs 6.533 per kg became Rs 6,533 per tonne', '8mm=6533 per tonne',
  $q$select z.display_name || '=' || f.amount || ' per ' || v.unit
     from chart_version_figures f join chart_versions v on v.id = f.version_id
     join charts c on c.id = v.chart_id join sizes z on z.id = f.size_id
     where c.name = 'Sunil from kg'$q$);

-- The template changes afterwards -----------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');

select pg_temp.expect_value('Admin changes the template (8mm 7000, 32mm 7000)', 'saved',
  $q$select case when save_chart_version(
       (select id from charts where is_template and name = 'Standard TMT – Maharashtra & Goa'), 'tonne',
       (select jsonb_agg(jsonb_build_object('size_id', z.id, 'amount',
                case when z.display_name in ('8mm', '32mm') then 7000 else 5500 end))
          from sizes z join segments s on s.id = z.segment_id
         where s.name = 'TMT Bars' and z.is_active)) is not null then 'saved' end$q$);

select pg_temp.as_user('00000000-0000-0000-0000-000000000051');

select pg_temp.expect_value('His copy is unchanged after the template changed',
  'v1 only, per tonne: 8mm=6500, 10mm=5500, 12mm=5500, 16mm=5500, 20mm=5500, 25mm=5500, 32mm=6500',
  $q$select case when count(distinct v.id) = 1 and max(v.version_number) = 1 then 'v1 only' else 'CHANGED' end
            || ', per ' || min(v.unit::text) || ': ' ||
            string_agg(z.display_name || '=' || f.amount, ', ' order by z.sort_order)
     from charts c
     join chart_versions v on v.chart_id = c.id
     join chart_version_figures f on f.version_id = v.id
     join sizes z on z.id = f.size_id
     where c.name = 'Sunil TMT sizes'$q$);
select pg_temp.expect_value('The template itself now shows the new figures', '8mm=7000, 32mm=7000',
  $q$select string_agg(z.display_name || '=' || f.amount, ', ' order by z.sort_order)
     from charts c
     join chart_versions v on v.chart_id = c.id
      and v.version_number = (select max(version_number) from chart_versions where chart_id = c.id)
     join chart_version_figures f on f.version_id = v.id
     join sizes z on z.id = f.size_id
     where c.name = 'Standard TMT – Maharashtra & Goa' and z.display_name in ('8mm', '32mm')$q$);
