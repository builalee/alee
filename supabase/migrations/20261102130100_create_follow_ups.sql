-- ============================================================
-- OBJECTIVE:      Follow-ups and the activity log for the client book: each
--                 follow-up has a customer, a due date, a note, and pending
--                 or done; each call, WhatsApp or visit is recorded and never
--                 changed. Logging a call or visit closes that customer's
--                 follow-ups that are due today or overdue.
-- WHY:            Decision 11.1 and the demo's Stage 4: a "Today" list of
--                 due and overdue follow-ups; one tap to call or WhatsApp,
--                 which logs it; logging a call or visit closes the due and
--                 overdue ones, while future ones stay unless he closes them
--                 too. "Today" is the date in India. Private to the seller.
-- CHANGES:        New types public.follow_up_status, public.client_activity_kind.
--                 New tables public.client_activities, public.follow_ups.
--                 New functions public.india_today, public.add_follow_up,
--                 public.close_follow_up, public.log_client_activity,
--                 public.follow_ups_due.
-- DEPENDS ON:     20261102130000_create_clients.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the functions, tables and types. Every
--                 follow-up and activity would be lost.
-- TESTED:         On alee-dev 2026-11-02: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass, including
--                 tests/database/client_book.sql.
-- DATE:           2026-11-02
-- ============================================================

create type public.follow_up_status as enum ('pending', 'done');
create type public.client_activity_kind as enum ('call', 'whatsapp', 'visit');

-- Today's date in India, the one place "today" is worked out for follow-ups.
create function public.india_today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

-- Built to extend (decision 11.1): a later site or counter column joins
-- client_id, with exactly one of them set.
create table public.client_activities (
  id            uuid primary key default gen_random_uuid(),
  seller_id     uuid not null references public.accounts (id) on delete cascade,
  client_id     uuid not null,
  kind          public.client_activity_kind not null,
  note          text check (length(note) <= 1000),
  created_at    timestamptz not null default clock_timestamp(),
  foreign key (client_id, seller_id) references public.clients (id, seller_id) on delete cascade
);

comment on table public.client_activities is
  'Each call, WhatsApp or visit a seller made to a customer. Never changed or deleted; removed only with his account.';

create index client_activities_by_client on public.client_activities (client_id, created_at desc);

create trigger client_activities_prevent_update
  before update on public.client_activities
  for each row execute function public.prevent_update();
create trigger client_activities_prevent_direct_delete
  before delete on public.client_activities
  for each row execute function public.prevent_direct_delete();

create table public.follow_ups (
  id             uuid primary key default gen_random_uuid(),
  seller_id      uuid not null references public.accounts (id) on delete cascade,
  client_id      uuid not null,
  due_on         date not null,
  note           text check (length(note) <= 1000),
  status         public.follow_up_status not null default 'pending',
  done_at        timestamptz,
  -- The call or visit that closed it; empty when closed with "Done".
  closed_by      uuid references public.client_activities (id),
  created_at     timestamptz not null default clock_timestamp(),
  foreign key (client_id, seller_id) references public.clients (id, seller_id) on delete cascade,
  check ((status = 'done') = (done_at is not null)),
  check (closed_by is null or status = 'done')
);

comment on table public.follow_ups is
  'A seller''s follow-ups with his customers. Only ever closed, never changed otherwise or deleted.';

create index follow_ups_pending on public.follow_ups (seller_id, due_on) where status = 'pending';
create index follow_ups_by_client on public.follow_ups (client_id, due_on);

-- A follow-up only ever moves from pending to done; nothing else changes.
create function public.follow_ups_only_close()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'pending' or new.status <> 'done'
     or (new.id, new.seller_id, new.client_id, new.due_on, new.note, new.created_at)
        is distinct from (old.id, old.seller_id, old.client_id, old.due_on, old.note, old.created_at) then
    raise exception 'A follow-up can only be closed, not changed.';
  end if;
  return new;
end;
$$;

create trigger follow_ups_only_close
  before update on public.follow_ups
  for each row execute function public.follow_ups_only_close();
create trigger follow_ups_prevent_direct_delete
  before delete on public.follow_ups
  for each row execute function public.prevent_direct_delete();

-- The caller's own customer, or a plain refusal.
create function public.own_client(p_client_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Log in first.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client_id and c.seller_id = auth.uid()) then
    raise exception 'Customer not found.';
  end if;
