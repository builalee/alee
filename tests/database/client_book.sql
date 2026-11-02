-- ============================================================
-- Checks: the client book (clients, follow_ups, client_activities and their
-- functions).
-- Covers: Row Level Security is on; only the seller himself reads, adds and
-- edits his customers, follow-ups and activities, not other sellers, not
-- visitors, not admins; one customer per phone in a book; follow-ups only for
-- his own customers, for today or later; the "Today" list holds due and
-- overdue ones, overdue marked; a call or visit closes the due and overdue
-- ones but not future ones; a WhatsApp only logs; "Done" closes one; nothing
-- is changed afterwards or deleted.
--
-- Test people (temporary logins, rolled back):
--   S ...a1  seller with a client book
--   T ...b2  another seller
--   C ...c3  admin
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, 'retailer', (select id from regions where level = 'district' and name = 'Pune')
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Suresh', '+919800000001'),
               ('00000000-0000-0000-0000-0000000000b2', 'Tanvi', '+919800000002')) as x (id, name, phone);

create temp table k as
select (select id from regions where level = 'district' and name = 'Satara') as satara;
grant select on k to public;

-- Structure ----------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on for all three tables', 'true | true | true',
  $q$select string_agg(relrowsecurity::text, ' | ') from pg_class
      where oid in ('public.clients'::regclass, 'public.follow_ups'::regclass, 'public.client_activities'::regclass)$q$);

-- Customers ----------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
insert into clients (seller_id, name, phone, region_id, client_type, note)
values ('00000000-0000-0000-0000-0000000000a1', 'Ganesh Builders', '+919811111111', (select satara from k), 'builder', 'Pays in 30 days'),
       ('00000000-0000-0000-0000-0000000000a1', 'Ravi Hardware', null, null, 'dealer', null);
select pg_temp.expect_refused('A seller cannot choose a customer''s ID himself',
  $q$insert into clients (id, seller_id, name) values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'X')$q$);
select pg_temp.as_owner();
create temp table c as
select (select id from clients where name = 'Ganesh Builders') as ganesh,
       (select id from clients where name = 'Ravi Hardware') as ravi;
grant select on c to public;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_rows('A seller adds customers to his own book', 2, $q$select * from clients$q$);

select pg_temp.expect_refused('...not to another seller''s book',
  $q$insert into clients (seller_id, name) values ('00000000-0000-0000-0000-0000000000b2', 'Planted')$q$);
select pg_temp.expect_refused('A customer needs a name',
  $q$insert into clients (seller_id, name) values ('00000000-0000-0000-0000-0000000000a1', '  ')$q$);
select pg_temp.expect_refused('A phone must be an Indian mobile',
  $q$insert into clients (seller_id, name, phone) values ('00000000-0000-0000-0000-0000000000a1', 'X', '12345')$q$);
select pg_temp.expect_refused('The same phone cannot be entered twice in one book',
  $q$insert into clients (seller_id, name, phone) values ('00000000-0000-0000-0000-0000000000a1', 'Ganesh again', '+919811111111')$q$);

update clients set note = 'Pays in 45 days', client_type = 'dealer' where id = (select ganesh from c);
select pg_temp.expect_value('He edits his customer', 'dealer | Pays in 45 days',
  $q$select concat_ws(' | ', client_type, note) from clients where id = (select ganesh from c)$q$);
select pg_temp.expect_refused('...but cannot move a customer to another book',
  $q$update clients set seller_id = '00000000-0000-0000-0000-0000000000b2' where id = (select ganesh from c)$q$);
