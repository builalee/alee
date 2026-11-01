-- ============================================================
-- OBJECTIVE:      The rate engine. One function works out what a buyer in
--                 an area sees for a seller's brand line, grade by grade
--                 and size by size: the area rate, the ex-works rate where
--                 switched on, the discount line beneath, open or closed,
--                 and any tag or message. Three ways in: the buyer's
--                 answer (final figures only), the seller's answer (every
--                 component and where it came from) and the seller's
--                 preview (every area in his setup, for the publish
--                 confirmation).
-- WHY:            CLAUDE.md sections 8 and 20; owner decisions 2026-10-29
--                 (docs/decisions.md 12.1-12.4). The publish confirmation,
--                 buyer feed, enquiries and orders must all use the same
--                 calculation, or they will eventually disagree. It runs
--                 in the database so the basic rate and the individual
--                 differences never leave it in a buyer's answer.
-- CHANGES:        New types public.rate_line, public.buyer_rate_line.
--                 New functions public.rate_engine (internal),
--                 public.buyer_rate, public.seller_rate, public.rate_preview.
-- DEPENDS ON:     20261029100000_create_role_requests,
--                 20261029100100_create_plans,
--                 20261029100200_create_rate_requests,
--                 20261029100300_create_ex_works_settings,
--                 20261029100400_money_and_unit_conversion,
--                 20261029100500_area_settings_say_where,
--                 20261017130818_territory_per_brand,
--                 20261017130335_create_brand_factories.
-- TOUCHES EXISTING DATA: No. Reads only; records nothing.
-- REVERSIBLE:     Yes, by dropping the functions and types.
-- TESTED:         On alee-dev 2026-10-29: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass,
--                 including tests/database/rate_engine.sql.
-- DATE:           2026-10-29
-- ============================================================

-- The full answer for one grade and size in one area: the seller's answer.
-- Components are in the seller's pricing unit; figures shown to buyers are
-- in the area's display unit, rounded once to the paisa.
create type public.rate_line as (
  region_id                 uuid,
  area_name                 text,
  brand_name                text,
  product_id                uuid,
  grade                     text,
  size_id                   uuid,
  size                      text,
  -- priced, not_served, not_offered, missing, served_by_factory,
  -- buy_from_distributor, priced_by_brand_owner, reach_limited,
  -- not_on_plan, not_quoting, not_published
  status                    text,
  message                   text,
  tag                       text,
  area_rate_label           text,
  pricing_unit              public.unit,
  display_unit              public.unit,
  base_rate                 numeric,
  grade_premium             numeric,
  grade_premium_from        text,
  size_difference           numeric,
  size_difference_from      text,
  loading                   numeric,
  loading_from              text,
  area_difference           numeric,
  area_difference_from      text,
  discount                  text,
  discount_from             text,
  area_rate                 numeric,
  area_rate_text            text,
  area_discount             numeric,
  area_discount_text        text,
  ex_works_label            text,
  ex_works_grade_premium    numeric,
  ex_works_size_difference  numeric,
  ex_works_loading          numeric,
  ex_works_rate             numeric,
  ex_works_text             text,
  ex_works_discount         numeric,
  ex_works_discount_text    text,
  -- What the seller must fix, in plain words. Never shown to buyers.
  missing                   text[],
  -- open, closed, preview (not yet published) or past (an earlier publish)
  market                    text,
  closed_at                 timestamptz,
  published_at              timestamptz,
  publish_id                uuid,
  is_correction             boolean
);

-- What a buyer receives. Final figures only: never the basic rate, the
-- grade premium or any individual difference.
create type public.buyer_rate_line as (
  brand_name              text,
  product_id              uuid,
  grade                   text,
  size_id                 uuid,
  size                    text,
  status                  text,
  message                 text,
  tag                     text,
  unit                    public.unit,
  area_rate               numeric,
  area_rate_label         text,
  area_rate_text          text,
  area_discount           numeric,
  area_discount_text      text,
  ex_works_rate           numeric,
  ex_works_label          text,
  ex_works_text           text,
  ex_works_discount       numeric,
  ex_works_discount_text  text,
  market                  text,
  closed_at               timestamptz,
  published_at            timestamptz,
  is_correction           boolean
);

