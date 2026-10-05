-- =============================================================================
-- Regions: the geographic hierarchy used for locating listings and buyers.
--
-- What this migration does
--   * Creates public.regions, a single self-referencing table holding every
--     place we know about, from states down to individual cities.
--   * Keeps alternate names (old names, spellings) on each region so search
--     still works after a rename, e.g. "Aurangabad" finds
--     "Chhatrapati Sambhajinagar".
--   * Never deletes regions. A region that goes away is deactivated, and may
--     point at the region that replaced it (replaced_by_id), so old
--     references can be followed to the current one.
--   * Turns on Row Level Security: anyone may read approved, active regions;
--     only admins may insert or update.
--   * Seeds Maharashtra and Goa with their districts.
--
-- Why four levels (state > district > taluka > city)
--   This mirrors how Indian administration and addresses actually work, and
--   how people describe where they are:
--     state    - Maharashtra, Goa. Top level; has no parent.
--     district - the main administrative unit inside a state (Pune, North Goa).
--     taluka   - a subdivision of a district (Haveli, Bardez). Many towns and
--                villages are only identifiable by their taluka, and people
--                commonly search by it.
--     city     - the town, city or village itself. Usually sits under a
--                taluka, but may sit directly under a district when the city
--                is the district seat or spans several talukas.
--   Fewer levels would lose the taluka, which is how much of rural and
--   semi-urban India identifies location. More levels (ward, pincode, locality)
--   are not needed for search and can be added later.
--
-- Buyer-added cities
--   is_approved defaults to false, so any city added on behalf of a buyer
--   stays hidden from public reads until an admin approves it.
--
-- Admins
--   A user is an admin when their JWT has app_metadata.role = 'admin'.
--   app_metadata can only be set server-side (service role / dashboard), so
--   users cannot grant it to themselves.
-- =============================================================================

create extension if not exists pg_trgm with schema extensions;

create type public.region_level as enum ('state', 'district', 'taluka', 'city');

create table public.regions (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(btrim(name)) > 0),
  level            public.region_level not null,
  parent_id        uuid references public.regions (id),
  is_active        boolean not null default true,
  is_approved      boolean not null default false,
  alternate_names  text[] not null default '{}',
  replaced_by_id   uuid references public.regions (id),
  -- Lower-cased name + alternate names, maintained by trigger, for search.
  search_text      text not null default '',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint regions_state_has_no_parent
    check ((level = 'state') = (parent_id is null)),
  constraint regions_not_replaced_by_self
    check (replaced_by_id is null or replaced_by_id <> id),
  constraint regions_only_inactive_are_replaced
    check (replaced_by_id is null or not is_active)
);

comment on table public.regions is
  'State > district > taluka > city hierarchy. Rows are deactivated, never deleted.';
comment on column public.regions.alternate_names is
  'Former names and alternate spellings, matched by search (e.g. Aurangabad).';
comment on column public.regions.replaced_by_id is
  'For a deactivated region, the region that replaced it, if any.';
comment on column public.regions.is_approved is
  'False for buyer-added regions until an admin approves them.';

-- No two siblings share a name (case-insensitive). States have a null parent,
-- so nulls must compare equal for that to apply to them too.
create unique index regions_parent_level_name_key
  on public.regions (parent_id, level, lower(name)) nulls not distinct;

-- Children of a region, e.g. all districts in a state.
create index regions_parent_id_idx on public.regions (parent_id, name);

-- Name and alternate-name search (ILIKE / similarity).
create index regions_search_text_trgm_idx
  on public.regions using gin (search_text extensions.gin_trgm_ops);

-- Foreign key lookups when following replacements.
create index regions_replaced_by_id_idx
  on public.regions (replaced_by_id) where replaced_by_id is not null;

-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------

-- Keeps search_text and updated_at current, tidies alternate names, and checks
-- that the parent is the right level.
create function public.regions_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  parent_level public.region_level;
begin
  new.name := btrim(new.name);

  select coalesce(array_agg(distinct btrim(n)), '{}')
    into new.alternate_names
    from unnest(new.alternate_names) as n
   where length(btrim(n)) > 0
     and lower(btrim(n)) <> lower(new.name);

  new.search_text := lower(
    new.name || ' ' || array_to_string(new.alternate_names, ' ')
  );

  if new.parent_id is not null then
    select r.level into parent_level
      from public.regions r
     where r.id = new.parent_id;

    if not (
         (new.level = 'district' and parent_level = 'state')
      or (new.level = 'taluka'   and parent_level = 'district')
      or (new.level = 'city'     and parent_level in ('district', 'taluka'))
    ) then
      raise exception 'A % cannot have a % as its parent', new.level, parent_level;
    end if;
  end if;

  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;

  return new;
end;
$$;

create trigger regions_before_write
  before insert or update on public.regions
  for each row execute function public.regions_before_write();

