-- ============================================================
-- OBJECTIVE:      A seller cannot add an area beyond his reach to his area
--                 settings: "Upgrade to reach more areas." Areas already in
--                 his previous saved version may stay (a lapsed plan keeps
--                 its settings saved), and "everywhere" and exclusions are
--                 always allowed.
-- WHY:            Owner decision 2026-11-01 (docs/decisions.md 14.1): area
--                 setup beyond reach shows "Upgrade to reach more areas",
--                 enforced in the database, for every seller. A lapsed plan
--                 keeps settings saved but not applied; nothing is deleted.
-- CHANGES:        New trigger public.area_settings_within_reach on
--                 public.area_settings (before insert), and its function.
-- DEPENDS ON:     20261101100100_reach_for_every_role (within_reach).
-- TOUCHES EXISTING DATA: No. Saved settings are unchanged; the rule applies
--                 only to new saves.
-- REVERSIBLE:     Yes, by dropping the trigger and function.
-- TESTED:         On alee-dev 2026-11-01: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/reach.sql.
-- DATE:           2026-11-01
-- ============================================================

-- Why "everywhere" is allowed: it means "the same in every area I reach",
-- for a flat-rate seller. The rate engine still applies his reach, so it
-- never shows his rate beyond it. Exclusions are allowed: saying "not
-- served" never shows a rate anywhere.
create function public.area_settings_within_reach()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v record;
begin
  if new.region_id is null or new.is_excluded then
    return new;
  end if;
  select av.seller_id, av.brand_id, av.segment_id, av.version_number into v
    from public.area_setting_versions av where av.id = new.version_id;
  if public.within_reach(v.seller_id, new.region_id) then
    return new;
  end if;
  -- Kept from his previous version: saved, though not applied on his plan.
  if exists (select 1 from public.area_settings s
               join public.area_setting_versions pv on pv.id = s.version_id
              where pv.seller_id = v.seller_id and pv.brand_id = v.brand_id and pv.segment_id = v.segment_id
                and pv.version_number = v.version_number - 1
                and s.region_id = new.region_id) then
    return new;
  end if;
  raise exception '%', format('Upgrade to reach more areas. %s is outside your reach.',
                              (select r.name from public.regions r where r.id = new.region_id));
end;
$$;

create trigger area_settings_within_reach
  before insert on public.area_settings
  for each row execute function public.area_settings_within_reach();

revoke execute on function public.area_settings_within_reach() from public, anon, authenticated;
