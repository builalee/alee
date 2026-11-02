-- ============================================================
-- Checks: enquiries (enquiries, send_enquiry, received_enquiries).
-- Covers: only a logged-in buyer sends, as himself, from his own area; the
-- same tap twice makes one enquiry; a Type B area's enquiry goes to the
-- authorised distributor; one sent after the market closed is marked; a
-- hidden name stays hidden from the seller, who sees area, buyer type and
-- recent activity instead; nobody reads another person's enquiries; nothing
-- is changed or deleted.
--
-- Test people (temporary logins, rolled back):
--   M ...a1  manufacturer in Pune, owns Check Steel, also sells Regular
--   D ...b2  distributor in Satara: Satara for Check Steel, Type B
--   E ...e5  buyer in Satara, hides his name
--   F ...f6  buyer in Pune, shows his name
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', '919800000005', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000f6', '919800000006', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, firm_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.firm, x.phone, x.role::account_role,
       (select id from regions where level = 'district' and name = x.district)
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Mohan', null, '+919800000001', 'manufacturer', 'Pune'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala', null, '+919800000002', 'distributor', 'Satara'),
               ('00000000-0000-0000-0000-0000000000e5', 'Esha', null, '+919800000005', 'retailer', 'Satara'),
               ('00000000-0000-0000-0000-0000000000f6', 'Farhan', 'Farhan Hardware', '+919800000006', 'retailer', 'Pune'))
       as x (id, name, firm, phone, role, district);

insert into seller_profiles (account_id, store_name, region_id, is_public, market_close_time)
select x.id::uuid, x.store, a.region_id, true, '18:00'
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Mohan Steel Mills'),
               ('00000000-0000-0000-0000-0000000000b2', 'Bala Traders')) as x (id, store)
  join accounts a on a.id = x.id::uuid;