select pg_temp.expect_refused('...nor delete one',
  $q$delete from clients where id = (select ravi from c)$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
insert into clients (seller_id, name, phone) values ('00000000-0000-0000-0000-0000000000b2', 'Ganesh Builders', '+919811111111');
select pg_temp.expect_rows('Another seller may hold the same person in his own book, and sees only his own', 1,
  $q$select * from clients$q$);
update clients set note = 'Changed' where seller_id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.as_owner();
select pg_temp.expect_value('Another seller cannot edit S''s customer', 'Pays in 45 days',
  $q$select note from clients where id = (select ganesh from c)$q$);

-- Follow-ups ---------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select add_follow_up((select ganesh from c), india_today(), 'Ask about the slab order');
select add_follow_up((select ganesh from c), india_today() + 7, 'Next week');
select add_follow_up((select ravi from c), india_today() + 1, null);
select pg_temp.expect_message('A follow-up cannot be set in the past', 'Choose today or a later date.',
  $q$select add_follow_up((select ganesh from c), india_today() - 1)$q$);
select pg_temp.expect_message('A follow-up needs a date', 'Choose a date for the follow-up.',
  $q$select add_follow_up((select ganesh from c), null)$q$);
select pg_temp.expect_refused('Nobody writes a follow-up directly',
  $q$insert into follow_ups (seller_id, client_id, due_on) values ('00000000-0000-0000-0000-0000000000a1', (select ganesh from c), india_today())$q$);

-- One overdue follow-up, as if set a few days ago.
select pg_temp.as_owner();
insert into follow_ups (seller_id, client_id, due_on, note)
values ('00000000-0000-0000-0000-0000000000a1', (select ganesh from c), india_today() - 3, 'Collect payment');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_message('Another seller cannot add a follow-up to S''s customer', 'Customer not found.',
  $q$select add_follow_up((select ganesh from c), india_today())$q$);
select pg_temp.expect_rows('...nor sees S''s follow-ups', 0, $q$select * from follow_ups$q$);
select pg_temp.expect_rows('...nor has them in his Today list', 0, $q$select * from follow_ups_due()$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('Today: due and overdue only, oldest first, overdue marked',
  'Ganesh Builders, Collect payment, overdue / Ganesh Builders, Ask about the slab order, due',
  $q$select string_agg(concat_ws(', ', client_name, note, case when overdue then 'overdue' else 'due' end), ' / ' order by due_on)
       from follow_ups_due()$q$);

-- Logging ------------------------------------------------------------------------

select pg_temp.expect_value('A WhatsApp is logged and closes nothing', '0',
  $q$select closed::text from log_client_activity((select ganesh from c), 'whatsapp')$q$);
select pg_temp.expect_value('A call closes Ganesh''s due and overdue follow-ups', '2',
  $q$select closed::text from log_client_activity((select ganesh from c), 'call', 'Will order Monday')$q$);
select pg_temp.expect_rows('...so Today is empty', 0, $q$select * from follow_ups_due()$q$);
select pg_temp.expect_value('...and next week''s stays pending', 'pending',
  $q$select status::text from follow_ups where note = 'Next week'$q$);
select pg_temp.expect_rows('...the closed ones point to the call that closed them', 2,
  $q$select * from follow_ups f join client_activities a on a.id = f.closed_by where a.kind = 'call'$q$);
select pg_temp.expect_rows('His activity log for Ganesh holds both', 2,
  $q$select * from client_activities where client_id = (select ganesh from c)$q$);

select close_follow_up(id) from follow_ups where note = 'Next week';
select pg_temp.expect_value('"Done" closes a future follow-up too', 'done',
  $q$select status::text from follow_ups where note = 'Next week'$q$);
select pg_temp.expect_message('...only once', 'This follow-up is already closed.',
  $q$select close_follow_up(id) from follow_ups where note = 'Next week'$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_message('Another seller cannot log against S''s customer', 'Customer not found.',
  $q$select * from log_client_activity((select ganesh from c), 'visit')$q$);
select pg_temp.expect_rows('...nor read S''s activity log', 0, $q$select * from client_activities$q$);
select pg_temp.as_owner();
select pg_temp.expect_message('Another seller cannot close S''s follow-up', 'Follow-up not found.',
  $q$select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}', true),
            close_follow_up(id) from follow_ups where client_id = (select ravi from c)$q$);

-- Visitors and admins ------------------------------------------------------------

select pg_temp.as_visitor();
select pg_temp.expect_refused('Visitors read no customers', $q$select * from clients$q$);
select pg_temp.expect_refused('Visitors read no follow-ups', $q$select * from follow_ups$q$);
select pg_temp.expect_refused('Visitors read no activity', $q$select * from client_activities$q$);
select pg_temp.expect_refused('Visitors cannot log anything',
  $q$select * from log_client_activity((select ganesh from c), 'call')$q$);

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_rows('An admin does not read anyone''s client book', 0, $q$select * from clients$q$);
select pg_temp.expect_rows('...nor their follow-ups', 0, $q$select * from follow_ups$q$);
select pg_temp.expect_rows('...nor their activity', 0, $q$select * from client_activities$q$);

-- Never changed, never deleted ---------------------------------------------------

select pg_temp.as_owner();
select pg_temp.expect_refused('An activity is never changed, even by the database owner',
  $q$update client_activities set note = 'Changed'$q$);
select pg_temp.expect_refused('...nor deleted', $q$delete from client_activities$q$);
select pg_temp.expect_refused('A follow-up''s date is never changed',
  $q$update follow_ups set due_on = due_on + 1 where status = 'pending'$q$);
select pg_temp.expect_refused('A closed follow-up is never reopened',
  $q$update follow_ups set status = 'pending', done_at = null, closed_by = null where status = 'done'$q$);
select pg_temp.expect_refused('A follow-up is never deleted', $q$delete from follow_ups$q$);
select pg_temp.expect_refused('A customer is never deleted on his own', $q$delete from clients$q$);
