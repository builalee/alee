-- ============================================================
-- OBJECTIVE:      Create ALEE's brand list: brands, the product families
--                 each covers, alternate spellings for search, and the
--                 unbranded "Regular". Sellers request missing brands; an
--                 admin approves or rejects them.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.37,
--                 2.41). Distributors and retailers quote different rates
--                 for different brands, so brands must exist before the
--                 rate engine. Admin approval prevents duplicate spellings.
-- CHANGES:        New enum public.brand_status.
--                 New tables public.brands and public.brand_families.
--                 New functions public.brand_covers_family(...),
--                 public.brand_display_name(...), public.request_brand(...),
--                 public.decide_brand(...).
--                 Seeds the brand "Regular".
-- DEPENDS ON:     20261017123200_segment_short_names.
--                 20261009155105_create_segments (prevent_delete).
-- TOUCHES EXISTING DATA: No (adds the "Regular" brand only).
-- REVERSIBLE:     Yes, by dropping the functions, tables and enum. Every
--                 brand and request would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/brands.sql (44).
--                 RLS on. One Regular, approved, covering every family, shown
--                 "Regular TMT"; cannot be rejected, switched off, given a
--                 family list or duplicated. Requests private until
--                 approved; duplicates and known spellings refused in plain
--                 words; only admins decide, decisions final, recorded who
--                 and when; nothing deleted.
-- DATE:           2026-10-17
-- ============================================================

create type public.brand_status as enum ('requested', 'approved', 'rejected');

create table public.brands (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(btrim(name)) > 0),
  -- The unbranded option: covers every family, never owned, shown as
  -- "Regular" plus the family's short name.
  is_regular       boolean not null default false,
  -- Old names and other spellings, for search and to catch duplicates.
  alternate_names  text[] not null default '{}',
  search_text      text not null default '',
  status           public.brand_status not null default 'requested',
  -- The seller who asked for it (empty when an admin added it directly).
  requested_by     uuid references public.seller_profiles (account_id) on delete set null,
  decided_by       uuid,
  decided_at       timestamptz,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint brands_regular_is_approved check (not is_regular or (status = 'approved' and is_active))
);

comment on table public.brands is
  'ALEE''s brand list. Requested by sellers, approved by admins. Never deleted. "Regular" is the unbranded option.';

-- No two live brands share a name (rejected requests don't count).
create unique index brands_name_key on public.brands (lower(name)) where status <> 'rejected';
-- Exactly one Regular.
create unique index brands_one_regular_key on public.brands (is_regular) where is_regular;
create index brands_search_trgm_idx on public.brands using gin (search_text extensions.gin_trgm_ops);
create index brands_requested_by_idx on public.brands (requested_by) where requested_by is not null;

-- Which product families a brand covers. Regular covers every family and
-- has no rows here.
create table public.brand_families (
  brand_id    uuid not null references public.brands (id),
  segment_id  uuid not null references public.segments (id),
  primary key (brand_id, segment_id)
);

create index brand_families_segment_idx on public.brand_families (segment_id);

-- Rules ---------------------------------------------------------------------

create function public.brands_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  select coalesce(array_agg(distinct btrim(n)), '{}') into new.alternate_names
    from unnest(new.alternate_names) n
   where length(btrim(n)) > 0 and lower(btrim(n)) <> lower(new.name);
  new.search_text := lower(new.name || ' ' || array_to_string(new.alternate_names, ' '));

  if tg_op = 'UPDATE' then
    if new.is_regular <> old.is_regular then
      raise exception 'Whether a brand is Regular never changes';
    end if;
    if new.status <> old.status and old.status <> 'requested' then
      raise exception 'A brand''s decision is final (%); a rejected name can be requested again as a new brand', old.status;
    end if;
    if new.requested_by is distinct from old.requested_by and old.requested_by is not null
       and new.requested_by is not null then
      raise exception 'Who requested a brand never changes';
    end if;
  end if;
  return new;
end;
$$;

create trigger brands_before_write
  before insert or update on public.brands
  for each row execute function public.brands_before_write();
create trigger brands_set_updated_at
  before update on public.brands
  for each row execute function public.set_updated_at();
create trigger brands_prevent_delete
  before delete on public.brands
  for each row execute function public.prevent_delete();

create function public.brand_families_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from public.brands b where b.id = new.brand_id and b.is_regular) then
    raise exception 'Regular covers every product family already';
  end if;
  return new;
end;
$$;

create trigger brand_families_before_write
  before insert or update on public.brand_families
  for each row execute function public.brand_families_before_write();
create trigger brand_families_prevent_delete
  before delete on public.brand_families
  for each row execute function public.prevent_delete();

-- Shared helpers --------------------------------------------------------------

