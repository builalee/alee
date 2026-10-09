-- ============================================================
-- OBJECTIVE:      Create the sizes table: the sizes of each product (8mm,
--                 25x3, ISMC 100) with the standard weight per metre and
--                 piece length ALEE uses to convert between units.
-- WHY:            Rates are converted between tonne, kg, piece and metre
--                 through weight. A wrong weight means a wrong rate, so
--                 sizes whose weight or length has not been checked are
--                 flagged and kept inactive until they are.
-- CHANGES:        New table public.sizes (product_id, display_name,
--                 sort_order, weight_per_metre_kg, piece_length_m,
--                 weight_source, is_verified, is_active).
--                 New view public.sizes_with_piece_weight, which derives
--                 weight per piece (never stored).
--                 Seeds 21 TMT sizes (verified, active) and 12 angle and
--                 channel sizes (unverified, inactive).
-- DEPENDS ON:     20261009155205_create_products.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the view and the table. Loses only the
--                 seeded rows.
-- TESTED:         On alee-dev 2026-10-09 (rehearsed in a rolled-back transaction, then applied).
--                 RLS enabled. Public sees the 21 TMT sizes only; the 12
--                 unverified sizes are hidden. Ordinary users cannot insert,
--                 update or delete. Admin cannot activate an unverified size.
--                 12mm weight per piece derives to 10.656 kg (0.888 x 12).
-- DATE:           2026-10-09
-- ============================================================

create table public.sizes (
  id                   uuid primary key default gen_random_uuid(),
  product_id           uuid not null references public.products (id),
  display_name         text not null check (length(btrim(display_name)) > 0),
  sort_order           integer not null default 0,
  weight_per_metre_kg  numeric(10, 4) not null check (weight_per_metre_kg > 0),
  piece_length_m       numeric(6, 2)  not null check (piece_length_m > 0),
  -- Where the weight came from, e.g. 'IS 1786:2008', or 'Calculated' when
  -- the size is not listed in a standard.
  weight_source        text not null,
  -- True once an admin has confirmed the weight and piece length.
  is_verified          boolean not null default false,
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  -- An unchecked weight must never be used to convert a rate.
  constraint sizes_active_requires_verified
    check (not is_active or is_verified)
);

comment on table public.sizes is
  'Sizes of a product with standard weight and length. Deactivated, never deleted.';
comment on column public.sizes.weight_per_metre_kg is
  'Standard weight in kg per metre. Basis of every unit conversion.';
comment on column public.sizes.piece_length_m is
  'Standard length of one piece in metres.';
comment on column public.sizes.is_verified is
  'Weight and length confirmed by an admin. A size cannot be active until verified.';

create unique index sizes_product_name_key
  on public.sizes (product_id, lower(display_name));
create index sizes_product_id_idx on public.sizes (product_id, sort_order);

create trigger sizes_set_updated_at
  before update on public.sizes
  for each row execute function public.set_updated_at();

create trigger sizes_prevent_delete
  before delete on public.sizes
  for each row execute function public.prevent_delete();

-- Weight per piece is derived, never stored, so it can never disagree with
-- weight per metre and piece length. security_invoker makes the view obey
-- the caller's RLS on sizes.
create view public.sizes_with_piece_weight
with (security_invoker = true)
as
select s.*,
       s.weight_per_metre_kg * s.piece_length_m as weight_per_piece_kg
  from public.sizes s;

-- Row Level Security --------------------------------------------------------

alter table public.sizes enable row level security;

create policy "Anyone can read active sizes"
  on public.sizes for select
  to anon, authenticated
  using (is_active);

create policy "Admins can read all sizes"
  on public.sizes for select
  to authenticated
  using ((select public.is_admin()));

create policy "Admins can insert sizes"
  on public.sizes for insert
  to authenticated
  with check ((select public.is_admin()));

create policy "Admins can update sizes"
  on public.sizes for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

-- No DELETE grant: sizes are never deleted.
grant select on public.sizes to anon, authenticated;
grant insert, update on public.sizes to authenticated;
grant select on public.sizes_with_piece_weight to anon, authenticated;

-- Seed ----------------------------------------------------------------------

-- TMT: nominal mass per metre from IS 1786:2008, 12 m standard length.
-- Same sizes for Fe500, Fe500D and Fe550D.
insert into public.sizes (
  product_id, display_name, sort_order, weight_per_metre_kg, piece_length_m,
  weight_source, is_verified, is_active
)
select p.id, w.display_name, w.sort_order, w.kg_per_m, 12, 'IS 1786:2008', true, true
  from public.products p
  join public.segments s on s.id = p.segment_id and s.name = 'TMT Bars'
 cross join (values
    ('8mm',  10, 0.395),
    ('10mm', 20, 0.617),
    ('12mm', 30, 0.888),
    ('16mm', 40, 1.580),
    ('20mm', 50, 2.466),
    ('25mm', 60, 3.853),
    ('32mm', 70, 6.313)
  ) as w (display_name, sort_order, kg_per_m);

-- Angles and channels: UNVERIFIED. Seeded inactive so nothing can use them
-- until the owner checks each weight and the 6 m piece length.
-- 25x6 and 32x3 are not listed in IS 808; their weights are calculated from
-- the dimensions (leg x thickness, steel density 7850 kg/m3).
insert into public.sizes (
  product_id, display_name, sort_order, weight_per_metre_kg, piece_length_m,
  weight_source, is_verified, is_active
)
select p.id, w.display_name, w.sort_order, w.kg_per_m, 6, w.source, false, false
  from (values
    ('MS Equal Angle',    '25×3',      10, 1.10, 'IS 808 (ISA 25x25x3)'),
    ('MS Equal Angle',    '25×5',      20, 1.77, 'IS 808 (ISA 25x25x5)'),
    ('MS Equal Angle',    '25×6',      30, 2.07, 'Calculated - not in IS 808'),
    ('MS Equal Angle',    '30×3',      40, 1.40, 'IS 808 (ISA 30x30x3)'),
    ('MS Equal Angle',    '32×3',      50, 1.44, 'Calculated - not in IS 808'),
    ('MS Equal Angle',    '40×5',      60, 3.00, 'IS 808 (ISA 40x40x5)'),
    ('MS Channel (ISMC)', 'ISMC 75',   10, 7.10, 'IS 808 (ISMC 75)'),
    ('MS Channel (ISMC)', 'ISMC 100',  20, 9.20, 'IS 808 (ISMC 100)'),
    ('MS Channel (ISMC)', 'ISMC 125',  30, 12.70, 'IS 808 (ISMC 125)'),
    ('MS Channel (ISMC)', 'ISMC 150',  40, 16.40, 'IS 808 (ISMC 150)'),
    ('MS Channel (ISMC)', 'ISMC 175',  50, 19.10, 'IS 808 (ISMC 175)'),
    ('MS Channel (ISMC)', 'ISMC 200',  60, 22.10, 'IS 808 (ISMC 200)')
  ) as w (product_name, display_name, sort_order, kg_per_m, source)
  join public.products p on p.name = w.product_name;
