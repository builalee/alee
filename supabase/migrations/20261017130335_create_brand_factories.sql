-- ============================================================
-- OBJECTIVE:      Let a brand's owner link factory accounts to the brand
--                 (each factory accepts, can decline, and can leave later),
--                 and decide which factory covers which area, per brand and
--                 product family, saved as versions. A lookup finds the
--                 factory serving a buyer's area (closer area wins).
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.39). A
--                 brand can have several factories, each its own seller
--                 account with its own rates, setup and closing time. A
--                 buyer sees the rate from the factory serving his area; the
--                 brand appears as one brand. A factory must accept being
--                 linked, so no one's rates can be shown under a brand
--                 without his agreement.
-- CHANGES:        New enums public.factory_link_status,
--                 public.factory_link_event.
--                 New tables public.brand_factories (links),
--                 public.brand_factory_events (history),
--                 public.factory_coverage_versions and
--                 public.factory_coverage_areas.
--                 New functions public.offer_factory_link(...),
--                 public.respond_to_factory_link(...),
--                 public.end_factory_link(...),
--                 public.save_factory_coverage(...),
--                 public.resolve_brand_factory(...).
-- DEPENDS ON:     20261017123656_create_brand_ownership.
--                 20261017124056_create_seller_brands.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the functions, tables and enums. Every
--                 factory link, its history and all coverage would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/factories.sql (47).
--                 Only the owner or an admin links factories; a link counts
--                 only once accepted; decline, leave, end and withdraw;
--                 coverage per brand and family with the closer area winning
--                 and "everywhere" only when chosen; Dev for angles and Farid
--                 for TMT in the same area; only linked factories selling
--                 that brand line; a factory that left is reported, not
--                 replaced; others see nothing; history and coverage never
--                 changed, even with the master key.
-- DATE:           2026-10-17
-- ============================================================

create type public.factory_link_status as enum (
  'offered',    -- the owner offered; the factory has not answered
  'active',     -- the factory accepted
  'declined',   -- the factory said no
  'withdrawn',  -- the owner took the offer back before it was answered
  'left',       -- the factory left the brand
  'ended'       -- the owner ended the link
);

create type public.factory_link_event as enum ('offered', 'accepted', 'declined', 'withdrawn', 'left', 'ended');

create table public.brand_factories (
  id           uuid primary key default gen_random_uuid(),
  brand_id     uuid not null references public.brands (id),
  factory_id   uuid not null references public.seller_profiles (account_id) on delete cascade,
  status       public.factory_link_status not null default 'offered',
  offered_at   timestamptz not null default clock_timestamp(),
  accepted_at  timestamptz,
  closed_at    timestamptz
);

comment on table public.brand_factories is
  'Factory accounts linked to a brand by its owner. Takes effect only when the factory accepts. Never deleted.';

-- One open link (offered or active) per brand and factory.
create unique index brand_factories_one_open_key
  on public.brand_factories (brand_id, factory_id) where status in ('offered', 'active');
create index brand_factories_factory_idx on public.brand_factories (factory_id, status);

create table public.brand_factory_events (
  id           uuid primary key default gen_random_uuid(),
  link_id      uuid not null references public.brand_factories (id) on delete cascade,
  event        public.factory_link_event not null,
  happened_at  timestamptz not null default clock_timestamp(),
  done_by      uuid not null,
  by_admin     boolean not null
);

comment on table public.brand_factory_events is
  'Every offer, acceptance, decline, withdrawal, leaving and ending of a factory link, with time and who. Never changed.';

create index brand_factory_events_idx on public.brand_factory_events (link_id, happened_at);

-- Which factory covers which area, per brand and family, saved as versions.
create table public.factory_coverage_versions (
  id              uuid primary key default gen_random_uuid(),
  brand_id        uuid not null references public.brands (id),
  segment_id      uuid not null references public.segments (id),
  version_number  integer not null check (version_number > 0),
  created_at      timestamptz not null default now(),
  created_by      uuid not null,
  by_admin        boolean not null,
  constraint factory_coverage_versions_number_key unique (brand_id, segment_id, version_number)
);

