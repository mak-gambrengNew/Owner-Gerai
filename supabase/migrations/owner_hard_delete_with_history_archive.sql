-- Hapus PERMANEN oleh Owner + arsip riwayat mandiri.
-- Data operasional dihapus sampai bersih; salinan riwayat/log-nya dipindahkan ke tabel arsip
-- yang TIDAK punya foreign key ke data yang dihapus, sehingga riwayat tetap ada.

create table if not exists public.owner_deletion_log(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  entity_name text,
  deleted_by uuid,
  deleted_at timestamptz not null default now(),
  summary jsonb not null default '{}'::jsonb
);
create table if not exists public.owner_history_archive(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  deletion_id uuid not null,
  entity_type text not null,
  entity_id uuid not null,
  entity_name text,
  source_table text not null,
  row_count integer not null,
  row_data jsonb not null,
  archived_by uuid,
  archived_at timestamptz not null default now()
);
create index if not exists owner_history_archive_entity_idx on public.owner_history_archive(business_id, entity_type, entity_id);
create index if not exists owner_history_archive_deletion_idx on public.owner_history_archive(deletion_id);
create index if not exists owner_deletion_log_business_idx on public.owner_deletion_log(business_id, deleted_at desc);

alter table public.owner_deletion_log enable row level security;
alter table public.owner_history_archive enable row level security;
drop policy if exists owner_select_deletion_log on public.owner_deletion_log;
create policy owner_select_deletion_log on public.owner_deletion_log for select to authenticated
  using (business_id = (select p.business_id from public.profiles p where p.id = (select auth.uid()) and p.role='owner' and p.status='active'));
drop policy if exists owner_select_history_archive on public.owner_history_archive;
create policy owner_select_history_archive on public.owner_history_archive for select to authenticated
  using (business_id = (select p.business_id from public.profiles p where p.id = (select auth.uid()) and p.role='owner' and p.status='active'));
revoke all on public.owner_deletion_log, public.owner_history_archive from anon, authenticated;
grant select on public.owner_deletion_log, public.owner_history_archive to authenticated;

