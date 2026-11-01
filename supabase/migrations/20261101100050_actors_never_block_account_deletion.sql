-- ============================================================
-- OBJECTIVE:      "Who did it" columns added on 2026-10-29 no longer link to
--                 the login, so deleting someone's account is never blocked
--                 because his name is on a record (for example a buyer who
--                 withdrew a rate request, or the admin who switched a plan
--                 on). The person's id is still recorded.
-- WHY:            CLAUDE.md section 15: account deletion must be complete.
--                 The earlier tables already record who acted as a plain id
--                 (publishes.published_by, territory events' done_by); the
--                 2026-10-29 tables linked it to the login by mistake, which
--                 stops the login being deleted while such a record exists.
-- CHANGES:        Drops the links (not the columns) on
--                 role_requests.decided_by, seller_plans.switched_on_by,
--                 seller_plans.ended_early_by, rate_requests.closed_by.
-- DEPENDS ON:     20261029100000_create_role_requests,
--                 20261029100100_create_plans,
--                 20261029100200_create_rate_requests.
-- TOUCHES EXISTING DATA: No. Every value stays as it is.
-- REVERSIBLE:     Yes, by adding the four links back.
-- TESTED:         On alee-dev 2026-11-01: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including the account deletion checks in
--                 tests/database/area_settings.sql, offerings.sql and
--                 rate_requests.sql.
-- DATE:           2026-11-01
-- ============================================================

alter table public.role_requests drop constraint role_requests_decided_by_fkey;
alter table public.seller_plans drop constraint seller_plans_switched_on_by_fkey;
alter table public.seller_plans drop constraint seller_plans_ended_early_by_fkey;
alter table public.rate_requests drop constraint rate_requests_closed_by_fkey;