create table public.factory_coverage_areas (
  id          uuid primary key default gen_random_uuid(),
  version_id  uuid not null references public.factory_coverage_versions (id) on delete cascade,
  -- The area; empty = everywhere (chosen explicitly).
  region_id   uuid references public.regions (id),
  factory_id  uuid not null references public.seller_profiles (account_id) on delete cascade,
  constraint factory_coverage_areas_one_factory_key unique nulls not distinct (version_id, region_id)
);

comment on table public.factory_coverage_versions is
  'Saved versions of which factory covers which area, for one brand and family. Never edited.';
comment on table public.factory_coverage_areas is
  'One factory per area in a coverage version. Empty region = everywhere. The closer area wins.';

create index factory_coverage_areas_version_idx on public.factory_coverage_areas (version_id, region_id);
create index factory_coverage_areas_factory_idx on public.factory_coverage_areas (factory_id);

-- Rules ---------------------------------------------------------------------

create function public.brand_factories_before_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.brand_id <> old.brand_id or new.factory_id <> old.factory_id or new.offered_at <> old.offered_at then
    raise exception 'A factory link''s brand, factory and offer time never change';
  end if;
  if new.status <> old.status and not (
       (old.status = 'offered' and new.status in ('active', 'declined', 'withdrawn'))
    or (old.status = 'active' and new.status in ('left', 'ended'))
  ) then
    raise exception 'A factory link cannot go from % to %', old.status, new.status;
  end if;
  if old.accepted_at is not null and new.accepted_at is distinct from old.accepted_at
     or old.closed_at is not null and new.closed_at is distinct from old.closed_at then
    raise exception 'Recorded times never change';
  end if;
  return new;
end;
$$;

create trigger brand_factories_before_update
  before update on public.brand_factories
  for each row execute function public.brand_factories_before_update();
create trigger brand_factories_prevent_direct_delete
  before delete on public.brand_factories
  for each row execute function public.prevent_direct_delete();
create trigger brand_factory_events_prevent_update
  before update on public.brand_factory_events
  for each row execute function public.prevent_update();
create trigger brand_factory_events_prevent_direct_delete
  before delete on public.brand_factory_events
  for each row execute function public.prevent_direct_delete();

-- Coverage is written only by save_factory_coverage (which marks the brand
-- and family being saved), and never changed afterwards.
create function public.factory_coverage_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'factory_coverage_versions' then
    if current_setting('alee.saving_coverage', true) is distinct from new.brand_id::text || '/' || new.segment_id::text then
      raise exception 'Factory coverage can only be saved through save_factory_coverage';
    end if;
    new.created_at := now();
  else
    if current_setting('alee.saving_coverage', true) is distinct from (
         select cv.brand_id::text || '/' || cv.segment_id::text
           from public.factory_coverage_versions cv where cv.id = new.version_id) then
      raise exception 'Areas can only be added while their coverage version is being saved; save a new version instead';
    end if;
  end if;
  return new;
end;
$$;

create trigger factory_coverage_versions_guard
  before insert on public.factory_coverage_versions
  for each row execute function public.factory_coverage_guard();
create trigger factory_coverage_areas_guard
  before insert on public.factory_coverage_areas
  for each row execute function public.factory_coverage_guard();
create trigger factory_coverage_versions_prevent_update
  before update on public.factory_coverage_versions
  for each row execute function public.prevent_update();
create trigger factory_coverage_areas_prevent_update
  before update on public.factory_coverage_areas
  for each row execute function public.prevent_update();
create trigger factory_coverage_versions_prevent_direct_delete
  before delete on public.factory_coverage_versions
  for each row execute function public.prevent_direct_delete();
create trigger factory_coverage_areas_prevent_direct_delete
  before delete on public.factory_coverage_areas
  for each row execute function public.prevent_direct_delete();

