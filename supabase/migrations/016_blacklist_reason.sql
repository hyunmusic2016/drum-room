-- 016_blacklist_reason.sql : 블랙리스트 사유와 이력(2026-10-30 사용자 요청)
-- · 블랙리스트에 넣을 때 사유(선택, 200자까지)를 적을 수 있고, 블랙리스트인 동안 관리자가 사유를 고칠 수 있습니다.
-- · 복귀해도 이력(횟수, 마지막 등록일, 복귀일, 사유)을 남겨 관리자 화면에 "블랙리스트 이력"으로 보여 줍니다.
-- · 이 정보는 관리자 함수(user_json → admin_users/admin_user)로만 나가며, 공개 함수에는 넣지 않습니다.

alter table public.users add column if not exists black_reason text;
alter table public.users add column if not exists black_count int not null default 0;
alter table public.users add column if not exists black_at timestamptz;
alter table public.users add column if not exists black_restored_at timestamptz;

-- 015 이전에 이미 블랙리스트였던 사람(있다면) 이력 채우기
update public.users set black_count = greatest(black_count, 1), black_at = coalesce(black_at, status_at)
 where status = 'blacklisted';

-- 이용자 정보 묶음에 블랙리스트 사유·이력 추가(나머지는 014와 같음)
create or replace function public.user_json(uid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', u.id, 'type', u.type, 'name', u.name, 'phone', u.phone, 'part', u.part, 'memo', u.memo,
    'status', u.status, 'status_at', u.status_at, 'created_at', u.created_at,
    'current', public.product_json(public.current_product(u.id)),
    'last', public.product_json((select id from public.products where user_id = u.id order by end_date desc, id desc limit 1)),
    'last_used', public.user_last_used(u.id), 'dormant', public.user_dormant(u.id),
    'black_reason', u.black_reason, 'black_count', u.black_count, 'black_at', u.black_at, 'black_restored_at', u.black_restored_at)
  from public.users u where u.id = uid
$$;

-- 상태 바꾸기: 블랙리스트 사유(p_reason) 추가, 등록·복귀 때 이력 기록(나머지는 015와 같음)
drop function if exists public.admin_set_status(bigint, text);
create or replace function public.admin_set_status(p_id bigint, p_status text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint; u public.users; nc int := 0; rs text := nullif(left(trim(coalesce(p_reason, '')), 200), '');
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_status not in ('active','expired','blacklisted') then return public.fail('잘못된 요청입니다.'); end if;
  select * into u from public.users where id = p_id;
  if not found then return public.fail('없는 이용자입니다.', true); end if;
  if p_status = 'expired' then
    for pid in select id from public.products where user_id = p_id and end_date >= public.app_today() loop
      perform public.end_product_row(pid);
    end loop;
  end if;
  if p_status = 'blacklisted' then
    if u.type <> 'ext' then return public.fail('블랙리스트는 외부 이용자만 등록할 수 있습니다.'); end if;
    if u.status = 'blacklisted' then return public.fail('이미 블랙리스트에 있습니다.', true); end if;
    update public.reservations set status = 'cancelled', updated_at = now(), cancel_reason = '관리자 취소: 이용 제한'
     where user_id = p_id and status = 'confirmed' and not public.slot_ended(date, hour);
    get diagnostics nc = row_count;
    update public.users set black_reason = rs, black_count = black_count + 1, black_at = now(), black_restored_at = null
     where id = p_id;
  end if;
  if p_status = 'active' and u.status = 'blacklisted' then
    update public.users set black_restored_at = now() where id = p_id;  -- 사유·횟수는 이력으로 남김
  end if;
  update public.users set status = p_status, status_at = now() where id = p_id;
  perform public.audit('admin', 'set_status', jsonb_build_object('id', p_id, 'status', p_status, 'cancelled', nc));
  return jsonb_build_object('ok', true, 'user', public.user_json(p_id), 'cancelled', nc);
end $$;

-- 블랙리스트 사유 고치기(블랙리스트인 동안, 200자까지, 비우면 사유 없음)
create or replace function public.admin_set_black_reason(p_id bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  update public.users set black_reason = nullif(left(trim(coalesce(p_reason, '')), 200), '')
   where id = p_id and status = 'blacklisted';
  if not found then return public.fail('블랙리스트 이용자가 아닙니다.', true); end if;
  perform public.audit('admin', 'black_reason', jsonb_build_object('id', p_id));
  return jsonb_build_object('ok', true, 'user', public.user_json(p_id));
end $$;

revoke execute on function public.user_json(bigint) from public, anon, authenticated;
revoke execute on function public.admin_set_status(bigint, text, text) from public, anon, authenticated;
revoke execute on function public.admin_set_black_reason(bigint, text) from public, anon, authenticated;
grant execute on function public.admin_set_status(bigint, text, text) to authenticated;
grant execute on function public.admin_set_black_reason(bigint, text) to authenticated;
