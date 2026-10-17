-- ============================================================
-- OBJECTIVE:      Store chart figures in versions. Each version records its
--                 unit (tonne or kg) and when it was saved. Size and loading
--                 figures are per size; discount is flat or a percentage.
-- WHY:            Saving a change always creates a new version and an
--                 existing version is never edited, so any past rate can be
--                 rebuilt exactly (decision 4.1). Zero is a real figure
--                 meaning "same as base" and is stored, never left empty
--                 (decision 2.9).
-- CHANGES:        New enum public.discount_kind (flat, percent).
--                 New tables public.chart_versions,
--                 public.chart_version_figures, public.chart_version_discounts.
--                 New shared helper public.prevent_update().
-- DEPENDS ON:     20261017055542_create_money_types.
--                 20261017055642_create_charts.
--                 20261009155938_sizes_belong_to_segment.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the three tables, the enum and the
--                 helper. Every chart figure would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; saved checks in tests/database/charts.sql (105) pass.
--                 RLS on. Zero stored as 0. Old versions cannot be changed,
--                 added to or deleted, by a seller or by the database
--                 owner. Only the chart's own family sizes accepted.
--                 Loading needs exactly one all-sizes figure. Discount is
--                 flat (not negative) or 0-100%.
-- DATE:           2026-10-17
-- ============================================================

create type public.discount_kind as enum ('flat', 'percent');

create table public.chart_versions (
  id              uuid primary key default gen_random_uuid(),
  chart_id        uuid not null references public.charts (id) on delete cascade,
  version_number  integer not null check (version_number > 0),
  -- The unit every figure in this version is in.
  unit            public.unit not null check (unit in ('tonne', 'kg')),
  -- Always the moment the version was saved.
  created_at      timestamptz not null default now(),
  constraint chart_versions_number_key unique (chart_id, version_number)
);

comment on table public.chart_versions is
  'Saved versions of a chart. Never edited: saving a change creates a new version.';
comment on column public.chart_versions.unit is
  'Unit of every figure in this version: tonne or kg.';

-- Size charts: one row per size. Loading charts: one row with no size (the
-- figure for all sizes) plus optional rows for particular sizes.
create table public.chart_version_figures (
  id          uuid primary key default gen_random_uuid(),
  version_id  uuid not null references public.chart_versions (id) on delete cascade,
  -- Empty only for a loading chart's "all sizes" figure.
  size_id     uuid references public.sizes (id),
  -- Required. Zero means "same as base" and is stored as 0.
  amount      public.rupees not null,
  constraint chart_version_figures_size_key unique nulls not distinct (version_id, size_id)
);

comment on table public.chart_version_figures is
  'Figures of a size or loading chart version. Zero is a real value. Never edited.';
comment on column public.chart_version_figures.size_id is
  'The size this figure applies to. Empty = all sizes (loading charts only).';

create index chart_version_figures_size_idx on public.chart_version_figures (size_id);

create table public.chart_version_discounts (
  version_id   uuid primary key references public.chart_versions (id) on delete cascade,
  kind         public.discount_kind not null,
  -- A discount is never negative.
  flat_amount  public.rupees check (flat_amount >= 0),
  percent      public.percentage,
  constraint chart_version_discounts_one_kind check (
    (kind = 'flat'    and flat_amount is not null and percent is null) or
    (kind = 'percent' and percent is not null and flat_amount is null)
  )
);

comment on table public.chart_version_discounts is
  'The discount of a discount chart version: flat per unit, or a percentage. Never edited.';

-- Guards ----------------------------------------------------------------------
-- Versions and their figures can only be written by the save and copy
-- functions (next migration), which mark the chart being saved for the
-- length of the call. Anything else, even with the secret key, is refused,
-- so nothing can be added to a version after it was saved.

create function public.chart_versions_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('alee.saving_chart', true) is distinct from new.chart_id::text then
    raise exception 'Chart versions can only be saved through save_chart_version or copy_template';
  end if;
  new.created_at := now();
  return new;
