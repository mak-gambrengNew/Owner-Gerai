-- Master data identity, global duplicate prevention, one-time logistics seed, change-revision signal.
-- Scope of identity: per business (inventory_items.business_id / menus.business_id). Idempotent.
-- Policy: identity is held by ALL rows regardless of status (an inactive item still owns its name).
--         Hard delete (owner_remove_*) removes the row and therefore frees the identity.

-- 1) Name normalizer: lower-case, drop every non-alphanumeric char (spaces, punctuation). Digits/sizes are kept.
create or replace function public.master_name_key(p_name text)
returns text language sql immutable parallel safe set search_path = ''
as $$ select regexp_replace(lower(coalesce(p_name,'')), '[^[:alnum:]]+', '', 'g') $$;

-- 2) Generated identity keys + unique indexes (database is the last line of defence)
alter table public.inventory_items
  add column if not exists name_key text generated always as (public.master_name_key(name)) stored;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='inventory_items_name_key_not_empty') then
    alter table public.inventory_items add constraint inventory_items_name_key_not_empty check (name_key <> '');
  end if;
end $$;
create unique index if not exists inventory_items_business_name_key_uidx
  on public.inventory_items (business_id, name_key);

alter table public.menus
  add column if not exists name_key text generated always as (public.master_name_key(name)) stored,
  add column if not exists category_key text generated always as (public.master_name_key(category)) stored;
create unique index if not exists menus_business_category_name_key_uidx
  on public.menus (business_id, category_key, name_key);

-- 3) Owner RPCs: normalise display name (trim + collapse spaces), reject duplicates with explicit codes
create or replace function public.owner_create_inventory_item(
  p_name text, p_unit text default 'pcs', p_minimum_stock numeric default 0,
  p_supplier text default null, p_logistics_type text default 'passive')
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare b uuid; i uuid; v_name text := regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g'); v_dup record;
begin
  select business_id into b from profiles where id=(select auth.uid()) and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  if v_name='' or public.master_name_key(v_name)='' then raise exception 'inventory_name_required'; end if;
  if p_minimum_stock < 0 then raise exception 'invalid_minimum_stock'; end if;
  if p_logistics_type not in ('passive','active') then raise exception 'invalid_logistics_type'; end if;
  begin
    insert into inventory_items(business_id,name,unit,minimum_stock,supplier,logistics_type)
    values(b,v_name,coalesce(nullif(trim(p_unit),''),'pcs'),p_minimum_stock,nullif(trim(p_supplier),''),p_logistics_type)
    returning id into i;
  exception when unique_violation then
    select id,status into v_dup from inventory_items where business_id=b and name_key=public.master_name_key(v_name);
    if v_dup.status='inactive' then raise exception 'inventory_name_duplicate_inactive:%',v_dup.id; end if;
    raise exception 'inventory_name_duplicate:%',v_dup.id;
  end;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,(select auth.uid()),'create','inventory_item',i,jsonb_build_object('name',v_name,'logistics_type',p_logistics_type));
  return i;
end $$;

create or replace function public.owner_update_inventory_item(
  p_inventory_id uuid, p_name text, p_unit text, p_minimum_stock numeric,
  p_supplier text, p_logistics_type text, p_status text default 'active')
returns void language plpgsql security definer set search_path to 'public' as $$
declare b uuid; v_name text := regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g'); v_dup record;
begin
  select business_id into b from profiles where id=(select auth.uid()) and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  if v_name='' or public.master_name_key(v_name)='' then raise exception 'inventory_name_required'; end if;
  if p_logistics_type not in ('passive','active') then raise exception 'invalid_logistics_type'; end if;
  if p_status not in ('active','inactive') then raise exception 'invalid_inventory_status'; end if;
  if p_minimum_stock < 0 then raise exception 'invalid_minimum_stock'; end if;
  begin
    update inventory_items set
      name=v_name,unit=coalesce(nullif(trim(p_unit),''),'pcs'),
      minimum_stock=p_minimum_stock,supplier=nullif(trim(p_supplier),''),
      logistics_type=p_logistics_type,status=p_status,updated_at=now()
    where id=p_inventory_id and business_id=b;
  exception when unique_violation then
    select id,status into v_dup from inventory_items
     where business_id=b and name_key=public.master_name_key(v_name) and id<>p_inventory_id;
    if v_dup.status='inactive' then raise exception 'inventory_name_duplicate_inactive:%',v_dup.id; end if;
    raise exception 'inventory_name_duplicate:%',v_dup.id;
  end;
  if not found then raise exception 'inventory_item_not_found'; end if;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,(select auth.uid()),'update','inventory_item',p_inventory_id,
         jsonb_build_object('logistics_type',p_logistics_type,'status',p_status,'minimum_stock',p_minimum_stock));