-- Regions are deactivated, never deleted. This also stops the service role,
-- which bypasses RLS.
create function public.regions_prevent_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Regions cannot be deleted; set is_active = false instead';
end;
$$;

create trigger regions_prevent_delete
  before delete on public.regions
  for each row execute function public.regions_prevent_delete();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------

create function public.is_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

alter table public.regions enable row level security;

create policy "Anyone can read approved active regions"
  on public.regions for select
  to anon, authenticated
  using (is_active and is_approved);

create policy "Admins can read all regions"
  on public.regions for select
  to authenticated
  using ((select public.is_admin()));

create policy "Admins can insert regions"
  on public.regions for insert
  to authenticated
  with check ((select public.is_admin()));

create policy "Admins can update regions"
  on public.regions for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

-- No delete policy: deletes are refused by RLS and by the trigger above.

-- -----------------------------------------------------------------------------
-- Search
-- -----------------------------------------------------------------------------

-- Finds regions whose name or alternate names contain the query. Runs as the
-- caller, so RLS decides which rows are visible. Exact and prefix matches on
-- the current name rank first.
create function public.search_regions(
  query       text,
  only_level  public.region_level default null,
  max_results integer default 20
)
returns setof public.regions
language sql
stable
security invoker
set search_path = ''
as $$
  select r.*
    from public.regions r
   where r.search_text like '%' || lower(btrim(query)) || '%'
     and (only_level is null or r.level = only_level)
   order by
     (lower(r.name) = lower(btrim(query))) desc,
     (lower(r.name) like lower(btrim(query)) || '%') desc,
     extensions.similarity(r.search_text, lower(btrim(query))) desc,
     r.name
   limit least(greatest(max_results, 1), 100);
$$;

-- -----------------------------------------------------------------------------
-- Seed data: Maharashtra (36 districts) and Goa (2 districts)
-- -----------------------------------------------------------------------------

insert into public.regions (name, level, is_approved)
values
  ('Maharashtra', 'state', true),
  ('Goa',         'state', true);

insert into public.regions (name, level, parent_id, is_approved, alternate_names)
select d.name, 'district', s.id, true, d.alternate_names
  from (values
    ('Maharashtra', 'Ahilyanagar',               array['Ahmednagar']),
    ('Maharashtra', 'Akola',                     '{}'::text[]),
    ('Maharashtra', 'Amravati',                  '{}'),
    ('Maharashtra', 'Beed',                      '{}'),
    ('Maharashtra', 'Bhandara',                  '{}'),
    ('Maharashtra', 'Buldhana',                  '{}'),
    ('Maharashtra', 'Chandrapur',                '{}'),
    ('Maharashtra', 'Chhatrapati Sambhajinagar', array['Aurangabad']),
    ('Maharashtra', 'Dharashiv',                 array['Osmanabad']),
    ('Maharashtra', 'Dhule',                     '{}'),
    ('Maharashtra', 'Gadchiroli',                '{}'),
    ('Maharashtra', 'Gondia',                    '{}'),
    ('Maharashtra', 'Hingoli',                   '{}'),
    ('Maharashtra', 'Jalgaon',                   '{}'),
    ('Maharashtra', 'Jalna',                     '{}'),
    ('Maharashtra', 'Kolhapur',                  '{}'),
    ('Maharashtra', 'Latur',                     '{}'),
    ('Maharashtra', 'Mumbai City',               '{}'),
    ('Maharashtra', 'Mumbai Suburban',           '{}'),
    ('Maharashtra', 'Nagpur',                    '{}'),
    ('Maharashtra', 'Nanded',                    '{}'),
    ('Maharashtra', 'Nandurbar',                 '{}'),
    ('Maharashtra', 'Nashik',                    '{}'),
    ('Maharashtra', 'Palghar',                   '{}'),
    ('Maharashtra', 'Parbhani',                  '{}'),
    ('Maharashtra', 'Pune',                      '{}'),
    ('Maharashtra', 'Raigad',                    '{}'),
    ('Maharashtra', 'Ratnagiri',                 '{}'),
    ('Maharashtra', 'Sangli',                    '{}'),
    ('Maharashtra', 'Satara',                    '{}'),
    ('Maharashtra', 'Sindhudurg',                '{}'),
    ('Maharashtra', 'Solapur',                   '{}'),
    ('Maharashtra', 'Thane',                     '{}'),
    ('Maharashtra', 'Wardha',                    '{}'),
    ('Maharashtra', 'Washim',                    '{}'),
    ('Maharashtra', 'Yavatmal',                  '{}'),
    ('Goa',         'North Goa',                 '{}'),
    ('Goa',         'South Goa',                 '{}')
  ) as d (state_name, name, alternate_names)
  join public.regions s
    on s.level = 'state' and s.name = d.state_name;
