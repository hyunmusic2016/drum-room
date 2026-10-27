-- 006_admin_reserve_product.sql : 관리자 예약도 정액권·이용권 횟수를 차감(2026-10-27 사용자 결정)
-- 입력한 구분·이름·비밀번호가 등록 이용자와 맞고, 그 날짜에 쓸 수 있는 정액권·이용권이 있으면
-- 일반 예약과 같은 원칙으로 그 상품의 횟수를 씁니다(다 썼으면 막음, 취소하면 돌려받음).
-- 상품이 없는 사람(일반 재원생, 미등록 외부 이용자 등)은 이전과 같이 하루 횟수·등록 확인 없이 예약합니다.

create or replace function public.admin_reserve(p_date date, p_hour int, p_name text, p_pw text, p_ext boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); t date := public.app_today(); prob jsonb; rid bigint; uid bigint;
  pid bigint; p public.products;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 예약할 수 있습니다.', true); end if;
  if not public.valid_name(n) then return public.fail('본명을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if not public.valid_pw(p_pw) then return public.fail('비밀번호는 숫자 4자리입니다.'); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  -- 같은 이름의 예약은 한 번에 하나씩 처리(공개 예약과 같은 잠금)
  perform pg_advisory_xact_lock(hashtext('name:' || n));
  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;
  uid := public.find_user(case when p_ext then 'ext' else 'stu' end, n, p_pw);
  if uid is not null then pid := public.product_on(uid, p_date); end if;
  if pid is not null then
    select * into p from public.products where id = pid for update; -- 같은 상품 동시 사용 방지
    if p.kind = 'count' and public.product_used(p.id) >= p.total_count then
      return public.fail('이용권 횟수(' || p.total_count || '회)를 모두 사용했습니다. 이용자 현황 > 수정에서 횟수를 늘린 뒤 예약하십시오.'); end if;
    if p.kind = 'flat' and public.product_used(p.id, p_date) >= p.daily_limit then
      return public.fail('정액권 하루 이용 횟수(' || p.daily_limit || '회)를 모두 사용했습니다.'); end if;
  end if;
  begin
    insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext, by_admin, product_id, product_kind)
    values (p_date, p_hour, n, public.hash_pw(p_pw), uid, coalesce(p_ext, false), true, p.id, p.kind) returning id into rid;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('admin', 'reserve', jsonb_build_object('id', rid));
  return jsonb_build_object('ok', true, 'id', rid, 'date', p_date, 'hour', p_hour, 'name', n, 'ext', coalesce(p_ext, false),
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end);
end $$;

revoke execute on function public.admin_reserve(date, int, text, text, boolean) from public, anon, authenticated;
grant execute on function public.admin_reserve(date, int, text, text, boolean) to authenticated;
