-- ============================================================
-- Checks: the demo setup screens, end to end, as ordinary logged-in people.
-- Sends the database exactly what the screens send, in the same order:
-- sign-up, role approval, brand request and approval, ownership claim and
-- approval, grades and sizes, template copy, loading, areas, closing time,
-- a first publish, appointing a distributor and his acceptance.
-- Covers: a district left out stays "Price on request", never priced; missing
-- and zero stay apart; an unapproved manufacturer is held to a retailer's
-- reach; only an admin approves. Tables: none new.
--
-- Test people (temporary logins, rolled back):
--   M ...a1  manufacturer in Satara    D ...b2  distributor in Sangli
--   A ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

create temp view ids as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select r.id from regions r where r.level = 'district' and r.name = 'Satara') as satara,
       (select r.id from regions r where r.level = 'district' and r.name = 'Sangli') as sangli,
       (select r.id from regions r where r.level = 'district' and r.name = 'Pune') as pune,
       (select id from charts where is_template and chart_type = 'size' and is_active limit 1) as template;
grant select on ids to public;

-- Sign-up ------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('Signing up with his own login phone works', 1,
  $q$insert into accounts (id, full_name, firm_name, phone, signup_role, region_id)
     values ('00000000-0000-0000-0000-0000000000a1', 'Check Maker', 'Check Mills', '+919800000001', 'manufacturer', (select satara from ids))$q$);
select pg_temp.expect_refused('Signing up with someone else''s phone is refused',
  $q$insert into accounts (id, full_name, phone, signup_role, region_id)
     values ('00000000-0000-0000-0000-0000000000a1', 'X', '+919800000002', 'retailer', (select satara from ids))$q$);
select pg_temp.expect_rows('Both consents are recorded', 2,
  $q$insert into consents (account_id, purpose, notice_version, granted) values
     ('00000000-0000-0000-0000-0000000000a1', 'terms_of_use', 'demo-2026-11', true),
     ('00000000-0000-0000-0000-0000000000a1', 'privacy_notice', 'demo-2026-11', true)$q$);
select pg_temp.expect_rows('Sign-up as manufacturer leaves a waiting request', 1,
  $q$select 1 from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1' and status = 'requested'$q$);
select pg_temp.expect_rows('His profile saves', 1,
  $q$insert into seller_profiles (account_id, store_name, region_id, is_public)
     values ('00000000-0000-0000-0000-0000000000a1', 'Check Mills', (select satara from ids), true)$q$);
select pg_temp.expect_rows('His family saves', 1,
  $q$insert into seller_segments (seller_id, segment_id, base_unit)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'tonne')$q$);
