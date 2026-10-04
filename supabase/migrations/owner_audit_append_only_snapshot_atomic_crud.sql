-- Owner CRUD hardening: audit append-only + snapshot sebelum/sesudah + penutupan jalur hapus tanpa audit.
-- Tidak menghapus tabel/kolom produksi. Kompatibel dengan frontend Owner yang sudah ada.

-- 1) Kolom snapshot pada audit_logs (nama entitas, nama pelaku, nilai sebelum & sesudah)
alter table public.audit_logs
  add column if not exists entity_name text,
  add column if not exists actor_name  text,
  add column if not exists before_data jsonb,
  add column if not exists after_data  jsonb;
create index if not exists audit_logs_business_created_idx on public.audit_logs(business_id, created_at desc);
create index if not exists audit_logs_entity_idx on public.audit_logs(business_id, entity, entity_id);

-- 2) Backfill snapshot untuk baris lama (dilakukan SEBELUM trigger append-only dipasang)
update public.audit_logs a set entity_name = coalesce(a.details->>'name', a.details->>'label', a.details->>'full_name')
 where a.entity_name is null;
update public.audit_logs a set entity_name = s.name from public.stores s where a.entity_name is null and a.entity='store' and s.id=a.entity_id;
update public.audit_logs a set entity_name = p.full_name from public.profiles p where a.entity_name is null and a.entity in ('spg','checker') and p.id=a.entity_id;
update public.audit_logs a set entity_name = m.name from public.menus m where a.entity_name is null and a.entity='menu' and m.id=a.entity_id;
update public.audit_logs a set entity_name = i.name from public.inventory_items i where a.entity_name is null and a.entity='inventory_item' and i.id=a.entity_id;
update public.audit_logs a set entity_name = coalesce(c.display_name,c.label) from public.ice_whatsapp_contacts c where a.entity_name is null and a.entity='ice_whatsapp_contact' and c.id=a.entity_id;
update public.audit_logs a set actor_name = p.full_name from public.profiles p where a.actor_name is null and p.id=a.actor_id;

-- 3) Penangkap nilai lama (transaksi-lokal) -> dipakai trigger audit untuk mengisi before_data
create or replace function public.audit_capture_old() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  perform set_config('audit.old_'||tg_table_name||'_'||replace(old.id::text,'-','_'),
    (to_jsonb(old) - 'access_code_hash' - 'access_code_lookup_hash' - 'ice_qr_token')::text, true);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.audit_capture_old() from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['stores','menus','inventory_items','ice_whatsapp_contacts','profiles'] loop
    execute format('drop trigger if exists trg_audit_capture_old on public.%I',t);
    execute format('create trigger trg_audit_capture_old before update or delete on public.%I for each row execute function public.audit_capture_old()',t);
  end loop;
end $$;

-- 4) Pengisi snapshot otomatis saat audit dicatat (waktu server, nama pelaku, nama entitas, before/after)
create or replace function public.audit_enrich() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_tbl text; v_old text; v_new jsonb;
begin
  new.created_at := now();
  if new.actor_name is null and new.actor_id is not null then
    select full_name into new.actor_name from public.profiles where id=new.actor_id;
  end if;
  v_tbl := case new.entity when 'store' then 'stores' when 'menu' then 'menus' when 'inventory_item' then 'inventory_items'
                           when 'ice_whatsapp_contact' then 'ice_whatsapp_contacts' when 'spg' then 'profiles' when 'checker' then 'profiles' end;
  if v_tbl is not null and new.entity_id is not null then
    v_old := nullif(current_setting('audit.old_'||v_tbl||'_'||replace(new.entity_id::text,'-','_'), true),'');
    if new.before_data is null and v_old is not null then new.before_data := v_old::jsonb; end if;
    if new.after_data is null then
      execute format('select to_jsonb(t) - %L - %L - %L from public.%I t where t.id=$1','access_code_hash','access_code_lookup_hash','ice_qr_token',v_tbl)
        into v_new using new.entity_id;
      new.after_data := v_new;
    end if;
  end if;
  if new.entity_name is null then
    new.entity_name := coalesce(new.details->>'name', new.details->>'label', new.details->>'full_name',
      new.after_data->>'name', new.after_data->>'full_name', new.after_data->>'display_name', new.after_data->>'label',
      new.before_data->>'name', new.before_data->>'full_name', new.before_data->>'display_name', new.before_data->>'label');
  end if;
  return new;
end $$;
revoke all on function public.audit_enrich() from public, anon, authenticated;
drop trigger if exists a_audit_enrich on public.audit_logs;
create trigger a_audit_enrich before insert on public.audit_logs for each row execute function public.audit_enrich();

