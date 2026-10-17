-- ============================================================
-- Checks: brand ownership.
-- Covers: a manufacturer claims a brand and an admin approves; claims are
-- private; one owner per brand; one manufacturer can own several; Regular
-- and unapproved brands cannot be claimed; the owner is set only through an
-- approved claim (not even an admin can set it directly); ending ownership;
-- every claim kept, never changed backwards or deleted.
-- Tables: brand_claims, brands.owner_id. Functions: claim_brand,
-- decide_brand_claim, end_brand_ownership.
--
-- Test people (temporary logins, rolled back):
--   M ...a1  manufacturer     N ...b2  another manufacturer
--   E ...e5  buyer (not a seller)     C ...c3  admin
-- Test brands: Check Steel, Check Rods (approved), Check Pending (requested)
-- ============================================================

insert into auth.users (id, phone, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', '919800000001', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', '919800000002', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', '919800000005', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', '919800000003', 'authenticated', 'authenticated');

insert into accounts (id, full_name, phone, signup_role, region_id)
select x.id::uuid, x.name, x.phone, x.role::account_role, r.id
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Mohan', '+919800000001', 'manufacturer'),
               ('00000000-0000-0000-0000-0000000000b2', 'Nikhil', '+919800000002', 'manufacturer'),
               ('00000000-0000-0000-0000-0000000000e5', 'Esha',  '+919800000005', 'retailer')) as x (id, name, phone, role)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into seller_profiles (account_id, store_name, region_id, is_public)
select x.id::uuid, x.store, r.id, true
  from (values ('00000000-0000-0000-0000-0000000000a1', 'Mohan Steel Mills'),
               ('00000000-0000-0000-0000-0000000000b2', 'Nikhil Ispat')) as x (id, store)
 cross join (select id from regions where level = 'district' and name = 'Pune') r;

insert into brands (name, status) values ('Check Steel', 'approved'), ('Check Rods', 'approved'), ('Check Pending', 'requested');

create temp table k as
select (select id from brands where name = 'Check Steel') as steel,
       (select id from brands where name = 'Check Rods') as rods,
       (select id from brands where name = 'Check Pending') as pending,
       (select id from brands where is_regular) as regular;
grant select on k to public;

-- Structure ---------------------------------------------------------------------

select pg_temp.expect_value('Row Level Security is on for claims', 'true',
  $q$select relrowsecurity::text from pg_class where oid = 'public.brand_claims'::regclass$q$);
select pg_temp.expect_value('No brand has an owner to begin with (test brands)', '0',
  $q$select count(*)::text from brands where name like 'Check%' and owner_id is not null$q$);

-- Claiming ------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_value('M claims Check Steel', 'claimed',
  $q$select case when claim_brand((select steel from k)) is not null then 'claimed' end$q$);
select pg_temp.expect_value('Claiming does not make him the owner yet', 'no owner',
  $q$select coalesce(owner_id::text, 'no owner') from brands where id = (select steel from k)$q$);
select pg_temp.expect_message('M claims it again while waiting', 'You have already claimed Check Steel; an admin will check it.',
  $q$select claim_brand((select steel from k))$q$);
select pg_temp.expect_message('Regular cannot be claimed', 'Regular is not a brand anyone can own.',
  $q$select claim_brand((select regular from k))$q$);
select pg_temp.expect_message('An unapproved brand cannot be claimed', 'That brand is not available to claim.',
  $q$select claim_brand((select pending from k))$q$);
