-- ============================================================
-- OBJECTIVE:      Create ALEE's first template: the TMT Bars size chart
--                 "Standard TMT – Maharashtra & Goa", per tonne.
-- WHY:            Owner decision 2026-10-17. Sellers in Maharashtra and Goa
--                 mostly use the same size differences; a template lets a
--                 new seller copy them instead of typing them. No loading
--                 template is created: loading varies per seller, so each
--                 seller enters his own (docs/decisions.md 2.16).
-- CHANGES:        Adds one row to public.charts (a template), version 1 in
--                 public.chart_versions (per tonne), and seven rows in
--                 public.chart_version_figures:
--                 8mm 6500, 10mm 5500, 12mm 5500, 16mm 5500, 20mm 5500,
--                 25mm 5500, 32mm 6500.
-- DEPENDS ON:     20261017055842_chart_save_and_copy.
--                 20261009155938_sizes_belong_to_segment (TMT sizes).
-- TOUCHES EXISTING DATA: No. Adds new rows only.
-- REVERSIBLE:     The template cannot be deleted (charts never are). It can
--                 be switched off by an admin, or corrected by saving a new
--                 version; sellers' existing copies are unaffected either way.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied. Saved checks tests/database/templates.sql (10)
--                 pass: exact figures per tonne; a seller's copy gets exactly
--                 these figures; a later template change leaves the copy
--                 unchanged; no loading template. charts.sql still passes.
-- DATE:           2026-10-17
-- ============================================================

-- Written the same way save_chart_version writes: the chart is marked as
-- being saved for the length of this block, so the guards on the version
-- tables accept these rows. The function itself cannot be used here
-- because a migration has no logged-in admin.
do $$
declare
  v_segment  uuid;
  v_chart    uuid;
  v_version  uuid;
  v_found    integer;
begin
  select id into v_segment from public.segments where name = 'TMT Bars';
  if v_segment is null then
    raise exception 'TMT Bars segment not found';
  end if;

  insert into public.charts (seller_id, is_template, segment_id, chart_type, name)
  values (null, true, v_segment, 'size', 'Standard TMT – Maharashtra & Goa')
  returning id into v_chart;

  perform set_config('alee.saving_chart', v_chart::text, true);

  insert into public.chart_versions (chart_id, version_number, unit)
  values (v_chart, 1, 'tonne')
  returning id into v_version;

  insert into public.chart_version_figures (version_id, size_id, amount)
  select v_version, z.id, f.amount
    from (values ('8mm', 6500), ('10mm', 5500), ('12mm', 5500), ('16mm', 5500),
                 ('20mm', 5500), ('25mm', 5500), ('32mm', 6500)) as f (size_name, amount)
    join public.sizes z on z.segment_id = v_segment and z.display_name = f.size_name;

  get diagnostics v_found = row_count;
  if v_found <> 7 then
    raise exception 'Expected 7 TMT sizes, found %; nothing saved', v_found;
  end if;

  perform set_config('alee.saving_chart', '', true);
end;
$$;
