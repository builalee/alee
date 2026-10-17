-- ============================================================
-- OBJECTIVE:      Store each seller's area settings per product family, as
--                 versions: area difference, size / loading / discount
--                 chart, grade premium, display unit, grades not sold, and
--                 explicit exclusions, at any region level or "everywhere".
-- WHY:            CLAUDE.md sections 8 and 9; owner decisions 2026-10-17
--                 (docs/decisions.md 2.19 to 2.21). Each setting resolves
--                 separately, most specific area first, carrying down when
--                 not set. "Not set" (empty) and zero are stored differently
--                 so they can never be confused. A publish will later record
--                 which version it used.
-- CHANGES:        New tables public.area_setting_versions,
--                 public.area_settings (one row per area in a version) and
--                 public.area_grade_settings (per-grade settings in an area).
-- DEPENDS ON:     20261017055742_create_chart_versions (prevent_update).
--                 20261017050259_create_seller_segments.
--                 20261005164142_create_regions.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the three tables. Every seller's area
--                 settings would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks (npm run check:db) pass, including
--                 tests/database/area_settings.sql (71).
--                 RLS on. Zero stored as 0, not set stored empty. Old
--                 versions cannot be changed, added to or deleted, even by
--                 the database owner. Another seller, a buyer and a visitor
--                 read nothing; admins read all. Charts must be the seller's
--                 own, right type and family, active and filled; areas must
--                 be approved; grades must be in the family.
-- DATE:           2026-10-17
-- ============================================================

-- One saved state of a seller's whole area setup for one product family.
create table public.area_setting_versions (
  id              uuid primary key default gen_random_uuid(),
  seller_id       uuid not null references public.seller_profiles (account_id) on delete cascade,
  segment_id      uuid not null references public.segments (id),
  version_number  integer not null check (version_number > 0),
  -- Unit of every amount in this version (area differences, grade
  -- premiums): the seller's unit for the family when it was saved.
  unit            public.unit not null check (unit in ('tonne', 'kg')),
  created_at      timestamptz not null default now(),
  constraint area_setting_versions_number_key unique (seller_id, segment_id, version_number)
);

comment on table public.area_setting_versions is
  'Saved versions of a seller''s area setup for one product family. Never edited. Private to the seller and admins.';

-- One row per area named in a version. An area with no row is simply not
-- mentioned: its settings carry down from the areas above it.
create table public.area_settings (
  id                 uuid primary key default gen_random_uuid(),
  version_id         uuid not null references public.area_setting_versions (id) on delete cascade,
  -- The area. Empty = "everywhere", the level above every state; the save
  -- function only writes it when the seller explicitly chooses it.
  region_id          uuid references public.regions (id),
  -- Explicit exclusion: this area is not served. An excluded area carries
  -- no other settings.
  is_excluded        boolean not null default false,
  -- Every setting below: empty = not set here (carries down from above);
  -- a value, including 0, = set here.
  area_difference    public.rupees,
  size_chart_id      uuid references public.charts (id) on delete cascade,
  loading_chart_id   uuid references public.charts (id) on delete cascade,
  discount_chart_id  uuid references public.charts (id) on delete cascade,
  display_unit       public.unit,
  constraint area_settings_area_key unique nulls not distinct (version_id, region_id),
  constraint area_settings_excluded_has_no_settings check (
    not is_excluded or (area_difference is null and size_chart_id is null and loading_chart_id is null
                        and discount_chart_id is null and display_unit is null)
  )
);

comment on table public.area_settings is
  'Settings for one area in an area-settings version. Empty = not set (carries down); 0 = zero. Empty region = everywhere.';
comment on column public.area_settings.region_id is
  'The area: a state, district, taluka or city. Empty = everywhere (chosen explicitly).';

-- Per-grade settings within one area.
create table public.area_grade_settings (
  id               uuid primary key default gen_random_uuid(),
  area_setting_id  uuid not null references public.area_settings (id) on delete cascade,
  product_id       uuid not null references public.products (id),
  -- Empty = not set here; 0 = no premium, set here.
  grade_premium    public.rupees,
  -- A size chart just for this grade in this area. Empty = not set.
  size_chart_id    uuid references public.charts (id) on delete cascade,
  -- false = not sold in this area; true = sold here (overrides a broader
  -- "not sold"); empty = not set (carries down; sold if never set).
  is_sold          boolean,
  constraint area_grade_settings_grade_key unique (area_setting_id, product_id),
  constraint area_grade_settings_sets_something
    check (grade_premium is not null or size_chart_id is not null or is_sold is not null)
);

comment on table public.area_grade_settings is
  'Per-grade settings within one area: grade premium, grade size chart, not sold. Empty = not set.';

create index area_settings_version_idx on public.area_settings (version_id, region_id);
create index area_grade_settings_setting_idx on public.area_grade_settings (area_setting_id, product_id);
create index area_settings_charts_idx on public.area_settings (size_chart_id, loading_chart_id, discount_chart_id);
create index area_grade_settings_chart_idx on public.area_grade_settings (size_chart_id) where size_chart_id is not null;

-- Guards ------------------------------------------------------------------------
-- Rows can only be written by save_area_settings (next migration), which
-- marks the seller and family being saved for the length of the call. So a
-- version is complete when saved and nothing can be added to it later.

