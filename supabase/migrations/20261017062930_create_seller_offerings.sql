-- ============================================================
-- OBJECTIVE:      Let each seller choose, within each product family he
--                 deals in, which grades and which sizes he sells. Nothing
--                 is selected by default. Every change is kept as history.
-- WHY:            Owner decision 2026-10-17 (docs/decisions.md 2.17). A
--                 grade or size the seller has not selected is "not offered"
--                 to his buyers. Sizes switched on in the catalogue later
--                 start unselected for every seller.
-- CHANGES:        New tables public.seller_grades, public.seller_sizes
--                 (current choice per grade / size) and
--                 public.seller_offering_history (every change, add-only).
--                 New function public.select_all_in_family(...).
-- DEPENDS ON:     20261017050259_create_seller_segments.
--                 20261009155938_sizes_belong_to_segment.
--                 20261017055742_create_chart_versions (prevent_update()).
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the three tables and the function.
--                 Every seller's selections and their history would be lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; all saved checks (npm run check:db) pass.
--                 tests/database/offerings.sql: nothing selected by default;
--                 select one, select all, unselect; only active items in a
--                 family the seller deals in; unselecting keeps the row;
--                 history records each change and who made it, and cannot be
--                 written, changed or deleted; a size switched on later starts
--                 unselected; another seller changes and sees nothing.
-- DATE:           2026-10-17
-- ============================================================

-- A missing row means "not selected". Unselecting sets is_selected = false;
-- rows are never deleted.
create table public.seller_grades (
  seller_id    uuid not null references public.seller_profiles (account_id) on delete cascade,
  product_id   uuid not null references public.products (id),
  is_selected  boolean not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (seller_id, product_id)
);

create table public.seller_sizes (
  seller_id    uuid not null references public.seller_profiles (account_id) on delete cascade,
  size_id      uuid not null references public.sizes (id),
  is_selected  boolean not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (seller_id, size_id)
);

comment on table public.seller_grades is
  'Grades a seller sells. No row or is_selected = false means not offered. Never deleted.';
comment on table public.seller_sizes is
  'Sizes a seller sells. No row or is_selected = false means not offered. Never deleted.';

create index seller_grades_product_idx on public.seller_grades (product_id) where is_selected;
create index seller_sizes_size_idx on public.seller_sizes (size_id) where is_selected;

-- Every selection change, oldest first. Written only by the trigger below.
create table public.seller_offering_history (
  id           uuid primary key default gen_random_uuid(),
  seller_id    uuid not null references public.seller_profiles (account_id) on delete cascade,
  product_id   uuid references public.products (id),
  size_id      uuid references public.sizes (id),
  is_selected  boolean not null,
  changed_at   timestamptz not null default now(),
  -- Who made the change: the seller, or an admin setting him up.
  changed_by   uuid,
  constraint seller_offering_history_one_item
    check ((product_id is null) <> (size_id is null))
);

comment on table public.seller_offering_history is
  'Every change to what a seller offers. Add-only; never changed or deleted.';

create index seller_offering_history_seller_idx
  on public.seller_offering_history (seller_id, changed_at);

-- Rules ---------------------------------------------------------------------

-- A seller can select only an active grade or size, in a product family he
-- currently deals in. Unselecting is always allowed.
create function public.seller_offerings_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_segment  uuid;
  v_active   boolean;
begin
  if tg_op = 'UPDATE' and new.seller_id <> old.seller_id then
    raise exception 'A selection cannot be moved to another seller';
  end if;

  if tg_table_name = 'seller_grades' then
    if tg_op = 'UPDATE' and new.product_id <> old.product_id then
      raise exception 'A selection cannot be moved to another grade';
    end if;
    select p.segment_id, p.is_active into v_segment, v_active
      from public.products p where p.id = new.product_id;
  else
    if tg_op = 'UPDATE' and new.size_id <> old.size_id then
      raise exception 'A selection cannot be moved to another size';
    end if;
    select s.segment_id, s.is_active into v_segment, v_active
      from public.sizes s where s.id = new.size_id;
  end if;

  if new.is_selected then
    -- A switched-off grade or size is invisible to sellers, so "not found"
    -- also means switched off.
    if v_segment is null or not v_active then
      raise exception 'This grade or size is switched off in the catalogue';
    end if;
    if not exists (
      select 1 from public.seller_segments ss
       where ss.seller_id = new.seller_id and ss.segment_id = v_segment and ss.is_active
    ) then
      raise exception 'Add this product family to the seller first';
    end if;
  end if;

  return new;
end;
$$;

create trigger seller_grades_before_write
  before insert or update on public.seller_grades
  for each row execute function public.seller_offerings_before_write();
create trigger seller_sizes_before_write
  before insert or update on public.seller_sizes
  for each row execute function public.seller_offerings_before_write();

create trigger seller_grades_set_updated_at
  before update on public.seller_grades
  for each row execute function public.set_updated_at();
create trigger seller_sizes_set_updated_at
  before update on public.seller_sizes
  for each row execute function public.set_updated_at();