end;
$$;

-- A new follow-up, for today or later.
create function public.add_follow_up(p_client_id uuid, p_due_on date, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform public.own_client(p_client_id);
  if p_due_on is null then
    raise exception 'Choose a date for the follow-up.';
  end if;
  if p_due_on < public.india_today() then
    raise exception 'Choose today or a later date.';
  end if;
  if length(p_note) > 1000 then
    raise exception 'Keep the note under 1,000 letters.';
  end if;
  insert into public.follow_ups (seller_id, client_id, due_on, note)
  values (auth.uid(), p_client_id, p_due_on, nullif(btrim(p_note), ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- "Done": closes one of his pending follow-ups, due or future.
create function public.close_follow_up(p_follow_up_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.follow_up_status;
begin
  if auth.uid() is null then
    raise exception 'Log in first.' using errcode = '42501';
  end if;
  select f.status into v_status from public.follow_ups f
   where f.id = p_follow_up_id and f.seller_id = auth.uid() for update;
  if v_status is null then
    raise exception 'Follow-up not found.';
  end if;
  if v_status = 'done' then
    raise exception 'This follow-up is already closed.';
  end if;
  update public.follow_ups set status = 'done', done_at = clock_timestamp() where id = p_follow_up_id;
end;
$$;

-- Records a call, WhatsApp or visit. A call or visit closes that customer's
-- follow-ups due today or overdue; future ones stay (decision 11.1).
create function public.log_client_activity(p_client_id uuid, p_kind public.client_activity_kind, p_note text default null)
returns table (activity_id uuid, closed integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      uuid;
  v_closed  integer := 0;
begin
  perform public.own_client(p_client_id);
  if p_kind is null then
    raise exception 'Choose call, WhatsApp or visit.';
  end if;
  if length(p_note) > 1000 then
    raise exception 'Keep the note under 1,000 letters.';
  end if;

  insert into public.client_activities (seller_id, client_id, kind, note)
  values (auth.uid(), p_client_id, p_kind, nullif(btrim(p_note), ''))
  returning id into v_id;

  if p_kind in ('call', 'visit') then
    update public.follow_ups
       set status = 'done', done_at = clock_timestamp(), closed_by = v_id
     where client_id = p_client_id and seller_id = auth.uid()
       and status = 'pending' and due_on <= public.india_today();
    get diagnostics v_closed = row_count;
  end if;

  return query select v_id, v_closed;
end;
$$;

-- The "Today" list: his pending follow-ups due today or overdue, oldest first.
create function public.follow_ups_due()
returns table (id uuid, client_id uuid, client_name text, phone text, due_on date, note text, overdue boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  select f.id, f.client_id, c.name, c.phone, f.due_on, f.note, f.due_on < public.india_today()
    from public.follow_ups f
    join public.clients c on c.id = f.client_id
   where f.seller_id = (select auth.uid()) and f.status = 'pending' and f.due_on <= public.india_today()
   order by f.due_on, c.name;
$$;

-- Access ---------------------------------------------------------------------
-- Only the seller reads his own follow-ups and activities; all writes go
-- through the functions above. Admins don't read them.

alter table public.client_activities enable row level security;
alter table public.follow_ups enable row level security;

create policy "Sellers read their own activity log"
  on public.client_activities for select to authenticated
  using (seller_id = (select auth.uid()));

create policy "Sellers read their own follow-ups"
  on public.follow_ups for select to authenticated
  using (seller_id = (select auth.uid()));

grant select on public.client_activities to authenticated;
grant select on public.follow_ups to authenticated;

revoke execute on function public.own_client(uuid) from public, anon, authenticated;
revoke execute on function public.add_follow_up(uuid, date, text) from public, anon;
revoke execute on function public.close_follow_up(uuid) from public, anon;
revoke execute on function public.log_client_activity(uuid, public.client_activity_kind, text) from public, anon;
revoke execute on function public.follow_ups_due() from public, anon;
grant execute on function public.add_follow_up(uuid, date, text) to authenticated;
grant execute on function public.close_follow_up(uuid) to authenticated;
grant execute on function public.log_client_activity(uuid, public.client_activity_kind, text) to authenticated;
grant execute on function public.follow_ups_due() to authenticated;
