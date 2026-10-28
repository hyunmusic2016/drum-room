-- 008_homonym_day_limit.sql : 동명이인 재원생 하루 1회 문제 수정(2026-10-28 사용자 결정)
-- 문제: 재원생 하루 1회를 "이름"만으로 세서, 이름이 같은 다른 사람(등록 이용자 이강현)의 예약 때문에
--       관계없는 재원생 이강현이 예약하지 못함. 정액권 재원생과 이름이 같은 다른 재원생은 아예 막힘.
-- 수정: 재원생 하루 1회는
--   · 등록 이용자: 그 이용자(user_id)의 재원생 예약만 셉니다.
--   · 미등록 재원생: 같은 이름의 "미등록" 재원생 예약만 셉니다(등록 이용자·외부 이용자 예약은 세지 않음).
--   · 정액권 재원생과 비밀번호가 다르면 다른 사람으로 보고 일반 재원생으로 예약합니다.

-- 그 날짜에 이 재원생(등록이면 p_uid, 미등록이면 이름)의 확정 예약이 이미 있는지. p_except: 시간 변경 중인 자기 예약
create or replace function public.stu_day_taken(p_date date, p_uid bigint, p_name text, p_except bigint default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.reservations
                  where date = p_date and status = 'confirmed' and not is_ext
                    and (p_except is null or id <> p_except)
                    and case when p_uid is not null then user_id = p_uid
                             else user_id is null and name = p_name end)
$$;

