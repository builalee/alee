-- ============================================================
-- OBJECTIVE:      Record which product families each seller deals in, and
--                 whether he prices each one per tonne or per kg.
-- WHY:            Buyers find sellers by product, and a seller's base rate
--                 for a segment is in the unit he chose here. The unit
--                 starts as the segment's catalogue default.
-- CHANGES:        New table public.seller_segments.
-- DEPENDS ON:     20261017050059_create_seller_profiles.
--                 20261017050159_segments_default_unit.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the table. Every seller's list of
--                 segments would be lost.
-- TESTED:         On alee-dev 2026-10-17 (rehearsed in a rolled-back transaction with
--                 temporary logins, then applied; 61 checks passed).
--                 RLS enabled. Visitors can read it. Unit defaults to the
--                 segment's (tonne); per kg can be chosen; per piece is
--                 refused; a switched-off segment cannot be added. Ordinary
--                 users cannot add to or change another seller's list;
--                 admin can. Deleting the login removes it.
-- DATE:           2026-10-17
-- ============================================================

create table public.seller_segments (
  seller_id   uuid not null references public.seller_profiles (account_id) on delete cascade,
  segment_id  uuid not null references public.segments (id),
  -- Unit this seller prices the segment in. Filled from the segment's
  -- default when not given.
  base_unit   public.unit not null check (base_unit in ('tonne', 'kg')),
  -- A seller who stops dealing in a segment is deactivated, not deleted.
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (seller_id, segment_id)
);

comment on table public.seller_segments is
  'Segments each seller deals in, with his pricing unit. Public. Deactivated, not deleted.';

-- Finding sellers by product family.
create index seller_segments_segment_idx
  on public.seller_segments (segment_id, seller_id) where is_active;

-- Fills the unit from the catalogue default and refuses inactive segments.
create function public.seller_segments_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  seg record;
begin
  select s.is_active, s.default_base_unit into seg
    from public.segments s
   where s.id = new.segment_id;

  if not found or not seg.is_active then
    raise exception 'This product family is not available';
  end if;

  if new.base_unit is null then
    new.base_unit := seg.default_base_unit;
  end if;

  return new;
end;
$$;

create trigger seller_segments_before_insert
  before insert on public.seller_segments
  for each row execute function public.seller_segments_before_insert();

create trigger seller_segments_set_updated_at
  before update on public.seller_segments
  for each row execute function public.set_updated_at();

-- Removed only when the whole account is deleted.
create trigger seller_segments_prevent_direct_delete
  before delete on public.seller_segments
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------

alter table public.seller_segments enable row level security;

create policy "Anyone can read active seller segments"
  on public.seller_segments for select
  to anon, authenticated
  using (is_active);

create policy "Sellers and admins read all of a seller's segments"
  on public.seller_segments for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Sellers add their own segments; admins add any"
  on public.seller_segments for insert
  to authenticated
  with check (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Sellers change their own segments; admins change any"
  on public.seller_segments for update
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()))
  with check (seller_id = (select auth.uid()) or (select public.is_admin()));

-- No DELETE grant.
grant select on public.seller_segments to anon, authenticated;
grant insert, update on public.seller_segments to authenticated;
