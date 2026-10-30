-- 020_rename_ext_member.sql : 서버 안내 문구 "외부 이용자" → "일반회원"(2026-10-30 사용자 결정)
-- · 화면의 "외부 이용자"를 "일반회원"으로 바꾸면서(v0.23.0), 서버가 보내는 안내 문구도 같이 바꿉니다.
-- · 동작·데이터는 그대로(구분 값은 계속 'ext'). 각 함수는 가장 최근 정의(check_user_fields 003, reserve·admin_reserve 015,
--   admin_set_status 016)와 같고 문구만 다릅니다.

create or replace function public.check_user_fields(p jsonb, need_pw boolean) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare n text := public.norm_name(trim(p->>'name')); ph text := public.fmt_phone(p->>'phone'); pw text := coalesce(p->>'pw', '');
begin
  if coalesce(p->>'type', '') not in ('stu','ext') then return public.fail('재원생 또는 일반회원을 선택하십시오.'); end if;
  if not public.valid_name(n) then return public.fail('이름을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if (need_pw or pw <> '') and not public.valid_pw(pw) then return public.fail('비밀번호는 숫자 4자리입니다.'); end if;
  if ph is null then return public.fail('전화번호를 올바르게 입력하십시오. (예: 010-1234-5678)'); end if;
  return jsonb_build_object('ok', true, 'name', n, 'phone', ph,
    'part', left(trim(coalesce(p->>'part', '')), 20), 'memo', left(trim(coalesce(p->>'memo', '')), 100));
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
      -- 블랙리스트 일반회원(이름+비밀번호가 맞음): 실패 횟수는 세지 않고 제한 안내(015)
      if exists (select 1 from public.users where type = 'ext' and name = n and status = 'blacklisted' and public.pw_ok(p_pw, pw_hash)) then
        perform public.fail_reset('ext:' || n);
        return public.fail('현재 예약이 제한되어 있습니다. 관리자에게 문의하십시오.');
      end if;
      perform public.fail_hit('ext:' || n);
      return public.fail('등록된 일반회원 정보와 일치하지 않습니다. 처음 이용하시는 경우 010-7753-8730으로 연락하시기 바랍니다.')
             || jsonb_build_object('ext', true);
    end if;
    perform public.fail_reset('ext:' || n);
  end if;

  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;

  if ext then
    -- 일반회원: 상품이 있으면 그 횟수를 쓰고, 없으면 하루 횟수 제한 없음
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
    select * into u from public.users where id = p_user_id and status in ('active', 'blacklisted');
    if not found or u.name <> n then return public.fail('선택한 이용자를 찾을 수 없습니다. 이름을 다시 입력하십시오.', true); end if;
    -- 블랙리스트 이용자: 일반예약은 막고 슈퍼패스만 허용(015)
    if u.status = 'blacklisted' and not sup then
      return public.fail('블랙리스트 이용자입니다. 일반예약은 할 수 없습니다. 꼭 필요하면 슈퍼패스로 예약하십시오.'); end if;
    uid := u.id; ext := u.type = 'ext'; h := u.pw_hash;
  else
    ext := coalesce(p_ext, false);
  end if;

  if not sup then
    if ext and uid is null then
      return public.fail('등록되지 않은 일반회원입니다. 슈퍼패스로 예약하거나 먼저 이용자 등록을 하십시오.'); end if;
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
    if u.type <> 'ext' then return public.fail('블랙리스트는 일반회원만 등록할 수 있습니다.'); end if;
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

revoke execute on function public.check_user_fields(jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.reserve(date, int, text, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean) from public, anon, authenticated;
revoke execute on function public.admin_set_status(bigint, text, text) from public, anon, authenticated;
grant execute on function public.reserve(date, int, text, text, boolean, text) to anon, authenticated;
grant execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean) to authenticated;
grant execute on function public.admin_set_status(bigint, text, text) to authenticated;