-- Who may act for a brand: its owner, or an admin.
create function public.brand_owner_or_admin(p_brand_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_admin()
      or exists (select 1 from public.brands b where b.id = p_brand_id and b.owner_id = auth.uid());
$$;

revoke execute on function public.brand_owner_or_admin(uuid) from public, anon;
grant execute on function public.brand_owner_or_admin(uuid) to authenticated;

create function public.factory_record(p_link_id uuid, p_event public.factory_link_event, p_on_behalf_of uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.brand_factory_events (link_id, event, done_by, by_admin)
  values (p_link_id, p_event, auth.uid(), auth.uid() is distinct from p_on_behalf_of);
$$;

revoke execute on function public.factory_record(uuid, public.factory_link_event, uuid) from public, anon, authenticated;

-- Linking factories -------------------------------------------------------------

-- The owner offers to link a seller account to his brand as a factory.
create function public.offer_factory_link(p_brand_id uuid, p_factory_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  b     public.brands%rowtype;
  v_id  uuid;
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  select * into b from public.brands where id = p_brand_id;
  if not found or b.owner_id is null then
    raise exception 'That brand has no owner on ALEE yet.';
  end if;
  if b.owner_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the owner of % can link factories.', b.name using errcode = '42501';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = p_factory_id) then
    raise exception 'That factory is not a seller on ALEE.';
  end if;
  if exists (select 1 from public.brand_factories f
              where f.brand_id = p_brand_id and f.factory_id = p_factory_id and f.status in ('offered', 'active')) then
    raise exception 'That factory is already linked to %, or has an offer waiting.', b.name;
  end if;

  insert into public.brand_factories (brand_id, factory_id) values (p_brand_id, p_factory_id)
  returning id into v_id;
  perform public.factory_record(v_id, 'offered', b.owner_id);
  return v_id;
end;
$$;

-- The factory accepts (true) or declines (false).
create function public.respond_to_factory_link(p_link_id uuid, p_accept boolean)
returns public.factory_link_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.brand_factories%rowtype;
begin
  select * into f from public.brand_factories where id = p_link_id for update;
  if not found then
    raise exception 'Factory link not found';
  end if;
  if f.factory_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the factory itself can accept or decline' using errcode = '42501';
  end if;
  if f.status <> 'offered' then
    raise exception 'This is no longer an open offer.';
  end if;
  if p_accept is null then
    raise exception 'Say whether you accept (true) or decline (false).';
  end if;

  if p_accept then
    update public.brand_factories set status = 'active', accepted_at = clock_timestamp() where id = p_link_id;
    perform public.factory_record(p_link_id, 'accepted', f.factory_id);
    return 'active';
  else
    update public.brand_factories set status = 'declined', closed_at = clock_timestamp() where id = p_link_id;
    perform public.factory_record(p_link_id, 'declined', f.factory_id);
    return 'declined';
  end if;
end;
$$;

-- The factory leaves, or the owner ends the link (or withdraws an offer).
create function public.end_factory_link(p_link_id uuid)
returns public.factory_link_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  f        public.brand_factories%rowtype;
  v_owner  uuid;
begin
  select * into f from public.brand_factories where id = p_link_id for update;
  if not found then
    raise exception 'Factory link not found';
  end if;
  select b.owner_id into v_owner from public.brands b where b.id = f.brand_id;
  if auth.uid() is distinct from f.factory_id and auth.uid() is distinct from v_owner and not public.is_admin() then
    raise exception 'Only the brand''s owner or the factory can end this link' using errcode = '42501';
  end if;

  if f.status = 'active' then
    if auth.uid() = f.factory_id then
      update public.brand_factories set status = 'left', closed_at = clock_timestamp() where id = p_link_id;
      perform public.factory_record(p_link_id, 'left', f.factory_id);
      return 'left';
    end if;
    update public.brand_factories set status = 'ended', closed_at = clock_timestamp() where id = p_link_id;
    perform public.factory_record(p_link_id, 'ended', v_owner);
    return 'ended';
  elsif f.status = 'offered' then
    if auth.uid() = f.factory_id then
      raise exception 'To turn down an offer, decline it.';
    end if;
    update public.brand_factories set status = 'withdrawn', closed_at = clock_timestamp() where id = p_link_id;
    perform public.factory_record(p_link_id, 'withdrawn', v_owner);
    return 'withdrawn';
  else
    raise exception 'This link has already finished (%).', f.status;
  end if;
end;
$$;

-- Coverage ---------------------------------------------------------------------

-- The owner saves which factory covers which area for one brand and family,
-- as a new version. p_areas: [{"region_id": "...", "factory_id": "..."},
-- {"everywhere": true, "factory_id": "..."}]. Every factory must be linked
-- (active) and must sell that brand in that family.
create function public.save_factory_coverage(p_brand_id uuid, p_segment_id uuid, p_areas jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  b         public.brands%rowtype;
  v_number  integer;
  v_version uuid;
  a         jsonb;
  k         text;
  v_factory uuid;
  v_name    text;
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  select * into b from public.brands where id = p_brand_id;
  if not found or b.owner_id is null then
    raise exception 'That brand has no owner on ALEE yet.';
  end if;
  if b.owner_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Only the owner of % can decide which factory covers which area.', b.name using errcode = '42501';
  end if;
  if not public.brand_covers_family(p_brand_id, p_segment_id) then
    raise exception '% is not listed for that product family.', b.name;
  end if;
  if p_areas is null or jsonb_typeof(p_areas) <> 'array' then
    raise exception 'Give a list of areas, each with its factory';
  end if;

  for a in select * from jsonb_array_elements(p_areas) loop
    for k in select jsonb_object_keys(a) loop
      if k not in ('region_id', 'everywhere', 'factory_id') then
        raise exception 'Unknown coverage field "%"', k;
      end if;
    end loop;
    if coalesce((a ->> 'everywhere')::boolean, false) = (coalesce(jsonb_typeof(a -> 'region_id'), 'null') <> 'null') then
      raise exception 'Each area must name a region, or be "everywhere": true';
    end if;
    if (a ->> 'region_id') is not null and not exists (
      select 1 from public.regions r where r.id = (a ->> 'region_id')::uuid and r.is_active and r.is_approved) then
      raise exception 'That area is not available.';
    end if;
    v_factory := (a ->> 'factory_id')::uuid;
    select sp.store_name into v_name from public.seller_profiles sp where sp.account_id = v_factory;
    if not exists (select 1 from public.brand_factories f
                    where f.brand_id = p_brand_id and f.factory_id = v_factory and f.status = 'active') then
      raise exception '% is not a linked factory of %.', coalesce(v_name, 'That seller'), b.name;
    end if;
    if not exists (select 1 from public.seller_brands sb
                    where sb.seller_id = v_factory and sb.brand_id = p_brand_id and sb.segment_id = p_segment_id and sb.is_active) then
      raise exception '% does not sell % yet.', v_name, public.brand_line_label(p_brand_id, p_segment_id);
    end if;
  end loop;

  perform set_config('alee.saving_coverage', p_brand_id::text || '/' || p_segment_id::text, true);

  select coalesce(max(cv.version_number), 0) + 1 into v_number
    from public.factory_coverage_versions cv where cv.brand_id = p_brand_id and cv.segment_id = p_segment_id;

  insert into public.factory_coverage_versions (brand_id, segment_id, version_number, created_by, by_admin)
  values (p_brand_id, p_segment_id, v_number, auth.uid(), auth.uid() is distinct from b.owner_id)
  returning id into v_version;

  insert into public.factory_coverage_areas (version_id, region_id, factory_id)
  select v_version, (e ->> 'region_id')::uuid, (e ->> 'factory_id')::uuid
    from jsonb_array_elements(p_areas) e;

  perform set_config('alee.saving_coverage', '', true);
  return v_version;
end;
$$;

-- The factory serving a buyer's area for a brand and family: the closest
-- area in the latest coverage version (or the given one), up to
-- "everywhere". No row = no factory covers the area. If the factory at that
-- area is no longer linked, factory_is_linked is false: the area is not
-- served until the owner reassigns it (never a quiet fall-back).
create function public.resolve_brand_factory(
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_version_id  uuid default null
)
returns table (
  factory_id         uuid,
  factory_name       text,
  covering_area      text,
  factory_is_linked  boolean,
  coverage_version   uuid
)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive v as (
    select cv.id from public.factory_coverage_versions cv
     where cv.brand_id = p_brand_id and cv.segment_id = p_segment_id
       and (p_version_id is null or cv.id = p_version_id)
     order by cv.version_number desc limit 1
  ),
  chain as (
    select r.id, r.parent_id, r.name, 1 as depth from public.regions r where r.id = p_region_id
    union all
    select p.id, p.parent_id, p.name, c.depth + 1 from chain c join public.regions p on p.id = c.parent_id
  ),
  levels as (
    select c.id as region_id, c.name as area_name, c.depth from chain c
    union all select null::uuid, 'everywhere', 99
  )
  select a.factory_id, sp.store_name, l.area_name,
         exists (select 1 from public.brand_factories f
                  where f.brand_id = p_brand_id and f.factory_id = a.factory_id and f.status = 'active'),
         (select v.id from v)
    from levels l
    join public.factory_coverage_areas a
      on a.version_id = (select v.id from v) and a.region_id is not distinct from l.region_id
    join public.seller_profiles sp on sp.account_id = a.factory_id
   order by l.depth
   limit 1;
$$;

comment on function public.resolve_brand_factory(uuid, uuid, uuid, uuid) is
  'The factory serving a buyer''s area for a brand and family (closer area wins). The rate engine uses it for a brand owner''s own rate.';

revoke execute on function public.offer_factory_link(uuid, uuid) from public, anon;
revoke execute on function public.respond_to_factory_link(uuid, boolean) from public, anon;
revoke execute on function public.end_factory_link(uuid) from public, anon;
revoke execute on function public.save_factory_coverage(uuid, uuid, jsonb) from public, anon;
revoke execute on function public.resolve_brand_factory(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.offer_factory_link(uuid, uuid) to authenticated;
grant execute on function public.respond_to_factory_link(uuid, boolean) to authenticated;
grant execute on function public.end_factory_link(uuid) to authenticated;
grant execute on function public.save_factory_coverage(uuid, uuid, jsonb) to authenticated;
grant execute on function public.resolve_brand_factory(uuid, uuid, uuid, uuid) to authenticated;

-- Row Level Security --------------------------------------------------------
-- Factory links and coverage are seen by the brand's owner, the factory
-- concerned (or, for coverage, any linked factory of the brand) and admins.
-- Buyers see the brand as one brand.

alter table public.brand_factories enable row level security;
alter table public.brand_factory_events enable row level security;
alter table public.factory_coverage_versions enable row level security;
alter table public.factory_coverage_areas enable row level security;

create policy "Owner, factory and admins see factory links"
  on public.brand_factories for select
  to authenticated
  using (factory_id = (select auth.uid()) or (select public.brand_owner_or_admin(brand_id)));

create policy "Visible when the link is visible"
  on public.brand_factory_events for select
  to authenticated
  using (exists (select 1 from public.brand_factories f where f.id = link_id));

create policy "Owner, linked factories and admins see coverage"
  on public.factory_coverage_versions for select
  to authenticated
  using ((select public.brand_owner_or_admin(brand_id))
         or exists (select 1 from public.brand_factories f
                     where f.brand_id = factory_coverage_versions.brand_id
                       and f.factory_id = (select auth.uid()) and f.status = 'active'));

create policy "Visible when the coverage version is visible"
  on public.factory_coverage_areas for select
  to authenticated
  using (exists (select 1 from public.factory_coverage_versions cv where cv.id = version_id));

grant select on public.brand_factories, public.brand_factory_events,
  public.factory_coverage_versions, public.factory_coverage_areas to authenticated;