create or replace function public.reserve(p_date date, p_hour int, p_name text, p_pw text, p_consent boolean, p_mode text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n text := public.norm_name(p_name); t date := public.app_today();
  ext boolean := p_mode = 'ext'; uid bigint; pid bigint; p public.products; prob jsonb; rid bigint; c record;
begin
  if p_mode not in ('stu','ext') then return public.fail('잘못된 요청입니다.'); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 예약할 수 있습니다.', true); end if;
  if not coalesce(p_consent, false) then return public.fail('개인정보 수집에 동의해 주십시오.'); end if;
  if not public.valid_name(n) then return public.fail('본명을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if not public.valid_pw(p_pw) then return public.fail('비밀번호는 숫자 4자리입니다.'); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  -- 같은 이름의 예약은 한 번에 하나씩 처리(하루 횟수 확인이 동시에 통과하는 것을 막음)
  perform pg_advisory_xact_lock(hashtext('name:' || n));

  if ext then
    if public.is_locked('ext:' || n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
    uid := public.find_user('ext', n, p_pw);
    if uid is null then
      perform public.fail_hit('ext:' || n);
      return public.fail('등록된 외부 이용자 정보와 일치하지 않습니다. 처음 이용하시는 경우 010-7753-8730으로 연락하시기 바랍니다.')
             || jsonb_build_object('ext', true);
    end if;
    perform public.fail_reset('ext:' || n);
  end if;

  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;

  if ext then
    -- 외부 이용자: 상품이 있으면 그 횟수를 쓰고, 없으면 하루 횟수 제한 없음
    pid := public.product_on(uid, p_date);
  else
    -- 재원생: 이름+비밀번호가 맞는 정액권이 있으면 정액권 예약.
    -- 비밀번호가 다르면 동명이인(다른 사람)으로 보고 일반 재원생으로 처리(008)
    for c in select p2.id as pid, u.id as uid, u.pw_hash from public.products p2 join public.users u on u.id = p2.user_id
              where u.type = 'stu' and u.status = 'active' and u.name = n and p2.kind = 'flat'
                and p_date between p2.start_date and p2.end_date loop
      if public.pw_ok(p_pw, c.pw_hash) then pid := c.pid; uid := c.uid; exit; end if;
    end loop;
    if pid is null then
      uid := public.find_user('stu', n, p_pw); -- 등록된 재원생이면 연결
      if public.stu_day_taken(p_date, uid, n) then
        return public.fail('하루에 한 번만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.'); end if;
    end if;
  end if;

  if pid is not null then
    select * into p from public.products where id = pid for update; -- 같은 상품 동시 사용 방지
    if p.kind = 'count' and public.product_used(p.id) >= p.total_count then
      return public.fail('이용권 횟수(' || p.total_count || '회)를 모두 사용했습니다. 관리자에게 문의하십시오.'); end if;
    if p.kind = 'flat' and public.product_used(p.id, p_date) >= p.daily_limit then
      return public.fail('정액권 하루 이용 횟수(' || p.daily_limit || '회)를 모두 사용했습니다.'); end if;
  end if;

  begin
    insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext, product_id, product_kind)
    values (p_date, p_hour, n, public.hash_pw(p_pw), uid, ext, p.id, p.kind) returning id into rid;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('public', 'reserve', jsonb_build_object('id', rid));
  return jsonb_build_object('ok', true, 'id', rid, 'date', p_date, 'hour', p_hour, 'name', n, 'ext', ext,
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end);
end $$;

create or replace function public.move_own(p_id bigint, p_name text, p_pw text, p_date date, p_hour int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); r public.reservations; p public.products; t date := public.app_today(); prob jsonb;
begin
  if public.is_locked(n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
  perform pg_advisory_xact_lock(hashtext('name:' || n));
  select * into r from public.reservations where id = p_id for update;
  if not found or r.name <> n or not public.pw_ok(p_pw, r.pw_hash) then
    perform public.fail_hit(n); return public.fail('본인의 예약이 아닙니다.'); end if;
  if r.status <> 'confirmed' then return public.fail('취소된 예약은 변경할 수 없습니다.', true); end if;
  if public.slot_started(r.date, r.hour) then return public.fail('시작된 예약은 직접 변경할 수 없습니다. 학원에 문의하십시오.'); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 선택할 수 있습니다.', true); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  if r.date = p_date and r.hour = p_hour then return public.fail('현재 예약과 같은 시간입니다.'); end if;
  prob := public.slot_problem(p_date, p_hour, r.id);
  if prob is not null then return prob; end if;
  if r.product_id is not null then
    -- 상품 예약: 상품 기간 안에서만 이동. 이용권은 횟수 변화 없음, 정액권은 옮길 날짜의 하루 횟수 확인
    select * into p from public.products where id = r.product_id for update;
    if not found or p_date not between p.start_date and p.end_date then
      return public.fail(case r.product_kind when 'flat' then '정액권' else '이용권' end || ' 기간 밖의 날짜입니다.'); end if;
    if p.kind = 'flat' and (select count(*) from public.reservations where product_id = p.id and date = p_date
                            and status = 'confirmed' and id <> r.id) >= p.daily_limit then
      return public.fail('정액권 하루 이용 횟수(' || p.daily_limit || '회)를 초과합니다.'); end if;
  elsif not r.is_ext and public.stu_day_taken(p_date, r.user_id, r.name, r.id) then
    return public.fail('하루에 한 번만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.');
  end if;
  begin
    update public.reservations set date = p_date, hour = p_hour, updated_at = now() where id = r.id;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('public', 'move_own', jsonb_build_object('id', r.id, 'from', r.date || ' ' || r.hour, 'to', p_date || ' ' || p_hour));
  return jsonb_build_object('ok', true, 'id', r.id, 'date', p_date, 'hour', p_hour, 'name', r.name, 'ext', r.is_ext, 'prod', r.product_kind);
end $$;

create or replace function public.admin_reserve(p_date date, p_hour int, p_name text, p_user_id bigint, p_ext boolean, p_super boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); t date := public.app_today(); prob jsonb; rid bigint;
  u public.users; uid bigint; ext boolean; h text; sup boolean := coalesce(p_super, false); pid bigint; p public.products;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 예약할 수 있습니다.', true); end if;
  if not public.valid_name(n) then return public.fail('본명을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  -- 같은 이름의 예약은 한 번에 하나씩 처리(공개 예약과 같은 잠금)
  perform pg_advisory_xact_lock(hashtext('name:' || n));
  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;

  if p_user_id is not null then
    select * into u from public.users where id = p_user_id and status = 'active';
    if not found or u.name <> n then return public.fail('선택한 이용자를 찾을 수 없습니다. 이름을 다시 입력하십시오.', true); end if;
    uid := u.id; ext := u.type = 'ext'; h := u.pw_hash;
  else
    ext := coalesce(p_ext, false);
  end if;

  if not sup then
    if ext and uid is null then
      return public.fail('등록되지 않은 외부 이용자입니다. 슈퍼패스로 예약하거나 먼저 이용자 등록을 하십시오.'); end if;
    if uid is not null then pid := public.product_on(uid, p_date); end if;
    if pid is not null then
      select * into p from public.products where id = pid for update; -- 같은 상품 동시 사용 방지
      if p.kind = 'count' and public.product_used(p.id) >= p.total_count then
        return public.fail('이용권 횟수(' || p.total_count || '회)를 모두 사용했습니다. 이용자 현황 > 수정에서 횟수를 늘리거나 슈퍼패스로 예약하십시오.'); end if;
      if p.kind = 'flat' and public.product_used(p.id, p_date) >= p.daily_limit then
        return public.fail('정액권 하루 이용 횟수(' || p.daily_limit || '회)를 모두 사용했습니다.'); end if;
    elsif not ext then
      if public.stu_day_taken(p_date, uid, n) then
        return public.fail('재원생은 하루에 한 번만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.'); end if;
    end if;
  end if;

  begin
    insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext, by_admin, is_super, product_id, product_kind)
    values (p_date, p_hour, n, h, uid, ext, true, sup, p.id, p.kind) returning id into rid;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('admin', 'reserve', jsonb_build_object('id', rid, 'super', sup));
  return jsonb_build_object('ok', true, 'id', rid, 'date', p_date, 'hour', p_hour, 'name', n, 'ext', ext, 'super', sup,
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end);
end $$;

create or replace function public.admin_find_users(p_name text, p_date date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name);
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'name', n,
    -- 미등록 재원생(이 이름) 쪽에서 그날 예약이 있는지
    'day_taken', public.stu_day_taken(p_date, null, n),
    'users', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'type', u.type, 'name', u.name,
                 'phone4', right(u.phone, 4), 'part', u.part,
                 'day_taken', u.type = 'stu' and public.stu_day_taken(p_date, u.id, n),
                 'product', public.product_json(public.product_on(u.id, p_date))) order by u.id desc)
               from public.users u where u.name = n and u.status = 'active'), '[]'));
end $$;

revoke execute on function public.stu_day_taken(date, bigint, text, bigint) from public, anon, authenticated;
revoke execute on function public.reserve(date, int, text, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.move_own(bigint, text, text, date, int) from public, anon, authenticated;
revoke execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean) from public, anon, authenticated;
revoke execute on function public.admin_find_users(text, date) from public, anon, authenticated;
grant execute on function public.reserve(date, int, text, text, boolean, text) to anon, authenticated;
grant execute on function public.move_own(bigint, text, text, date, int) to anon, authenticated;
grant execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean) to authenticated;
grant execute on function public.admin_find_users(text, date) to authenticated;