-- ===== helper internal (tidak dapat dipanggil langsung dari browser) =====
create or replace function public.owner_archive_rows(p_deletion uuid,p_business uuid,p_type text,p_entity uuid,p_name text,p_table text,p_where text,p_actor uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  execute format('select count(*) from public.%I t where %s',p_table,p_where) into n;
  if n=0 then return 0; end if;
  execute format($f$insert into public.owner_history_archive(business_id,deletion_id,entity_type,entity_id,entity_name,source_table,row_count,row_data,archived_by)
    select %L::uuid,%L::uuid,%L,%L::uuid,%L,%L,count(*),
           jsonb_agg(to_jsonb(t) - 'access_code_hash' - 'access_code_lookup_hash' - 'ice_qr_token'),%L::uuid
    from public.%I t where %s$f$,p_business,p_deletion,p_type,p_entity,p_name,p_table,p_actor,p_table,p_where);
  return n;
end $$;

create or replace function public.owner_purge_rows(p_table text,p_where text)
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  execute format('delete from public.%I t where %s',p_table,p_where);
  get diagnostics n = row_count;
  return n;
end $$;

-- arsip + hapus semua tabel yang punya kolom p_col bernilai p_val (kecuali p_skip)
create or replace function public.owner_sweep_column(p_deletion uuid,p_business uuid,p_type text,p_entity uuid,p_name text,p_actor uuid,p_col text,p_val uuid,p_skip text[])
returns jsonb language plpgsql security definer set search_path=public as $$
declare r record; n integer; v_sum jsonb:='{}'::jsonb; v_w text;
begin
  v_w := format('%I = %L::uuid',p_col,p_val::text);
  for r in
    select c.table_name from information_schema.columns c
    join information_schema.tables t on t.table_schema=c.table_schema and t.table_name=c.table_name and t.table_type='BASE TABLE'
    where c.table_schema='public' and c.column_name=p_col
      and c.table_name <> all(coalesce(p_skip,array[]::text[]))
      and c.table_name not in ('owner_history_archive','owner_deletion_log','audit_logs')
    order by c.table_name
  loop
    perform public.owner_archive_rows(p_deletion,p_business,p_type,p_entity,p_name,r.table_name,v_w,p_actor);
    n := public.owner_purge_rows(r.table_name,v_w);
    if n>0 then v_sum := v_sum || jsonb_build_object(r.table_name,n); end if;
  end loop;
  return v_sum;
end $$;
revoke all on function public.owner_archive_rows(uuid,uuid,text,uuid,text,text,text,uuid), public.owner_purge_rows(text,text),
  public.owner_sweep_column(uuid,uuid,text,uuid,text,uuid,text,uuid,text[]) from public, anon, authenticated;

-- ===== HAPUS GERAI =====
create or replace function public.owner_remove_store(p_store_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  b uuid; v_uid uuid := (select auth.uid()); v_name text; v_del uuid := gen_random_uuid();
  v_sum jsonb := '{}'::jsonb; v_item text; v_tbl text; v_w text; n integer; v_left text; r record;
  v_steps text[] := array[
    'monitoring_daily_transactions','monitoring_daily_store_closures','monitoring_daily_checker_items',
    'monitoring_daily_checker_inspections','monitoring_daily_restock_items','monitoring_daily_restock_requests',
    'monitoring_daily_cash_movements','monitoring_daily_ice_movements','monitoring_daily_ice_orders',
    'monitoring_daily_ice_receptions','monitoring_daily_inventory','monitoring_daily_inventory_movements',
    'monitoring_daily_menu_sales','monitoring_daily_payment_summary','monitoring_daily_store_cash',
    'monitoring_sales_events',
    'checker_validation_events',
    'checker_inspection_items::inspection_id in (select id from public.checker_inspections where store_id = $S)',
    'checker_inspections','monitoring_menu_sales','monitoring_store_sales','store_cash_movements','store_inventory_movements',
    'store_opening_inventory_items::opening_id in (select id from public.store_opening_inventory where store_id = $S)',
    'store_opening_inventory','store_inventory_items','store_restock_request_items','store_restock_requests',
    'store_emergency_requests','store_ice_movements',
    'ice_order_events::order_id in (select id from public.ice_orders where store_id = $S)',
    'ice_orders','ice_receipts','ice_receptions','owner_bills','store_payments','store_operation_sessions',
    'store_cash_accounts','store_ice_inventory','user_notifications','store_workspaces'
  ];
begin
  select business_id into b from profiles where id=v_uid and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  select name into v_name from stores where id=p_store_id and business_id=b;
  if not found then raise exception 'store_not_found'; end if;

  insert into owner_deletion_log(id,business_id,entity_type,entity_id,entity_name,deleted_by)
  values(v_del,b,'store',p_store_id,v_name,v_uid);

  -- 1) ARSIPKAN dulu seluruh riwayat gerai (sebelum ada yang diubah/dihapus)
  perform owner_archive_rows(v_del,b,'store',p_store_id,v_name,'stores',format('id = %L::uuid',p_store_id::text),v_uid);
  foreach v_item in array v_steps loop
    v_tbl := split_part(v_item,'::',1);
    v_w := replace(coalesce(nullif(split_part(v_item,'::',2),''),'store_id = $S'),'$S',quote_literal(p_store_id::text)||'::uuid');
    perform owner_archive_rows(v_del,b,'store',p_store_id,v_name,v_tbl,v_w,v_uid);
  end loop;

  -- 2) putus referensi melingkar tagihan <-> pembayaran <-> penerimaan es
  update ice_receptions set bill_id=null,payment_id=null where store_id=p_store_id;
  update owner_bills set payment_id=null where store_id=p_store_id;
  update store_payments set bill_id=null where store_id=p_store_id;

  -- 3) HAPUS bersih sesuai urutan dependensi
  foreach v_item in array v_steps loop
    v_tbl := split_part(v_item,'::',1);
    v_w := replace(coalesce(nullif(split_part(v_item,'::',2),''),'store_id = $S'),'$S',quote_literal(p_store_id::text)||'::uuid');
    n := owner_purge_rows(v_tbl,v_w);
    if n>0 then v_sum := v_sum || jsonb_build_object(v_tbl,n); end if;
  end loop;

  -- 4) sapu tabel lain (termasuk tabel baru di masa depan) yang masih punya store_id
  v_sum := v_sum || owner_sweep_column(v_del,b,'store',p_store_id,v_name,v_uid,'store_id',p_store_id,array['stores']);

  for r in
    select c.table_name from information_schema.columns c
    join information_schema.tables t on t.table_schema=c.table_schema and t.table_name=c.table_name and t.table_type='BASE TABLE'
    where c.table_schema='public' and c.column_name='store_id'
      and c.table_name not in ('stores','owner_history_archive','owner_deletion_log')
  loop
    execute format('select count(*) from public.%I where store_id = %L::uuid',r.table_name,p_store_id::text) into n;
    if n>0 then v_left := coalesce(v_left||',','')||r.table_name; end if;
  end loop;
  if v_left is not null then raise exception 'store_cleanup_incomplete:%',v_left; end if;

  delete from stores where id=p_store_id and business_id=b;

  update owner_deletion_log set summary=v_sum where id=v_del;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,v_uid,'delete','store',p_store_id,jsonb_build_object('name',v_name,'deletion_id',v_del,'archived',v_sum));
  return jsonb_build_object('ok',true,'deletion_id',v_del,'entity_name',v_name,'archived',v_sum);
