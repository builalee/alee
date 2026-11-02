-- ============================================================
-- OBJECTIVE:      Let ALEE remove a role it approved earlier, and keep that
--                 as a permanent record. From that moment the account no
--                 longer has the role.
-- WHY:            Owner decision 2026-11-02 (docs/decisions.md 16.9): if a
--                 distributor's approval is removed later, his appointments
--                 must stop counting at once. A role request is decided once
--                 and never changed, so a removal can't be written on it.
-- CHANGES:        New table public.role_removals. New functions
--                 public.holds_role, public.remove_role. public.approved_role
--                 now skips a removed role.
-- DEPENDS ON:     20261029100000_create_role_requests.
-- TOUCHES EXISTING DATA: No. There are no removals yet, so every account
--                 keeps the role it has today.
-- REVERSIBLE:     Yes: put approved_role back and drop the two functions and
--                 the table. Any removals recorded would be lost, and those
--                 accounts would get their roles back.
-- TESTED:         On alee-dev 2026-11-02: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass, including
--                 tests/database/roles.sql.
-- DATE:           2026-11-02
-- ============================================================

create table public.role_removals (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null unique references public.role_requests (id) on delete cascade,
  reason      text not null check (length(btrim(reason)) > 0),
  removed_by  uuid not null,
  removed_at  timestamptz not null default clock_timestamp()
);

comment on table public.role_removals is
  'An approved role that ALEE later removed: which approval, why, who and when. Never changed or deleted.';

create trigger role_removals_prevent_update
  before update on public.role_removals
  for each row execute function public.prevent_update();
create trigger role_removals_prevent_direct_delete
  before delete on public.role_removals
  for each row execute function public.prevent_direct_delete();

-- Whether an account holds a role now: approved, and not removed since.
-- Internal, like approved_role.
create function public.holds_role(p_account_id uuid, p_role public.account_role)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.role_requests rr
     where rr.account_id = p_account_id and rr.requested_role = p_role and rr.status = 'approved'
       and not exists (select 1 from public.role_removals x where x.request_id = rr.id));
$$;

-- The role an account actually has: the most recently approved higher role
-- not removed since, otherwise retailer.
create or replace function public.approved_role(p_account_id uuid)
returns public.account_role
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select rr.requested_role from public.role_requests rr
      where rr.account_id = p_account_id and rr.status = 'approved'
        and not exists (select 1 from public.role_removals x where x.request_id = rr.id)
      order by rr.decided_at desc limit 1),
    'retailer'::public.account_role);
$$;

-- An admin removes a role. To have it again he asks again, and an admin
-- decides again.
create function public.remove_role(p_account_id uuid, p_role public.account_role, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only ALEE can remove a role.';
  end if;
  if not public.holds_role(p_account_id, p_role) then
    raise exception 'This account doesn''t have that role.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why the role is being removed.';
  end if;

  insert into public.role_removals (request_id, reason, removed_by)
  select rr.id, btrim(p_reason), auth.uid()
    from public.role_requests rr
   where rr.account_id = p_account_id and rr.requested_role = p_role and rr.status = 'approved'
     and not exists (select 1 from public.role_removals x where x.request_id = rr.id);
end;
$$;

-- Access ---------------------------------------------------------------------

alter table public.role_removals enable row level security;

create policy "People see their own role removals; admins see all"
  on public.role_removals for select to authenticated
  using ((select public.is_admin()) or exists (
    select 1 from public.role_requests rr
     where rr.id = request_id and rr.account_id = (select auth.uid())));

grant select on public.role_removals to authenticated;

revoke execute on function public.holds_role(uuid, public.account_role) from public, anon, authenticated;
revoke execute on function public.remove_role(uuid, public.account_role, text) from public, anon;
grant execute on function public.remove_role(uuid, public.account_role, text) to authenticated;