-- The engine. Internal: reached only through the three functions below,
-- which decide who may ask.
--   p_region_id   the buyer's area (empty = "everywhere", for the preview)
--   p_buyer_id    the buyer, if known (for an approved outside buyer)
--   p_publish_id  an earlier publish to rebuild; default the latest
--   p_base_rate   preview only: the basic rate about to be published,
--                 worked out with his current settings
--   p_at          the moment (default now) for plan, reach, ex-works and
--                 open or closed
create function public.rate_engine(
  p_seller_id   uuid,
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_size_id     uuid default null,
  p_buyer_id    uuid default null,
  p_publish_id  uuid default null,
  p_base_rate   numeric default null,
  p_at          timestamptz default null
)
returns setof public.rate_line
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_brand    uuid := public.require_brand(p_brand_id);
  v_at       timestamptz := coalesce(p_at, clock_timestamp());
  v_draft    boolean := p_base_rate is not null;
  v_store    text;
  v_bname    text;
  v_area     text;               -- the buyer's area
  v_region   uuid := p_region_id; -- the area priced (his home area for an approved outside buyer)
  v_rarea    text;
  v_label    text;
  v_line     text;               -- set when the whole brand line stops early
  v_msg      text;
  v_tag      text;
  v_xw_ok    boolean := true;
  v_xw       boolean;
  v_pub      uuid;
  v_pub_at   timestamptz;
  v_corr     boolean;
  v_base     numeric;
  v_unit     public.unit;
  v_version  uuid;
  v_market   text;
  v_closed   timestamptz;
  f          record;
  t          record;
  rch        record;
  xw         record;
  ms         record;
  g          record;
  z          record;
  -- area settings for the area priced, and at the plant city
  a_served boolean; a_unit public.unit; a_diff numeric; a_diff_from text; a_disc uuid; a_disc_from text;
  a_du public.unit; a_prem numeric; a_prem_from text; a_sold boolean;
  x_served boolean; x_unit public.unit; x_disc uuid; x_prem numeric; x_sold boolean;
  -- discounts
  d_kind public.discount_kind; d_flat numeric; d_pct numeric; d_unit public.unit;
  e_kind public.discount_kind; e_flat numeric; e_pct numeric; e_unit public.unit;
  v_sf       jsonb;
  v_pf       jsonb;
  v_size_diff numeric; v_load numeric; v_xsize numeric; v_xload numeric;
  v_exact    numeric;
  v_dexact   numeric;
  v_xmiss    text[];
  r          public.rate_line;
