-- ============================================================
-- OBJECTIVE:      In a Type A area, an enquiry sent from the manufacturer's
--                 profile goes to the appointed distributor, as it already
--                 does in a Type B area.
-- WHY:            Owner decision 16.11 (2026-11-02): in a Type A district the
--                 distributor sets the price, so he receives the enquiry,
--                 marked "via [manufacturer] profile".
-- CHANGES:        Replaces public.send_enquiry (same inputs and output).
-- DEPENDS ON:     20261102110200_create_enquiries.
-- TOUCHES EXISTING DATA: No. Enquiries already sent keep their receiver.
-- REVERSIBLE:     Yes, by restoring the earlier send_enquiry. No data lost.
-- TESTED:         On alee-dev 2026-11-02: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass, including
--                 the new Type A checks in tests/database/enquiries.sql.
-- DATE:           2026-11-02
-- ============================================================

create or replace function public.send_enquiry(
  p_seller_id      uuid,
  p_brand_id       uuid,
  p_segment_id     uuid,
  p_request_key    uuid,
  p_product_id     uuid default null,
  p_size_id        uuid default null,
  p_quantity       numeric default null,
  p_quantity_unit  public.unit default null,
  p_note           text default null,
  p_show_identity  boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id         uuid;
  v_region     uuid;
  v_recipient  uuid := p_seller_id;
  t            record;
begin
  if auth.uid() is null then
    raise exception 'Log in to send an enquiry.' using errcode = '42501';
  end if;
  select a.region_id into v_region from public.accounts a where a.id = auth.uid();
  if v_region is null then
    raise exception 'Create your account first.';
  end if;
  if p_request_key is null then
    raise exception 'Send the enquiry again from the form.';
  end if;

  perform pg_advisory_xact_lock(hashtext('enquiry:' || auth.uid()::text));
  select e.id into v_id from public.enquiries e where e.buyer_id = auth.uid() and e.request_key = p_request_key;
  if v_id is not null then
    return v_id;
  end if;

  if p_seller_id = auth.uid() then
    raise exception 'You cannot send an enquiry to yourself.';
  end if;
  if not exists (select 1 from public.seller_brands sb
                  where sb.seller_id = p_seller_id and sb.brand_id = p_brand_id
                    and sb.segment_id = p_segment_id and sb.is_active) then
    raise exception 'This seller doesn''t sell that brand.';
  end if;
  if p_product_id is not null and not exists (
       select 1 from public.products p where p.id = p_product_id and p.segment_id = p_segment_id) then
    raise exception 'That grade is not in this product family.';
  end if;
  if p_size_id is not null and not exists (
       select 1 from public.sizes z where z.id = p_size_id and z.segment_id = p_segment_id) then
    raise exception 'That size is not in this product family.';
  end if;
  if p_quantity is not null and p_quantity <= 0 then
    raise exception 'Enter a quantity above zero, or leave it empty.';
  end if;
  if length(p_note) > 1000 then
    raise exception 'Keep the note under 1,000 letters.';
  end if;

  -- In a Type A or Type B area, enquiries go to the appointed distributor
  -- (decisions 2.36 and 16.11).
  select * into t from public.territory_effect(p_seller_id, p_brand_id, p_segment_id, v_region);
  if t.effect in ('shown_with_tag', 'pointed_to_distributor') then
    v_recipient := t.distributor_id;
  end if;

  insert into public.enquiries (buyer_id, seller_id, recipient_id, brand_id, segment_id, region_id,
                                product_id, size_id, quantity, quantity_unit, note, show_identity,
                                received_after_close, request_key)
  values (auth.uid(), p_seller_id, v_recipient, p_brand_id, p_segment_id, v_region,
          p_product_id, p_size_id, p_quantity,
          case when p_quantity is not null then coalesce(p_quantity_unit, 'tonne') end,
          nullif(btrim(p_note), ''), coalesce(p_show_identity, true),
          coalesce((select m.status = 'closed'
                      from public.market_status(p_seller_id, p_segment_id, null, p_brand_id) m), false),
          p_request_key)
  returning id into v_id;
  return v_id;
end;
$$;
