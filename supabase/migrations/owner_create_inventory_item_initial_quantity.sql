-- Jumlah awal saat Owner mendaftarkan logistik.
-- Stok awal ditulis ke inventory_items.stock dan dicatat di central_inventory_movements ('opening').
drop function if exists public.owner_create_inventory_item(text, text, numeric, text, text);

create or replace function public.owner_create_inventory_item(
  p_name text,
  p_unit text default 'pcs',
  p_minimum_stock numeric default 0,
  p_supplier text default null,
  p_logistics_type text default 'passive',
  p_initial_quantity numeric default 0
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  b uuid; i uuid; v_dup record;
  v_name text := regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g');
  v_qty numeric := coalesce(p_initial_quantity,0);
begin
  select business_id into b from profiles where id=(select auth.uid()) and role='owner' and status='active';
  if b is null then raise exception 'owner_access_denied'; end if;
  if v_name='' or public.master_name_key(v_name)='' then raise exception 'inventory_name_required'; end if;
  if p_minimum_stock < 0 then raise exception 'invalid_minimum_stock'; end if;
  if v_qty < 0 then raise exception 'invalid_initial_quantity'; end if;
  if p_logistics_type not in ('passive','active') then raise exception 'invalid_logistics_type'; end if;
  begin
    insert into inventory_items(business_id,name,unit,stock,minimum_stock,supplier,logistics_type)
    values(b,v_name,coalesce(nullif(trim(p_unit),''),'pcs'),v_qty,p_minimum_stock,nullif(trim(p_supplier),''),p_logistics_type)
    returning id into i;
  exception when unique_violation then
    select id,status into v_dup from inventory_items where business_id=b and name_key=public.master_name_key(v_name);
    if v_dup.status='inactive' then raise exception 'inventory_name_duplicate_inactive:%',v_dup.id; end if;
    raise exception 'inventory_name_duplicate:%',v_dup.id;
  end;
  if v_qty > 0 then
    insert into central_inventory_movements(business_id,inventory_item_id,movement_type,quantity_delta,stock_before,stock_after,reference_type,reference_id,note,created_by,inventory_item_name_snapshot,inventory_item_unit_snapshot)
    values(b,i,'opening',v_qty,0,v_qty,'inventory_item',i::text,'Stok awal saat pendaftaran logistik',(select auth.uid()),v_name,coalesce(nullif(trim(p_unit),''),'pcs'));
  end if;
  insert into audit_logs(business_id,actor_id,action,entity,entity_id,details)
  values(b,(select auth.uid()),'create','inventory_item',i,jsonb_build_object('name',v_name,'logistics_type',p_logistics_type,'initial_quantity',v_qty));
  return i;
end $function$;

revoke all on function public.owner_create_inventory_item(text,text,numeric,text,text,numeric) from public, anon;
grant execute on function public.owner_create_inventory_item(text,text,numeric,text,text,numeric) to authenticated;
