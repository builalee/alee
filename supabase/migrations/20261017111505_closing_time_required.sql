-- ============================================================
-- OBJECTIVE:      Once a seller has published, his daily closing time can
--                 be changed but never cleared.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.30): a
--                 daily closing time is required before a seller's first
--                 publish (the publish itself checks this, next migration).
--                 Clearing it afterwards would leave his published rate
--                 open forever.
-- CHANGES:        New trigger on public.seller_profiles.
-- DEPENDS ON:     20261017050059_create_seller_profiles.
--                 20261017084616_create_publishes.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the trigger and its function.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks pass, including
--                 tests/database/publishes.sql (99).
--                 Before publishing a seller can set and clear his closing
--                 time; after publishing he can change it but not clear it,
--                 nor can the database owner.
-- DATE:           2026-10-17
-- ============================================================

create function public.seller_profiles_keep_closing_time()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.market_close_time is null and old.market_close_time is not null
     and exists (select 1 from public.publishes p where p.seller_id = new.account_id) then
    raise exception 'A seller who has published must keep a daily closing time. Change it instead of clearing it.';
  end if;
  return new;
end;
$$;

-- Runs with the caller's rights; the publishes check is not limited by
-- RLS for the seller himself or an admin, the only people who can update a
-- profile.
create trigger seller_profiles_keep_closing_time
  before update of market_close_time on public.seller_profiles
  for each row execute function public.seller_profiles_keep_closing_time();
