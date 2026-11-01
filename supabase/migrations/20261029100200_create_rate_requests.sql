-- ============================================================
-- OBJECTIVE:      Let a buyer outside a retailer's reach ask to see his
--                 rates, and let the retailer approve or decline, up to his
--                 plan's outside-buyer limit. Either side can end an
--                 approval later. Every request is kept.
-- WHY:            Owner decision 2026-10-29 (docs/decisions.md 10.3): a
--                 buyer outside a free retailer's reach sees no rate unless
--                 the retailer approves his rate request; an approved
--                 outside buyer then sees the retailer's own-area rate,
--                 labelled. The rate engine needs to know who is approved.
-- CHANGES:        New enum public.rate_request_status. New table
--                 public.rate_requests. New functions public.request_rates,
--                 public.decide_rate_request, public.end_rate_request,
--                 public.is_approved_outside_buyer.
-- DEPENDS ON:     20261029100100_create_plans (seller_reach, region_within).
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the functions, table and enum. Request
--                 history would be lost.
-- TESTED:         On alee-dev 2026-10-29: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/rate_requests.sql.
-- DATE:           2026-10-29
-- ============================================================

-- requested -> approved, declined or withdrawn (by the buyer);
-- approved -> ended (by either side). Forward only.
create type public.rate_request_status as enum ('requested', 'approved', 'declined', 'withdrawn', 'ended');

create table public.rate_requests (
  id            uuid primary key default gen_random_uuid(),
  seller_id     uuid not null references public.accounts (id) on delete cascade,
  buyer_id      uuid not null references public.accounts (id) on delete cascade,
  status        public.rate_request_status not null default 'requested',
  requested_at  timestamptz not null default clock_timestamp(),
  decided_at    timestamptz,
  closed_at     timestamptz,
  closed_by     uuid references auth.users (id),
  check (seller_id <> buyer_id)
);

-- One open request or approval per seller and buyer at a time.
create unique index rate_requests_one_open
  on public.rate_requests (seller_id, buyer_id) where status in ('requested', 'approved');
create index rate_requests_by_buyer on public.rate_requests (buyer_id);

create function public.rate_requests_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.id, new.seller_id, new.buyer_id, new.requested_at) is distinct from
     (old.id, old.seller_id, old.buyer_id, old.requested_at)
     or not ((old.status = 'requested' and new.status in ('approved', 'declined', 'withdrawn'))
          or (old.status = 'approved' and new.status = 'ended')) then
    raise exception 'A rate request only moves forward: requested, then approved, declined or withdrawn; approved, then ended';
  end if;
  return new;
end;
$$;

create trigger rate_requests_before_update
  before update on public.rate_requests
  for each row execute function public.rate_requests_before_update();

create trigger rate_requests_prevent_delete
  before delete on public.rate_requests
  for each row execute function public.prevent_direct_delete();

-- Is this buyer an approved outside buyer of this seller right now?
create function public.is_approved_outside_buyer(p_seller_id uuid, p_buyer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.rate_requests rr
                  where rr.seller_id = p_seller_id and rr.buyer_id = p_buyer_id and rr.status = 'approved');
$$;

-- A buyer asks a reach-limited seller for his rates.
create function public.request_rates(p_seller_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reach  record;
  v_region uuid;
  v_id     uuid;
begin
  select a.region_id into v_region from public.accounts a where a.id = auth.uid();
  if v_region is null then
    raise exception 'Create your account first.';
  end if;
  if p_seller_id = auth.uid() then
    raise exception 'These are your own rates.';
  end if;
  select * into v_reach from public.seller_reach(p_seller_id);
  if v_reach.home_region_id is null then
    raise exception 'That seller was not found.';
  end if;
  if not v_reach.is_limited or public.region_within(v_region, v_reach.reach_region_id) then
    raise exception 'You can already see this seller''s rates for your area.';
  end if;
  if exists (select 1 from public.rate_requests rr where rr.seller_id = p_seller_id and rr.buyer_id = auth.uid()
               and rr.status in ('requested', 'approved')) then
    raise exception 'You have already asked this seller for his rates.';
  end if;
  insert into public.rate_requests (seller_id, buyer_id) values (p_seller_id, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- The seller (or an admin) approves or declines. Approving is limited by
-- the seller's plan: free retailers up to the outside-buyer limit.
create function public.decide_rate_request(p_request_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       record;
  v_limit integer;
begin
  select * into r from public.rate_requests rr where rr.id = p_request_id for update;
  if not found or (r.seller_id <> auth.uid() and not public.is_admin()) then
    raise exception 'That request was not found.';
  end if;
  if r.status <> 'requested' then
    raise exception 'That request is not waiting for a decision.';
  end if;
  if p_approve then
    select sr.outside_buyer_limit into v_limit from public.seller_reach(r.seller_id) sr;
    if v_limit is not null and (select count(*) from public.rate_requests x
                                 where x.seller_id = r.seller_id and x.status = 'approved') >= v_limit then
      raise exception '%', format('You can approve up to %s outside buyers on your plan. Upgrade to approve more.', v_limit);
    end if;
  end if;
  update public.rate_requests
     set status = case when p_approve then 'approved'::public.rate_request_status else 'declined' end,
         decided_at = clock_timestamp()
   where id = p_request_id;
end;
$$;

-- The buyer withdraws a waiting request, or either side ends an approval.
create function public.end_rate_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  select * into r from public.rate_requests rr where rr.id = p_request_id for update;
  if not found or (auth.uid() not in (r.seller_id, r.buyer_id) and not public.is_admin()) then
    raise exception 'That request was not found.';
  end if;
  if r.status = 'requested' and r.buyer_id = auth.uid() then
    update public.rate_requests set status = 'withdrawn', closed_at = clock_timestamp(), closed_by = auth.uid()
     where id = p_request_id;
  elsif r.status = 'approved' then
    update public.rate_requests set status = 'ended', closed_at = clock_timestamp(), closed_by = auth.uid()
     where id = p_request_id;
  else
    raise exception 'That request is already closed.';
  end if;
end;
$$;

-- Access ---------------------------------------------------------------------

alter table public.rate_requests enable row level security;

create policy "The seller and the buyer see their requests; admins see all"
  on public.rate_requests for select to authenticated
  using (seller_id = (select auth.uid()) or buyer_id = (select auth.uid()) or (select public.is_admin()));

grant select on public.rate_requests to authenticated;

revoke execute on function public.is_approved_outside_buyer(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.request_rates(uuid) from public, anon;
revoke execute on function public.decide_rate_request(uuid, boolean) from public, anon;
revoke execute on function public.end_rate_request(uuid) from public, anon;
grant execute on function public.request_rates(uuid) to authenticated;
grant execute on function public.decide_rate_request(uuid, boolean) to authenticated;
grant execute on function public.end_rate_request(uuid) to authenticated;
