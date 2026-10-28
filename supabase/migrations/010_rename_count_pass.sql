-- 010_rename_count_pass.sql : 상품 이름 "이용권" → "횟수권"(2026-10-28 사용자 결정)
-- 서버가 보내는 안내 문구만 바꿉니다(동작·데이터는 그대로, 상품 종류 값은 계속 'count').
-- 함수 내용은 각 함수의 가장 최근 정의(check_product·admin_update_user는 003, reserve·move_own·admin_reserve는 008)와 같고,
-- 문구의 "이용권"만 "횟수권"으로 바뀌었습니다.

create or replace function public.check_product(t text, kind text, s date, days int, lim int, tot int) returns jsonb
language plpgsql immutable set search_path = '' as $$
begin
  if kind not in ('flat','count') then return public.fail('정액권·횟수권 종류를 확인하십시오.'); end if;
  if t = 'stu' and kind <> 'flat' then return public.fail('재원생은 정액권만 등록할 수 있습니다.'); end if;
  if s is null or days is null or days not between 1 and 999 then
    return public.fail('시작일과 기간(일)을 확인하십시오. 기간은 1 이상의 숫자로 입력하십시오.'); end if;
  if kind = 'flat' and (lim is null or lim not between 1 and 99) then
    return public.fail('하루 이용 횟수를 1~99 사이의 숫자로 입력하십시오.'); end if;
  if kind = 'count' and (tot is null or tot not between 1 and 999) then
    return public.fail('총 이용 횟수를 1~999 사이의 숫자로 입력하십시오.'); end if;
  return null;
end $$;

create or replace function public.admin_update_user(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u public.users; f jsonb; nt text := p->>'type'; pw text := nullif(p->>'pw', ''); c public.products;
  ep jsonb := nullif(p->'edit_prod', 'null'::jsonb); np jsonb := nullif(p->'new_prod', 'null'::jsonb);
  chk jsonb; s date; days int; e date; lim int; tot int; h text; used int; oldname text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  select * into u from public.users where id = (p->>'id')::bigint for update;
  if not found then return public.fail('없는 이용자입니다.', true); end if;
  f := public.check_user_fields(p, false);
  if not (f->>'ok')::boolean then return f; end if;
  select * into c from public.products where id = public.current_product(u.id) for update;
  if nt = 'stu' and c.kind = 'count' then
    return public.fail('재원생은 횟수권을 사용할 수 없습니다. 횟수권을 먼저 종료한 뒤 재원생으로 바꾸십시오.'); end if;
  if pw is not null and exists (select 1 from public.users where id <> u.id and type = nt and name = f->>'name'
                                 and public.pw_ok(pw, pw_hash)) then
    return public.fail('같은 이름과 비밀번호로 등록된 이용자가 이미 있습니다. 다른 비밀번호를 사용하십시오.'); end if;
  if c.id is not null and ep is not null then
    s := (ep->>'start')::date; days := (ep->>'days')::int;
    lim := case when c.kind = 'flat' then (ep->>'limit')::int end;
    tot := case when c.kind = 'count' then (ep->>'total')::int end;
    chk := public.check_product(nt, c.kind, s, days, lim, tot);
    if chk is not null then return chk; end if;
    e := s + days - 1;
    used := public.product_used(c.id);
    if c.kind = 'count' and tot < used then
      return public.fail('이미 ' || used || '회 사용했습니다. 총 이용 횟수는 ' || used || '회 이상이어야 합니다.'); end if;
    if exists (select 1 from public.products where user_id = u.id and id <> c.id and start_date <= e and end_date >= s) then
      return public.fail('이 이용자의 다른 상품과 기간이 겹칩니다.'); end if;
  elsif c.id is null and np is not null then
    s := (np->>'start')::date; days := (np->>'days')::int;
    chk := public.check_product(nt, np->>'kind', s, days, (np->>'limit')::int, (np->>'total')::int);
    if chk is not null then return chk; end if;
    if exists (select 1 from public.products where user_id = u.id and end_date >= s) then
      return public.fail('시작일이 지난 상품 기간과 겹칩니다. 시작일을 확인하십시오.'); end if;
  end if;

  -- 여기부터 저장
  oldname := u.name;
  h := case when pw is not null then public.hash_pw(pw) end;
  update public.users set type = nt, name = f->>'name', phone = f->>'phone', part = f->>'part', memo = f->>'memo',
         pw_hash = coalesce(h, pw_hash) where id = u.id;
  -- 이 이용자의 예약도 이름·비밀번호를 함께 바꾸고, 구분이 바뀌면 아직 끝나지 않은 확정 예약의 구분도 바꿉니다.
  update public.reservations set name = f->>'name', pw_hash = coalesce(h, pw_hash),
         is_ext = case when nt <> u.type and status = 'confirmed' and not public.slot_ended(date, hour) then nt = 'ext' else is_ext end,
         updated_at = now()
   where user_id = u.id;
  if c.id is not null and ep is not null then
    update public.products set start_date = s, end_date = e, daily_limit = lim, total_count = tot where id = c.id;
  elsif c.id is null and np is not null then
    insert into public.products (user_id, kind, start_date, end_date, daily_limit, total_count)
    values (u.id, np->>'kind', s, s + days - 1,
            case when np->>'kind' = 'flat' then (np->>'limit')::int end,
            case when np->>'kind' = 'count' then (np->>'total')::int end);
  end if;
  perform public.fail_reset(k) from unnest(array[oldname, 'ext:' || oldname, 'stu:' || oldname, 'info:' || oldname,
    f->>'name', 'ext:' || (f->>'name'), 'stu:' || (f->>'name'), 'info:' || (f->>'name')]) k;
  perform public.audit('admin', 'update_user', jsonb_build_object('id', u.id));
  return jsonb_build_object('ok', true, 'user', public.user_json(u.id));
exception when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range then
  return public.fail('입력값을 확인하십시오.');
end $$;

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
      return public.fail('횟수권 ' || p.total_count || '회를 모두 사용했습니다. 관리자에게 문의하십시오.'); end if;
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
    -- 상품 예약: 상품 기간 안에서만 이동. 횟수권은 횟수 변화 없음, 정액권은 옮길 날짜의 하루 횟수 확인
    select * into p from public.products where id = r.product_id for update;
    if not found or p_date not between p.start_date and p.end_date then
      return public.fail(case r.product_kind when 'flat' then '정액권' else '횟수권' end || ' 기간 밖의 날짜입니다.'); end if;
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
        return public.fail('횟수권 ' || p.total_count || '회를 모두 사용했습니다. 이용자 현황 > 수정에서 횟수를 늘리거나 슈퍼패스로 예약하십시오.'); end if;
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

revoke execute on function public.check_product(text, text, date, int, int, int) from public, anon, authenticated;
revoke execute on function public.admin_update_user(jsonb) from public, anon, authenticated;
revoke execute on function public.reserve(date, int, text, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.move_own(bigint, text, text, date, int) from public, anon, authenticated;
revoke execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean) from public, anon, authenticated;
grant execute on function public.admin_update_user(jsonb) to authenticated;
grant execute on function public.reserve(date, int, text, text, boolean, text) to anon, authenticated;
grant execute on function public.move_own(bigint, text, text, date, int) to anon, authenticated;
grant execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean) to authenticated;