-- 5) Append-only: audit_logs, owner_deletion_log (hanya kolom summary boleh diisi), owner_history_archive
create or replace function public.audit_append_only_guard() returns trigger
language plpgsql set search_path=public as $$
begin
  if tg_op='TRUNCATE' then raise exception 'audit_append_only'; end if;
  if tg_op='DELETE' then
    if pg_trigger_depth()>1 then return old; end if;   -- hanya cascade referensial (hapus bisnis), bukan DELETE langsung
    raise exception 'audit_append_only';
  end if;
  if tg_table_name='audit_logs' and new.actor_id is null and (to_jsonb(new)-'actor_id') = (to_jsonb(old)-'actor_id') then
    return new;                                         -- FK ON DELETE SET NULL saat akun anggota dihapus; nama pelaku tetap di actor_name
  elsif tg_table_name='owner_deletion_log' and (to_jsonb(new)-'summary') = (to_jsonb(old)-'summary') then
    return new;
  end if;
  raise exception 'audit_append_only';
end $$;
revoke all on function public.audit_append_only_guard() from public, anon, authenticated;
do $$ declare t text; begin
  foreach t in array array['audit_logs','owner_deletion_log','owner_history_archive'] loop
    execute format('drop trigger if exists trg_append_only on public.%I',t);
    execute format('create trigger trg_append_only before update or delete on public.%I for each row execute function public.audit_append_only_guard()',t);
    execute format('drop trigger if exists trg_append_only_truncate on public.%I',t);
    execute format('create trigger trg_append_only_truncate before truncate on public.%I for each statement execute function public.audit_append_only_guard()',t);
  end loop;
end $$;

-- 6) Audit tidak boleh dipalsukan/ditulis dari browser: tulis hanya lewat fungsi server.
--    Fungsi Owner yang sebelumnya berjalan sebagai pemanggil dijadikan SECURITY DEFINER (semuanya sudah memvalidasi Owner & business_id).
alter function public.owner_create_inventory_item(text,text,numeric,text,text) security definer;
alter function public.owner_update_inventory_item(uuid,text,text,numeric,text,text,text) security definer;
alter function public.owner_set_inventory_logistics_type(uuid,text) security definer;
alter function public.owner_set_menu_status(uuid,text) security definer;
alter function public.owner_upsert_store(uuid,text,text,text,text) security definer;
drop policy if exists "owner audit insert" on public.audit_logs;
revoke insert, update, delete, truncate, references, trigger on public.audit_logs from anon, authenticated;
grant select on public.audit_logs to authenticated;

-- 7) Tutup jalur hapus langsung yang melewati arsip & audit. Hapus Owner hanya lewat owner_remove_* (atomik).
drop policy if exists "owner stores delete" on public.stores;
drop policy if exists "owner menus delete" on public.menus;
drop policy if exists "owner inventory delete" on public.inventory_items;
drop policy if exists "owner ice whatsapp delete" on public.ice_whatsapp_contacts;
drop policy if exists "owner profiles delete" on public.profiles;
revoke delete on public.stores, public.menus, public.inventory_items, public.ice_whatsapp_contacts, public.profiles from anon, authenticated;
do $$ declare r record; begin
  for r in select tablename from pg_tables where schemaname='public' loop
    execute format('revoke truncate, references, trigger on public.%I from anon, authenticated', r.tablename);
  end loop;
end $$;

-- 8) Fungsi hapus lama tanpa arsip dinonaktifkan dari klien (digantikan owner_remove_*)
revoke execute on function public.owner_delete_crud_master(text,uuid) from public, anon, authenticated;
revoke execute on function public.owner_delete_whatsapp_contact(uuid) from public, anon, authenticated;

-- 9) Edit anggota (nama, telepon, status) dalam SATU transaksi
create or replace function public.owner_save_member(p_role text, p_profile_id uuid, p_full_name text, p_phone text, p_status text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b uuid; v_uid uuid := (select auth.uid());
begin
  select business_id into b from profiles where id=v_uid and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  if p_role not in ('spg','checker') then raise exception 'invalid_member_role'; end if;
  if coalesce(trim(p_full_name),'')='' then raise exception 'member_name_required'; end if;
  if p_status not in ('active','inactive','suspended') then raise exception 'invalid_member_status'; end if;
  update profiles set full_name=trim(p_full_name), phone=nullif(trim(p_phone),''),
         status=case when p_status='active' then 'active' else 'inactive' end, updated_at=now()
   where id=p_profile_id and business_id=b and role=p_role;
  if not found then raise exception 'member_not_found'; end if;
  if p_role='spg' then update spg_identities set status=p_status, updated_at=now() where profile_id=p_profile_id and business_id=b;
  else update checker_identities set status=p_status, updated_at=now() where profile_id=p_profile_id and business_id=b; end if;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,v_uid,'update',p_role,p_profile_id,jsonb_build_object('full_name',trim(p_full_name),'status',p_status));
  return jsonb_build_object('ok',true,'profile_id',p_profile_id);
end $$;
revoke all on function public.owner_save_member(text,uuid,text,text,text) from public, anon;
grant execute on function public.owner_save_member(text,uuid,text,text,text) to authenticated;