-- Records every real change in the history. Runs with owner rights because
-- nobody may write the history table directly.
create function public.seller_offerings_record_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.is_selected = old.is_selected then
    return null;
  end if;

  -- clock_timestamp: the real moment of each change, so several changes
  -- in one save keep their order.
  if tg_table_name = 'seller_grades' then
    insert into public.seller_offering_history (seller_id, product_id, is_selected, changed_at, changed_by)
    values (new.seller_id, new.product_id, new.is_selected, clock_timestamp(), auth.uid());
  else
    insert into public.seller_offering_history (seller_id, size_id, is_selected, changed_at, changed_by)
    values (new.seller_id, new.size_id, new.is_selected, clock_timestamp(), auth.uid());
  end if;
  return null;
end;
$$;

create trigger seller_grades_record_history
  after insert or update on public.seller_grades
  for each row execute function public.seller_offerings_record_history();
create trigger seller_sizes_record_history
  after insert or update on public.seller_sizes
  for each row execute function public.seller_offerings_record_history();

-- Never deleted; removed only when the seller's whole account is deleted.
create trigger seller_grades_prevent_direct_delete
  before delete on public.seller_grades
  for each row execute function public.prevent_direct_delete();
create trigger seller_sizes_prevent_direct_delete
  before delete on public.seller_sizes
  for each row execute function public.prevent_direct_delete();
create trigger seller_offering_history_prevent_direct_delete
  before delete on public.seller_offering_history
  for each row execute function public.prevent_direct_delete();
create trigger seller_offering_history_prevent_update
  before update on public.seller_offering_history
  for each row execute function public.prevent_update();

-- Row Level Security --------------------------------------------------------

alter table public.seller_grades enable row level security;
alter table public.seller_sizes enable row level security;
alter table public.seller_offering_history enable row level security;

-- What a seller offers is public, like his product families.
create policy "Anyone can read what sellers offer"
  on public.seller_grades for select
  to anon, authenticated
  using (is_selected);
create policy "Sellers and admins read all of a seller's grade choices"
  on public.seller_grades for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));
create policy "Sellers choose their own grades; admins choose for any seller"
  on public.seller_grades for insert
  to authenticated
  with check (seller_id = (select auth.uid()) or (select public.is_admin()));
create policy "Sellers change their own grade choices; admins change any"
  on public.seller_grades for update
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()))
  with check (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Anyone can read what sellers offer"
  on public.seller_sizes for select
  to anon, authenticated
  using (is_selected);
create policy "Sellers and admins read all of a seller's size choices"
  on public.seller_sizes for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));
create policy "Sellers choose their own sizes; admins choose for any seller"
  on public.seller_sizes for insert
  to authenticated
  with check (seller_id = (select auth.uid()) or (select public.is_admin()));
create policy "Sellers change their own size choices; admins change any"
  on public.seller_sizes for update
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()))
  with check (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Sellers read their own history; admins read all"
  on public.seller_offering_history for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

grant select on public.seller_grades, public.seller_sizes to anon, authenticated;
grant insert, update on public.seller_grades, public.seller_sizes to authenticated;
grant select on public.seller_offering_history to authenticated;

-- Select all / unselect all ---------------------------------------------------

-- Selects (or unselects) every grade or every size of one product family
-- for a seller, and returns how many choices changed. "Select all" covers
-- what is switched on in the catalogue now; sizes switched on later start
-- unselected. Runs with the caller's rights, so the same rules apply as
-- choosing one by one.
create function public.select_all_in_family(
  p_segment_id  uuid,
  p_what        text,
  p_selected    boolean default true,
  p_seller_id   uuid default null
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_seller   uuid := coalesce(p_seller_id, auth.uid());
  v_changed  integer;
begin
  if p_what = 'grades' then
    if p_selected then
      insert into public.seller_grades (seller_id, product_id, is_selected)
      select v_seller, p.id, true
        from public.products p where p.segment_id = p_segment_id and p.is_active
      on conflict (seller_id, product_id) do update set is_selected = true
        where public.seller_grades.is_selected is distinct from true;
    else
      update public.seller_grades g set is_selected = false
        from public.products p
       where p.id = g.product_id and p.segment_id = p_segment_id
         and g.seller_id = v_seller and g.is_selected;
    end if;
  elsif p_what = 'sizes' then
    if p_selected then
      insert into public.seller_sizes (seller_id, size_id, is_selected)
      select v_seller, s.id, true
        from public.sizes s where s.segment_id = p_segment_id and s.is_active
      on conflict (seller_id, size_id) do update set is_selected = true
        where public.seller_sizes.is_selected is distinct from true;
    else
      update public.seller_sizes z set is_selected = false
        from public.sizes s
       where s.id = z.size_id and s.segment_id = p_segment_id
         and z.seller_id = v_seller and z.is_selected;
    end if;
  else
    raise exception 'Choose "grades" or "sizes"';
  end if;

  get diagnostics v_changed = row_count;
  return v_changed;
end;
$$;

revoke execute on function public.select_all_in_family(uuid, text, boolean, uuid) from public, anon;
grant execute on function public.select_all_in_family(uuid, text, boolean, uuid) to authenticated;
