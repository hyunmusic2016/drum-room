-- 012_my_user_type.sql : 내 예약 조회 결과에 이용자 구분(재원생/외부 이용자) 추가(2026-10-28 사용자 요청)
-- 내 예약 맨 위에 이름 + 구분 배지 + 정액권/횟수권 배지를 보여 주기 위함. 나머지 동작은 002와 같습니다.

create or replace function public.my_reservations(p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); kf date := public.keep_from(); list jsonb; uid bigint; cur bigint;
begin
  if public.is_locked(n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
  if not public.valid_name(n) or not public.valid_pw(p_pw) then
    return public.fail('이름 또는 비밀번호가 일치하지 않거나 예약이 없습니다.'); end if;
  select jsonb_agg(jsonb_build_object('id', id, 'date', date, 'hour', hour, 'status', status, 'reason', cancel_reason,
           'prod', product_kind, 'ext', is_ext, 'started', public.slot_started(date, hour), 'ended', public.slot_ended(date, hour))
           order by date, hour)
    into list from public.reservations where name = n and date >= kf and public.pw_ok(p_pw, pw_hash);
  select id into uid from public.users where name = n and public.pw_ok(p_pw, pw_hash)
   order by (status = 'active') desc, id desc limit 1;
  if list is null and uid is null then
    perform public.fail_hit(n);
    return public.fail('이름 또는 비밀번호가 일치하지 않거나 예약이 없습니다.');
  end if;
  perform public.fail_reset(n);
  if uid is not null then cur := public.current_product(uid); end if;
  return jsonb_build_object('ok', true, 'now', public.app_now(), 'list', coalesce(list, '[]'),
    -- 등록 이용자면 구분(stu/ext), 미등록이면 null(화면은 예약의 구분으로 판단)
    'user_type', (select type from public.users where id = uid),
    'product', public.product_json(cur),
    'old_products', coalesce((select jsonb_agg(public.product_json(id) order by end_date desc) from public.products
                     where user_id = uid and end_date < public.app_today() and end_date >= kf), '[]'));
end $$;

revoke execute on function public.my_reservations(text, text) from public, anon, authenticated;
grant execute on function public.my_reservations(text, text) to anon, authenticated;