-- Whether a brand covers a product family (Regular covers every family).
create function public.brand_covers_family(p_brand_id uuid, p_segment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.brands b where b.id = p_brand_id and b.is_regular)
      or exists (select 1 from public.brand_families bf
                  where bf.brand_id = p_brand_id and bf.segment_id = p_segment_id);
$$;

-- How a brand is shown for a family: "Regular TMT" for Regular, otherwise
-- the brand's name. The one place this is decided.
create function public.brand_display_name(p_brand_id uuid, p_segment_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case when b.is_regular then 'Regular ' || s.short_name else b.name end
    from public.brands b, public.segments s
   where b.id = p_brand_id and s.id = p_segment_id;
$$;

grant execute on function public.brand_covers_family(uuid, uuid) to anon, authenticated;
grant execute on function public.brand_display_name(uuid, uuid) to anon, authenticated;

-- A seller asks for a missing brand, naming the families it covers. It
-- waits for an admin. Refused, in plain words, if the name or one of its
-- spellings is already on ALEE or already requested.
create function public.request_brand(
  p_name         text,
  p_segment_ids  uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name     text := btrim(p_name);
  v_existing text;
  v_id       uuid;
begin
  if auth.uid() is null then
    raise exception 'Not logged in' using errcode = '42501';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.account_id = auth.uid()) then
    raise exception 'Only sellers can request a brand.';
  end if;
  if v_name is null or v_name = '' then
    raise exception 'Enter the brand''s name.';
  end if;
  if p_segment_ids is null or cardinality(p_segment_ids) = 0 then
    raise exception 'Choose which product families % covers.', v_name;
  end if;
  if exists (select 1 from unnest(p_segment_ids) x
              where not exists (select 1 from public.segments s where s.id = x and s.is_active)) then
    raise exception 'That product family is not available.';
  end if;

  select b.name into v_existing from public.brands b
   where b.status <> 'rejected'
     and (lower(b.name) = lower(v_name) or lower(v_name) = any (select lower(n) from unnest(b.alternate_names) n))
   limit 1;
  if v_existing is not null then
    raise exception '% is already on ALEE (as %).', v_name, v_existing;
  end if;

  insert into public.brands (name, status, requested_by)
  values (v_name, 'requested', auth.uid())
  returning id into v_id;

  insert into public.brand_families (brand_id, segment_id)
  select v_id, x from (select distinct unnest(p_segment_ids) as x) d;

  return v_id;
end;
$$;

-- An admin approves or rejects a requested brand.
create function public.decide_brand(p_brand_id uuid, p_approve boolean)
returns public.brand_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.brand_status;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can approve or reject a brand' using errcode = '42501';
  end if;
  select b.status into v_status from public.brands b where b.id = p_brand_id for update;
  if v_status is null then
    raise exception 'Brand not found';
  end if;
  if v_status <> 'requested' then
    raise exception 'This brand has already been decided (%).', v_status;
  end if;

  update public.brands
     set status = case when p_approve then 'approved' else 'rejected' end::public.brand_status,
         decided_by = auth.uid(), decided_at = clock_timestamp()
   where id = p_brand_id;
  return case when p_approve then 'approved' else 'rejected' end::public.brand_status;
end;
$$;

revoke execute on function public.request_brand(text, uuid[]) from public, anon;
revoke execute on function public.decide_brand(uuid, boolean) from public, anon;
grant execute on function public.request_brand(text, uuid[]) to authenticated;
grant execute on function public.decide_brand(uuid, boolean) to authenticated;

-- Row Level Security --------------------------------------------------------

alter table public.brands enable row level security;
alter table public.brand_families enable row level security;

create policy "Anyone can see approved, active brands"
  on public.brands for select
  to anon, authenticated
  using (status = 'approved' and is_active);

create policy "Requesters see their own requests; admins see all"
  on public.brands for select
  to authenticated
  using (requested_by = (select auth.uid()) or (select public.is_admin()));

-- Admins add brands directly, and edit names, spellings and families.
create policy "Admins add brands"
  on public.brands for insert
  to authenticated
  with check ((select public.is_admin()));

create policy "Admins change brands"
  on public.brands for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

create policy "Visible when the brand is visible"
  on public.brand_families for select
  to anon, authenticated
  using (exists (select 1 from public.brands b where b.id = brand_id));

create policy "Admins set brand families"
  on public.brand_families for insert
  to authenticated
  with check ((select public.is_admin()));

grant select on public.brands, public.brand_families to anon, authenticated;
grant insert, update on public.brands to authenticated;
grant insert on public.brand_families to authenticated;

-- Seed ----------------------------------------------------------------------

insert into public.brands (name, is_regular, status)
values ('Regular', true, 'approved');
