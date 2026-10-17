-- ============================================================
-- OBJECTIVE:      Create the charts table: a named size, loading or
--                 discount chart belonging to one seller and one product
--                 family, or to ALEE as a template.
-- WHY:            Sellers keep size differences, loading and trade discount
--                 in named charts, and may hold several of each (owner
--                 decisions 2.4, 2.5). Charts are never deleted; one that a
--                 publish has used can be switched off only by naming a
--                 replacement, so history always leads somewhere.
-- CHANGES:        New enum public.chart_type (size, loading, discount).
--                 New table public.charts. The figures live in versions
--                 (next migration).
-- DEPENDS ON:     20261017050059_create_seller_profiles.
--                 20261009155105_create_segments.
-- TOUCHES EXISTING DATA: No.
-- REVERSIBLE:     Yes, by dropping the table and enum. Every chart would be
--                 lost.
-- TESTED:         On alee-dev 2026-10-17: rehearsed in a rolled-back transaction, then
--                 applied; saved checks in tests/database/charts.sql (105) pass.
--                 RLS on. A seller sees and changes only his own charts;
--                 another seller gets nothing back and changes nothing;
--                 visitors are refused. Owner, family, type and origin
--                 cannot change. Only the publish engine marks a chart used;
--                 a used chart is switched off only with a valid
--                 replacement. No one can delete a chart on its own.
-- DATE:           2026-10-17
-- ============================================================

create type public.chart_type as enum ('size', 'loading', 'discount');

create table public.charts (
  id                       uuid primary key default gen_random_uuid(),
  -- The seller who owns the chart. Empty for an ALEE template.
  seller_id                uuid references public.seller_profiles (account_id) on delete cascade,
  is_template              boolean not null default false,
  segment_id               uuid not null references public.segments (id),
  chart_type               public.chart_type not null,
  name                     text not null check (length(btrim(name)) > 0),
  -- For a seller's chart copied from a template: which template. For
  -- information only; the copy is fully separate.
  copied_from_template_id  uuid references public.charts (id),
  -- When a publish first used this chart. Set only by the publish engine
  -- (server side), never through the app, and never cleared.
  in_use_since             timestamptz,
  -- For a switched-off chart: the chart that replaced it.
  replaced_by_id           uuid references public.charts (id),
  is_active                boolean not null default true,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint charts_template_has_no_seller
    check (is_template = (seller_id is null)),
  constraint charts_template_is_not_a_copy
    check (not is_template or copied_from_template_id is null),
  constraint charts_template_never_in_use
    check (not is_template or in_use_since is null),
  constraint charts_not_replaced_by_self
    check (replaced_by_id is null or replaced_by_id <> id),
  constraint charts_only_inactive_are_replaced
    check (replaced_by_id is null or not is_active)
);

comment on table public.charts is
  'Size, loading or discount charts, per seller and product family, or ALEE templates. Never deleted. Figures live in chart_versions.';
comment on column public.charts.in_use_since is
  'When a publish first used this chart. Set only by the publish engine; once set, the chart can be switched off only with a replacement.';
comment on column public.charts.copied_from_template_id is
  'Template this chart was copied from. Information only: the copy is fully separate.';

-- No two active charts of the same seller, family and type share a name
-- (templates count as one owner).
create unique index charts_active_name_key
  on public.charts (seller_id, segment_id, chart_type, lower(name)) nulls not distinct
  where is_active;

create index charts_seller_idx on public.charts (seller_id, segment_id, chart_type);
create index charts_templates_idx on public.charts (segment_id, chart_type) where is_template;
create index charts_copied_from_idx on public.charts (copied_from_template_id)
  where copied_from_template_id is not null;
create index charts_replaced_by_idx on public.charts (replaced_by_id)
  where replaced_by_id is not null;

-- Rules that RLS cannot express ---------------------------------------------

create function public.charts_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  src record;
  rep record;
begin
  new.name := btrim(new.name);

  if tg_op = 'INSERT' then
    if not exists (select 1 from public.segments s where s.id = new.segment_id and s.is_active) then
      raise exception 'This product family is not available';
    end if;
  else
    if new.seller_id is distinct from old.seller_id
       or new.is_template <> old.is_template
       or new.segment_id <> old.segment_id
       or new.chart_type <> old.chart_type
       or new.copied_from_template_id is distinct from old.copied_from_template_id then
      raise exception 'A chart''s owner, product family, type and origin cannot be changed; create a new chart instead';
    end if;
    if old.in_use_since is not null and new.in_use_since is distinct from old.in_use_since then
      raise exception 'A chart that has been used cannot be marked unused';
    end if;
  end if;

  -- Only the publish engine (server side) may mark a chart as used.
  if current_user in ('anon', 'authenticated')
     and new.in_use_since is distinct from (case when tg_op = 'UPDATE' then old.in_use_since end) then
    raise exception 'Only the publish engine can mark a chart as used';
  end if;

  if tg_op = 'INSERT' and new.copied_from_template_id is not null then
    select c.is_template, c.segment_id, c.chart_type into src
      from public.charts c where c.id = new.copied_from_template_id;
    if not found or not src.is_template
       or src.segment_id <> new.segment_id or src.chart_type <> new.chart_type then
      raise exception 'A chart can only be copied from a template of the same product family and type';
    end if;
  end if;

  -- A replacement must be an active chart of the same owner, family and
  -- type. The lookup obeys the caller's RLS, so a seller cannot name
  -- another seller's chart.
  if new.replaced_by_id is not null
     and (tg_op = 'INSERT' or new.replaced_by_id is distinct from old.replaced_by_id) then
    select c.seller_id, c.segment_id, c.chart_type, c.is_active into rep
      from public.charts c where c.id = new.replaced_by_id;
    if not found or rep.seller_id is distinct from new.seller_id
       or rep.segment_id <> new.segment_id or rep.chart_type <> new.chart_type
       or not rep.is_active then
      raise exception 'A replacement must be an active chart of the same seller, product family and type';
    end if;
  end if;

  if not new.is_active and new.in_use_since is not null and new.replaced_by_id is null then
    raise exception 'This chart has been used in a publish. Switch it off only by naming the chart that replaces it';
  end if;

  return new;
end;
$$;

create trigger charts_before_write
  before insert or update on public.charts
  for each row execute function public.charts_before_write();

create trigger charts_set_updated_at
  before update on public.charts
  for each row execute function public.set_updated_at();

-- Never deleted; a seller's charts go only when his account is deleted.
create trigger charts_prevent_direct_delete
  before delete on public.charts
  for each row execute function public.prevent_direct_delete();

-- Row Level Security --------------------------------------------------------
-- No access for visitors yet: once area settings exist, visitors will see
-- only the charts that apply to their own area.

alter table public.charts enable row level security;

create policy "Sellers read their own charts; admins read all"
  on public.charts for select
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()));

create policy "Sellers read active templates"
  on public.charts for select
  to authenticated
  using (
    is_template and is_active
    and exists (select 1 from public.seller_profiles sp where sp.account_id = (select auth.uid()))
  );

create policy "Sellers create their own charts; admins create any, including templates"
  on public.charts for insert
  to authenticated
  with check (
    (not is_template and seller_id = (select auth.uid()))
    or (select public.is_admin())
  );

create policy "Sellers change their own charts; admins change any, including templates"
  on public.charts for update
  to authenticated
  using (seller_id = (select auth.uid()) or (select public.is_admin()))
  with check (
    (not is_template and seller_id = (select auth.uid()))
    or (select public.is_admin())
  );

-- No DELETE grant. No grant to anon.
grant select, insert, update on public.charts to authenticated;
