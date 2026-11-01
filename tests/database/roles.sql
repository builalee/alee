-- ============================================================
-- Checks: role requests (role_requests, approved_role, request_role,
-- decide_role_request).
-- Covers: signing up as a higher role is a request, and the account is a
-- retailer until approved; retailer signups need nothing; only admins
-- decide; a decision is final and kept; one waiting request at a time;
-- people see only their own requests; nothing can be deleted.
--
-- Test people (temporary logins, rolled back):
--   A ...a1  signs up as a distributor
--   R ...a2  signs up as a retailer
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');
insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Anil', '+919800000001', 'distributor'),
               ('00000000-0000-0000-0000-0000000000a2', 'Rekha', '+919800000002', 'retailer')) as x (id, name, phone, role)
 cross join (select id from regions where level = 'district' and name = 'Satara') r;

-- Structure ----------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on', 'true',
  $q$select relrowsecurity::text from pg_class where oid = 'public.role_requests'::regclass$q$);

-- Signup --------------------------------------------------------------------------

select pg_temp.expect_value('Signing up as a distributor creates a waiting request', 'distributor requested',
  $q$select requested_role || ' ' || status from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_value('...and until it is approved he is a retailer', 'retailer',
  $q$select approved_role('00000000-0000-0000-0000-0000000000a1')::text$q$);
select pg_temp.expect_value('A retailer signup needs no request', '0 requests, retailer',
  $q$select (select count(*) from role_requests where account_id = '00000000-0000-0000-0000-0000000000a2') || ' requests, '
         || approved_role('00000000-0000-0000-0000-0000000000a2')$q$);

-- Who decides ------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('He cannot approve his own request', 'Only ALEE can approve roles.',
  $q$select decide_role_request(id, true) from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('He cannot change his request directly',
  $q$update role_requests set status = 'approved' where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('He cannot add an approved request directly',
  $q$insert into role_requests (account_id, requested_role, status) values ('00000000-0000-0000-0000-0000000000a1', 'manufacturer', 'approved')$q$);
select pg_temp.expect_message('A second request while one is waiting', 'Your earlier request is still waiting for ALEE.',
  $q$select request_role('manufacturer')$q$);
select pg_temp.expect_message('Asking for retailer', 'Every account can sell as a retailer already.',
  $q$select request_role('retailer')$q$);
select pg_temp.expect_refused('He cannot read whether someone is a retailer through the lookup',
  $q$select approved_role('00000000-0000-0000-0000-0000000000a2')$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.expect_rows('Another person sees none of his requests', 0,
  $q$select * from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_rows('A retailer asks to become a wholesaler', 1, $q$select request_role('wholesaler')$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('The admin sees both requests', 2,
  $q$select * from role_requests where account_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.expect_rows('The admin approves the distributor', 1,
  $q$select decide_role_request(id, true) from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_rows('The admin refuses the wholesaler', 1,
  $q$select decide_role_request(id, false) from role_requests where account_id = '00000000-0000-0000-0000-0000000000a2'$q$);
select pg_temp.as_owner();
select pg_temp.expect_value('Approved: now a distributor; refused: still a retailer', 'distributor, retailer',
  $q$select approved_role('00000000-0000-0000-0000-0000000000a1') || ', ' || approved_role('00000000-0000-0000-0000-0000000000a2')$q$);
select pg_temp.expect_value('Who decided and when is recorded', 'decided by admin',
  $q$select 'decided by admin' from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'
       and decided_by = '00000000-0000-0000-0000-0000000000c3' and decided_at is not null$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_message('A decision cannot be taken twice', 'That request is not waiting for a decision.',
  $q$select decide_role_request(id, false) from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Never changed, never deleted --------------------------------------------------------

select pg_temp.as_owner();
select pg_temp.expect_refused('Not even the database owner can change a decision',
  $q$update role_requests set status = 'refused' where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
select pg_temp.expect_refused('Not even the database owner can delete a request',
  $q$delete from role_requests where account_id = '00000000-0000-0000-0000-0000000000a1'$q$);
