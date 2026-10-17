-- ============================================================
-- OBJECTIVE:      Create the publish record: one row per publish (one
--                 action by a seller), one row per product family in it
--                 with the basic rate and the area-settings version used,
--                 and the exact chart versions used, so any past rate can
--                 be rebuilt exactly.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.25 to
--                 2.27). Updating several families at once is one publish,
--                 so buyers get one notification. The time is set by the
--                 database and can never be back-dated. Nothing is ever
--                 changed or removed; a wrong rate is fixed by publishing
--                 again, marked as a correction.
-- CHANGES:        New tables public.publishes, public.publish_items,
--                 public.publish_chart_versions.
-- DEPENDS ON:     20261017065210_create_area_settings.
--                 20261017055742_create_chart_versions.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the three tables. Every publish would be
--                 lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/publishes.sql (88).
--                 RLS on. One publish holds both families; time set by the
--                 database; nothing can be changed, added or deleted, even
--                 with the master key; another seller, a buyer and a visitor
--                 read no basic rate.
-- DATE:           2026-10-17
-- ============================================================

create table public.publishes (
  id                   uuid primary key default gen_random_uuid(),
  -- Strict order of publishes, even within the same second.
  publish_number       bigint generated always as identity unique,
  seller_id            uuid not null references public.seller_profiles (account_id) on delete cascade,
  -- Set by the database at the moment of publishing; never back-dated.
  published_at         timestamptz not null default clock_timestamp(),
  -- The login that pressed publish: the seller, or an admin during setup.
  published_by         uuid not null,
  by_admin             boolean not null,
  -- A correction tells buyers the earlier figure was wrong. The earlier
  -- publish stays in history, unchanged.
  is_correction        boolean not null default false,
  corrects_publish_id  uuid references public.publishes (id),
  constraint publishes_correction_flagged
    check (corrects_publish_id is null or is_correction),
  constraint publishes_not_correcting_itself
    check (corrects_publish_id is null or corrects_publish_id <> id)
);

comment on table public.publishes is
  'One publish = one action by a seller, covering one or more product families. Never changed or removed. Private to the seller and admins.';

-- What one publish contains for one product family.
create table public.publish_items (
  publish_id               uuid not null references public.publishes (id) on delete cascade,
  segment_id               uuid not null references public.segments (id),
  -- The seller's basic rate. Private: buyers only ever see their own final
  -- rate, through the rate engine.
  base_rate                public.rupees not null check (base_rate > 0),
  -- The unit of the basic rate: the seller's unit for the family then.
  unit                     public.unit not null check (unit in ('tonne', 'kg')),
  -- The area-settings version in force.
  area_setting_version_id  uuid not null references public.area_setting_versions (id) on delete cascade,
  primary key (publish_id, segment_id)
);

comment on table public.publish_items is
  'Per product family in a publish: basic rate, its unit, and the area-settings version used. Private.';

-- The exact version of every chart the area settings pointed to.
create table public.publish_chart_versions (
  publish_id        uuid not null,
  segment_id        uuid not null,
  chart_id          uuid not null references public.charts (id) on delete cascade,
  chart_version_id  uuid not null references public.chart_versions (id) on delete cascade,
  primary key (publish_id, segment_id, chart_id),
  foreign key (publish_id, segment_id)
    references public.publish_items (publish_id, segment_id) on delete cascade
);

comment on table public.publish_chart_versions is
  'The exact chart versions a publish used, so any past rate rebuilds exactly. Private.';

create index publishes_seller_idx on public.publishes (seller_id, publish_number desc);
create index publish_items_segment_idx on public.publish_items (segment_id);
create index publish_items_area_version_idx on public.publish_items (area_setting_version_id);
create index publish_chart_versions_version_idx on public.publish_chart_versions (chart_version_id);
create index publishes_corrects_idx on public.publishes (corrects_publish_id) where corrects_publish_id is not null;

-- Guards ------------------------------------------------------------------------
-- Rows can only be written by publish_rates (a later migration), which marks
-- the seller being published for the length of the call.

create function public.publishes_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('alee.publishing', true) is distinct from new.seller_id::text then
    raise exception 'Rates can only be published through publish_rates';
  end if;
  new.published_at := clock_timestamp();
  return new;
end;
$$;

create trigger publishes_before_insert
  before insert on public.publishes
  for each row execute function public.publishes_before_insert();

create function public.publish_items_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_seller uuid;
begin
  select p.seller_id into v_seller from public.publishes p where p.id = new.publish_id;
  if current_setting('alee.publishing', true) is distinct from v_seller::text then
    raise exception 'Nothing can be added to a publish after it is made; publish again instead';
  end if;
  if not exists (
    select 1 from public.area_setting_versions av
     where av.id = new.area_setting_version_id
       and av.seller_id = v_seller and av.segment_id = new.segment_id
  ) then
    raise exception 'The area settings must be the seller''s own, for this product family';
  end if;
  return new;
end;
$$;

create trigger publish_items_before_insert
  before insert on public.publish_items
  for each row execute function public.publish_items_before_insert();

create function public.publish_chart_versions_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_seller uuid;
begin
  select p.seller_id into v_seller from public.publishes p where p.id = new.publish_id;
  if current_setting('alee.publishing', true) is distinct from v_seller::text then
    raise exception 'Nothing can be added to a publish after it is made; publish again instead';
  end if;
  if not exists (
    select 1 from public.chart_versions cv
      join public.charts c on c.id = cv.chart_id
     where cv.id = new.chart_version_id and c.id = new.chart_id
       and c.seller_id = v_seller and c.segment_id = new.segment_id
  ) then
    raise exception 'A publish can only use the seller''s own chart versions, for this product family';
  end if;
  return new;
end;
$$;

create trigger publish_chart_versions_before_insert
  before insert on public.publish_chart_versions
  for each row execute function public.publish_chart_versions_before_insert();

-- Never changed by anyone, not even the database owner.
create trigger publishes_prevent_update
  before update on public.publishes
  for each row execute function public.prevent_update();
create trigger publish_items_prevent_update
  before update on public.publish_items
  for each row execute function public.prevent_update();
create trigger publish_chart_versions_prevent_update
  before update on public.publish_chart_versions
  for each row execute function public.prevent_update();

-- Never removed on its own; see docs/decisions.md open question on account
-- deletion versus the trade record.
create trigger publishes_prevent_direct_delete
  before delete on public.publishes
  for each row execute function public.prevent_direct_delete();
create trigger publish_items_prevent_direct_delete
  before delete on public.publish_items
  for each row execute function public.prevent_direct_delete();
create trigger publish_chart_versions_prevent_direct_delete
  before delete on public.publish_chart_versions
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------
-- The basic rate is private: only the seller and admins. Buyers, other
-- sellers and visitors get nothing from these tables.

alter table public.publishes enable row level security;
alter table public.publish_items enable row level security;
alter table public.publish_chart_versions enable row level security;

create policy "Sellers read their own publishes; admins read all"
  on public.publishes for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Visible when the publish is visible"
  on public.publish_items for select
  to authenticated
  using (exists (select 1 from public.publishes p where p.id = publish_id));

create policy "Visible when the publish is visible"
  on public.publish_chart_versions for select
  to authenticated
  using (exists (select 1 from public.publishes p where p.id = publish_id));

-- Read only. Writing goes through publish_rates. No grant to anon.
grant select on public.publishes, public.publish_items, public.publish_chart_versions to authenticated;
