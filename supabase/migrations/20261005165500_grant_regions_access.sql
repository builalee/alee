-- Table privileges for public.regions.
--
-- This project does not grant new tables to the API roles automatically, so
-- without these grants every request fails before RLS is even consulted.
-- RLS policies (see create_regions) still decide which rows each role can
-- read or write; these grants only make the table reachable.
-- No DELETE grant: regions are deactivated, never deleted.

grant select on public.regions to anon, authenticated;
grant insert, update on public.regions to authenticated;

grant execute on function public.search_regions(text, public.region_level, integer)
  to anon, authenticated;
grant execute on function public.is_admin() to anon, authenticated;