select pg_temp.expect_refused('A user cannot approve his own role',
  $q$select decide_role_request((select id from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'), true)$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_rows('The distributor signs up', 1,
  $q$insert into accounts (id, full_name, phone, signup_role, region_id)
     values ('00000000-0000-0000-0000-0000000000b2', 'Check Dist', '+919800000002', 'distributor', (select sangli from ids))$q$);
select pg_temp.expect_rows('The distributor saves a profile', 1,
  $q$insert into seller_profiles (account_id, store_name, region_id, is_public)
     values ('00000000-0000-0000-0000-0000000000b2', 'Check Dist Co', (select sangli from ids), true)$q$);

-- Brand request, claim and the admin's three approvals -----------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('He requests his brand', 'requested',
  $q$select case when request_brand('Check Demo Steel', array[(select tmt from ids)]) is not null then 'requested' end$q$);
select pg_temp.expect_refused('He cannot approve his own brand',
  $q$select decide_brand((select id from brands where name = 'Check Demo Steel'), true)$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('The admin sees the waiting role requests', 2,
  $q$select 1 from role_requests where status = 'requested'
      and account_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2')$q$);
select decide_role_request((select id from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'), true);
select decide_role_request((select id from role_requests where account_id = '00000000-0000-0000-0000-0000000000b2'), true);
select pg_temp.expect_value('The admin approves the brand', 'approved',
  $q$select decide_brand((select id from brands where name = 'Check Demo Steel'), true)::text$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('He adds the approved brand', 1,
  $q$insert into seller_brands (seller_id, brand_id, segment_id)
     values ('00000000-0000-0000-0000-0000000000a1', (select id from brands where name = 'Check Demo Steel'), (select tmt from ids))$q$);
select pg_temp.expect_value('He claims it', 'claimed',
  $q$select case when claim_brand((select id from brands where name = 'Check Demo Steel')) is not null then 'claimed' end$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('The admin approves the claim', 'approved',
  $q$select decide_brand_claim((select id from brand_claims where status = 'claimed' and manufacturer_id = '00000000-0000-0000-0000-0000000000a1'), true)::text$q$);

-- Grades, sizes, template, loading, areas -----------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
create temp view b as select id from brands where name = 'Check Demo Steel';
grant select on b to public;

select pg_temp.expect_value('The template copies into his own chart', 'copied',
  $q$select case when copy_template((select template from ids), 'Size differences', '00000000-0000-0000-0000-0000000000a1') is not null then 'copied' end$q$);
select pg_temp.expect_rows('All grades save', (select count(*)::int from products where segment_id = (select tmt from ids) and is_active),
  $q$insert into seller_grades (seller_id, brand_id, product_id, is_selected)
     select '00000000-0000-0000-0000-0000000000a1', (select id from b), p.id, true
       from products p where p.segment_id = (select tmt from ids) and p.is_active$q$);
select pg_temp.expect_rows('All sizes save', (select count(*)::int from sizes where segment_id = (select tmt from ids) and is_active),
  $q$insert into seller_sizes (seller_id, brand_id, size_id, is_selected)
     select '00000000-0000-0000-0000-0000000000a1', (select id from b), s.id, true
       from sizes s where s.segment_id = (select tmt from ids) and s.is_active$q$);
select pg_temp.expect_rows('The loading chart saves', 1,
  $q$insert into charts (seller_id, segment_id, chart_type, name)
     values ('00000000-0000-0000-0000-0000000000a1', (select tmt from ids), 'loading', 'Loading')$q$);
select pg_temp.expect_value('Loading entered as 0 saves as text, exactly as the screen sends it', 'saved',
  $q$select case when save_chart_version((select id from charts where seller_id = '00000000-0000-0000-0000-0000000000a1' and chart_type = 'loading'),
       'tonne', '[{"size_id": null, "amount": "0"}]'::jsonb) is not null then 'saved' end$q$);

-- What the screen sends: one row per district he filled in, each carrying the
-- charts and the grade premiums. Grade premiums 0, Satara 0, Pune +300.
create function pg_temp.areas(with_premium boolean) returns jsonb language sql stable as $f$
  select jsonb_agg(jsonb_build_object(
           'region_id', r.region, 'area_difference', r.diff,
           'size_chart_id', (select id from charts where seller_id = '00000000-0000-0000-0000-0000000000a1' and chart_type = 'size'),
           'loading_chart_id', (select id from charts where seller_id = '00000000-0000-0000-0000-0000000000a1' and chart_type = 'loading'),
           'grades', case when with_premium then
             (select jsonb_agg(jsonb_build_object('product_id', p.id, 'premium', '0'))
                from products p where p.segment_id = (select tmt from ids) and p.is_active)
             else '[]'::jsonb end))
    from (values ((select satara from ids), '0'), ((select pune from ids), '300')) as r (region, diff);
$f$;
grant execute on function pg_temp.areas(boolean) to public;

select pg_temp.expect_value('His areas save', 'saved',
  $q$select case when save_area_settings((select tmt from ids), pg_temp.areas(true),
       '00000000-0000-0000-0000-0000000000a1', (select id from b)) is not null then 'saved' end$q$);
select pg_temp.expect_value('Nothing is missing, so the setup screen says ready', '0',
  $q$select count(*)::text from rate_preview((select id from b), (select tmt from ids), 1, '00000000-0000-0000-0000-0000000000a1') p
      where coalesce(array_length(p.missing, 1), 0) > 0$q$);
select pg_temp.expect_value('A setup with no premium saves', 'saved',
  $q$select case when save_area_settings((select tmt from ids), pg_temp.areas(false),
       '00000000-0000-0000-0000-0000000000a1', (select id from b)) is not null then 'saved' end$q$);
select pg_temp.expect_value('The same preview then flags what is missing', 'flagged',
  $q$select case when count(*) > 0 then 'flagged' else 'none' end
       from rate_preview((select id from b), (select tmt from ids), 1, '00000000-0000-0000-0000-0000000000a1') p
      where coalesce(array_length(p.missing, 1), 0) > 0$q$);
select pg_temp.expect_value('Saving the full setup again clears it', 'saved',
  $q$select case when save_area_settings((select tmt from ids), pg_temp.areas(true),
       '00000000-0000-0000-0000-0000000000a1', (select id from b)) is not null then 'saved' end$q$);

select pg_temp.expect_refused('Publishing before accepting a closing time is refused',
  $q$select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from ids), 'brand_id', (select id from b), 'base_rate', 50000)))$q$);
select pg_temp.expect_rows('He accepts the closing time', 1,
  $q$update seller_profiles set market_close_time = '18:00' where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('Now his first publish goes through', 'published',
  $q$select case when publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from ids), 'brand_id', (select id from b), 'base_rate', 50000))) is not null then 'published' end$q$);

select pg_temp.expect_value('A district he filled in is priced', 'priced',
  $q$select distinct status from seller_rate('00000000-0000-0000-0000-0000000000a1', (select id from b), (select tmt from ids), (select pune from ids))$q$);
select pg_temp.expect_value('A district he left out is "Price on request", never priced', 'price_on_request',
  $q$select distinct status from seller_rate('00000000-0000-0000-0000-0000000000a1', (select id from b), (select tmt from ids),
       (select r.id from regions r where r.level = 'district' and r.name = 'Kolhapur'))$q$);

-- Appointing a distributor ---------------------------------------------------------

select pg_temp.expect_value('He offers Sangli to the distributor, Type B', 'offered',
  $q$select case when offer_territory((select id from b), '00000000-0000-0000-0000-0000000000b2', (select tmt from ids),
       (select sangli from ids), 'manufacturer_prices') is not null then 'offered' end$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_rows('The distributor sees the offer', 1,
  $q$select 1 from territory_allocations where distributor_id = '00000000-0000-0000-0000-0000000000b2' and status = 'offered'$q$);
select pg_temp.expect_value('The distributor accepts', 'active',
  $q$select respond_to_territory((select id from territory_allocations where distributor_id = '00000000-0000-0000-0000-0000000000b2'), true)::text$q$);
select pg_temp.expect_rows('The distributor cannot read the manufacturer''s area setup', 0,
  $q$select 1 from area_setting_versions where seller_id = '00000000-0000-0000-0000-0000000000a1'$q$);
