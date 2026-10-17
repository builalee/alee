-- ============================================================
-- OBJECTIVE:      Track, per seller and product family, the latest publish,
--                 whether he is quoting today, and any early market close;
--                 keep every switch and early close as history; and work
--                 out whether a family is open, closed or not quoting.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.28 to
--                 2.30). A seller can stop quoting a family with one tap,
--                 without publishing; it stays off until he switches it back
--                 on. A family closes at the seller's daily closing time
--                 (Indian time) or when he presses "close market now";
--                 publishing again reopens it. This status is public; it
--                 contains no rates.
-- CHANGES:        New enum public.family_status_event.
--                 New tables public.seller_family_status (current state)
--                 and public.seller_family_status_history (every switch and
--                 early close, add-only).
--                 New functions public.market_status(...),
--                 public.set_quoting(...), public.close_market_now(...).
-- DEPENDS ON:     20261017084616_create_publishes.
--                 20261017050059_create_seller_profiles (market_close_time).
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the functions, tables and enum. The
--                 quoting and early-close history would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/publishes.sql (88).
--                 Status public and rate-free. Not quoting recorded and
--                 reversed, survives a publish; close now recorded, repeat
--                 records nothing, publishing reopens; admin actions marked;
--                 daily close at the Indian closing time, next day if
--                 published after it, never if no closing time is set.
-- DATE:           2026-10-17
-- ============================================================

create type public.family_status_event as enum ('stopped_quoting', 'resumed_quoting', 'closed_early');

-- Current state per seller and product family. Written only by
-- publish_rates, set_quoting and close_market_now.
create table public.seller_family_status (
  seller_id          uuid not null references public.seller_profiles (account_id) on delete cascade,
  segment_id         uuid not null references public.segments (id),
  -- Latest publish for this family: the quick way to a seller's current rate.
  latest_publish_id  uuid references public.publishes (id) on delete cascade,
  last_published_at  timestamptz,
  -- false = "not quoting today": buyers see "not quoting" and no figure.
  is_quoting         boolean not null default true,
  -- The latest "close market now". It closes the family only if it came
  -- after the latest publish; publishing again reopens.
  closed_early_at    timestamptz,
  updated_at         timestamptz not null default now(),
  primary key (seller_id, segment_id)
);

comment on table public.seller_family_status is
  'Per seller and family: latest publish, quoting or not, latest early close. Public; holds no rates.';

create index seller_family_status_publish_idx on public.seller_family_status (latest_publish_id);

create table public.seller_family_status_history (
  id           uuid primary key default gen_random_uuid(),
  seller_id    uuid not null references public.seller_profiles (account_id) on delete cascade,
  segment_id   uuid not null references public.segments (id),
  event        public.family_status_event not null,
  happened_at  timestamptz not null default clock_timestamp(),
  done_by      uuid not null,
  by_admin     boolean not null
);

comment on table public.seller_family_status_history is
  'Every "not quoting" switch and every early market close, with its time and who did it. Never changed.';

create index seller_family_status_history_idx
  on public.seller_family_status_history (seller_id, segment_id, happened_at);

create trigger seller_family_status_set_updated_at
  before update on public.seller_family_status
  for each row execute function public.set_updated_at();
create trigger seller_family_status_prevent_direct_delete
  before delete on public.seller_family_status
  for each row execute function public.prevent_direct_delete();
create trigger seller_family_status_history_prevent_update
  before update on public.seller_family_status_history
  for each row execute function public.prevent_update();
create trigger seller_family_status_history_prevent_direct_delete
  before delete on public.seller_family_status_history
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------

alter table public.seller_family_status enable row level security;
alter table public.seller_family_status_history enable row level security;

create policy "Anyone can see whether a seller is quoting, open or closed"
  on public.seller_family_status for select
  to anon, authenticated
  using (true);

create policy "Sellers read their own status history; admins read all"
  on public.seller_family_status_history for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

-- Read only; written by the functions below and publish_rates.
grant select on public.seller_family_status to anon, authenticated;
grant select on public.seller_family_status_history to authenticated;

-- Market status -------------------------------------------------------------------

