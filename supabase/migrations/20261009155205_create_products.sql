-- ============================================================
-- OBJECTIVE:      Create the products table: items within a segment, such
--                 as Fe500D within TMT Bars, each with the unit its base
--                 rate is priced in.
-- WHY:            A seller's base rate is per the product's base unit
--                 (tonne or kg), not always per tonne. ALEE converts
--                 between units through weight.
-- CHANGES:        New enum public.unit (tonne, kg, piece, metre).
--                 New table public.products (segment_id, name, base_unit,
--                 is_active). Seeds five products.
-- DEPENDS ON:     20261009155105_create_segments.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the table and the enum (only while no
--                 sizes reference it). Loses only the seeded rows.
-- TESTED:         On alee-dev 2026-10-09 (rehearsed in a rolled-back transaction, then applied).
--                 RLS enabled. Anonymous and ordinary users read only
--                 active rows and every insert, update and delete by them
--                 is refused. Admin can insert and update; nobody can delete.
-- DATE:           2026-10-09
-- ============================================================

-- Every unit ALEE can show a rate in. Conversion between them goes through
-- the size's weight per metre and piece length.
create type public.unit as enum ('tonne', 'kg', 'piece', 'metre');

create table public.products (
  id          uuid primary key default gen_random_uuid(),
  segment_id  uuid not null references public.segments (id),
  name        text not null check (length(btrim(name)) > 0),
  -- Sellers price by weight only; piece and metre are display units derived
  -- from weight.
  base_unit   public.unit not null default 'tonne'
              check (base_unit in ('tonne', 'kg')),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.products is
  'Items within a segment (e.g. Fe500D in TMT Bars). Deactivated, never deleted.';
comment on column public.products.base_unit is
  'Unit the seller''s base rate is per: tonne or kg.';

create unique index products_segment_name_key
  on public.products (segment_id, lower(name));
create index products_segment_id_idx on public.products (segment_id, name);

create trigger products_set_updated_at
  before update on public.products
  for each row execute function public.set_updated_at();

create trigger products_prevent_delete
  before delete on public.products
  for each row execute function public.prevent_delete();

-- Row Level Security --------------------------------------------------------

alter table public.products enable row level security;

create policy "Anyone can read active products"
  on public.products for select
  to anon, authenticated
  using (is_active);

create policy "Admins can read all products"
  on public.products for select
  to authenticated
  using ((select public.is_admin()));

create policy "Admins can insert products"
  on public.products for insert
  to authenticated
  with check ((select public.is_admin()));

create policy "Admins can update products"
  on public.products for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

-- No DELETE grant: products are never deleted.
grant select on public.products to anon, authenticated;
grant insert, update on public.products to authenticated;

-- Seed ----------------------------------------------------------------------

insert into public.products (segment_id, name, base_unit)
select s.id, p.name, 'tonne'
  from (values
    ('TMT Bars',    'Fe500'),
    ('TMT Bars',    'Fe500D'),
    ('TMT Bars',    'Fe550D'),
    ('MS Angles',   'MS Equal Angle'),
    ('MS Channels', 'MS Channel (ISMC)')
  ) as p (segment_name, name)
  join public.segments s on s.name = p.segment_name;
