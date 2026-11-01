-- ============================================================
-- OBJECTIVE:      Record requests for the higher roles (wholesaler,
--                 distributor, manufacturer) and their approval or refusal,
--                 and give one lookup for the role an account actually has.
--                 Until an admin approves a higher role, the account is a
--                 retailer.
-- WHY:            Owner decision 2026-10-29 (docs/decisions.md 9.3): anyone
--                 can sign up as a retailer at once; the higher roles are a
--                 request, because they carry no reach limit (10.3). The
--                 rate engine needs to know who is a retailer.
-- CHANGES:        New enum public.role_request_status. New table
--                 public.role_requests. New functions public.approved_role,
--                 public.request_role, public.decide_role_request. Signing
--                 up with a higher role creates a request automatically.
-- DEPENDS ON:     20261017045859_create_accounts.
-- TOUCHES EXISTING DATA: Yes, additions only. Every existing account that
--                 signed up as wholesaler, distributor or manufacturer gets
--                 one waiting request, so until an admin approves it he is
--                 treated as a retailer. Nothing existing is changed. On
--                 alee-dev there are no accounts, so nothing is added.
-- REVERSIBLE:     Yes, by dropping the functions, table and enum. The
--                 request history would be lost.
-- TESTED:         On alee-dev 2026-10-29: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/roles.sql.
-- DATE:           2026-10-29
-- ============================================================

create type public.role_request_status as enum ('requested', 'approved', 'refused');

create table public.role_requests (
  id              uuid primary key default gen_random_uuid(),
  account_id      uuid not null references public.accounts (id) on delete cascade,
  requested_role  public.account_role not null check (requested_role <> 'retailer'),
  status          public.role_request_status not null default 'requested',
  requested_at    timestamptz not null default clock_timestamp(),
  decided_by      uuid references auth.users (id),
  decided_at      timestamptz,
  check ((status = 'requested') = (decided_at is null)),
  check ((status = 'requested') = (decided_by is null))
);

-- One waiting request per account at a time.
create unique index role_requests_one_waiting
  on public.role_requests (account_id) where status = 'requested';
create index role_requests_by_account on public.role_requests (account_id, decided_at desc);

-- A request is decided once: requested -> approved or refused. Nothing else
-- about it ever changes.
create function public.role_requests_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'requested' or new.status = 'requested'
     or new.account_id <> old.account_id or new.requested_role <> old.requested_role
     or new.requested_at <> old.requested_at then
    raise exception 'A role request is decided once and never changed afterwards';
  end if;
  return new;
end;
$$;

create trigger role_requests_before_update
  before update on public.role_requests
  for each row execute function public.role_requests_before_update();

create trigger role_requests_prevent_delete
  before delete on public.role_requests
  for each row execute function public.prevent_direct_delete();

-- The role an account actually has: the most recently approved higher
-- role, otherwise retailer. Internal: used by the rate engine and other
-- engines, which run with owner rights.
create function public.approved_role(p_account_id uuid)
returns public.account_role
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select rr.requested_role from public.role_requests rr
      where rr.account_id = p_account_id and rr.status = 'approved'
      order by rr.decided_at desc limit 1),
    'retailer'::public.account_role);
$$;

-- Signing up as a higher role is a request.
create function public.accounts_request_signup_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.signup_role <> 'retailer' then
    insert into public.role_requests (account_id, requested_role) values (new.id, new.signup_role);
  end if;
  return new;
end;
$$;

create trigger accounts_request_signup_role
  after insert on public.accounts
  for each row execute function public.accounts_request_signup_role();

-- A person asks for a higher role later.
create function public.request_role(p_role public.account_role)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null or not exists (select 1 from public.accounts a where a.id = auth.uid()) then
    raise exception 'Create your account first.';
  end if;
  if p_role = 'retailer' then
    raise exception 'Every account can sell as a retailer already.';
  end if;
  if public.approved_role(auth.uid()) = p_role then
    raise exception 'You already have this role.';
  end if;
  if exists (select 1 from public.role_requests rr where rr.account_id = auth.uid() and rr.status = 'requested') then
    raise exception 'Your earlier request is still waiting for ALEE.';
  end if;
  insert into public.role_requests (account_id, requested_role) values (auth.uid(), p_role)
  returning id into v_id;
  return v_id;
end;
$$;

-- An admin approves or refuses.
create function public.decide_role_request(p_request_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only ALEE can approve roles.';
  end if;
  update public.role_requests
     set status = case when p_approve then 'approved'::public.role_request_status else 'refused' end,
         decided_by = auth.uid(), decided_at = clock_timestamp()
   where id = p_request_id and status = 'requested';
  if not found then
    raise exception 'That request is not waiting for a decision.';
  end if;
end;
$$;

-- Existing accounts that signed up with a higher role: one waiting request
-- each (none on alee-dev).
insert into public.role_requests (account_id, requested_role)
select a.id, a.signup_role from public.accounts a where a.signup_role <> 'retailer';

-- Access ---------------------------------------------------------------------

alter table public.role_requests enable row level security;

create policy "People see their own role requests; admins see all"
  on public.role_requests for select to authenticated
  using (account_id = (select auth.uid()) or (select public.is_admin()));

grant select on public.role_requests to authenticated;

revoke execute on function public.approved_role(uuid) from public, anon, authenticated;
revoke execute on function public.accounts_request_signup_role() from public, anon, authenticated;
revoke execute on function public.request_role(public.account_role) from public, anon;
revoke execute on function public.decide_role_request(uuid, boolean) from public, anon;
grant execute on function public.request_role(public.account_role) to authenticated;
grant execute on function public.decide_role_request(uuid, boolean) to authenticated;
