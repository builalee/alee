-- ============================================================
-- Checks: the brand list.
-- Covers: Regular exists, covers every family, shown as "Regular TMT";
-- family short names; sellers request missing brands; duplicates and known
-- spellings refused in plain words; admins approve or reject; decisions are
-- final; requests private until approved; approved brands public; nobody
-- but admins edits brands; nothing deleted.
-- Tables: brands, brand_families. Functions: request_brand, decide_brand,
-- brand_covers_family, brand_display_name.
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller        T ...b2  another seller
--   E ...e5  buyer (not a seller)    C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', '919800000005', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'distributor', r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Sunil', '+919800000001'),
               ('00000000-0000-0000-0000-0000000000b2', 'Tara',  '+919800000002'),
               ('00000000-0000-0000-0000-0000000000e5', 'Esha',  '+919800000005')) as x (id, name, phone)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_profiles (account_id, store_name, region_id, is_public)
select x.id::uuid, x.store, r.id, true
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Sunil Steel'),
               ('00000000-0000-0000-0000-0000000000b2', 'Tara Traders')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from segments where name = 'MS Angles') as angles,
       (select id from segments where name = 'MS Channels') as channels,
       (select id from brands where is_regular) as regular;
grant select on k to public;

-- Structure and Regular -----------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on', 'brand_families=true, brands=true',
  $q$select string_agg(relname || '=' || relrowsecurity, ', ' order by relname) from pg_class
     where relnamespace = 'public'::regnamespace and relname in ('brands', 'brand_families')$q$);
select pg_temp.expect_value('Family short names', 'TMT, Angles, Channels',
  $q$select string_agg(short_name, ', ' order by sort_order) from segments where name in ('TMT Bars', 'MS Angles', 'MS Channels')$q$);
select pg_temp.expect_value('Exactly one Regular brand, approved and active', '1 Regular, approved, active',
  $q$select count(*) || ' Regular, ' || min(status::text) || ', ' || case when bool_and(is_active) then 'active' else 'off' end
     from brands where is_regular$q$);
select pg_temp.expect_value('Regular covers every family', 'true, true, true',
  $q$select string_agg(brand_covers_family((select regular from k), id)::text, ', ' order by sort_order)
     from segments where name in ('TMT Bars', 'MS Angles', 'MS Channels')$q$);
select pg_temp.expect_value('Regular is shown with the family''s name', 'Regular TMT, Regular Angles, Regular Channels',
  $q$select string_agg(brand_display_name((select regular from k), id), ', ' order by sort_order)
     from segments where name in ('TMT Bars', 'MS Angles', 'MS Channels')$q$);