select pg_temp.expect_refused('M approves his own claim',
  $q$select decide_brand_claim(id, true) from brand_claims where brand_id = (select steel from k)$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('N also claims Check Steel (two claimants)', 'claimed',
  $q$select case when claim_brand((select steel from k)) is not null then 'claimed' end$q$);
select pg_temp.expect_value('N sees only his own claim', '1',
  $q$select count(*)::text from brand_claims where brand_id = (select steel from k)$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000e5');
select pg_temp.expect_message('A buyer (not a seller) claims a brand', 'Only a manufacturer selling on ALEE can claim a brand.',
  $q$select claim_brand((select rods from k))$q$);
select pg_temp.expect_value('A buyer sees no claims', '0', $q$select count(*)::text from brand_claims$q$);
select pg_temp.as_visitor();
select pg_temp.expect_refused('Visitors cannot read claims', $q$select * from brand_claims$q$);
select pg_temp.expect_refused('Visitors cannot claim', $q$select claim_brand((select rods from k))$q$);

-- Deciding --------------------------------------------------------------------------

select pg_temp.as_owner();
create temp table cl as
select (select id from brand_claims where manufacturer_id = '00000000-0000-0000-0000-0000000000a1') as m_claim,
       (select id from brand_claims where manufacturer_id = '00000000-0000-0000-0000-0000000000b2') as n_claim;
grant select on cl to public;

select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin approves M''s claim', 'approved', $q$select decide_brand_claim((select m_claim from cl), true)::text$q$);
select pg_temp.expect_message('N''s claim cannot also be approved: one owner per brand',
  'Check Steel already has an owner. End that ownership before approving another claim.',
  $q$select decide_brand_claim((select n_claim from cl), true)$q$);
select pg_temp.expect_value('Admin rejects N''s claim', 'rejected', $q$select decide_brand_claim((select n_claim from cl), false)::text$q$);
select pg_temp.expect_message('A decided claim cannot be decided again', 'This claim has already been decided (approved).',
  $q$select decide_brand_claim((select m_claim from cl), false)$q$);
select pg_temp.expect_refused('Admin sets an owner directly, without a claim',
  $q$update brands set owner_id = '00000000-0000-0000-0000-0000000000b2' where id = (select steel from k)$q$);

select pg_temp.as_visitor();
select pg_temp.expect_value('Who owns a brand is public', 'Check Steel owned by Mohan Steel Mills',
  $q$select b.name || ' owned by ' || sp.store_name from brands b join seller_profiles sp on sp.account_id = b.owner_id
     where b.id = (select steel from k)$q$);

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_message('N claims an owned brand', 'Check Steel already has an owner. If you believe it is yours, contact ALEE.',
  $q$select claim_brand((select steel from k))$q$);
select pg_temp.expect_value('N sees his claim was rejected, and when', 'rejected, decided',
  $q$select status || ', ' || case when decided_at is not null then 'decided' else 'undecided' end
     from brand_claims where id = (select n_claim from cl)$q$);

-- One manufacturer, several brands ------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_message('M claims a brand he already owns', 'You already own Check Steel.',
  $q$select claim_brand((select steel from k))$q$);
select pg_temp.expect_value('M claims Check Rods too', 'claimed',
  $q$select case when claim_brand((select rods from k)) is not null then 'claimed' end$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin approves it', 'approved',
  $q$select decide_brand_claim(id, true)::text from brand_claims where brand_id = (select rods from k) and status = 'claimed'$q$);
select pg_temp.expect_value('M owns both brands', 'Check Rods, Check Steel',
  $q$select string_agg(name, ', ' order by name) from brands where owner_id = '00000000-0000-0000-0000-0000000000a1'$q$);

-- Ending ownership ------------------------------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.expect_refused('M ends his own ownership (only an admin can)', $q$select end_brand_ownership((select steel from k))$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin ends M''s ownership of Check Steel (brand sold)', 'ended',
  $q$select 'ended' from (select end_brand_ownership((select steel from k))) x$q$);
select pg_temp.expect_value('Check Steel now has no owner', 'no owner',
  $q$select coalesce(owner_id::text, 'no owner') from brands where id = (select steel from k)$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b2');
select pg_temp.expect_value('Now N can claim it', 'claimed',
  $q$select case when claim_brand((select steel from k)) is not null then 'claimed' end$q$);
select pg_temp.as_admin('00000000-0000-0000-0000-0000000000c3');
select pg_temp.expect_value('Admin approves N', 'approved',
  $q$select decide_brand_claim(id, true)::text from brand_claims
     where brand_id = (select steel from k) and status = 'claimed'$q$);
select pg_temp.expect_value('The full history of Check Steel is kept', 'M approved then ended, N rejected, N approved',
  $q$select string_agg(case manufacturer_id when '00000000-0000-0000-0000-0000000000a1' then 'M' else 'N' end
                       || ' ' || case status when 'ended' then 'approved then ended' else status::text end,
                       ', ' order by claimed_at)
     from brand_claims where brand_id = (select steel from k)$q$);

-- History can't be changed or removed -------------------------------------------------------

select pg_temp.as_owner();
select pg_temp.expect_refused('Even with the master key: turn an ended ownership back into approved',
  $q$update brand_claims set status = 'approved' where id = (select m_claim from cl)$q$);
select pg_temp.expect_refused('Even with the master key: change who claimed',
  $q$update brand_claims set manufacturer_id = '00000000-0000-0000-0000-0000000000b2' where id = (select m_claim from cl)$q$);
select pg_temp.expect_refused('Even with the master key: delete a claim',
  $q$delete from brand_claims where id = (select n_claim from cl)$q$);
select pg_temp.expect_refused('Even with the master key: set an owner without a claim',
  $q$update brands set owner_id = '00000000-0000-0000-0000-0000000000a1' where id = (select steel from k)$q$);
-- Pretend to be the claim functions (mark Regular as being changed), to
-- prove Regular still cannot be owned.
select set_config('alee.brand_ownership', (select regular from k)::text, true);
select pg_temp.expect_message('Even with the master key: give Regular an owner', 'Regular is never owned',
  $q$update brands set owner_id = '00000000-0000-0000-0000-0000000000a1' where is_regular$q$);
select set_config('alee.brand_ownership', '', true);