create function public.area_chart_is_usable(
  p_chart_id    uuid,
  p_seller_id   uuid,
  p_segment_id  uuid,
  p_type        public.chart_type
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  c record;
begin
  if p_chart_id is null then
    return;
  end if;
  select ch.seller_id, ch.segment_id, ch.chart_type, ch.is_active into c
    from public.charts ch where ch.id = p_chart_id;
  if not found or c.seller_id is distinct from p_seller_id then
    raise exception 'A seller can only use his own charts';
  end if;
  if c.segment_id <> p_segment_id then
    raise exception 'That chart is for a different product family';
  end if;
  if c.chart_type <> p_type then
    raise exception 'That is a % chart, not a % chart', c.chart_type, p_type;
  end if;
  if not c.is_active then
    raise exception 'That chart is switched off';
  end if;
  if not exists (select 1 from public.chart_versions v where v.chart_id = p_chart_id) then
    raise exception 'That chart has no figures yet';
  end if;
end;
$$;

create function public.area_setting_versions_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('alee.saving_area_settings', true)
       is distinct from new.seller_id::text || '/' || new.segment_id::text then
    raise exception 'Area settings can only be saved through save_area_settings';
  end if;
  new.created_at := now();
  return new;
end;
$$;

create trigger area_setting_versions_before_insert
  before insert on public.area_setting_versions
  for each row execute function public.area_setting_versions_before_insert();

create function public.area_settings_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v record;
begin
  select av.seller_id, av.segment_id into v
    from public.area_setting_versions av where av.id = new.version_id;

  if current_setting('alee.saving_area_settings', true)
       is distinct from v.seller_id::text || '/' || v.segment_id::text then
    raise exception 'Areas can only be added while their version is being saved; save a new version instead';
  end if;

  if new.region_id is not null and not exists (
    select 1 from public.regions r where r.id = new.region_id and r.is_active and r.is_approved
  ) then
    raise exception 'That area is not available';
  end if;

  perform public.area_chart_is_usable(new.size_chart_id,     v.seller_id, v.segment_id, 'size');
  perform public.area_chart_is_usable(new.loading_chart_id,  v.seller_id, v.segment_id, 'loading');
  perform public.area_chart_is_usable(new.discount_chart_id, v.seller_id, v.segment_id, 'discount');
  return new;
end;
$$;

create trigger area_settings_before_insert
  before insert on public.area_settings
  for each row execute function public.area_settings_before_insert();

create function public.area_grade_settings_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  a record;
begin
  select s.is_excluded, av.seller_id, av.segment_id into a
    from public.area_settings s
    join public.area_setting_versions av on av.id = s.version_id
   where s.id = new.area_setting_id;

  if current_setting('alee.saving_area_settings', true)
       is distinct from a.seller_id::text || '/' || a.segment_id::text then
    raise exception 'Grade settings can only be added while their version is being saved; save a new version instead';
  end if;
  if a.is_excluded then
    raise exception 'An excluded area carries no grade settings';
  end if;
  if not exists (
    select 1 from public.products p
     where p.id = new.product_id and p.segment_id = a.segment_id and p.is_active
  ) then
    raise exception 'That grade is not in this product family';
  end if;

  perform public.area_chart_is_usable(new.size_chart_id, a.seller_id, a.segment_id, 'size');
  return new;
end;
$$;

create trigger area_grade_settings_before_insert
  before insert on public.area_grade_settings
  for each row execute function public.area_grade_settings_before_insert();

-- Never changed by anyone; removed only when the seller's account is deleted.
create trigger area_setting_versions_prevent_update
  before update on public.area_setting_versions
  for each row execute function public.prevent_update();
create trigger area_settings_prevent_update
  before update on public.area_settings
  for each row execute function public.prevent_update();
create trigger area_grade_settings_prevent_update
  before update on public.area_grade_settings
  for each row execute function public.prevent_update();

create trigger area_setting_versions_prevent_direct_delete
  before delete on public.area_setting_versions
  for each row execute function public.prevent_direct_delete();
create trigger area_settings_prevent_direct_delete
  before delete on public.area_settings
  for each row execute function public.prevent_direct_delete();
create trigger area_grade_settings_prevent_direct_delete
  before delete on public.area_grade_settings
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------
-- Area settings reveal a seller's margins by area. Only the seller and
-- admins can read them: no buyer, no other seller, no visitor. Buyers will
-- only ever see their own final rate, through the rate engine.

alter table public.area_setting_versions enable row level security;
alter table public.area_settings enable row level security;
alter table public.area_grade_settings enable row level security;

create policy "Sellers read their own area settings; admins read all"
  on public.area_setting_versions for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Visible when the version is visible"
  on public.area_settings for select
  to authenticated
  using (exists (select 1 from public.area_setting_versions v where v.id = version_id));

create policy "Visible when the area is visible"
  on public.area_grade_settings for select
  to authenticated
  using (exists (select 1 from public.area_settings s where s.id = area_setting_id));

-- Read only, and only by logged-in users the policies allow. No grant to
-- anon. Writing goes through save_area_settings only.
grant select on public.area_setting_versions, public.area_settings,
  public.area_grade_settings to authenticated;
