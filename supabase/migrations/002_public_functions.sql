-- 002_public_functions.sql : 도우미 함수 + 누구나(로그인 없이) 부를 수 있는 함수
-- 모든 함수는 SECURITY DEFINER(표 주인 권한으로 실행)이고 search_path를 비워 두어 이름 바꿔치기를 막습니다.
-- 응답은 jsonb: 성공 {ok:true,...} / 실패 {ok:false, msg:'안내 문구', refresh:화면을 새로 고쳐야 하는지}
-- 공개 응답에는 이름 원본·비밀번호·전화번호·메모를 넣지 않습니다(이름은 가린 이름만).

-- ===== 시간 =====
-- 서울 기준 현재 시각. 로컬 시험(postgres로 접속)에서만 app.fake_now로 시각을 바꿀 수 있습니다.
create or replace function public.app_now() returns timestamp
language plpgsql stable set search_path = '' as $$
declare f text := current_setting('app.fake_now', true);
begin
  if session_user = 'postgres' and coalesce(f, '') <> '' then return f::timestamp; end if;
  return (now() at time zone 'Asia/Seoul');
end $$;
create or replace function public.app_today() returns date
language sql stable set search_path = '' as $$ select public.app_now()::date $$;
-- 시작 시각이 지났는지 / 끝 시각이 지났는지(23시 칸은 다음 날 0시에 끝남)
create or replace function public.slot_started(d date, h int) returns boolean
language sql stable set search_path = '' as $$ select (d + make_interval(hours => h)) <= public.app_now() $$;
create or replace function public.slot_ended(d date, h int) returns boolean
language sql stable set search_path = '' as $$ select (d + make_interval(hours => h + 1)) <= public.app_now() $$;