begin
  select sp.store_name into v_store from public.seller_profiles sp where sp.account_id = p_seller_id;
  if not found then
    raise exception 'That seller was not found.';
  end if;
  v_bname := public.brand_display_name(v_brand, p_segment_id);
  v_area  := coalesce((select rg.name from public.regions rg where rg.id = p_region_id), 'everywhere');
  v_rarea := v_area;
  select * into rch from public.seller_reach(p_seller_id, v_at);
  select * into xw from public.ex_works_at(p_seller_id, v_at);

  -- 1. Factory: a brand owner's own rate comes from the factory he assigned
  --    to this area. Only for the owner and his linked factories, and only
  --    once he has said which factory covers which area.
  if exists (select 1 from public.factory_coverage_versions cv
              where cv.brand_id = v_brand and cv.segment_id = p_segment_id)
     and (exists (select 1 from public.brands b where b.id = v_brand and b.owner_id = p_seller_id)
          or exists (select 1 from public.brand_factories bf
                      where bf.brand_id = v_brand and bf.factory_id = p_seller_id and bf.status = 'active')) then
    select * into f from public.resolve_brand_factory(v_brand, p_segment_id, p_region_id);
    if f.factory_id is null or not f.factory_is_linked then
      v_line := 'not_served';
      v_msg := format('Doesn''t currently supply %s', v_area);
      v_xw_ok := false;
    elsif f.factory_id <> p_seller_id then
      v_line := 'served_by_factory';
      v_msg := format('%s in %s is supplied by %s', v_bname, v_area, f.factory_name);
      v_xw_ok := false;
    end if;
  end if;

  -- 2. Territory, per brand.
  if v_line is null then
    select * into t from public.territory_effect(p_seller_id, v_brand, p_segment_id, p_region_id);
    if t.effect = 'pointed_to_distributor' then
      v_line := 'buy_from_distributor';
      v_msg := format('For %s in %s, buy from %s, the authorised distributor.', v_bname, t.area_name, t.distributor_name);
      v_xw_ok := false;
    elsif t.effect = 'hidden' then
      v_line := 'priced_by_brand_owner';
      v_msg := format('Authorised distributor for %s. %s is sold there at the brand owner''s rate.', t.area_name, v_bname);
      v_xw_ok := false;
    elsif t.effect = 'shown_with_tag' then
      v_tag := format('Authorised distributor for %s: %s', t.area_name, t.distributor_name);
    end if;
  end if;

  -- 3. Reach (retailers only). Outside his reach: never ex-works.
  if v_line is null and rch.is_limited and not public.region_within(p_region_id, rch.reach_region_id) then
    v_xw_ok := false;
    if v_draft then
      v_line := 'not_on_plan';
      v_msg := 'Saved, not applied on your plan';
    elsif p_buyer_id is not null and public.is_approved_outside_buyer(p_seller_id, p_buyer_id) then
      v_region := rch.home_region_id;
      v_rarea  := rch.home_area_name;
      v_label  := format('%s rate. Delivery to %s: ask seller.', rch.home_area_name, v_area);
    else
      v_line := 'reach_limited';
      v_msg := format('%s shares rates with buyers in %s.', v_store, rch.reach_area_name);
    end if;
  end if;

  -- 4 and 5. The publish: not quoting, nothing published yet, or the rate
  --    and the versions it pinned. A preview uses the current settings.
  if v_draft then
    v_base := p_base_rate;
    v_market := 'preview';
    select ss.base_unit into v_unit from public.seller_segments ss
     where ss.seller_id = p_seller_id and ss.segment_id = p_segment_id;
    select av.id into v_version from public.area_setting_versions av
     where av.seller_id = p_seller_id and av.segment_id = p_segment_id and av.brand_id = v_brand
     order by av.version_number desc limit 1;
    if v_version is null then
      raise exception '%', format('Choose where you sell %s before publishing.', public.brand_line_label(v_brand, p_segment_id));
    end if;
  else
    if p_publish_id is null then
      select * into ms from public.market_status(p_seller_id, p_segment_id, v_at, v_brand);
      v_market := ms.status;
      v_closed := ms.closed_at;
      select st.latest_publish_id into v_pub from public.seller_family_status st
       where st.seller_id = p_seller_id and st.brand_id = v_brand and st.segment_id = p_segment_id;
      if v_line is null and ms.status = 'not_quoting' then
        v_line := 'not_quoting';
        v_msg := 'Not quoting today';
      elsif v_line is null and ms.status = 'not_published' then
        v_line := 'not_published';
        v_msg := 'No rate published yet';
      end if;
    else
      v_pub := p_publish_id;
      v_market := 'past';
    end if;
    if v_pub is not null then
      select pi.base_rate, pi.unit, pi.area_setting_version_id, p.published_at, p.is_correction
        into v_base, v_unit, v_version, v_pub_at, v_corr
        from public.publish_items pi join public.publishes p on p.id = pi.publish_id
       where pi.publish_id = v_pub and p.seller_id = p_seller_id
         and pi.brand_id = v_brand and pi.segment_id = p_segment_id;
      if not found then
        raise exception 'That publish was not found for this seller and product family';
      end if;
    end if;
  end if;

  -- Ex-works: switched on, not stopped above, and for a retailer only on a
  -- paid plan (inside his reach, checked above).
  v_xw := v_xw_ok and xw.is_on and (not rch.is_limited or not rch.plan_is_free);

  for g in
    select p.id, p.name, coalesce(sg.is_selected, false) as selected
      from public.products p
      left join public.seller_grades sg
        on sg.seller_id = p_seller_id and sg.brand_id = v_brand and sg.product_id = p.id
     where p.segment_id = p_segment_id and p.is_active
       and (p_product_id is null or p.id = p_product_id)
     order by p.name
  loop
    a_served := null; a_unit := null; a_diff := null; a_diff_from := null; a_disc := null; a_disc_from := null;
    a_du := null; a_prem := null; a_prem_from := null; a_sold := null;
    x_served := null; x_unit := null; x_disc := null; x_prem := null; x_sold := null;
    d_kind := null; d_flat := null; d_pct := null; d_unit := null;
    e_kind := null; e_flat := null; e_pct := null; e_unit := null;
    v_sf := '{}'; v_pf := '{}';

    -- 6-8. Settings from the versions recorded in that publish (or the
    --      current ones, for a preview), for this grade.
    if v_line is null and g.selected then
      select s.is_served, s.unit, s.area_difference, s.area_difference_from, s.discount_chart_id, s.discount_from,
             s.display_unit, s.grade_premium, s.grade_premium_from, s.grade_sold_here
        into a_served, a_unit, a_diff, a_diff_from, a_disc, a_disc_from, a_du, a_prem, a_prem_from, a_sold
        from public.resolve_area_settings(p_seller_id, p_segment_id, v_region, g.id, v_version, v_brand) s;

      if a_served then
        select coalesce(jsonb_object_agg(sf.size_id::text, jsonb_build_object(
                 'diff', sf.size_difference, 'diff_unit', sf.size_difference_unit,
                 'diff_from', sf.size_difference_from || ', ' || sf.size_difference_chart || ' chart',
                 'load', sf.loading, 'load_unit', sf.loading_unit, 'load_from', sf.loading_from)), '{}')
          into v_sf
          from public.resolve_size_figures(p_seller_id, p_segment_id, v_region, g.id,
                                           case when v_draft then v_version end, v_pub, v_brand) sf;
        if a_disc is not null then
          select dd.kind, dd.flat_amount, dd.percent, cv.unit into d_kind, d_flat, d_pct, d_unit
            from public.chart_versions cv join public.chart_version_discounts dd on dd.version_id = cv.id
           where cv.id = case
             when v_pub is not null then
               (select pcv.chart_version_id from public.publish_chart_versions pcv
                 where pcv.publish_id = v_pub and pcv.brand_id = v_brand
                   and pcv.segment_id = p_segment_id and pcv.chart_id = a_disc)
             else (select x.id from public.chart_versions x where x.chart_id = a_disc
                    order by x.version_number desc limit 1) end;
        end if;
      end if;

      if v_xw then
        select s.is_served, s.unit, s.discount_chart_id, s.grade_premium, s.grade_sold_here
          into x_served, x_unit, x_disc, x_prem, x_sold
          from public.resolve_area_settings(p_seller_id, p_segment_id, xw.plant_region_id, g.id, v_version, v_brand) s;
        if x_served then
          select coalesce(jsonb_object_agg(sf.size_id::text, jsonb_build_object(
                   'diff', sf.size_difference, 'diff_unit', sf.size_difference_unit,
                   'load', sf.loading, 'load_unit', sf.loading_unit)), '{}')
            into v_pf
            from public.resolve_size_figures(p_seller_id, p_segment_id, xw.plant_region_id, g.id,
                                             case when v_draft then v_version end, v_pub, v_brand) sf;
          if x_disc is not null then
            select dd.kind, dd.flat_amount, dd.percent, cv.unit into e_kind, e_flat, e_pct, e_unit
              from public.chart_versions cv join public.chart_version_discounts dd on dd.version_id = cv.id
             where cv.id = case
               when v_pub is not null then
                 (select pcv.chart_version_id from public.publish_chart_versions pcv
                   where pcv.publish_id = v_pub and pcv.brand_id = v_brand
                     and pcv.segment_id = p_segment_id and pcv.chart_id = x_disc)
               else (select x.id from public.chart_versions x where x.chart_id = x_disc
                      order by x.version_number desc limit 1) end;
          end if;
        end if;
      end if;
    end if;

    for z in
      select s.id, s.display_name, coalesce(ss.is_selected, false) as offered
        from public.sizes s
        left join public.seller_sizes ss
          on ss.seller_id = p_seller_id and ss.brand_id = v_brand and ss.size_id = s.id
       where s.segment_id = p_segment_id and s.is_active
         and (p_size_id is null or s.id = p_size_id)
       order by s.sort_order
    loop
      r := null;
      r.region_id := p_region_id;
      r.area_name := v_area;
      r.brand_name := v_bname;
      r.product_id := g.id;
      r.grade := g.name;
      r.size_id := z.id;
      r.size := z.display_name;
      r.tag := v_tag;
      r.pricing_unit := v_unit;
      r.base_rate := v_base;
      r.market := v_market;
      r.closed_at := v_closed;
      r.published_at := v_pub_at;
      r.publish_id := v_pub;
      r.is_correction := v_corr;
      r.missing := '{}';

      if v_line is not null then
        r.status := v_line;
        r.message := v_msg;
      elsif not g.selected or not z.offered then
        r.status := 'not_offered';
        r.message := 'Not offered';
      elsif not a_served then
        r.status := 'not_served';
        r.message := format('Doesn''t currently supply %s', v_rarea);
      elsif not a_sold then
        r.status := 'not_offered';
        r.message := format('%s is not sold in %s', g.name, v_rarea);
      else
        -- 9. Anything that could make the price look cheaper is never
        --    assumed to be zero.
        v_size_diff := public.convert_rate((v_sf -> z.id::text ->> 'diff')::numeric,
                         (v_sf -> z.id::text ->> 'diff_unit')::public.unit, v_unit, z.id);
        v_load := public.convert_rate((v_sf -> z.id::text ->> 'load')::numeric,
                    (v_sf -> z.id::text ->> 'load_unit')::public.unit, v_unit, z.id);
        r.grade_premium := public.convert_rate(a_prem, a_unit, v_unit, z.id);
        r.grade_premium_from := a_prem_from;
        r.size_difference := v_size_diff;
        r.size_difference_from := v_sf -> z.id::text ->> 'diff_from';
        r.loading := v_load;
        r.loading_from := v_sf -> z.id::text ->> 'load_from';
        r.area_difference := public.convert_rate(a_diff, a_unit, v_unit, z.id);
        r.area_difference_from := a_diff_from;

        if a_prem is null then
          r.missing := r.missing || format('Grade premium for %s is not set for %s. If %s is your base grade, enter 0.', g.name, v_rarea, g.name);
        end if;
        if v_size_diff is null then
          r.missing := r.missing || format('Size difference for %s is not set for %s.', z.display_name, v_rarea);
        end if;
        if v_load is null then
          r.missing := r.missing || format('Loading for %s is not set for %s. If you don''t charge loading, enter 0.', z.display_name, v_rarea);
        end if;
        if a_diff is null then
          r.missing := r.missing || format('Area difference is not set for %s. If the price there is your basic rate, enter 0.', v_rarea);
        end if;

        if cardinality(r.missing) > 0 then
          r.status := 'missing';
          r.message := 'Rate not available';
        else
          r.status := 'priced';
          r.display_unit := coalesce(a_du, v_unit);
          r.area_rate_label := coalesce(v_label,
            case when v_region is null then 'Rate everywhere' else v_rarea || ' rate' end);
          v_exact := public.convert_rate(v_base + r.grade_premium + v_size_diff + v_load + r.area_difference,
                                         v_unit, r.display_unit, z.id);
          r.area_rate := round(v_exact, 2);
          r.area_rate_text := public.format_rupees(r.area_rate) || '/' || r.display_unit;
          if d_kind = 'flat' then
            r.discount := format('%s per %s', public.format_rupees(d_flat), d_unit);
            v_dexact := public.convert_rate(d_flat, d_unit, r.display_unit, z.id);
          elsif d_kind = 'percent' then
            r.discount := trim_scale(d_pct) || '%';
            v_dexact := v_exact * d_pct / 100;
          else
            v_dexact := null;
          end if;
          r.discount_from := case when d_kind is not null then a_disc_from end;
          if v_dexact is not null then
            r.area_discount := round(v_dexact, 2);
            r.area_discount_text := case when d_kind = 'percent'
              then format('less %s (%s/%s)', r.discount, public.format_rupees(r.area_discount), r.display_unit)
              else format('less %s/%s', public.format_rupees(r.area_discount), r.display_unit) end;
          end if;
        end if;
      end if;

      -- Ex-works, where switched on: beside a priced area rate, or alone in
      -- an area he doesn't serve.
      if v_xw and r.status in ('priced', 'not_served') then
        r.display_unit := coalesce(r.display_unit, v_unit);
        r.ex_works_label := 'Ex-' || xw.plant_name;
        v_xmiss := '{}';
        if not coalesce(x_served, false) then
          v_xmiss := v_xmiss || format('Ex-works needs your settings to cover %s, your plant city.', xw.plant_name);
        elsif x_sold then
          v_xsize := public.convert_rate((v_pf -> z.id::text ->> 'diff')::numeric,
                       (v_pf -> z.id::text ->> 'diff_unit')::public.unit, v_unit, z.id);
          v_xload := public.convert_rate((v_pf -> z.id::text ->> 'load')::numeric,
                       (v_pf -> z.id::text ->> 'load_unit')::public.unit, v_unit, z.id);
          r.ex_works_grade_premium := public.convert_rate(x_prem, x_unit, v_unit, z.id);
          r.ex_works_size_difference := v_xsize;
          r.ex_works_loading := v_xload;
          if x_prem is null then
            v_xmiss := v_xmiss || format('Ex-works: grade premium for %s is not set for %s.', g.name, xw.plant_name);
          end if;
          if v_xsize is null then
            v_xmiss := v_xmiss || format('Ex-works: size difference for %s is not set for %s.', z.display_name, xw.plant_name);
          end if;
          if v_xload is null then
            v_xmiss := v_xmiss || format('Ex-works: loading for %s is not set for %s.', z.display_name, xw.plant_name);
          end if;
          if cardinality(v_xmiss) = 0 then
            v_exact := public.convert_rate(v_base + r.ex_works_grade_premium + v_xsize + v_xload,
                                           v_unit, r.display_unit, z.id);
            r.ex_works_rate := round(v_exact, 2);
            r.ex_works_text := public.format_rupees(r.ex_works_rate) || '/' || r.display_unit;
            v_dexact := case e_kind when 'flat' then public.convert_rate(e_flat, e_unit, r.display_unit, z.id)
                                    when 'percent' then v_exact * e_pct / 100 end;
            if v_dexact is not null then
              r.ex_works_discount := round(v_dexact, 2);
              r.ex_works_discount_text := case when e_kind = 'percent'
                then format('less %s%% (%s/%s)', trim_scale(e_pct), public.format_rupees(r.ex_works_discount), r.display_unit)
                else format('less %s/%s', public.format_rupees(r.ex_works_discount), r.display_unit) end;
            end if;
          end if;
        end if;
        r.missing := r.missing || v_xmiss;
        -- No figure, no label: a buyer never sees an empty ex-works line.
        if r.ex_works_rate is null then
          r.ex_works_label := null;
        end if;
      end if;

      return next r;
    end loop;
  end loop;
