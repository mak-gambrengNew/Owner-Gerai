-- Fitur Pengumuman (marquee) — Owner membuat, Gerai (SPG) & Checker membaca.
-- Target audiens: 'gerai' (SPG), 'checker', 'semua'. Otomatis kedaluwarsa 24 jam.
-- Pengumuman baru MENAMBAH daftar (tidak mengganti yang aktif).
-- Idempoten: aman dijalankan ulang.

create table if not exists public.announcements (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  audience    text not null check (audience in ('gerai','checker','semua')),
  message     text not null check (char_length(btrim(message)) between 1 and 280),
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '24 hours')
);
create index if not exists announcements_business_expires_idx
  on public.announcements (business_id, expires_at desc);

alter table public.announcements enable row level security;
revoke all on table public.announcements from anon, authenticated;
grant select on table public.announcements to authenticated;   -- tulis hanya lewat RPC Owner

-- Pembaca: anggota aktif bisnis yang sama, sesuai audiens perannya. Owner melihat semuanya.
drop policy if exists "announcements read by audience" on public.announcements;
create policy "announcements read by audience" on public.announcements
  for select to authenticated
  using (
    expires_at > now()
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and p.business_id = announcements.business_id
        and p.status = 'active'
        and (
          p.role = 'owner'
          or (p.role = 'spg'     and announcements.audience in ('gerai','semua'))
          or (p.role = 'checker' and announcements.audience in ('checker','semua'))
        )
    )
  );

-- Pembersihan baris kedaluwarsa (dipanggil lazy oleh RPC; tidak butuh pg_cron).
create or replace function public.announcement_purge_expired()
returns void language sql security definer set search_path = public as $$
  delete from public.announcements where expires_at <= now();
$$;
revoke all on function public.announcement_purge_expired() from public, anon, authenticated;

-- ===== Owner: buat =====
create or replace function public.owner_create_announcement(p_audience text, p_message text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := (select auth.uid()); b uuid; v_msg text := btrim(coalesce(p_message,'')); r public.announcements;
begin
  select business_id into b from profiles where id = v_uid and role = 'owner' and status = 'active';
  if b is null then raise exception 'owner_access_denied'; end if;
  if p_audience not in ('gerai','checker','semua') then raise exception 'invalid_audience'; end if;
  if v_msg = '' then raise exception 'announcement_message_required'; end if;
  if char_length(v_msg) > 280 then raise exception 'announcement_too_long'; end if;
  perform announcement_purge_expired();
  insert into announcements(business_id, audience, message, created_by)
    values (b, p_audience, v_msg, v_uid) returning * into r;
  begin
    insert into audit_logs(business_id, actor_id, action, entity, entity_id, details)
      values (b, v_uid, 'create', 'announcement', r.id,
              jsonb_build_object('name', left(v_msg, 60), 'audience', p_audience));
  exception when others then null;  -- audit tidak boleh menggagalkan pengumuman
  end;
  return to_jsonb(r);
end $$;

-- ===== Owner: daftar aktif (semua audiens) =====
create or replace function public.owner_list_announcements()
returns setof public.announcements language plpgsql security definer set search_path = public as $$
declare b uuid;
begin
  select business_id into b from profiles where id = (select auth.uid()) and role = 'owner' and status = 'active';
  if b is null then raise exception 'owner_access_denied'; end if;
  perform announcement_purge_expired();
  return query select * from announcements where business_id = b and expires_at > now() order by created_at desc;
end $$;

-- ===== Owner: ubah (teks/audiens). Masa tayang tetap, tidak diperpanjang. =====
create or replace function public.owner_update_announcement(p_id uuid, p_audience text, p_message text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := (select auth.uid()); b uuid; v_msg text := btrim(coalesce(p_message,'')); r public.announcements;
begin
  select business_id into b from profiles where id = v_uid and role = 'owner' and status = 'active';
  if b is null then raise exception 'owner_access_denied'; end if;
  if p_audience not in ('gerai','checker','semua') then raise exception 'invalid_audience'; end if;
  if v_msg = '' then raise exception 'announcement_message_required'; end if;
  if char_length(v_msg) > 280 then raise exception 'announcement_too_long'; end if;
  update announcements set audience = p_audience, message = v_msg, updated_at = now()
   where id = p_id and business_id = b and expires_at > now() returning * into r;
  if not found then raise exception 'announcement_not_found'; end if;
  begin
    insert into audit_logs(business_id, actor_id, action, entity, entity_id, details)
      values (b, v_uid, 'update', 'announcement', r.id,
              jsonb_build_object('name', left(v_msg, 60), 'audience', p_audience));
  exception when others then null;
  end;
  return to_jsonb(r);
end $$;

-- ===== Owner: hapus (menghentikan tayang sekarang juga) =====
create or replace function public.owner_remove_announcement(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := (select auth.uid()); b uuid; r public.announcements;
begin
  select business_id into b from profiles where id = v_uid and role = 'owner' and status = 'active';
  if b is null then raise exception 'owner_access_denied'; end if;
  delete from announcements where id = p_id and business_id = b returning * into r;
  if not found then raise exception 'announcement_not_found'; end if;
  begin
    insert into audit_logs(business_id, actor_id, action, entity, entity_id, details)
      values (b, v_uid, 'delete', 'announcement', r.id,
              jsonb_build_object('name', left(r.message, 60), 'audience', r.audience));
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;

-- ===== SPG / Checker / Owner: pengumuman aktif sesuai peran pemanggil =====
-- Dipakai PWA Gerai sekarang dan Panel Checker nanti (kontrak sama, tanpa parameter).
create or replace function public.announcement_list_active()
returns table (id uuid, audience text, message text, created_at timestamptz, expires_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_role text; b uuid;
begin
  select p.role, p.business_id into v_role, b from profiles p where p.id = (select auth.uid()) and p.status = 'active';
  if b is null then return; end if;
  return query
    select a.id, a.audience, a.message, a.created_at, a.expires_at
      from announcements a
     where a.business_id = b and a.expires_at > now()
       and (v_role = 'owner'
            or (v_role = 'spg'     and a.audience in ('gerai','semua'))
            or (v_role = 'checker' and a.audience in ('checker','semua')))
     order by a.created_at asc;   -- lama → baru; yang baru ditambahkan di belakang
end $$;

revoke all on function public.owner_create_announcement(text,text)        from public, anon;
revoke all on function public.owner_list_announcements()                  from public, anon;
revoke all on function public.owner_update_announcement(uuid,text,text)   from public, anon;
revoke all on function public.owner_remove_announcement(uuid)            from public, anon;
revoke all on function public.announcement_list_active()                  from public, anon;
grant execute on function public.owner_create_announcement(text,text)      to authenticated;
grant execute on function public.owner_list_announcements()                to authenticated;
grant execute on function public.owner_update_announcement(uuid,text,text) to authenticated;
grant execute on function public.owner_remove_announcement(uuid)           to authenticated;
grant execute on function public.announcement_list_active()                to authenticated;

-- Realtime (RLS tetap berlaku)
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='announcements') then
    alter publication supabase_realtime add table public.announcements;
  end if;
end $$;
8