select pg_temp.expect_value('A new family without a short name gets its full name', 'Check Pipes',
  $q$with s as (insert into segments (name, sort_order) values ('Check Pipes', 999) returning short_name) select short_name from s$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_refused('Regular cannot be given a family list (it covers all)',
  $q$insert into brand_families (brand_id, segment_id) values ((select regular from k), (select tmt from k))$q$);
select pg_temp.expect_refused('Regular cannot be rejected', $q$update brands set status = 'rejected' where is_regular$q$);
select pg_temp.expect_refused('Regular cannot be switched off', $q$update brands set is_active = false where is_regular$q$);
select pg_temp.expect_refused('A second Regular cannot be added',
  $q$insert into brands (name, is_regular, status) values ('Plain', true, 'approved')$q$);

-- A seller requests a missing brand ---------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('S requests "Check Tiscon" for TMT and angles', 'requested',
  $q$select case when request_brand(' Check Tiscon ', array[(select tmt from k), (select angles from k)]) is not null
     then 'requested' end$q$);

select pg_temp.as_owner();
create temp table req as select id from brands where name = 'Check Tiscon';
grant select on req to public;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('S sees his request, name tidied, with its families', 'Check Tiscon: requested, Angles + TMT',
  $q$select b.name || ': ' || b.status || ', ' ||
            (select string_agg(s.short_name, ' + ' order by s.short_name) from brand_families bf join segments s on s.id = bf.segment_id
              where bf.brand_id = b.id)
     from brands b where b.id = (select id from req)$q$);
select pg_temp.expect_message('The same name again, in other capitals', 'check tiscon is already on ALEE (as Check Tiscon).',
  $q$select request_brand('check tiscon', array[(select tmt from k)])$q$);
select pg_temp.expect_message('A request with no families', 'Choose which product families Check Kamdhenu covers.',
  $q$select request_brand('Check Kamdhenu', array[]::uuid[])$q$);
select pg_temp.expect_message('A request with no name', 'Enter the brand''s name.',
  $q$select request_brand('  ', array[(select tmt from k)])$q$);
select pg_temp.expect_refused('S approves his own request', $q$select decide_brand((select id from req), true)$q$);
select pg_temp.expect_rows('S edits his request directly (nothing changes)', 0,
  $q$update brands set status = 'approved' where id = (select id from req)$q$);
select pg_temp.expect_refused('S adds an approved brand directly',
  $q$insert into brands (name, status) values ('Check Sneaky', 'approved')$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('Another seller cannot see the request', '0',
  $q$select count(*)::text from brands where id = (select id from req)$q$);
select pg_temp.expect_message('...and cannot request the same name meanwhile', 'Check Tiscon is already on ALEE (as Check Tiscon).',
  $q$select request_brand('Check Tiscon', array[(select tmt from k)])$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_message('A buyer (not a seller) requests a brand', 'Only sellers can request a brand.',
  $q$select request_brand('Check Buyer Brand', array[(select tmt from k)])$q$);
select pg_temp.as_visitor();
select pg_temp.expect_value('Visitors cannot see the request', '0',
  $q$select count(*)::text from brands where id = (select id from req)$q$);
select pg_temp.expect_refused('Visitors cannot request brands', $q$select request_brand('Check V', array[(select tmt from k)])$q$);

-- An admin decides ------------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin approves "Check Tiscon"', 'approved', $q$select decide_brand((select id from req), true)::text$q$);
select pg_temp.expect_value('The decision records who and when', 'by admin C, timed',
  $q$select case when decided_by = '00000000-0000-0000-0000-0000000000c3' then 'by admin C' else 'by ?' end || ', ' ||
            case when decided_at is not null then 'timed' else 'untimed' end from brands where id = (select id from req)$q$);
select pg_temp.expect_message('A decision is final', 'This brand has already been decided (approved).',
  $q$select decide_brand((select id from req), false)$q$);
select pg_temp.expect_refused('...even editing the status directly', $q$update brands set status = 'rejected' where id = (select id from req)$q$);
select pg_temp.expect_rows('Admin adds an old spelling', 1,
  $q$update brands set alternate_names = array['Check Tisconn'] where id = (select id from req)$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_message('A known spelling is caught', 'check tisconn is already on ALEE (as Check Tiscon).',
  $q$select request_brand('check tisconn', array[(select tmt from k)])$q$);
select pg_temp.expect_value('T requests "Check Typo Steel"', 'requested',
  $q$select case when request_brand('Check Typo Steel', array[(select tmt from k)]) is not null then 'requested' end$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin rejects it', 'rejected',
  $q$select decide_brand((select id from brands where name = 'Check Typo Steel'), false)::text$q$);
select pg_temp.expect_rows('Admin adds a brand directly, already approved', 1,
  $q$insert into brands (name, status) values ('Check Kamdhenu', 'approved')$q$);
select pg_temp.expect_rows('...and sets its family', 1,
  $q$insert into brand_families (brand_id, segment_id) select id, (select tmt from k) from brands where name = 'Check Kamdhenu'$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('T still sees his rejected request', 'rejected',
  $q$select status::text from brands where name = 'Check Typo Steel'$q$);
select pg_temp.expect_value('A rejected name can be requested again later', 'requested',
  $q$select case when request_brand('Check Typo Steel', array[(select tmt from k)]) is not null then 'requested' end$q$);
select pg_temp.expect_value('...and both the rejected and the new request are kept', 'rejected, requested',
  $q$select string_agg(status::text, ', ' order by status::text) from brands where name = 'Check Typo Steel'$q$);

-- Who sees what ------------------------------------------------------------------------

select pg_temp.as_visitor();
select pg_temp.expect_value('Visitors see approved brands only', 'Check Kamdhenu, Check Tiscon',
  $q$select string_agg(name, ', ' order by name) from brands where name like 'Check%'$q$);
select pg_temp.expect_value('Visitors see which families an approved brand covers', 'Check Tiscon: Angles, TMT',
  $q$select 'Check Tiscon: ' || string_agg(s.short_name, ', ' order by s.short_name)
     from brand_families bf join segments s on s.id = bf.segment_id where bf.brand_id = (select id from req)$q$);
select pg_temp.expect_value('Check Tiscon covers TMT, not Channels', 'TMT true, Channels false',
  $q$select 'TMT ' || brand_covers_family((select id from req), (select tmt from k)) || ', Channels '
            || brand_covers_family((select id from req), (select channels from k))$q$);
select pg_temp.expect_value('A branded name is shown as itself', 'Check Tiscon',
  $q$select brand_display_name((select id from req), (select tmt from k))$q$);

-- Nothing is deleted ------------------------------------------------------------------

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_refused('Admin deletes a brand', $q$delete from brands where id = (select id from req)$q$);
select pg_temp.as_owner();
select pg_temp.expect_refused('Even with the master key: delete a brand', $q$delete from brands where id = (select id from req)$q$);
select pg_temp.expect_refused('Even with the master key: remove a brand''s family',
  $q$delete from brand_families where brand_id = (select id from req)$q$);
select pg_temp.expect_rows('A brand is switched off instead', 1, $q$update brands set is_active = false where id = (select id from req)$q$);
