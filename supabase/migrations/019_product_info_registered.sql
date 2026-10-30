-- 019_product_info_registered.sql : 예약 창 상품 정보에 "등록 이용자 맞음" 표시 추가(2026-10-30 사용자 요청)
-- · 정액권·횟수권이 없는 외부 이용자가 예약할 때 일반 예약 이용료 입금 안내 창을 띄우려면,
--   이름+비밀번호가 맞는 등록 외부 이용자인지 알아야 합니다(미등록이면 어차피 예약이 거절되므로 안내를 띄우지 않음).
-- · 맞을 때만 registered:true를 줍니다. 틀리면 지금처럼 product:null만(누가 등록됐는지 알 수 없음).
-- · 나머지는 017의 product_info와 같습니다.

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
  -- 019: 이름+비밀번호가 맞는 등록 이용자(사용 중)라는 표시. 화면은 상품 없는 외부 이용자에게 일반 예약 입금 안내를 띄움
  return jsonb_build_object('ok', true, 'registered', true, 'product', public.product_json(pid));
end $$;

revoke execute on function public.product_info(text, text, text) from public, anon, authenticated;
grant execute on function public.product_info(text, text, text) to anon, authenticated;
