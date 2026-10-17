-- ============================================================
-- OBJECTIVE:      Give each product family a short name ("TMT", "Angles",
--                 "Channels"), used to show the unbranded option as
--                 "Regular TMT", "Regular Angles".
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.37, 2.41).
-- CHANGES:        public.segments: new column short_name (required, unique;
--                 defaults to the full name when not given).
-- DEPENDS ON:     20261009155105_create_segments.
-- TOUCHES EXISTING DATA: YES. Sets short_name on the three existing
--                 families: TMT Bars -> TMT, MS Angles -> Angles,
--                 MS Channels -> Channels. Nothing else changes. Stops,
--                 changing nothing, if any other family exists without a
--                 short name.
-- REVERSIBLE:     Yes, by dropping the column. No other data is affected.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction with every
--                 saved check file, then applied; all saved checks pass,
--                 including tests/database/brands.sql (44).
--                 TMT, Angles, Channels set; a family added without a short
--                 name gets its full name; all earlier checks unchanged.
-- DATE:           2026-10-17
-- ============================================================

alter table public.segments add column short_name text;

update public.segments set short_name = case name
  when 'TMT Bars'    then 'TMT'
  when 'MS Angles'   then 'Angles'
  when 'MS Channels' then 'Channels'
end;

do $$
begin
  if exists (select 1 from public.segments where short_name is null) then
    raise exception 'A product family has no short name; add one in this migration before running it';
  end if;
end;
$$;

alter table public.segments
  alter column short_name set not null,
  add constraint segments_short_name_not_blank check (length(btrim(short_name)) > 0);

create unique index segments_short_name_key on public.segments (lower(short_name));

comment on column public.segments.short_name is
  'Short name used in display, e.g. "Regular TMT". Defaults to the full name if not given.';

-- A family added without a short name gets its full name.
create function public.segments_default_short_name()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.short_name is null or btrim(new.short_name) = '' then
    new.short_name := new.name;
  end if;
  return new;
end;
$$;

create trigger segments_default_short_name
  before insert or update on public.segments
  for each row execute function public.segments_default_short_name();