end $$;

create or replace function public.owner_upsert_menu(
  p_menu_id uuid default null, p_name text default null, p_category text default 'Minuman',
  p_price numeric default 0, p_hpp numeric default 0, p_status text default 'active',
  p_consumptions jsonb default '[]'::jsonb, p_price_reason text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare
  b uuid; m uuid; old_price numeric; item jsonb; iid uuid; qty numeric; v_dup uuid;
  v_name text := regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g');
  v_cat text := coalesce(nullif(regexp_replace(trim(coalesce(p_category,'')),'\s+',' ','g'),''),'Minuman');
begin
  select business_id into b from profiles where id=(select auth.uid()) and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  if v_name='' or public.master_name_key(v_name)='' then raise exception 'menu_name_required'; end if;
  if p_price is null or p_price < 0 then raise exception 'invalid_menu_price'; end if;
  if p_hpp is null or p_hpp < 0 then raise exception 'invalid_menu_hpp'; end if;
  if p_status not in ('active','inactive') then raise exception 'invalid_menu_status'; end if;

  if p_menu_id is null then
    begin
      insert into menus(business_id,name,category,price,hpp,status)
      values(b,v_name,v_cat,p_price,p_hpp,p_status) returning id into m;
    exception when unique_violation then
      select id into v_dup from menus where business_id=b and name_key=public.master_name_key(v_name)
        and category_key=public.master_name_key(v_cat);
      raise exception 'menu_name_duplicate:%',v_dup;
    end;
    if p_price <> 0 then
      insert into menu_price_history(business_id,menu_id,old_price,new_price,changed_by,reason)
      values(b,m,0,p_price,(select auth.uid()),p_price_reason);
    end if;
  else
    select id,price into m,old_price from menus where id=p_menu_id and business_id=b for update;
    if m is null then raise exception 'menu_not_found'; end if;
    begin
      update menus set name=v_name,category=v_cat,price=p_price,hpp=p_hpp,status=p_status,updated_at=now()
      where id=m and business_id=b;
    exception when unique_violation then
      select id into v_dup from menus where business_id=b and name_key=public.master_name_key(v_name)
        and category_key=public.master_name_key(v_cat) and id<>m;
      raise exception 'menu_name_duplicate:%',v_dup;
    end;
    if old_price is distinct from p_price then
      insert into menu_price_history(business_id,menu_id,old_price,new_price,changed_by,reason)
      values(b,m,coalesce(old_price,0),p_price,(select auth.uid()),p_price_reason);
    end if;
    delete from menu_inventory_consumptions where menu_id=m and business_id=b;
  end if;

  for item in select * from jsonb_array_elements(coalesce(p_consumptions,'[]'::jsonb)) loop
    iid := (item->>'inventory_id')::uuid;
    qty := nullif(item->>'quantity_per_sale','')::numeric;
    if qty is null or qty <= 0 then raise exception 'invalid_consumption_quantity'; end if;
    if not exists (select 1 from inventory_items where id=iid and business_id=b and status='active')
      then raise exception 'inventory_item_not_found:%',iid; end if;
    update inventory_items set logistics_type='active', updated_at=now() where id=iid and business_id=b;
    insert into menu_inventory_consumptions(business_id,menu_id,inventory_item_id,quantity_per_sale)
    values(b,m,iid,qty);
  end loop;

  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,(select auth.uid()),case when p_menu_id is null then 'create' else 'update' end,
         'menu',m,jsonb_build_object('name',v_name,'price',p_price,'hpp',p_hpp,'status',p_status));
  return m;
end $$;

-- 4) One-time seed ledger + idempotent seed. Not callable from browser roles.
create table if not exists public.master_seed_log (
  business_id uuid not null,
  seed_key text not null,
  applied_at timestamptz not null default now(),
  inserted_count integer not null default 0,
  matched_count integer not null default 0,
  primary key (business_id, seed_key)
);
alter table public.master_seed_log enable row level security;
revoke all on table public.master_seed_log from anon, authenticated;