end $$;

-- ===== HAPUS MENU =====
create or replace function public.owner_remove_menu(p_menu_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b uuid; v_uid uuid := (select auth.uid()); v_name text; v_del uuid := gen_random_uuid(); v_sum jsonb;
begin
  select business_id into b from profiles where id=v_uid and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  select name into v_name from menus where id=p_menu_id and business_id=b;
  if not found then raise exception 'menu_not_found'; end if;
  insert into owner_deletion_log(id,business_id,entity_type,entity_id,entity_name,deleted_by) values(v_del,b,'menu',p_menu_id,v_name,v_uid);
  perform owner_archive_rows(v_del,b,'menu',p_menu_id,v_name,'menus',format('id = %L::uuid',p_menu_id::text),v_uid);
  v_sum := owner_sweep_column(v_del,b,'menu',p_menu_id,v_name,v_uid,'menu_id',p_menu_id,array[]::text[]);
  delete from menus where id=p_menu_id and business_id=b;
  update owner_deletion_log set summary=v_sum where id=v_del;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,v_uid,'delete','menu',p_menu_id,jsonb_build_object('name',v_name,'deletion_id',v_del,'archived',v_sum));
  return jsonb_build_object('ok',true,'deletion_id',v_del,'entity_name',v_name,'archived',v_sum);
end $$;

