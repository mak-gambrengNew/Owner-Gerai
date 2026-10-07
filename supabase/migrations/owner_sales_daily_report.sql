-- Laporan Penjualan harian (tab Laporan Owner)
-- Sumber: snapshot final monitoring_daily_* yang dibuat finalize_monitoring_day
-- (hanya terisi setelah SEMUA gerai tutup dan Checker menyelesaikan penutupan hari).
--
-- Mengapa RPC baru: owner_get_report berjalan sebagai invoker, sedangkan role
-- `authenticated` tidak punya SELECT pada monitoring_daily_closures,
-- monitoring_daily_store_closures, dan monitoring_daily_menu_sales. Dua RPC di bawah
-- SECURITY DEFINER, read-only, dan memvalidasi Owner lewat auth.uid().
--
-- "Total penjualan" = jumlah porsi/item terjual (BUKAN nominal rupiah).

create or replace function public.owner_get_sales_report(p_sales_date date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_business uuid;
  v_daily record;
  v_date date;
  v_latest date;
  v_prev date;
  v_next date;
begin
  if v_uid is null then raise exception 'owner_auth_required'; end if;

  select p.business_id into v_business
  from public.profiles p
  where p.id = v_uid
    and lower(coalesce(p.role,'')) = 'owner'
    and lower(coalesce(p.status,'active')) = 'active'
  limit 1;
  if v_business is null then raise exception 'owner_access_required'; end if;

  select max(c.sales_date) into v_latest
  from public.monitoring_daily_closures c
  where c.business_id = v_business and c.status = 'closed';

  if v_latest is null then
    return jsonb_build_object('status','NONE_AVAILABLE','requested_date',p_sales_date);
  end if;

  v_date := coalesce(p_sales_date, v_latest);

  select max(c.sales_date) into v_prev
  from public.monitoring_daily_closures c
  where c.business_id = v_business and c.status = 'closed' and c.sales_date < v_date;

  select min(c.sales_date) into v_next
  from public.monitoring_daily_closures c
  where c.business_id = v_business and c.status = 'closed' and c.sales_date > v_date;

  select * into v_daily
  from public.monitoring_daily_closures c
  where c.business_id = v_business and c.sales_date = v_date and c.status = 'closed';

  if v_daily.id is null then
    return jsonb_build_object(
      'status','NO_REPORT',
      'sales_date',v_date,
      'latest_date',v_latest,
      'prev_date',v_prev,
      'next_date',v_next
    );
  end if;

  return jsonb_build_object(
    'status','FINAL',
    'sales_date',v_date,
    'latest_date',v_latest,
    'prev_date',v_prev,
    'next_date',v_next,
    'finalized_at',v_daily.finalized_at,
    'summary',jsonb_build_object(
      'items_sold',coalesce((select sum(m.quantity) from public.monitoring_daily_menu_sales m where m.daily_closure_id = v_daily.id),0),
      'transaction_count',coalesce(v_daily.transaction_count,0),
      'menu_count',(select count(distinct m.menu_id) from public.monitoring_daily_menu_sales m where m.daily_closure_id = v_daily.id),
      'store_count',coalesce(v_daily.store_count,0),
      'closed_store_count',coalesce(v_daily.closed_store_count,0)
    ),
    'stores',coalesce((
      select jsonb_agg(to_jsonb(q) order by q.items_sold desc, q.store_name)
      from (
        select sc.store_id,
               sc.store_name,
               coalesce(sc.transaction_count,0) as transaction_count,
               coalesce((select sum(m.quantity) from public.monitoring_daily_menu_sales m
                         where m.daily_closure_id = v_daily.id and m.store_id = sc.store_id),0) as items_sold,
               sc.opened_at,
               sc.closed_at
        from public.monitoring_daily_store_closures sc
        where sc.daily_closure_id = v_daily.id
      ) q
    ),'[]'::jsonb),
    'menus',coalesce((
      select jsonb_agg(to_jsonb(q) order by q.quantity desc, q.menu_name)
      from (
        select m.menu_id,
               max(m.menu_name) as menu_name,
               sum(m.quantity) as quantity,
               (select coalesce(jsonb_agg(jsonb_build_object('store_name',x.store_name,'quantity',x.qty) order by x.qty desc, x.store_name),'[]'::jsonb)
                from (
                  select coalesce(max(sc2.store_name),'Gerai') as store_name, sum(m2.quantity) as qty
                  from public.monitoring_daily_menu_sales m2
                  left join public.monitoring_daily_store_closures sc2
                    on sc2.daily_closure_id = m2.daily_closure_id and sc2.store_id = m2.store_id
                  where m2.daily_closure_id = v_daily.id and m2.menu_id is not distinct from m.menu_id
                  group by m2.store_id
                ) x
               ) as by_store
        from public.monitoring_daily_menu_sales m
        where m.daily_closure_id = v_daily.id
        group by m.menu_id
      ) q
    ),'[]'::jsonb)
  );
end;
$function$;

create or replace function public.owner_list_sales_report_dates(p_limit integer default 60)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_business uuid;
begin
  if v_uid is null then raise exception 'owner_auth_required'; end if;

  select p.business_id into v_business
  from public.profiles p
  where p.id = v_uid
    and lower(coalesce(p.role,'')) = 'owner'
    and lower(coalesce(p.status,'active')) = 'active'
  limit 1;
  if v_business is null then raise exception 'owner_access_required'; end if;

  return jsonb_build_object(
    'latest',(select max(c.sales_date) from public.monitoring_daily_closures c where c.business_id = v_business and c.status = 'closed'),
    'earliest',(select min(c.sales_date) from public.monitoring_daily_closures c where c.business_id = v_business and c.status = 'closed'),
    'dates',coalesce((
      select jsonb_agg(d.sales_date order by d.sales_date desc)
      from (
        select c.sales_date
        from public.monitoring_daily_closures c
        where c.business_id = v_business and c.status = 'closed'
        order by c.sales_date desc
        limit greatest(1, least(coalesce(p_limit,60), 400))
      ) d
    ),'[]'::jsonb)
  );
end;
$function$;

revoke all on function public.owner_get_sales_report(date) from public, anon;
revoke all on function public.owner_list_sales_report_dates(integer) from public, anon;
grant execute on function public.owner_get_sales_report(date) to authenticated;
grant execute on function public.owner_list_sales_report_dates(integer) to authenticated;