create or replace function public.seed_initial_logistics(p_business uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_names text[] := array['Teh','Gula','Air Galon','Gas','Plastik Ukuran 1','Plastik Ukuran 2','Plastik Ukuran 3',
                          'Seal Cup','Sedotan','Susu','Milo','Cup 16 oz','Cup 22 oz Datar','Cup 22 oz Oval'];
  n text; v_ins int := 0; v_match int := 0; v_rows int;
begin
  -- ledger row claims the seed atomically; a deleted/renamed/deactivated item is never re-seeded
  insert into master_seed_log(business_id,seed_key) values(p_business,'initial_logistics_v1') on conflict do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then return jsonb_build_object('skipped',true); end if;
  foreach n in array v_names loop
    insert into inventory_items(business_id,name,unit,minimum_stock,logistics_type,status)
    values(p_business,n,'pcs',0,'passive','active')
    on conflict (business_id,name_key) do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 1 then v_ins := v_ins + 1; else v_match := v_match + 1; end if;
  end loop;
  update master_seed_log set inserted_count=v_ins, matched_count=v_match
   where business_id=p_business and seed_key='initial_logistics_v1';
  return jsonb_build_object('inserted',v_ins,'matched_existing',v_match);
end $$;
revoke all on function public.seed_initial_logistics(uuid) from public, anon, authenticated;

select public.seed_initial_logistics(id) from public.businesses;

-- 5) Change-revision signal for Gerai realtime (RLS-safe: no cost/stock columns exposed to SPG)
create table if not exists public.master_data_revision (
  business_id uuid primary key,
  menu_rev bigint not null default 0,
  logistics_rev bigint not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.master_data_revision enable row level security;
revoke all on table public.master_data_revision from anon, authenticated;
grant select on table public.master_data_revision to authenticated;
drop policy if exists "spg read master revision" on public.master_data_revision;
create policy "spg read master revision" on public.master_data_revision
  for select to authenticated using (public.is_active_spg_of(business_id));
drop policy if exists "owner read master revision" on public.master_data_revision;
create policy "owner read master revision" on public.master_data_revision
  for select to authenticated using (exists(select 1 from public.businesses b
    where b.id = master_data_revision.business_id and b.owner_id = (select auth.uid())));

create or replace function public.bump_master_revision()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_b uuid := case when tg_op='DELETE' then old.business_id else new.business_id end;
        v_menu int := case when tg_argv[0]='menu' then 1 else 0 end;
begin
  insert into master_data_revision(business_id,menu_rev,logistics_rev) values(v_b,v_menu,1-v_menu)
  on conflict (business_id) do update set
    menu_rev = master_data_revision.menu_rev + v_menu,
    logistics_rev = master_data_revision.logistics_rev + (1-v_menu),
    updated_at = now();
  return null;
end $$;
revoke all on function public.bump_master_revision() from public, anon, authenticated;

drop trigger if exists trg_rev_inventory_ins_del on public.inventory_items;
create trigger trg_rev_inventory_ins_del after insert or delete on public.inventory_items
  for each row execute function public.bump_master_revision('logistics');
drop trigger if exists trg_rev_inventory_upd on public.inventory_items;
create trigger trg_rev_inventory_upd after update of name, unit, minimum_stock, status, logistics_type on public.inventory_items
  for each row execute function public.bump_master_revision('logistics');
drop trigger if exists trg_rev_menus_ins_del on public.menus;
create trigger trg_rev_menus_ins_del after insert or delete on public.menus
  for each row execute function public.bump_master_revision('menu');
drop trigger if exists trg_rev_menus_upd on public.menus;
create trigger trg_rev_menus_upd after update of name, category, price, hpp, status on public.menus
  for each row execute function public.bump_master_revision('menu');
drop trigger if exists trg_rev_menu_consumptions on public.menu_inventory_consumptions;
create trigger trg_rev_menu_consumptions after insert or update or delete on public.menu_inventory_consumptions
  for each row execute function public.bump_master_revision('menu');

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='master_data_revision') then
    alter publication supabase_realtime add table public.master_data_revision;
  end if;
end $$;

-- prime a revision row for every business so Gerai has a baseline
insert into public.master_data_revision(business_id, menu_rev, logistics_rev)
select id, 1, 1 from public.businesses on conflict (business_id) do nothing;
