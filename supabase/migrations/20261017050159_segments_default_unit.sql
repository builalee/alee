-- ============================================================
-- OBJECTIVE:      Give each segment a default pricing unit (tonne or kg),
--                 which a seller starts with when he adds that segment.
-- WHY:            Each seller chooses per segment whether he prices per
--                 tonne or per kg, starting from the catalogue's default.
--                 Until now the unit was recorded only per grade.
-- CHANGES:        public.segments: new column default_base_unit.
-- DEPENDS ON:     20261009155205_create_products (public.unit enum).
-- TOUCHES EXISTING DATA: YES. Sets default_base_unit = 'tonne' on the three
--                 existing segments (TMT Bars, MS Angles, MS Channels),
--                 matching the unit already on all their grades. Nothing
--                 else changes.
-- REVERSIBLE:     Yes, by dropping the column. No other data is affected.
-- TESTED:         On alee-dev 2026-10-17 (rehearsed in a rolled-back transaction with
--                 temporary logins, then applied; 61 checks passed).
--                 All three segments default to tonne.
-- DATE:           2026-10-17
-- ============================================================

alter table public.segments
  add column default_base_unit public.unit not null default 'tonne'
  constraint segments_default_base_unit_check
    check (default_base_unit in ('tonne', 'kg'));

comment on column public.segments.default_base_unit is
  'Unit a seller starts with for this segment: tonne or kg.';
