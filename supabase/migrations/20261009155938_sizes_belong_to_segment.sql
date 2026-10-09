-- ============================================================
-- OBJECTIVE:      Move sizes from the product (grade) to the segment, so
--                 TMT has one size list (8-32mm) shared by Fe500, Fe500D
--                 and Fe550D, and likewise for angles and channels.
-- WHY:            Owner decision 2026-10-09: a size is a property of the
--                 product family, not the grade. Grade differences are
--                 priced through a grade premium (an area-level setting,
--                 built later), and size charts are assigned per segment by
--                 default, per grade where a region needs it (built later).
-- CHANGES:        public.sizes: new column segment_id (required); column
--                 product_id removed; unique name is now per segment.
--                 View public.sizes_with_piece_weight recreated.
-- DEPENDS ON:     20261009155305_create_sizes.
-- TOUCHES EXISTING DATA: YES.
--                 * Removes the 14 duplicate TMT size rows that were copies
--                   for Fe500D and Fe550D. The Fe500 rows are kept and
--                   become the shared TMT list. The migration first checks
--                   that each removed row has exactly the same weight and
--                   length as the kept row, and that nothing references
--                   sizes; if either check fails it stops and changes
--                   nothing.
--                 * Every remaining size gets the segment of its old product.
--                 These rows are seed data never used by any rate, which is
--                 why removing them is allowed here despite the never-delete
--                 rule.
-- REVERSIBLE:     Not automatically. No information is lost (removed rows
--                 were exact copies), so a later migration could restore a
--                 product link if ever needed.
-- TESTED:         On alee-dev 2026-10-09 (rehearsed in a rolled-back transaction, then
--                 applied). Sizes 33 -> 19: TMT 7, angles 6, channels 6.
--                 product_id gone; public still sees only the 7 verified
--                 TMT sizes; a duplicate size name in a segment is refused;
--                 ordinary users still cannot insert, update or delete;
--                 12mm weight per piece still derives to 10.656 kg.
-- DATE:           2026-10-09
-- ============================================================

-- Safety checks ---------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_constraint where confrelid = 'public.sizes'::regclass) then
    raise exception 'Something now references sizes; removing duplicates is no longer safe';
  end if;

  -- Duplicates within a segment must be exact copies, or information would
  -- be lost.
  if exists (
    select 1
      from public.sizes s
      join public.products p on p.id = s.product_id
     group by p.segment_id, lower(s.display_name)
    having count(distinct (s.weight_per_metre_kg, s.piece_length_m,
                           s.weight_source, s.is_verified, s.is_active)) > 1
  ) then
    raise exception 'Duplicate sizes differ between grades; resolve by hand first';
  end if;
end;
$$;

-- Restructure ---------------------------------------------------------------

drop view public.sizes_with_piece_weight;

alter table public.sizes
  add column segment_id uuid references public.segments (id);

update public.sizes s
   set segment_id = p.segment_id
  from public.products p
 where p.id = s.product_id;

-- Keep one row per segment and size name: the one whose product name sorts
-- first (Fe500 for TMT). Delete is otherwise blocked by trigger.
alter table public.sizes disable trigger sizes_prevent_delete;

delete from public.sizes s
 using (
   select s2.id,
          row_number() over (
            partition by s2.segment_id, lower(s2.display_name)
            order by p.name, s2.id
          ) as rn
     from public.sizes s2
     join public.products p on p.id = s2.product_id
 ) ranked
 where ranked.id = s.id
   and ranked.rn > 1;

alter table public.sizes enable trigger sizes_prevent_delete;

alter table public.sizes alter column segment_id set not null;

drop index public.sizes_product_name_key;
drop index public.sizes_product_id_idx;
alter table public.sizes drop column product_id;

create unique index sizes_segment_name_key
  on public.sizes (segment_id, lower(display_name));
create index sizes_segment_id_idx on public.sizes (segment_id, sort_order);

comment on table public.sizes is
  'Sizes of a segment, shared by all its grades, with standard weight and length. Deactivated, never deleted.';

-- Weight per piece stays derived, never stored.
create view public.sizes_with_piece_weight
with (security_invoker = true)
as
select s.*,
       s.weight_per_metre_kg * s.piece_length_m as weight_per_piece_kg
  from public.sizes s;

grant select on public.sizes_with_piece_weight to anon, authenticated;