-- ===== HAPUS INVENTORY / LOGISTIK =====
create or replace function public.owner_remove_inventory_item(p_inventory_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b uuid; v_uid uuid := (select auth.uid()); v_name text; v_del uuid := gen_random_uuid(); v_sum jsonb := '{}'::jsonb; v_w text; v_tbl text; n integer;
begin
  select business_id into b from profiles where id=v_uid and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  select name into v_name from inventory_items where id=p_inventory_id and business_id=b;
  if not found then raise exception 'inventory_item_not_found'; end if;
  insert into owner_deletion_log(id,business_id,entity_type,entity_id,entity_name,deleted_by) values(v_del,b,'inventory_item',p_inventory_id,v_name,v_uid);
  perform owner_archive_rows(v_del,b,'inventory_item',p_inventory_id,v_name,'inventory_items',format('id = %L::uuid',p_inventory_id::text),v_uid);
  foreach v_tbl in array array['store_inventory_movements','store_opening_inventory_items'] loop
    v_w := format('store_inventory_item_id in (select id from public.store_inventory_items where inventory_item_id = %L::uuid)',p_inventory_id::text);
    perform owner_archive_rows(v_del,b,'inventory_item',p_inventory_id,v_name,v_tbl,v_w,v_uid);
    n := owner_purge_rows(v_tbl,v_w);
    if n>0 then v_sum := v_sum || jsonb_build_object(v_tbl,n); end if;
  end loop;
  v_sum := v_sum || owner_sweep_column(v_del,b,'inventory_item',p_inventory_id,v_name,v_uid,'inventory_item_id',p_inventory_id,array[]::text[]);
  delete from inventory_items where id=p_inventory_id and business_id=b;
  update owner_deletion_log set summary=v_sum where id=v_del;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,v_uid,'delete','inventory_item',p_inventory_id,jsonb_build_object('name',v_name,'deletion_id',v_del,'archived',v_sum));
  return jsonb_build_object('ok',true,'deletion_id',v_del,'entity_name',v_name,'archived',v_sum);
end $$;

-- ===== HAPUS KONTAK WHATSAPP ES KRISTAL =====
create or replace function public.owner_remove_whatsapp_contact(p_contact_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b uuid; v_uid uuid := (select auth.uid()); v_name text; v_del uuid := gen_random_uuid();
begin
  select business_id into b from profiles where id=v_uid and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  select coalesce(display_name,label) into v_name from ice_whatsapp_contacts where id=p_contact_id and business_id=b;
  if not found then raise exception 'contact_not_found'; end if;
  insert into owner_deletion_log(id,business_id,entity_type,entity_id,entity_name,deleted_by) values(v_del,b,'ice_whatsapp_contact',p_contact_id,v_name,v_uid);
  perform owner_archive_rows(v_del,b,'ice_whatsapp_contact',p_contact_id,v_name,'ice_whatsapp_contacts',format('id = %L::uuid',p_contact_id::text),v_uid);
  delete from ice_whatsapp_contacts where id=p_contact_id and business_id=b;
  if not exists (select 1 from ice_whatsapp_contacts where business_id=b and is_primary and status='active') then
    update ice_whatsapp_contacts set is_primary=true
     where id=(select id from ice_whatsapp_contacts where business_id=b and status='active' order by created_at limit 1);
  end if;
  update owner_deletion_log set summary=jsonb_build_object('ice_whatsapp_contacts',1) where id=v_del;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,v_uid,'delete','ice_whatsapp_contact',p_contact_id,jsonb_build_object('name',v_name,'deletion_id',v_del));
  return jsonb_build_object('ok',true,'deletion_id',v_del,'entity_name',v_name);
end $$;