end;
$$;

-- The buyer's answer. In Phase 1 so far, only the seller himself and
-- admins can ask (to see exactly what a buyer would see); buyers come with
-- subscriptions. Never contains the basic rate or any individual difference.
create function public.buyer_rate(
  p_seller_id   uuid,
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_size_id     uuid default null,
  p_buyer_id    uuid default null,
  p_publish_id  uuid default null,
  p_at          timestamptz default null
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
    raise exception 'Only the seller and ALEE can see these rates for now.';
  end if;
  return query
  select e.brand_name, e.product_id, e.grade, e.size_id, e.size, e.status, e.message, e.tag,
         e.display_unit, e.area_rate, e.area_rate_label, e.area_rate_text, e.area_discount, e.area_discount_text,
         e.ex_works_rate, e.ex_works_label, e.ex_works_text, e.ex_works_discount, e.ex_works_discount_text,
         e.market, e.closed_at, e.published_at, e.is_correction
    from public.rate_engine(p_seller_id, p_brand_id, p_segment_id, p_region_id, p_product_id, p_size_id,
                            p_buyer_id, p_publish_id, null, p_at) e;
end;
$$;

-- The seller's answer: every component and where it came from. For the
-- seller himself and admins only.
create function public.seller_rate(
  p_seller_id   uuid,
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_region_id   uuid,
  p_product_id  uuid default null,
  p_size_id     uuid default null,
  p_buyer_id    uuid default null,
  p_publish_id  uuid default null,
  p_at          timestamptz default null
)
returns setof public.rate_line
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or (auth.uid() <> p_seller_id and not public.is_admin()) then
    raise exception 'You can only see the breakdown of your own rates.';
  end if;
  return query
  select * from public.rate_engine(p_seller_id, p_brand_id, p_segment_id, p_region_id, p_product_id, p_size_id,
                                   p_buyer_id, p_publish_id, null, p_at);
end;
$$;

-- The seller's preview, for one brand line: every area in his current
-- setup (and "everywhere", if he set it), every grade and size, worked out
-- with a basic rate (default: his latest published one) and his current
-- settings. The publish confirmation uses this.
create function public.rate_preview(
  p_brand_id    uuid,
  p_segment_id  uuid,
  p_base_rate   numeric default null,
  p_seller_id   uuid default null
)
returns setof public.rate_line
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_seller  uuid := coalesce(p_seller_id, auth.uid());
  v_brand   uuid := public.require_brand(p_brand_id);
  v_base    numeric := p_base_rate;
  v_version uuid;
begin
  if auth.uid() is null or (v_seller <> auth.uid() and not public.is_admin()) then
    raise exception 'You can only preview your own rates.';
  end if;
  if v_base is null then
    select pi.base_rate into v_base
      from public.seller_family_status st
      join public.publish_items pi on pi.publish_id = st.latest_publish_id
                                  and pi.brand_id = st.brand_id and pi.segment_id = st.segment_id
      join public.seller_segments ss on ss.seller_id = st.seller_id and ss.segment_id = st.segment_id
     where st.seller_id = v_seller and st.brand_id = v_brand and st.segment_id = p_segment_id
       and pi.unit = ss.base_unit;
  end if;
  if v_base is null then
    raise exception '%', format('Enter your basic rate for %s.', public.brand_line_label(v_brand, p_segment_id));
  end if;
  select av.id into v_version from public.area_setting_versions av
   where av.seller_id = v_seller and av.segment_id = p_segment_id and av.brand_id = v_brand
   order by av.version_number desc limit 1;
  if v_version is null then
    raise exception '%', format('Choose where you sell %s before publishing.', public.brand_line_label(v_brand, p_segment_id));
  end if;

  return query
  select e.*
    from (select s.region_id,
                 case when s.region_id is null then 0
                      else array_position(array['state', 'district', 'taluka', 'city'], rg.level::text) end as lvl,
                 coalesce(rg.name, '') as nm
            from public.area_settings s
            left join public.regions rg on rg.id = s.region_id
           where s.version_id = v_version) areas
    cross join lateral public.rate_engine(v_seller, v_brand, p_segment_id, areas.region_id,
                                          null, null, null, null, v_base, null) e
   order by areas.lvl, areas.nm;
end;
$$;

revoke execute on function public.rate_engine(uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, numeric, timestamptz)
  from public, anon, authenticated;
-- Visitors may call buyer_rate only to be told "Log in to see rates."
revoke execute on function public.buyer_rate(uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, timestamptz) from public;
revoke execute on function public.seller_rate(uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, timestamptz) from public, anon;
revoke execute on function public.rate_preview(uuid, uuid, numeric, uuid) from public, anon;
grant execute on function public.buyer_rate(uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, timestamptz) to anon, authenticated;
grant execute on function public.seller_rate(uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, timestamptz) to authenticated;
grant execute on function public.rate_preview(uuid, uuid, numeric, uuid) to authenticated;
