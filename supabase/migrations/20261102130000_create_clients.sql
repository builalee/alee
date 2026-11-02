-- ============================================================
-- OBJECTIVE:      The client book: each seller's own private list of his
--                 customers, who need not be on ALEE.
-- WHY:            Decisions 11.1 and 14.4, and the demo's Stage 4: name,
--                 phone, area, type (distributor, dealer, builder, retailer)
--                 and a private note; add, edit and search. One fixed ID per
--                 customer. Private to the seller: not even admins read it
--                 (CLAUDE.md sections 12 and 13). The customer limit is not
--                 enforced in the demo (owner, Stage 4 plan).
-- CHANGES:        New type public.client_type. New table public.clients.
-- DEPENDS ON:     20261017045859_create_accounts, 20261005164142_create_regions.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the table and the type. Every customer
--                 entered would be lost.
-- TESTED:         On alee-dev 2026-11-02: rehearsed in a rolled-back
--                 transaction, then applied; all saved checks pass, including
--                 tests/database/client_book.sql.
-- DATE:           2026-11-02
-- ============================================================

create type public.client_type as enum ('distributor', 'dealer', 'builder', 'retailer');

create table public.clients (
  id           uuid primary key default gen_random_uuid(),
  -- Whose client book this customer is in.
  seller_id    uuid not null references public.accounts (id) on delete cascade,
  name         text not null check (btrim(name) <> '' and length(name) <= 100),
  -- Indian mobile in +91 form, if he has one.
  phone        text check (phone ~ '^\+91[6-9][0-9]{9}$'),
  region_id    uuid references public.regions (id),
  client_type  public.client_type,
  -- Private to the seller. Never feeds any ALEE data (CLAUDE.md section 13).
  note         text check (length(note) <= 2000),
  created_at   timestamptz not null default clock_timestamp(),
  -- Lets follow-ups and activities prove their customer is the same seller's.
  unique (id, seller_id)
);

comment on table public.clients is
  'A seller''s own customers. Private to him; removed only with his account.';

-- One customer per phone in a seller's book, so the same person isn't entered twice.
create unique index clients_one_per_phone on public.clients (seller_id, phone) where phone is not null;
create index clients_by_seller_name on public.clients (seller_id, lower(name));

create trigger clients_prevent_direct_delete
  before delete on public.clients
  for each row execute function public.prevent_direct_delete();

-- Access ---------------------------------------------------------------------
-- Only the seller himself reads, adds and edits his customers. Admins don't.

alter table public.clients enable row level security;

create policy "Sellers read their own customers"
  on public.clients for select to authenticated
  using (seller_id = (select auth.uid()));

create policy "Sellers add customers to their own book"
  on public.clients for insert to authenticated
  with check (seller_id = (select auth.uid()));

create policy "Sellers edit their own customers"
  on public.clients for update to authenticated
  using (seller_id = (select auth.uid()))
  with check (seller_id = (select auth.uid()));

grant select on public.clients to authenticated;
grant insert (seller_id, name, phone, region_id, client_type, note) on public.clients to authenticated;
grant update (name, phone, region_id, client_type, note) on public.clients to authenticated;