-- Whether a seller's product family is open, closed or not quoting at a
-- moment (now by default). Public. The one place this is worked out.
--
--   not_published  never published (and not switched off)
--   not_quoting    switched off by the seller; no figure is shown
--   open           the latest published rate stands
--   closed         the latest published rate stays visible, marked closed
--                  at closed_at
--
-- Closed means a close happened after the latest publish and by p_at: the
-- first daily closing time (Indian time) after the publish, or an earlier
-- "close market now". With no closing time set, only "close market now"
-- closes. Publishing again reopens.
create function public.market_status(
  p_seller_id   uuid,
  p_segment_id  uuid,
  -- The moment to ask about; empty = right now (the real clock, so a
  -- close or publish a moment ago always counts).
  p_at          timestamptz default null
)
returns table (
  status             text,
  last_published_at  timestamptz,
  closed_at          timestamptz
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  s           record;
  v_at        timestamptz := coalesce(p_at, clock_timestamp());
  v_close     time;
  v_daily     timestamptz;
  v_closes_at timestamptz;
begin
  select st.last_published_at, st.is_quoting, st.closed_early_at into s
    from public.seller_family_status st
   where st.seller_id = p_seller_id and st.segment_id = p_segment_id;

  if found and not s.is_quoting then
    return query select 'not_quoting'::text, s.last_published_at, null::timestamptz;
    return;
  end if;
  if not found or s.last_published_at is null then
    return query select 'not_published'::text, null::timestamptz, null::timestamptz;
    return;
  end if;

  select sp.market_close_time into v_close
    from public.seller_profiles sp where sp.account_id = p_seller_id;

  if v_close is not null then
    -- The closing time on the day of the publish, Indian time; if the
    -- publish was at or after it, the next day's.
    v_daily := (((s.last_published_at at time zone 'Asia/Kolkata')::date + v_close)
                at time zone 'Asia/Kolkata');
    if v_daily <= s.last_published_at then
      v_daily := v_daily + interval '1 day';
    end if;
  end if;

  v_closes_at := least(
    v_daily,
    case when s.closed_early_at > s.last_published_at then s.closed_early_at end
  );

  if v_closes_at is not null and v_closes_at <= v_at then
    return query select 'closed'::text, s.last_published_at, v_closes_at;
  else
    return query select 'open'::text, s.last_published_at, null::timestamptz;
  end if;
end;
$$;

comment on function public.market_status(uuid, uuid, timestamptz) is
  'Open, closed, not quoting or not published, for one seller and family. The one place market status is worked out.';

grant execute on function public.market_status(uuid, uuid, timestamptz) to anon, authenticated;

-- Shared check for the two switches below: who may act for which seller.
create function public.status_actor(p_seller_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_seller uuid := coalesce(p_seller_id, auth.uid());
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if v_seller is distinct from auth.uid() and not public.is_admin() then
    raise exception 'You can only change your own quoting and market' using errcode = '42501';
  end if;
  return v_seller;
end;
$$;

revoke execute on function public.status_actor(uuid) from public, anon;

-- "Not quoting today": switch a family off (or back on) with one tap,
-- without publishing. Returns the new state. Switching to the state it is
-- already in changes nothing and records nothing.
create function public.set_quoting(
  p_segment_id  uuid,
  p_quoting     boolean,
  p_seller_id   uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller   uuid := public.status_actor(p_seller_id);
  v_current  boolean;
begin
  if p_quoting is null then
    raise exception 'Say whether the family is quoting (true) or not (false)';
  end if;
  if not exists (
    select 1 from public.seller_segments ss
     where ss.seller_id = v_seller and ss.segment_id = p_segment_id and ss.is_active
  ) then
    raise exception 'The seller does not deal in this product family';
  end if;

  select st.is_quoting into v_current
    from public.seller_family_status st
   where st.seller_id = v_seller and st.segment_id = p_segment_id;
  if coalesce(v_current, true) = p_quoting then
    return p_quoting;
  end if;

  insert into public.seller_family_status (seller_id, segment_id, is_quoting)
  values (v_seller, p_segment_id, p_quoting)
  on conflict (seller_id, segment_id) do update set is_quoting = excluded.is_quoting;

  insert into public.seller_family_status_history (seller_id, segment_id, event, done_by, by_admin)
  values (v_seller, p_segment_id,
          case when p_quoting then 'resumed_quoting' else 'stopped_quoting' end::public.family_status_event,
          auth.uid(), v_seller <> auth.uid());

  return p_quoting;
end;
$$;

-- "Close market now": closes the given families (all the seller deals in,
-- if none are given) straight away. Only families currently open are
-- closed and recorded. Publishing again reopens. Returns how many closed.
create function public.close_market_now(
  p_segment_ids  uuid[] default null,
  p_seller_id    uuid default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seller  uuid := public.status_actor(p_seller_id);
  v_at      timestamptz := clock_timestamp();
  v_seg     uuid;
  v_count   integer := 0;
begin
  for v_seg in
    select ss.segment_id from public.seller_segments ss
     where ss.seller_id = v_seller and ss.is_active
       and (p_segment_ids is null or ss.segment_id = any (p_segment_ids))
  loop
    if (select m.status from public.market_status(v_seller, v_seg, v_at) m) = 'open' then
      update public.seller_family_status set closed_early_at = v_at
       where seller_id = v_seller and segment_id = v_seg;
      insert into public.seller_family_status_history (seller_id, segment_id, event, happened_at, done_by, by_admin)
      values (v_seller, v_seg, 'closed_early', v_at, auth.uid(), v_seller <> auth.uid());
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.set_quoting(uuid, boolean, uuid) from public, anon;
revoke execute on function public.close_market_now(uuid[], uuid) from public, anon;
grant execute on function public.set_quoting(uuid, boolean, uuid) to authenticated;
grant execute on function public.close_market_now(uuid[], uuid) to authenticated;
