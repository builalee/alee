-- ============================================================
-- OBJECTIVE:      Record which brands each seller sells, in each product
--                 family: his "brand lines" (e.g. Bala Traders - Tata -
--                 TMT). Every existing seller's families are carried across
--                 as Regular brand lines.
-- WHY:            Owner decisions 2026-10-17 (docs/decisions.md 2.37,
--                 2.40, 2.41). Each brand a seller sells will get its own
--                 setup, rates and status; this table is the list of them.
--                 Any seller can sell any approved brand, even before its
--                 manufacturer joins.
-- CHANGES:        New table public.seller_brands.
--                 TRANSITIONAL (docs/decisions.md 2.44, removed in brands
--                 step 11): when a seller adds a product family, a Regular
--                 brand line is added for it too, so everything built
--                 before brands keeps working unchanged.
-- DEPENDS ON:     20261017123300_create_brands.
--                 20261017050259_create_seller_segments.
-- TOUCHES EXISTING DATA: YES. Adds one Regular brand line for every
--                 existing seller product family (same active / switched
--                 off state). Nothing existing is changed or removed. On
--                 alee-dev there are none (no sellers yet).
-- REVERSIBLE:     Yes, by dropping the trigger, its function and the table.
--                 Every seller's brand list would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/seller_brands.sql (24).
--                 Adding a family adds Regular; approved brands added for
--                 families they cover and the seller deals in, refused in
--                 plain words otherwise; unowned brands can be sold; only
--                 the seller or an admin changes lines; public when active;
--                 switched off, never deleted; seller, brand and family
--                 never change; all earlier checks unchanged.
-- DATE:           2026-10-17
-- ============================================================

create table public.seller_brands (
  seller_id   uuid not null references public.seller_profiles (account_id) on delete cascade,
  brand_id    uuid not null references public.brands (id),
  segment_id  uuid not null references public.segments (id),
  -- A seller who stops selling a brand is switched off, not deleted.
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (seller_id, brand_id, segment_id)
);

comment on table public.seller_brands is
  'Brand lines: which brands a seller sells, per product family. Public. Switched off, not deleted.';

-- Finding sellers of a brand in a family.
create index seller_brands_brand_idx on public.seller_brands (brand_id, segment_id) where is_active;

-- Rules ---------------------------------------------------------------------

-- A brand line can be added (or switched back on) only for an approved,
-- active brand that covers the family, in a family the seller deals in.
create function public.seller_brands_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_brand   text;
  v_family  text;
begin
  if tg_op = 'UPDATE' and (new.seller_id <> old.seller_id or new.brand_id <> old.brand_id
                           or new.segment_id <> old.segment_id) then
    raise exception 'A brand line''s seller, brand and family never change';
  end if;

  if new.is_active then
    select b.name into v_brand from public.brands b
     where b.id = new.brand_id and b.status = 'approved' and b.is_active;
    select s.name into v_family from public.segments s where s.id = new.segment_id;
    if v_brand is null then
      raise exception 'That brand is not available yet.';
    end if;
    if not public.brand_covers_family(new.brand_id, new.segment_id) then
      raise exception '% is not listed for %.', v_brand, coalesce(v_family, 'that product family');
    end if;
    if not exists (
      select 1 from public.seller_segments ss
       where ss.seller_id = new.seller_id and ss.segment_id = new.segment_id and ss.is_active
    ) then
      raise exception 'Add % to your product families first.', coalesce(v_family, 'this product family');
    end if;
  end if;
  return new;
end;
$$;

create trigger seller_brands_before_write
  before insert or update on public.seller_brands
  for each row execute function public.seller_brands_before_write();
create trigger seller_brands_set_updated_at
  before update on public.seller_brands
  for each row execute function public.set_updated_at();
create trigger seller_brands_prevent_direct_delete
  before delete on public.seller_brands
  for each row execute function public.prevent_direct_delete();

-- TRANSITIONAL (removed in brands step 11): adding a product family adds a
-- Regular brand line for it.
create function public.seller_segments_add_regular_line()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.seller_brands (seller_id, brand_id, segment_id, is_active)
  select new.seller_id, b.id, new.segment_id, new.is_active
    from public.brands b where b.is_regular
  on conflict (seller_id, brand_id, segment_id) do nothing;
  return null;
end;
$$;

create trigger seller_segments_add_regular_line
  after insert on public.seller_segments
  for each row execute function public.seller_segments_add_regular_line();

-- Row Level Security --------------------------------------------------------

alter table public.seller_brands enable row level security;

create policy "Anyone can see which brands sellers sell"
  on public.seller_brands for select
  to anon, authenticated
  using (is_active);

create policy "Sellers and admins see all of a seller's brand lines"
  on public.seller_brands for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Sellers add their own brand lines; admins add any"
  on public.seller_brands for insert
  to authenticated
  with check (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Sellers change their own brand lines; admins change any"
  on public.seller_brands for update
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()))
  with check (seller_id = (select auth.uid()) or (select public.is_admin()));

grant select on public.seller_brands to anon, authenticated;
grant insert, update on public.seller_brands to authenticated;

-- Carry existing sellers across ---------------------------------------------------

insert into public.seller_brands (seller_id, brand_id, segment_id, is_active)
select ss.seller_id, b.id, ss.segment_id, ss.is_active
  from public.seller_segments ss
 cross join public.brands b
 where b.is_regular
on conflict do nothing;
