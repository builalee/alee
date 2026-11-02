-- ============================================================
-- OBJECTIVE:      Store buyers' enquiries to sellers, and give each seller
--                 the list of enquiries he received.
-- WHY:            Owner decisions (docs/decisions.md 2.31, 16.1, 16.10, and
--                 the enquiry decision in section 1): a buyer may hide his
--                 name, and the seller then sees area, buyer type and
--                 activity; an enquiry from a Type B area goes to the
--                 authorised distributor; one sent after the market closed is
--                 marked "received after close"; Send counts once even if
--                 tapped twice.
-- CHANGES:        New table public.enquiries. New functions
--                 public.send_enquiry, public.received_enquiries.
-- DEPENDS ON:     20261102100100_approved_distributors_only (territory),
--                 20261017131658_brands_required (market_status).
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the two functions and the table. Every
--                 enquiry would be lost.
-- TESTED:         On alee-dev 2026-11-02: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass, including
--                 tests/database/enquiries.sql.
-- DATE:           2026-11-02
-- ============================================================

create table public.enquiries (
  id                    uuid primary key default gen_random_uuid(),
  buyer_id              uuid not null references public.accounts (id) on delete cascade,
  -- Whose rate or profile the buyer enquired from.
  seller_id             uuid not null references public.seller_profiles (account_id) on delete cascade,
  -- Who receives it: the seller, or the authorised distributor in a Type B area.
  recipient_id          uuid not null references public.seller_profiles (account_id) on delete cascade,
  brand_id              uuid not null references public.brands (id),
  segment_id            uuid not null references public.segments (id),
  -- The buyer's area when he sent it.
  region_id             uuid not null references public.regions (id),
  product_id            uuid references public.products (id),
  size_id               uuid references public.sizes (id),
  quantity              numeric check (quantity > 0),
  quantity_unit         public.unit,
  note                  text check (length(note) <= 1000),
  show_identity         boolean not null,
  received_after_close  boolean not null,
  request_key           uuid not null,
  created_at            timestamptz not null default clock_timestamp(),
  check ((quantity is null) = (quantity_unit is null))
);

comment on table public.enquiries is
  'A buyer''s enquiry to a seller, as sent. Never changed or deleted; it leaves only with the buyer''s account.';

create unique index enquiries_one_per_request on public.enquiries (buyer_id, request_key);
create index enquiries_by_recipient on public.enquiries (recipient_id, created_at desc);
create index enquiries_by_buyer on public.enquiries (buyer_id, created_at desc);

create trigger enquiries_prevent_update
  before update on public.enquiries
  for each row execute function public.prevent_update();
create trigger enquiries_prevent_direct_delete
  before delete on public.enquiries
  for each row execute function public.prevent_direct_delete();

-- A buyer sends an enquiry about one brand line of a seller. The same request
-- key again gives back the enquiry already sent.
create function public.send_enquiry(
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

  -- A Type B area's enquiries go to the authorised distributor.
  select * into t from public.territory_effect(p_seller_id, p_brand_id, p_segment_id, v_region);
  if t.effect = 'shown_with_tag' then
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

-- What a seller sees of the enquiries he received. A buyer who hid his name
-- shows only his area, his type and how many enquiries he sent in the last
-- 30 days.
create function public.received_enquiries()
returns table (
  id                    uuid,
  created_at            timestamptz,
  brand_name            text,
  grade                 text,
  size                  text,
  quantity              numeric,
  quantity_unit         public.unit,
  note                  text,
  area_name             text,
  received_after_close  boolean,
  via_seller            text,
  buyer_name            text,
  buyer_phone           text,
  buyer_type            public.account_role,
  buyer_recent          bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, e.created_at, public.brand_line_label(e.brand_id, e.segment_id), p.name, z.display_name,
         e.quantity, e.quantity_unit, e.note, r.name, e.received_after_close,
         case when e.seller_id <> e.recipient_id then sp.store_name end,
         case when e.show_identity then coalesce(nullif(a.firm_name, '') || ' (' || a.full_name || ')', a.full_name) end,
         case when e.show_identity then a.phone end,
         public.approved_role(e.buyer_id),
         (select count(*) from public.enquiries x
           where x.buyer_id = e.buyer_id and x.created_at > clock_timestamp() - interval '30 days')
    from public.enquiries e
    join public.accounts a on a.id = e.buyer_id
    join public.regions r on r.id = e.region_id
    join public.seller_profiles sp on sp.account_id = e.seller_id
    left join public.products p on p.id = e.product_id
    left join public.sizes z on z.id = e.size_id
   where e.recipient_id = auth.uid()
   order by e.created_at desc;
$$;

-- Access ---------------------------------------------------------------------
-- The buyer sees what he sent, and admins see all. A seller sees what he
-- received only through received_enquiries, so a hidden name stays hidden.

alter table public.enquiries enable row level security;

create policy "Buyers see the enquiries they sent; admins see all"
  on public.enquiries for select to authenticated
  using (buyer_id = (select auth.uid()) or (select public.is_admin()));

grant select on public.enquiries to authenticated;

revoke execute on function public.send_enquiry(uuid, uuid, uuid, uuid, uuid, uuid, numeric, public.unit, text, boolean) from public, anon;
revoke execute on function public.received_enquiries() from public, anon;
grant execute on function public.send_enquiry(uuid, uuid, uuid, uuid, uuid, uuid, numeric, public.unit, text, boolean) to authenticated;
grant execute on function public.received_enquiries() to authenticated;
