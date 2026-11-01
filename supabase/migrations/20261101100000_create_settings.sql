-- ============================================================
-- OBJECTIVE:      One table for the values admins change without a code
--                 change: free reach per role, the free customer limit and
--                 the free outside-buyer limit. Every change records who
--                 made it and when.
-- WHY:            CLAUDE.md section 11: settings are never hardcoded.
--                 Owner decisions 2026-11-01 (docs/decisions.md 14): free
--                 reach depends on the role (retailer: taluka; wholesaler
--                 and distributor: district; manufacturer: state); the free
--                 client book holds 20 customers (replacing 30).
-- CHANGES:        New table public.settings, new table
--                 public.settings_history, new functions
--                 public.setting_text, public.setting_int,
--                 public.change_setting. Six settings seeded.
-- DEPENDS ON:     20261005164142_create_regions (is_admin).
-- TOUCHES EXISTING DATA: No (new tables, seeded rows only).
-- REVERSIBLE:     Yes, by dropping the functions and tables. The history
--                 of changes would be lost.
-- TESTED:         On alee-dev 2026-11-01: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/settings.sql.
-- DATE:           2026-11-01
-- ============================================================

create table public.settings (
  key          text primary key,
  value        text not null,
  -- What the value must look like: a whole number, or one of a list.
  value_kind   text not null check (value_kind in ('integer', 'reach_level')),
  description  text not null,
  updated_at   timestamptz not null default clock_timestamp(),
  updated_by   uuid
);

create table public.settings_history (
  id          uuid primary key default gen_random_uuid(),
  key         text not null references public.settings (key),
  old_value   text not null,
  new_value   text not null,
  changed_at  timestamptz not null default clock_timestamp(),
  changed_by  uuid
);
create index settings_history_by_key on public.settings_history (key, changed_at desc);

create function public.settings_check_value()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.value_kind = 'integer' and new.value !~ '^[0-9]+$' then
    raise exception '%', format('%s must be a whole number.', new.key);
  end if;
  if new.value_kind = 'reach_level' and new.value not in ('taluka', 'district', 'state') then
    raise exception '%', format('%s must be taluka, district or state.', new.key);
  end if;
  if tg_op = 'UPDATE' and (new.key <> old.key or new.value_kind <> old.value_kind) then
    raise exception 'A setting''s name and kind never change';
  end if;
  return new;
end;
$$;

create trigger settings_check_value
  before insert or update on public.settings
  for each row execute function public.settings_check_value();
create trigger settings_prevent_delete
  before delete on public.settings
  for each row execute function public.prevent_delete();
create trigger settings_history_prevent_update
  before update on public.settings_history
  for each row execute function public.prevent_update();
create trigger settings_history_prevent_delete
  before delete on public.settings_history
  for each row execute function public.prevent_delete();

insert into public.settings (key, value, value_kind, description) values
  ('free_reach_retailer',      'taluka',   'reach_level', 'How far a retailer''s rates reach without a paid plan'),
  ('free_reach_wholesaler',    'district', 'reach_level', 'How far a wholesaler''s rates reach without a paid plan'),
  ('free_reach_distributor',   'district', 'reach_level', 'How far a distributor''s rates reach without a paid plan'),
  ('free_reach_manufacturer',  'state',    'reach_level', 'How far a manufacturer''s rates reach without a paid plan'),
  ('free_customer_limit',      '20',       'integer',     'Customers in the client book without a paid client-book plan'),
  ('free_outside_buyer_limit', '10',       'integer',     'Outside buyers a seller can approve without a paid reach plan');

create function public.setting_text(p_key text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v text;
begin
  select s.value into v from public.settings s where s.key = p_key;
  if v is null then
    raise exception 'Setting % is missing', p_key;
  end if;
  return v;
end;
$$;

create function public.setting_int(p_key text)
returns integer
language sql
stable
set search_path = ''
as $$
  select public.setting_text(p_key)::integer;
$$;

-- Admins change a setting; the old value is kept in history.
create function public.change_setting(p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old text;
begin
  if not public.is_admin() then
    raise exception 'Only ALEE can change settings.';
  end if;
  select s.value into v_old from public.settings s where s.key = p_key for update;
  if v_old is null then
    raise exception 'That setting does not exist.';
  end if;
  if v_old = p_value then
    return;
  end if;
  update public.settings set value = p_value, updated_at = clock_timestamp(), updated_by = auth.uid()
   where key = p_key;
  insert into public.settings_history (key, old_value, new_value, changed_by)
  values (p_key, v_old, p_value, auth.uid());
end;
$$;

-- Access ---------------------------------------------------------------------

alter table public.settings enable row level security;
alter table public.settings_history enable row level security;

create policy "Logged-in users see settings"
  on public.settings for select to authenticated using (true);
create policy "Admins see the history of settings"
  on public.settings_history for select to authenticated using ((select public.is_admin()));

grant select on public.settings, public.settings_history to authenticated;

revoke execute on function public.setting_text(text) from public, anon;
revoke execute on function public.setting_int(text) from public, anon;
revoke execute on function public.change_setting(text, text) from public, anon;
grant execute on function public.setting_text(text) to authenticated;
grant execute on function public.setting_int(text) to authenticated;
grant execute on function public.change_setting(text, text) to authenticated;