insert into seller_segments (seller_id, segment_id)
select x.id::uuid, s.id from segments s,
  (values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2')) as x (id)
 where s.name = 'TMT Bars';
select pg_temp.sell_regular();
select pg_temp.approve_test_roles();

insert into brands (name, status) values ('Check Steel', 'approved');
insert into brand_families (brand_id, segment_id)
select b.id, s.id from brands b, segments s where b.name = 'Check Steel' and s.name = 'TMT Bars';

create temp table k as
select (select id from segments where name = 'TMT Bars') as tmt,
       (select id from brands where name = 'Check Steel') as steel,
       (select id from brands where is_regular) as regular,
       (select id from regions where level = 'district' and name = 'Satara') as satara,
       (select id from products p where p.segment_id = (select id from segments where name = 'TMT Bars') order by p.name limit 1) as grade,
       (select id from sizes z where z.segment_id = (select id from segments where name = 'MS Angles') limit 1) as angle_size;
grant select on k to public;

-- M owns Check Steel and appoints D for Satara, Type B.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into seller_brands (seller_id, brand_id, segment_id)
values ('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select tmt from k));
select claim_brand((select steel from k));
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_brand_claim(id, true) from brand_claims where brand_id = (select steel from k);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select offer_territory((select steel from k), '00000000-0000-0000-0000-0000000000b2', (select tmt from k), (select satara from k), 'manufacturer_prices');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select respond_to_territory(id, true) from territory_allocations where distributor_id = '00000000-0000-0000-0000-0000000000b2';

-- M's Regular line is published, then his market closed.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select save_area_settings((select tmt from k), '[{"everywhere": true, "area_difference": 0}]', null, (select regular from k));
select publish_rates(jsonb_build_array(jsonb_build_object('segment_id', (select tmt from k), 'base_rate', 40000, 'brand_id', (select regular from k))));
select close_market_now(null, null, array[(select regular from k)]);

-- Structure ----------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on', 'true',
  $q$select relrowsecurity::text from pg_class where oid = 'public.enquiries'::regclass$q$);

-- Sending ------------------------------------------------------------------------

select pg_temp.as_visitor();
select pg_temp.expect_refused('A visitor cannot send an enquiry',
  $q$select send_enquiry('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select tmt from k), gen_random_uuid())$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_refused('Nobody writes an enquiry directly',
  $q$insert into enquiries (buyer_id, seller_id, recipient_id, brand_id, segment_id, region_id, show_identity, received_after_close, request_key)
     values ('00000000-0000-0000-0000-0000000000e5', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1',
             (select steel from k), (select tmt from k), (select satara from k), true, false, gen_random_uuid())$q$);
select pg_temp.expect_message('Without the form''s key, nothing is sent', 'Send the enquiry again from the form.',
  $q$select send_enquiry('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select tmt from k), null)$q$);
select pg_temp.expect_message('A brand the seller doesn''t sell', 'This seller doesn''t sell that brand.',
  $q$select send_enquiry('00000000-0000-0000-0000-0000000000b2', (select steel from k), (select tmt from k), gen_random_uuid())$q$);
select pg_temp.expect_message('A size from another product family', 'That size is not in this product family.',
  $q$select send_enquiry('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select tmt from k), gen_random_uuid(),
       null, (select angle_size from k))$q$);
select pg_temp.expect_message('A quantity of zero', 'Enter a quantity above zero, or leave it empty.',
  $q$select send_enquiry('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select tmt from k), gen_random_uuid(),
       null, null, 0)$q$);

select pg_temp.expect_value('Tapping Send twice with the same key gives back the same enquiry', 'same',
  $q$select case when send_enquiry('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select tmt from k),
                                   '00000000-0000-0000-0000-00000000e001', (select grade from k), null, 25, 'tonne', 'Need by Friday', false)
                    = send_enquiry('00000000-0000-0000-0000-0000000000a1', (select steel from k), (select tmt from k),
                                   '00000000-0000-0000-0000-00000000e001', (select grade from k), null, 25, 'tonne', 'Need by Friday', false)
                 then 'same' end$q$);
select pg_temp.expect_rows('...so there is one enquiry', 1, $q$select * from enquiries$q$);

select pg_temp.as_owner();
select pg_temp.expect_value('Type B area (Satara): it goes to the authorised distributor, from his own area', 'Bala Traders, Satara',
  $q$select sp.store_name || ', ' || r.name from enquiries e
       join seller_profiles sp on sp.account_id = e.recipient_id join regions r on r.id = e.region_id
      where e.buyer_id = '00000000-0000-0000-0000-0000000000e5'$q$);
select pg_temp.expect_value('Check Steel''s market was never closed: not marked', 'false',
  $q$select received_after_close::text from enquiries where buyer_id = '00000000-0000-0000-0000-0000000000e5'$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000f6');
select send_enquiry('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k),
                    '00000000-0000-0000-0000-00000000f001', null, null, null, null, 'Rate for 12mm?', true);
select pg_temp.as_owner();
select pg_temp.expect_value('No territory in Pune: it goes to the seller himself', 'Mohan Steel Mills',
  $q$select sp.store_name from enquiries e join seller_profiles sp on sp.account_id = e.recipient_id
      where e.buyer_id = '00000000-0000-0000-0000-0000000000f6'$q$);
select pg_temp.expect_value('Sent after M closed his Regular market: marked received after close', 'true',
  $q$select received_after_close::text from enquiries where buyer_id = '00000000-0000-0000-0000-0000000000f6'$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('A seller cannot send an enquiry to himself', 'You cannot send an enquiry to yourself.',
  $q$select send_enquiry('00000000-0000-0000-0000-0000000000a1', (select regular from k), (select tmt from k), gen_random_uuid())$q$);

-- Who sees what ------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('The distributor sees the enquiry, but not the hidden name or phone',
  'Satara | Mohan Steel Mills | no name | no phone | retailer | 1 | 25 tonne | Need by Friday | false',
  $q$select concat_ws(' | ', area_name, via_seller, coalesce(buyer_name, 'no name'), coalesce(buyer_phone, 'no phone'),
                      buyer_type, buyer_recent, trim_scale(quantity) || ' ' || quantity_unit, note, received_after_close::text)
       from received_enquiries()$q$);
select pg_temp.expect_rows('...and cannot read it, or the buyer, from the table', 0, $q$select * from enquiries$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('M sees only the one sent to him, with the name the buyer chose to show',
  'Pune | Farhan Hardware (Farhan) | +919800000006 | true',
  $q$select concat_ws(' | ', area_name, buyer_name, buyer_phone, received_after_close::text) from received_enquiries()$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_rows('A buyer sees the enquiries he sent', 1, $q$select * from enquiries$q$);
select pg_temp.expect_rows('...and receives none', 0, $q$select * from received_enquiries()$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f6');
select pg_temp.expect_rows('Another buyer doesn''t see them', 0,
  $q$select * from enquiries where buyer_id = '00000000-0000-0000-0000-0000000000e5'$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('Visitors read nothing', $q$select * from enquiries$q$);
select pg_temp.expect_refused('Visitors receive nothing', $q$select * from received_enquiries()$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('Admins see every enquiry', 2,
  $q$select * from enquiries where buyer_id in ('00000000-0000-0000-0000-0000000000e5', '00000000-0000-0000-0000-0000000000f6')$q$);

-- Never changed, never deleted ---------------------------------------------------

select pg_temp.as_owner();
select pg_temp.expect_refused('Not even the database owner can change an enquiry', $q$update enquiries set note = 'Changed'$q$);
select pg_temp.expect_refused('Not even the database owner can delete an enquiry', $q$delete from enquiries$q$);
