-- ============================================================
-- Shared helpers for the database checks. Loaded by
-- scripts/check-db.mts before every check file. Everything here is
-- temporary: the runner wraps each file in a transaction and always rolls
-- it back, so nothing a check creates is ever kept.
--
-- In a check file:
--   select pg_temp.as_visitor();            -- not logged in
--   select pg_temp.as_user('<uuid>');       -- ordinary logged-in user
--   select pg_temp.as_admin('<uuid>');      -- admin (app_metadata.role)
--   select pg_temp.as_owner();              -- database owner, like the
--                                           -- server's secret key
--
--   select pg_temp.expect_refused('label', $q$ <sql> $q$);
--   select pg_temp.expect_message('label', '<exact message>', $q$ <sql> $q$);
--   select pg_temp.expect_rows('label', <n>, $q$ <sql> $q$);
--   select pg_temp.expect_value('label', '<text>', $q$ <sql returning one value> $q$);
-- ============================================================

create temp table check_results (
  n         serial primary key,
  test      text not null,
  expected  text not null,
  got       text not null,
  pass      boolean not null
);
grant all on check_results to public;
grant all on sequence check_results_n_seq to public;

-- Error codes that mean "the database refused": no permission or blocked
-- by Row Level Security, a broken rule (check, unique, not-null, link), or
-- refused by one of our triggers. Any other error (a typo in the check, a
-- missing column) is reported as a broken check, never as a pass.
create function pg_temp.is_refusal(code text)
returns boolean language sql immutable as $$
  select code in ('42501', '23514', '23505', '23502', '23503', 'P0001');
$$;

create function pg_temp.expect_refused(test text, q text)
returns void language plpgsql as $$
declare
  code text;
  msg  text;
begin
  begin
    execute q;
  exception when others then
    get stacked diagnostics code = returned_sqlstate, msg = message_text;
  end;

  insert into check_results (test, expected, got, pass)
  values (
    test,
    'refused',
    case
      when code is null then 'allowed'
      when pg_temp.is_refusal(code) then 'refused: ' || msg
      else 'BROKEN CHECK (' || code || '): ' || msg
    end,
    code is not null and pg_temp.is_refusal(code)
  );
end;
$$;

-- Refused, and with exactly this message (for plain-language messages the
-- seller will see).
create function pg_temp.expect_message(test text, expected text, q text)
returns void language plpgsql as $$
declare
  code text;
  msg  text;
begin
  begin
    execute q;
  exception when others then
    get stacked diagnostics code = returned_sqlstate, msg = message_text;
  end;

  insert into check_results (test, expected, got, pass)
  values (test, 'refused: ' || expected,
          case when code is null then 'allowed' else 'refused: ' || msg end,
          code is not null and pg_temp.is_refusal(code) and msg = expected);
end;
$$;

create function pg_temp.expect_rows(test text, expected integer, q text)
returns void language plpgsql as $$
declare
  c   bigint;
  got text;
begin
  begin
    execute q;
    get diagnostics c = row_count;
    got := c || ' row(s)';
  exception when others then
    got := 'error: ' || sqlerrm;
  end;

  insert into check_results (test, expected, got, pass)
  values (test, expected || ' row(s)', got, got = expected || ' row(s)');
end;
$$;

create function pg_temp.expect_value(test text, expected text, q text)
returns void language plpgsql as $$
declare
  got text;
  ok  boolean := true;
begin
  begin
    execute q into got;
    got := coalesce(got, '(nothing)');
  exception when others then
    got := 'error: ' || sqlerrm;
    ok := false;
  end;

  insert into check_results (test, expected, got, pass)
  values (test, expected, got, ok and got = expected);
end;
$$;

-- Gives every test seller (ids 00000000-0000-0000-0000-...) a Regular brand
-- line for each product family he deals in. Adding a family does not do
-- this by itself (a seller sells only the brands he chooses). Runs with
-- owner rights, whoever is acting.
create function pg_temp.sell_regular()
returns void language sql security definer as $$
  insert into public.seller_brands (seller_id, brand_id, segment_id)
  select ss.seller_id, b.id, ss.segment_id
    from public.seller_segments ss, public.brands b
   where b.is_regular and ss.is_active and ss.seller_id::text like '00000000-0000-0000-0000-%'
  on conflict do nothing;
$$;

-- Acting as different people. Settings are local to the transaction.

create function pg_temp.as_user(uid uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', uid, 'role', 'authenticated', 'app_metadata', '{}'::json)::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;

create function pg_temp.as_admin(uid uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', uid, 'role', 'authenticated', 'app_metadata', json_build_object('role', 'admin'))::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;

create function pg_temp.as_visitor()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role', 'anon', true);
end;
$$;

create function pg_temp.as_owner()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'none', true);
end;
$$;

-- Approves the waiting role requests of every test person (ids
-- 00000000-0000-0000-0000-...), so checks about other things run with people
-- who really hold their roles. Runs with owner rights, whoever is acting.
create function pg_temp.approve_test_roles()
returns void language sql security definer as $$
  update public.role_requests set status = 'approved', decided_by = account_id, decided_at = clock_timestamp()
   where status = 'requested' and account_id::text like '00000000-0000-0000-0000-%';
$$;

-- Gives every test seller (ids 00000000-0000-0000-0000-...) with a seller
-- profile a reach plan covering every state, so checks about other things
-- are not stopped by reach. Checks about reach itself do not call this.
-- Runs with owner rights, whoever is acting.
create function pg_temp.reach_everywhere()
returns void language sql security definer as $$
  insert into public.plans (name, kind, reach_level, extra_states)
  values ('Check Wide Reach', 'reach', 'state', 9) on conflict (name) do nothing;
  insert into public.seller_plans (seller_id, plan_id, starts_at, ends_at, switched_on_by)
  select sp.account_id, (select p.id from public.plans p where p.name = 'Check Wide Reach'),
         now() - interval '1 day', now() + interval '1 year', sp.account_id
    from public.seller_profiles sp
   where sp.account_id::text like '00000000-0000-0000-0000-%'
     and not exists (select 1 from public.seller_plans x where x.seller_id = sp.account_id);
  insert into public.seller_plan_areas (seller_plan_id, region_id)
  select x.id, r.id
    from public.seller_plans x join public.plans p on p.id = x.plan_id and p.name = 'Check Wide Reach',
         public.regions r
   where r.level = 'state'
  on conflict do nothing;
$$;