-- ===== HAPUS SPG / CHECKER (akun Auth, profil, identitas, kode akses ikut terhapus) =====
-- Catatan riwayat gerai yang dibuat anggota ini tetap ada: kolom pembuat dikosongkan (bila boleh kosong)
-- atau dialihkan ke Owner (bila wajib terisi). Daftar baris yang terdampak diarsipkan agar jejaknya tetap bisa dilacak.
create or replace function public.owner_remove_member(p_role text,p_profile_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare
  b uuid; v_uid uuid := (select auth.uid()); v_name text; v_del uuid := gen_random_uuid();
  v_sum jsonb := '{}'::jsonb; r record; n integer; v_w text; v_idtbl text;
begin
  select business_id into b from profiles where id=v_uid and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  if p_role not in ('spg','checker') then raise exception 'invalid_member_role'; end if;
  if p_profile_id = v_uid then raise exception 'cannot_delete_self'; end if;
  select full_name into v_name from profiles where id=p_profile_id and business_id=b and role=p_role;
  if not found then raise exception 'member_not_found'; end if;
  v_idtbl := case when p_role='spg' then 'spg_identities' else 'checker_identities' end;

  insert into owner_deletion_log(id,business_id,entity_type,entity_id,entity_name,deleted_by) values(v_del,b,p_role,p_profile_id,v_name,v_uid);
  perform owner_archive_rows(v_del,b,p_role,p_profile_id,v_name,'profiles',format('id = %L::uuid',p_profile_id::text),v_uid);
  perform owner_archive_rows(v_del,b,p_role,p_profile_id,v_name,v_idtbl,format('profile_id = %L::uuid',p_profile_id::text),v_uid);
  perform owner_archive_rows(v_del,b,p_role,p_profile_id,v_name,'audit_logs',format('actor_id = %L::uuid',p_profile_id::text),v_uid);

  for r in
    select cl.relname tbl, a.attname col, a.attnotnull nn
    from pg_constraint c
    join pg_class cl on cl.oid=c.conrelid
    join pg_attribute a on a.attrelid=c.conrelid and a.attnum=c.conkey[1]
    where c.contype='f' and array_length(c.conkey,1)=1 and cl.relnamespace='public'::regnamespace
      and c.confrelid in ('auth.users'::regclass,'public.profiles'::regclass)
      and c.confdeltype in ('a','r')
      and cl.relname not in ('businesses','profiles','spg_identities','checker_identities')
  loop
    v_w := format('%I = %L::uuid',r.col,p_profile_id::text);
    execute format('select count(*) from public.%I t where %s',r.tbl,v_w) into n;
    if n=0 then continue; end if;
    if r.tbl='chat_messages' then
      perform owner_archive_rows(v_del,b,p_role,p_profile_id,v_name,r.tbl,v_w,v_uid);
      n := owner_purge_rows(r.tbl,v_w);
      v_sum := v_sum || jsonb_build_object(r.tbl||' (dihapus)',n);
    else
      execute format($f$insert into public.owner_history_archive(business_id,deletion_id,entity_type,entity_id,entity_name,source_table,row_count,row_data,archived_by)
        select %L::uuid,%L::uuid,%L,%L::uuid,%L,%L,count(*),jsonb_agg(jsonb_build_object('id',to_jsonb(t)->'id')),%L::uuid
        from public.%I t where %s$f$,b,v_del,p_role,p_profile_id,v_name,'attribution:'||r.tbl||'.'||r.col,v_uid,r.tbl,v_w);
      if r.nn then
        execute format('update public.%I set %I = %L::uuid where %I = %L::uuid',r.tbl,r.col,v_uid::text,r.col,p_profile_id::text);
        v_sum := v_sum || jsonb_build_object(r.tbl||'.'||r.col||' (dialihkan ke Owner)',n);
      else
        execute format('update public.%I set %I = null where %I = %L::uuid',r.tbl,r.col,r.col,p_profile_id::text);
        v_sum := v_sum || jsonb_build_object(r.tbl||'.'||r.col||' (dikosongkan)',n);
      end if;
    end if;
  end loop;

  delete from auth.users where id=p_profile_id;   -- profil, identitas, kode akses, sesi, push, partisipasi chat ikut terhapus
  if exists (select 1 from profiles where id=p_profile_id) then raise exception 'member_cleanup_incomplete'; end if;

  update owner_deletion_log set summary=v_sum where id=v_del;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,v_uid,'delete',p_role,p_profile_id,jsonb_build_object('name',v_name,'deletion_id',v_del,'archived',v_sum));
  return jsonb_build_object('ok',true,'deletion_id',v_del,'entity_name',v_name,'archived',v_sum);
end $$;

revoke all on function public.owner_remove_store(uuid), public.owner_remove_menu(uuid), public.owner_remove_inventory_item(uuid),
  public.owner_remove_whatsapp_contact(uuid), public.owner_remove_member(text,uuid) from public, anon;
grant execute on function public.owner_remove_store(uuid), public.owner_remove_menu(uuid), public.owner_remove_inventory_item(uuid),
  public.owner_remove_whatsapp_contact(uuid), public.owner_remove_member(text,uuid) to authenticated;
