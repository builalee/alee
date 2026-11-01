-- ============================================================
-- Checks: outside-buyer rate requests (rate_requests, request_rates,
-- decide_rate_request, end_rate_request, is_approved_outside_buyer).
-- Covers: only a buyer outside a seller's reach can ask (every role has a
-- reach); one open request
-- at a time; only the seller (or an admin) decides; the outside-buyer limit
-- comes from his plan; either side can end an approval; the buyer can
-- withdraw a waiting request; each side sees only his own requests; moves
-- forward only; nothing is deleted.
--
-- Test people (temporary logins, rolled back):
--   T ...a1  Tara Hardware, retailer at Check Karad City (free plan)
--   W ...a2  Wagh Steel, wholesaler (approved) at Satara
--   P ...b1, Q ...b2  buyers in Pune;  K ...b3  buyer in Check Karad City
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role)
select x.id::uuid, x.phone, 'authenticated', 'authenticated'
  from (values ('00000000-0000-0000-0000-0000000000a1', '919800000001'), ('00000000-0000-0000-0000-0000000000a2', '919800000002'),
               ('00000000-0000-0000-0000-0000000000b1', '919800000011'), ('00000000-0000-0000-0000-0000000000b2', '919800000012'),
               ('00000000-0000-0000-0000-0000000000b3', '919800000013'), ('00000000-0000-0000-0000-0000000000c3', '919800000033')) as x (id, phone);
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad', 'taluka', id, true from regions where level = 'district' and name = 'Satara';
insert into regions (name, level, parent_id, is_approved)
select 'Check Karad City', 'city', id, true from regions where name = 'Check Karad';
insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, '+' || u.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Tara', 'retailer', 'Check Karad City'),
               ('00000000-0000-0000-0000-0000000000a2', 'Wagh', 'wholesaler', 'Satara'),
               ('00000000-0000-0000-0000-0000000000b1', 'Prakash', 'retailer', 'Pune'),
               ('00000000-0000-0000-0000-0000000000b2', 'Qadir', 'retailer', 'Pune'),
               ('00000000-0000-0000-0000-0000000000b3', 'Kiran', 'retailer', 'Check Karad City')) as x (id, name, role, place)
  join auth.users u on u.id = x.id::uuid
  join regions r on r.name = x.place and r.level in ('district', 'city');
insert into seller_profiles (account_id, store_name, region_id, is_public)
select a.id, x.store, a.region_id, true
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Tara Hardware'), ('00000000-0000-0000-0000-0000000000a2', 'Wagh Steel')) as x (id, store)
  join accounts a on a.id = x.id::uuid;
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select decide_role_request(id, true) from role_requests where status = 'requested';
-- The free plan allows one outside buyer, for these checks.
select change_setting('free_outside_buyer_limit', '1');

-- Structure ----------------------------------------------------------------------

select pg_temp.as_owner();
select pg_temp.expect_value('Row Level Security is on', 'true',
  $q$select relrowsecurity::text from pg_class where oid = 'public.rate_requests'::regclass$q$);

-- Asking --------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b3');
select pg_temp.expect_message('A buyer inside his taluka does not need to ask', 'You can already see this seller''s rates for your area.',
  $q$select request_rates('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_message('A buyer inside a wholesaler''s district does not need to ask either', 'You can already see this seller''s rates for your area.',
  $q$select request_rates('00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select pg_temp.expect_rows('A Pune buyer asks Tara for her rates', 1, $q$select request_rates('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_message('...only once while it is open', 'You have already asked this seller for his rates.',
  $q$select request_rates('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_refused('He cannot approve himself by writing directly',
  $q$update rate_requests set status = 'approved'$q$);
select pg_temp.expect_message('He cannot decide his own request', 'That request was not found.',
  $q$select decide_rate_request(id, true) from rate_requests$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_rows('Q asks too', 1, $q$select request_rates('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_rows('Q sees only his own request', 1, $q$select * from rate_requests$q$);

-- Deciding ------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('Tara sees both requests', 2, $q$select * from rate_requests$q$);
select pg_temp.expect_rows('Tara approves P', 1,
  $q$select decide_rate_request(id, true) from rate_requests where buyer_id = '00000000-0000-0000-0000-0000000000b1'$q$);
select pg_temp.expect_message('Beyond her plan''s outside-buyer limit, an upgrade prompt', 'You can approve up to 1 outside buyers on your plan. Upgrade to approve more.',
  $q$select decide_rate_request(id, true) from rate_requests where buyer_id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_rows('She can still decline Q', 1,
  $q$select decide_rate_request(id, false) from rate_requests where buyer_id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('P is an approved outside buyer; Q is not', 'P yes, Q no',
  $q$select 'P ' || case when is_approved_outside_buyer('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1') then 'yes' else 'no' end
         || ', Q ' || case when is_approved_outside_buyer('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b2') then 'yes' else 'no' end$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_refused('Q cannot check approvals through the lookup',
  $q$select is_approved_outside_buyer('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1')$q$);
select pg_temp.expect_rows('After a decline Q can ask again; the old request stays', 1,
  $q$select request_rates('00000000-0000-0000-0000-0000000000a1')$q$);
select pg_temp.expect_rows('Q withdraws his new request', 1,
  $q$select end_rate_request(id) from rate_requests where status = 'requested'$q$);

-- Ending ------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('Tara ends P''s approval', 1,
  $q$select end_rate_request(id) from rate_requests where buyer_id = '00000000-0000-0000-0000-0000000000b1' and status = 'approved'$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('Every request is kept, with its outcome', 'P ended | Q declined | Q withdrawn',
  $q$select string_agg(case buyer_id when '00000000-0000-0000-0000-0000000000b1' then 'P' else 'Q' end || ' ' || status, ' | ' order by case buyer_id when '00000000-0000-0000-0000-0000000000b1' then 'P' else 'Q' end, status)
     from rate_requests$q$);

-- Never deleted, forward only --------------------------------------------------------

select pg_temp.expect_refused('An ended approval cannot be reopened, even by the database owner',
  $q$update rate_requests set status = 'approved' where status = 'ended'$q$);
select pg_temp.expect_refused('Not even the database owner can delete a request', $q$delete from rate_requests$q$);

-- Account deletion is never blocked ---------------------------------------------------

select pg_temp.expect_rows('A buyer who withdrew a request can still delete his account', 1,
  $q$delete from auth.users where id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_value('...and his requests go with it', '0',
  $q$select count(*)::text from rate_requests where buyer_id = '00000000-0000-0000-0000-0000000000b2'$q$);
select pg_temp.expect_rows('The admin who decided a role can delete his login too', 1,
  $q$delete from auth.users where id = '00000000-0000-0000-0000-0000000000c3'$q$);
