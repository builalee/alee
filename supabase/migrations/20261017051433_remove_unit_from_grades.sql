-- ============================================================
-- OBJECTIVE:      Remove the pricing unit from grades (products). The only
--                 pricing unit is now the one each seller chooses per
--                 product family (seller_segments.base_unit), starting from
--                 the family's catalogue default (segments.default_base_unit).
-- WHY:            Owner decision 2026-10-17. With a unit on the grade and
--                 another on the seller's product family, the two could
--                 disagree and a buyer could see a per-tonne price labelled
--                 per kg. One source of truth removes that risk.
-- CHANGES:        public.products: column base_unit removed (with its
--                 default and its tonne-or-kg check).
-- DEPENDS ON:     20261009155205_create_products.
--                 20261017050159_segments_default_unit.
--                 20261017050259_create_seller_segments.
-- TOUCHES EXISTING DATA: YES. Drops the unit stored on the five grades
--                 (Fe500, Fe500D, Fe550D, MS Equal Angle, MS Channel (ISMC)).
--                 All five were 'tonne', the same as their family's default,
--                 so no information is lost. The migration checks this first
--                 and stops, changing nothing, if any grade differs from its
--                 family's default.
-- REVERSIBLE:     Yes. A later migration can re-add the column and fill it
--                 from segments.default_base_unit, which holds the same values.
-- TESTED:         On alee-dev 2026-10-17 (rehearsed in a rolled-back transaction, then
--                 applied; 67 checks passed). Grades no longer carry a unit;
--                 the only units left are the family default and each
--                 seller's choice. A seller's unit still starts as tonne,
--                 per kg can be chosen, per piece is refused. Visitors still
--                 read the 5 grades; ordinary users still cannot add or
--                 change grades; admin can add a grade without a unit.
-- DATE:           2026-10-17
-- ============================================================

do $$
begin
  if exists (
    select 1
      from public.products p
      join public.segments s on s.id = p.segment_id
     where p.base_unit <> s.default_base_unit
  ) then
    raise exception 'A grade''s unit differs from its family default; resolve by hand first';
  end if;
end;
$$;

alter table public.products drop column base_unit;

comment on table public.products is
  'Grades within a segment (e.g. Fe500D in TMT Bars). Pricing unit is per seller per segment (seller_segments.base_unit). Deactivated, never deleted.';
