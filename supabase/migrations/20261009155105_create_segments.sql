-- ============================================================
-- OBJECTIVE:      Create the segments table: the product families ALEE
--                 trades (TMT Bars, MS Angles, MS Channels).
-- WHY:            Every product belongs to exactly one segment, and sellers
--                 publish and buyers browse by segment.
-- CHANGES:        New table public.segments (name, sort_order, is_active).
--                 New shared helpers public.set_updated_at() and
--                 public.prevent_delete(), reused by products and sizes.
--                 Seeds three segments.
-- DEPENDS ON:     20261005164142_create_regions (for public.is_admin()).
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the table and the two helper functions
--                 (only while no products reference it). Loses only the
--                 three seeded rows.
-- TESTED:         On alee-dev 2026-10-09 (rehearsed in a rolled-back transaction, then applied).
--                 RLS enabled. Anonymous and ordinary users read only
--                 active rows and every insert, update and delete by them
--                 is refused. Admin can insert and update; nobody can delete.
-- DATE:           2026-10-09
-- ============================================================

-- Shared helper: keeps updated_at current on any table that uses it.
create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Shared helper: catalogue rows are deactivated, never deleted. This also
-- stops the service role, which bypasses RLS.
create function public.prevent_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% rows cannot be deleted; set is_active = false instead', tg_table_name;
end;
$$;

create table public.segments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) > 0),
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.segments is
  'Product families (TMT Bars, MS Angles, MS Channels). Deactivated, never deleted.';

create unique index segments_name_key on public.segments (lower(name));
create index segments_sort_idx on public.segments (sort_order, name);

create trigger segments_set_updated_at
  before update on public.segments
  for each row execute function public.set_updated_at();

create trigger segments_prevent_delete
  before delete on public.segments
  for each row execute function public.prevent_delete();

-- Row Level Security --------------------------------------------------------

alter table public.segments enable row level security;

create policy "Anyone can read active segments"
  on public.segments for select
  to anon, authenticated
  using (is_active);

create policy "Admins can read all segments"
  on public.segments for select
  to authenticated
  using ((select public.is_admin()));

create policy "Admins can insert segments"
  on public.segments for insert
  to authenticated
  with check ((select public.is_admin()));

create policy "Admins can update segments"
  on public.segments for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

-- New tables are not exposed to API roles by default in this project.
-- No DELETE grant: segments are never deleted.
grant select on public.segments to anon, authenticated;
grant insert, update on public.segments to authenticated;

-- Seed ----------------------------------------------------------------------

insert into public.segments (name, sort_order)
values
  ('TMT Bars',    10),
  ('MS Angles',   20),
  ('MS Channels', 30);