end;
$$;

create trigger chart_versions_before_insert
  before insert on public.chart_versions
  for each row execute function public.chart_versions_before_insert();

create function public.chart_version_figures_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  ch record;
  sz record;
begin
  select c.id, c.chart_type, c.segment_id into ch
    from public.chart_versions v
    join public.charts c on c.id = v.chart_id
   where v.id = new.version_id;

  if current_setting('alee.saving_chart', true) is distinct from ch.id::text then
    raise exception 'Figures can only be added while their version is being saved; save a new version instead';
  end if;

  if ch.chart_type = 'discount' then
    raise exception 'A discount chart has no per-size figures';
  end if;

  if new.size_id is null then
    if ch.chart_type <> 'loading' then
      raise exception 'Every figure in a size chart must name a size';
    end if;
  else
    select s.segment_id, s.is_active, s.display_name into sz
      from public.sizes s where s.id = new.size_id;
    if not found or sz.segment_id <> ch.segment_id then
      raise exception 'Only sizes from the chart''s own product family are allowed';
    end if;
    if not sz.is_active then
      raise exception 'Size % is switched off and cannot be priced', sz.display_name;
    end if;
  end if;

  return new;
end;
$$;

create trigger chart_version_figures_before_insert
  before insert on public.chart_version_figures
  for each row execute function public.chart_version_figures_before_insert();

create function public.chart_version_discounts_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  ch record;
begin
  select c.id, c.chart_type into ch
    from public.chart_versions v
    join public.charts c on c.id = v.chart_id
   where v.id = new.version_id;

  if current_setting('alee.saving_chart', true) is distinct from ch.id::text then
    raise exception 'A discount can only be set while its version is being saved; save a new version instead';
  end if;
  if ch.chart_type <> 'discount' then
    raise exception 'Only a discount chart has a discount';
  end if;
  return new;
end;
$$;

create trigger chart_version_discounts_before_insert
  before insert on public.chart_version_discounts
  for each row execute function public.chart_version_discounts_before_insert();

-- Shared helper: rows that can never be changed once saved, by anyone.
create function public.prevent_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% rows can never be changed once saved; save a new version instead', tg_table_name;
end;
$$;

create trigger chart_versions_prevent_update
  before update on public.chart_versions
  for each row execute function public.prevent_update();
create trigger chart_version_figures_prevent_update
  before update on public.chart_version_figures
  for each row execute function public.prevent_update();
create trigger chart_version_discounts_prevent_update
  before update on public.chart_version_discounts
  for each row execute function public.prevent_update();

-- Removed only when the seller's whole account is deleted.
create trigger chart_versions_prevent_direct_delete
  before delete on public.chart_versions
  for each row execute function public.prevent_direct_delete();
create trigger chart_version_figures_prevent_direct_delete
  before delete on public.chart_version_figures
  for each row execute function public.prevent_direct_delete();
create trigger chart_version_discounts_prevent_direct_delete
  before delete on public.chart_version_discounts
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------
-- A version or figure is visible exactly when its chart is visible to the
-- caller (the charts rules apply inside these checks).

alter table public.chart_versions enable row level security;
alter table public.chart_version_figures enable row level security;
alter table public.chart_version_discounts enable row level security;

create policy "Visible when the chart is visible"
  on public.chart_versions for select
  to authenticated
  using (exists (select 1 from public.charts c where c.id = chart_id));

create policy "Visible when the version is visible"
  on public.chart_version_figures for select
  to authenticated
  using (exists (select 1 from public.chart_versions v where v.id = version_id));

create policy "Visible when the version is visible"
  on public.chart_version_discounts for select
  to authenticated
  using (exists (select 1 from public.chart_versions v where v.id = version_id));

-- Read only through the API. Writing goes through the save and copy
-- functions; there is no insert, update or delete grant.
grant select on public.chart_versions, public.chart_version_figures,
  public.chart_version_discounts to authenticated;
