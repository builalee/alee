-- ============================================================
-- OBJECTIVE:      A logged-in buyer can see a public seller's rates for his
--                 own area, and a list of every public seller's rates for his
--                 area in one call.
-- WHY:            Owner decision 2026-11-01 (docs/decisions.md 12.3, 16.1):
--                 any logged-in user sees a public seller's rates for his own
--                 area without subscribing. Until now only the seller and
--                 admins could ask.
-- CHANGES:        Changed public.buyer_rate (who may ask). New function
--                 public.area_rates.
-- DEPENDS ON:     20261101100500_rate_engine_reach_and_ex_works.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes: restore buyer_rate from the migration above and drop
--                 area_rates.
-- TESTED:         On alee-dev 2026-11-02: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass, including
--                 tests/database/rate_engine.sql.
-- DATE:           2026-11-02
-- ============================================================

-- The buyer's answer, now. The seller himself and admins can ask for any area.
-- Anyone else logged in asks as himself, for his own area, and only of a
-- public seller (or one who approved him as an outside buyer). The engine then
-- applies reach, territory and everything else. Never contains the basic rate
-- or any individual difference.
create or replace function public.buyer_rate(
  p_seller_id   uuid,
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_size_id     uuid default null,
  p_buyer_id    uuid default null,
  p_publish_id  uuid default null
)
returns setof public.buyer_rate_line
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Log in to see rates.';
  end if;
  if auth.uid() <> p_seller_id and not public.is_admin() then
    if p_buyer_id is distinct from auth.uid() then
      raise exception 'You can only see rates as yourself.' using errcode = '42501';
    end if;
    if p_region_id is distinct from (select a.region_id from public.accounts a where a.id = auth.uid()) then
      raise exception 'You can see rates for your own area only.';
    end if;
    if p_publish_id is not null then
      raise exception 'Past rates are not available here yet.';
    end if;
    if not coalesce((select sp.is_public from public.seller_profiles sp where sp.account_id = p_seller_id), false)
       and not public.is_approved_outside_buyer(p_seller_id, auth.uid()) then
      raise exception 'This seller shares his rates only with buyers he approves.';
    end if;
  end if;
  return query
  select e.brand_name, e.product_id, e.grade, e.size_id, e.size, e.status, e.message, e.tag,
         e.display_unit, e.area_rate, e.area_rate_label, e.area_rate_text, e.area_discount, e.area_discount_text,
         e.ex_works_rate, e.ex_works_label, e.ex_works_text, e.ex_works_discount, e.ex_works_discount_text,
         e.market, e.closed_at, e.published_at, e.published_today, e.is_correction
    from public.rate_engine(p_seller_id, p_brand_id, p_segment_id, p_region_id, p_product_id, p_size_id,
                            p_buyer_id, p_publish_id) e;
end;
$$;

-- Every public seller's rates for the logged-in buyer's own area, one row per
-- brand line, grade and size, each worked out by buyer_rate. A seller's own
-- lines are left out: they are not rates he buys at. Optionally one seller.
create function public.area_rates(p_segment_id uuid, p_seller_id uuid default null)
returns table (
  seller_id   uuid,
  store_name  text,
  brand_id    uuid,
  line        public.buyer_rate_line
)
language sql
stable
security invoker
set search_path = ''
as $$
  select sb.seller_id, sp.store_name, sb.brand_id, b
    from public.seller_brands sb
    join public.seller_profiles sp on sp.account_id = sb.seller_id
    cross join lateral public.buyer_rate(sb.seller_id, sb.brand_id, sb.segment_id,
      (select a.region_id from public.accounts a where a.id = auth.uid()), null, null, auth.uid()) b
   where sb.segment_id = p_segment_id and sb.is_active and sp.is_public
     and sb.seller_id is distinct from auth.uid()
     and (p_seller_id is null or sb.seller_id = p_seller_id)
   order by sp.store_name, sb.seller_id, sb.brand_id;
$$;

revoke execute on function public.area_rates(uuid, uuid) from public, anon;
grant execute on function public.area_rates(uuid, uuid) to authenticated;