-- ===== 설정값 =====
create or replace function public.setting_int(k text) returns int
language sql stable security definer set search_path = '' as $$
  select (value #>> '{}')::int from public.settings where key = k
$$;
-- 보관 기간 시작일(오늘부터 3개월 전)
create or replace function public.keep_from() returns date
language sql stable security definer set search_path = '' as $$
  select (public.app_today() - make_interval(months => coalesce(public.setting_int('keep_months'), 3)))::date
$$;

-- ===== 이름·비밀번호 =====
create or replace function public.norm_name(n text) returns text
language sql immutable set search_path = '' as $$ select regexp_replace(coalesce(n, ''), '\s+', '', 'g') $$;
create or replace function public.valid_name(n text) returns boolean
language sql immutable set search_path = '' as $$ select n ~ '^[가-힣]{2,5}$' or n ~ '^[A-Za-z]{2,20}$' $$;
create or replace function public.valid_pw(p text) returns boolean
language sql immutable set search_path = '' as $$ select coalesce(p, '') ~ '^[0-9]{4}$' $$;
create or replace function public.hash_pw(p text) returns text
language sql volatile set search_path = '' as $$ select extensions.crypt(p, extensions.gen_salt('bf', 6)) $$;
create or replace function public.pw_ok(p text, h text) returns boolean
language sql stable set search_path = '' as $$ select coalesce(p, '') <> '' and h = extensions.crypt(p, h) $$;
-- 공개용 가린 이름: 홍길동 → 홍*동, 홍길 → 홍*, 4글자 이상은 첫·끝 글자만
create or replace function public.mask_name(n text) returns text
language plpgsql immutable set search_path = '' as $$
declare l int := char_length(n);
begin
  if l <= 1 then return n; end if;
  if l = 2 then return left(n, 1) || '*'; end if;
  return left(n, 1) || repeat('*', l - 2) || right(n, 1);
end $$;

-- ===== 비밀번호 실패 잠금(5회 실패 → 15분) =====
create or replace function public.is_locked(k text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.login_attempts where key = k and locked_until > now())
$$;
create or replace function public.fail_hit(k text) returns void
language plpgsql security definer set search_path = '' as $$
declare f int;
begin
  insert into public.login_attempts as a (key, fails) values (k, 1)
    on conflict (key) do update set fails = a.fails + 1 returning fails into f;
  if f >= coalesce(public.setting_int('lock_fails'), 5) then
    update public.login_attempts
       set fails = 0, locked_until = now() + make_interval(mins => coalesce(public.setting_int('lock_minutes'), 15))
     where key = k;
  end if;
end $$;
create or replace function public.fail_reset(k text) returns void
language sql security definer set search_path = '' as $$ delete from public.login_attempts where key = k $$;

-- ===== 이용자·상품 =====
-- 사용 중(active)인 이용자 중 구분·이름·비밀번호가 모두 맞는 사람
create or replace function public.find_user(t text, n text, p text) returns bigint
language sql stable security definer set search_path = '' as $$
  select id from public.users
   where type = t and name = n and status = 'active' and public.pw_ok(p, pw_hash)
   order by id limit 1
$$;
-- 상품 사용 횟수(확정 예약 수). d를 주면 그날만
create or replace function public.product_used(pid bigint, d date default null) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.reservations
   where product_id = pid and status = 'confirmed' and (d is null or date = d)
$$;
-- 그 날짜에 쓸 수 있는 상품
create or replace function public.product_on(uid bigint, d date) returns bigint
language sql stable security definer set search_path = '' as $$
  select id from public.products where user_id = uid and start_date <= d and d <= end_date
   order by end_date desc, id desc limit 1
$$;
-- 현재 상품(종료일이 오늘 이후, 시작 전 포함) 중 종료일이 가장 늦은 것
create or replace function public.current_product(uid bigint) returns bigint
language sql stable security definer set search_path = '' as $$
  select id from public.products where user_id = uid and end_date >= public.app_today()
   order by end_date desc, id desc limit 1
$$;
-- 상품 정보 묶음(화면 표시용). 오늘·내일 남은 횟수 포함
create or replace function public.product_json(pid bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p public.products; t date := public.app_today(); used int;
  lf jsonb;
begin
  select * into p from public.products where id = pid;
  if not found then return null; end if;
  used := public.product_used(p.id);
  if p.kind = 'flat' then
    lf := jsonb_build_object(
      'today', case when t between p.start_date and p.end_date then greatest(p.daily_limit - public.product_used(p.id, t), 0) end,
      'tomorrow', case when t + 1 between p.start_date and p.end_date then greatest(p.daily_limit - public.product_used(p.id, t + 1), 0) end);
  else
    lf := jsonb_build_object('total', greatest(p.total_count - used, 0));
  end if;
  return jsonb_build_object('id', p.id, 'kind', p.kind, 'start', p.start_date, 'end', p.end_date,
    'limit', p.daily_limit, 'total', p.total_count, 'used', used, 'left', lf,
    'topups', coalesce((select jsonb_agg(jsonb_build_object('date', (created_at at time zone 'Asia/Seoul')::date,
                         'add', added_count, 'days', days) order by id) from public.product_topups where product_id = p.id), '[]'));
end $$;

create or replace function public.fail(m text, refresh boolean default false) returns jsonb
language sql immutable set search_path = '' as $$ select jsonb_build_object('ok', false, 'msg', m, 'refresh', refresh) $$;

create or replace function public.audit(actor text, action text, detail jsonb default '{}') returns void
language sql security definer set search_path = '' as $$
  insert into public.audit_log (actor, action, detail) values (actor, action, detail)
$$;

-- 예약 칸 확인(지난 시간·이용 불가·이미 예약). 문제 없으면 null
create or replace function public.slot_problem(d date, h int, skip_id bigint default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.slot_ended(d, h) then return public.fail('이미 지난 시간입니다. 다른 시간을 선택하십시오.', true); end if;
  if exists (select 1 from public.blocked_slots where room_id = 1 and date = d and hour = h) then
    return public.fail('이용할 수 없는 시간입니다.', true); end if;
  if exists (select 1 from public.reservations where room_id = 1 and date = d and hour = h and status = 'confirmed'
              and (skip_id is null or id <> skip_id)) then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true); end if;
  return null;
end $$;

-- ===================== 공개 함수 =====================

-- 예약 현황(오늘·내일). 가린 이름, 상품 종류, 외부 이용자 여부, 이용 불가만 내려줍니다.
create or replace function public.public_board() returns jsonb
language sql stable security definer set search_path = '' as $$
  with d as (select public.app_today() as t)
  select jsonb_build_object(
    'now', public.app_now(), 'today', d.t, 'dates', jsonb_build_array(d.t, d.t + 1),
    'slots', (select jsonb_agg(jsonb_build_object(
        'date', g.dt, 'hour', g.h, 'past', public.slot_ended(g.dt, g.h),
        'blocked', b.id is not null, 'taken', r.id is not null,
        'masked', case when r.id is not null then public.mask_name(r.name) end,
        'prod', r.product_kind, 'ext', coalesce(r.is_ext, false)) order by g.dt, g.h)
      from (select (d.t + i)::date as dt, h from generate_series(0, 1) i, generate_series(0, 23) h) g
      left join public.reservations r on r.room_id = 1 and r.date = g.dt and r.hour = g.h and r.status = 'confirmed'
      left join public.blocked_slots b on b.room_id = 1 and b.date = g.dt and b.hour = g.h))
  from d
$$;

-- 예약 창의 상품 표시: 이름과 비밀번호가 모두 맞을 때만 상품 정보를 줍니다(결정 사항 2).
create or replace function public.product_info(p_mode text, p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); uid bigint; pid bigint; k text := 'info:' || public.norm_name(p_name);
begin
  if p_mode not in ('stu','ext') or not public.valid_name(n) or not public.valid_pw(p_pw) or public.is_locked(k) then
    return jsonb_build_object('ok', true, 'product', null); end if;
  uid := public.find_user(p_mode, n, p_pw);
  if uid is null then
    -- 상품이 있는 사람의 비밀번호를 맞혀 보는 시도는 횟수를 셉니다.
    if exists (select 1 from public.users u join public.products p on p.user_id = u.id
                where u.type = p_mode and u.name = n and u.status = 'active' and p.end_date >= public.app_today()) then
      perform public.fail_hit(k); end if;
    return jsonb_build_object('ok', true, 'product', null);
  end if;
  pid := public.current_product(uid);
  return jsonb_build_object('ok', true, 'product', public.product_json(pid));
end $$;

-- 예약하기(재원생 p_mode='stu' / 외부 이용자 'ext')
create or replace function public.reserve(p_date date, p_hour int, p_name text, p_pw text, p_consent boolean, p_mode text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n text := public.norm_name(p_name); t date := public.app_today();
  ext boolean := p_mode = 'ext'; uid bigint; pid bigint; p public.products; prob jsonb; rid bigint; c record; matched boolean := false;
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
    -- 재원생: 이 이름의 정액권이 있으면 비밀번호가 맞아야 정액권 예약
    for c in select p2.id as pid, u.id as uid, u.pw_hash from public.products p2 join public.users u on u.id = p2.user_id
              where u.type = 'stu' and u.status = 'active' and u.name = n and p2.kind = 'flat'
                and p_date between p2.start_date and p2.end_date loop
      matched := true;
      if public.pw_ok(p_pw, c.pw_hash) then pid := c.pid; uid := c.uid; exit; end if;
    end loop;
    if matched and pid is null then
      if public.is_locked('stu:' || n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
      perform public.fail_hit('stu:' || n);
      return public.fail('정액권 비밀번호가 일치하지 않습니다.');
    end if;
    if pid is null then
      if exists (select 1 from public.reservations where date = p_date and name = n and status = 'confirmed') then
        return public.fail('하루에 한 번만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.'); end if;
      uid := public.find_user('stu', n, p_pw); -- 등록된 재원생이면 연결(기록 보기용)
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

-- 내 예약 조회: 이름+비밀번호가 맞는 예약(보관 기간 안)과 현재·지난 상품
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
    'product', public.product_json(cur),
    'old_products', coalesce((select jsonb_agg(public.product_json(id) order by end_date desc) from public.products
                     where user_id = uid and end_date < public.app_today() and end_date >= kf), '[]'));
end $$;

-- 본인 취소(시작 전까지만)
create or replace function public.cancel_own(p_id bigint, p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); r public.reservations;
begin
  if public.is_locked(n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
  select * into r from public.reservations where id = p_id for update;
  if not found or r.name <> n or not public.pw_ok(p_pw, r.pw_hash) then
    perform public.fail_hit(n); return public.fail('본인의 예약이 아닙니다.'); end if;
  if r.status <> 'confirmed' then return public.fail('이미 취소된 예약입니다.', true); end if;
  if public.slot_started(r.date, r.hour) then return public.fail('시작된 예약은 직접 취소할 수 없습니다. 학원에 문의하십시오.'); end if;
  update public.reservations set status = 'cancelled', cancel_reason = '본인 취소', updated_at = now() where id = p_id;
  perform public.audit('public', 'cancel_own', jsonb_build_object('id', p_id));
  return jsonb_build_object('ok', true);
end $$;

-- 본인 시간 변경(시작 전까지만). 같은 예약을 새 시간으로 옮깁니다.
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
  elsif not r.is_ext and exists (select 1 from public.reservations where id <> r.id and date = p_date and name = r.name
                                  and status = 'confirmed') then
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

-- 권한: 위 함수 중 화면에서 부르는 6개만 anon·authenticated에 엽니다(나머지 도우미는 내부 전용).
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.public_board() to anon, authenticated;
grant execute on function public.product_info(text, text, text) to anon, authenticated;
grant execute on function public.reserve(date, int, text, text, boolean, text) to anon, authenticated;
grant execute on function public.my_reservations(text, text) to anon, authenticated;
grant execute on function public.cancel_own(bigint, text, text) to anon, authenticated;
grant execute on function public.move_own(bigint, text, text, date, int) to anon, authenticated;
