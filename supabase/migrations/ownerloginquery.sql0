create or replace function public.owner_get_login_identity()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_email text;
  v_owner_id uuid;
begin
  select b.owner_id into v_owner_id
  from public.businesses b
  join public.profiles p on p.id = b.owner_id
  where b.code = 'MA-GAMBRENG'
    and p.role = 'owner'
    and p.status = 'active'
  limit 1;

  if v_owner_id is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'not_configured'
    );
  end if;

  select email
  into v_email
  from auth.users
  where id = v_owner_id;

  if v_email is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'not_configured'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'email', v_email
  );
end;
$$;

revoke all
on function public.owner_get_login_identity()
from public;

revoke execute
on function public.owner_get_login_identity()
from authenticated;

grant execute
on function public.owner_get_login_identity()
to anon;
