-- 017_recent_expired_info.sql : 끝난 지 7일 안의 정액권·횟수권도 예약 창에 알려 주기(2026-10-30 사용자 요청)
-- · 예약 창은 상품이 끝난 날짜를 예약할 때 "일반 예약으로 잡힙니다" 경고와 연장·이용료 안내 창을 보여 줍니다(화면 v0.21.15~).
-- · 지금까지는 사용 중·시작 예정 상품만 알려 줘서, 상품이 끝난 다음 날부터는 안내가 사라졌습니다.
-- · 이제 사용 중·시작 예정 상품이 없으면, 종료일이 7일 안에 지난 상품을 대신 알려 줍니다(화면이 종료일을 보고 안내).
-- · 이름+비밀번호가 맞을 때만 주는 것은 그대로입니다(결정 사항 2). 나머지는 002의 product_info와 같습니다.

create or replace function public.product_info(p_mode text, p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); uid bigint; pid bigint; k text := 'info:' || public.norm_name(p_name);
begin
  if p_mode not in ('stu','ext') or not public.valid_name(n) or not public.valid_pw(p_pw) or public.is_locked(k) then
    return jsonb_build_object('ok', true, 'product', null); end if;
  uid := public.find_user(p_mode, n, p_pw);
  if uid is null then
    -- 상품이 있는(또는 7일 안에 끝난) 사람의 비밀번호를 맞혀 보는 시도는 횟수를 셉니다.
    if exists (select 1 from public.users u join public.products p on p.user_id = u.id
                where u.type = p_mode and u.name = n and u.status = 'active' and p.end_date >= public.app_today() - 7) then
      perform public.fail_hit(k); end if;
    return jsonb_build_object('ok', true, 'product', null);
  end if;
  pid := public.current_product(uid);
  if pid is null then  -- 017: 끝난 지 7일 안의 상품
    select id into pid from public.products
     where user_id = uid and end_date < public.app_today() and end_date >= public.app_today() - 7
     order by end_date desc, id desc limit 1;
  end if;
  return jsonb_build_object('ok', true, 'product', public.product_json(pid));
end $$;

revoke execute on function public.product_info(text, text, text) from public, anon, authenticated;
grant execute on function public.product_info(text, text, text) to anon, authenticated;
