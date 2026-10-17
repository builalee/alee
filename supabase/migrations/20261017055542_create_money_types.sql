-- ============================================================
-- OBJECTIVE:      Define one shared type for money amounts (rupees) and
--                 one for percentages, both exact.
-- WHY:            Money must never drift by fractions of a rupee. Exact
--                 decimals are used everywhere, never approximate numbers,
--                 and a figure with more precision than allowed is refused
--                 rather than silently rounded.
-- CHANGES:        New domain public.rupees (exact, up to 4 decimal places,
--                 any sign). New domain public.percentage (exact, 0 to 100,
--                 up to 4 decimal places).
-- DEPENDS ON:     None.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping both domains (only while no column uses
--                 them).
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; saved checks in tests/database/charts.sql (105) pass.
--                 Amounts with more than 4 decimals are refused, not
--                 rounded; 6.5330 is stored exactly; percentages outside
--                 0-100 are refused.
-- DATE:           2026-10-17
-- ============================================================

-- Rupee amounts. Four decimal places are allowed so that a per-tonne figure
-- converted to per kg stays exact (Rs 6,533 per tonne = Rs 6.533 per kg).
-- Rounding for display belongs to the money engine, never to storage.
create domain public.rupees as numeric
  constraint rupees_exact check (value = round(value, 4))
  constraint rupees_range check (abs(value) < 1000000000);

comment on domain public.rupees is
  'Exact rupee amount, up to 4 decimal places. Extra precision is refused, never rounded.';

create domain public.percentage as numeric
  constraint percentage_exact check (value = round(value, 4))
  constraint percentage_range check (value >= 0 and value <= 100);

comment on domain public.percentage is
  'Exact percentage from 0 to 100, up to 4 decimal places.';
