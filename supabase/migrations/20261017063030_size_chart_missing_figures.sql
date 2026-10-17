-- ============================================================
-- OBJECTIVE:      Report the sizes a seller has selected that his size
--                 chart has no figure for.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.17): a
--                 selected size with no figure is an error, never zero.
--                 Publishing must flag it and leave that size out until it
--                 is fixed. This is the single check publishing and the
--                 rate engine will use, so they can never disagree.
-- CHANGES:        New function public.size_chart_missing_figures(chart).
-- DEPENDS ON:     20261017062930_create_seller_offerings.
--                 20261017055742_create_chart_versions.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the function.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks (npm run check:db) pass.
--                 tests/database/offerings.sql: selected sizes with no figure
--                 are listed; a figure of 0 counts as present; unselected
--                 sizes are not listed; another seller cannot check.
-- DATE:           2026-10-17
-- ============================================================

-- For a seller's size chart: every size of the chart's product family that
-- the seller has selected (and that is switched on), but that the chart's
-- latest version has no figure for. A figure of 0 counts as present.
-- Empty result = nothing missing. Runs with the caller's rights, so a
-- seller can check only his own charts.
create function public.size_chart_missing_figures(p_chart_id uuid)
returns table (size_id uuid, display_name text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  c  public.charts%rowtype;
begin
  select * into c from public.charts where id = p_chart_id;
  if not found then
    raise exception 'Chart not found';
  end if;
  if c.chart_type <> 'size' or c.is_template then
    raise exception 'Only a seller''s size chart can be checked for missing sizes';
  end if;

  return query
  select z.id, z.display_name
    from public.seller_sizes ss
    join public.sizes z on z.id = ss.size_id
   where ss.seller_id = c.seller_id
     and ss.is_selected
     and z.is_active
     and z.segment_id = c.segment_id
     and not exists (
       select 1
         from public.chart_version_figures f
        where f.size_id = z.id
          and f.version_id = (
            select v.id from public.chart_versions v
             where v.chart_id = c.id
             order by v.version_number desc limit 1)
     )
   order by z.sort_order;
end;
$$;

comment on function public.size_chart_missing_figures(uuid) is
  'Selected sizes with no figure in the size chart''s latest version. Never treat these as zero.';

revoke execute on function public.size_chart_missing_figures(uuid) from public, anon;
grant execute on function public.size_chart_missing_figures(uuid) to authenticated;
