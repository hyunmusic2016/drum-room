-- 003_admin_functions.sql : 관리자 전용 함수
-- 관리자 = Supabase Auth로 로그인한 계정 중 public.admins 표에 등록된 사람(1명).
-- 모든 함수는 맨 앞에서 is_admin()을 확인하고, 아니면 아무것도 하지 않고 거절합니다.

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;
create or replace function public.not_admin() returns jsonb
language sql immutable set search_path = '' as $$ select public.fail('관리자 로그인이 필요합니다.') $$;

-- 전화번호 형식 맞추기(010-1234-5678). 형식이 틀리면 null
create or replace function public.fmt_phone(v text) returns text
language plpgsql immutable set search_path = '' as $$
declare d text := regexp_replace(coalesce(v, ''), '\D', '', 'g');
begin
  if d !~ '^01[0-9]{8,9}$' then return null; end if;
  if char_length(d) = 11 then return substr(d, 1, 3) || '-' || substr(d, 4, 4) || '-' || substr(d, 8, 4); end if;
  return substr(d, 1, 3) || '-' || substr(d, 4, 3) || '-' || substr(d, 7, 4);
end $$;

-- 이용자 정보 묶음(현재 상품, 가장 최근 상품 포함)
create or replace function public.user_json(uid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', u.id, 'type', u.type, 'name', u.name, 'phone', u.phone, 'part', u.part, 'memo', u.memo,
    'status', u.status, 'status_at', u.status_at, 'created_at', u.created_at,
    'current', public.product_json(public.current_product(u.id)),
    'last', public.product_json((select id from public.products where user_id = u.id order by end_date desc, id desc limit 1)))
  from public.users u where u.id = uid
$$;

-- 상품 입력값 확인. 문제가 있으면 fail jsonb, 없으면 null
create or replace function public.check_product(t text, kind text, s date, days int, lim int, tot int) returns jsonb
language plpgsql immutable set search_path = '' as $$
begin
  if kind not in ('flat','count') then return public.fail('정액권·이용권 종류를 확인하십시오.'); end if;
  if t = 'stu' and kind <> 'flat' then return public.fail('재원생은 정액권만 등록할 수 있습니다.'); end if;
  if s is null or days is null or days not between 1 and 999 then
    return public.fail('시작일과 기간(일)을 확인하십시오. 기간은 1 이상의 숫자로 입력하십시오.'); end if;
  if kind = 'flat' and (lim is null or lim not between 1 and 99) then
    return public.fail('하루 이용 횟수를 1~99 사이의 숫자로 입력하십시오.'); end if;
  if kind = 'count' and (tot is null or tot not between 1 and 999) then
    return public.fail('총 이용 횟수를 1~999 사이의 숫자로 입력하십시오.'); end if;
  return null;
end $$;

-- 이용자 입력값 확인 + 정리. 결과: {ok:true, name, phone, part, memo} 또는 fail
create or replace function public.check_user_fields(p jsonb, need_pw boolean) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare n text := public.norm_name(trim(p->>'name')); ph text := public.fmt_phone(p->>'phone'); pw text := coalesce(p->>'pw', '');
begin
  if coalesce(p->>'type', '') not in ('stu','ext') then return public.fail('재원생 또는 외부 이용자를 선택하십시오.'); end if;
  if not public.valid_name(n) then return public.fail('이름을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if (need_pw or pw <> '') and not public.valid_pw(pw) then return public.fail('비밀번호는 숫자 4자리입니다.'); end if;
  if ph is null then return public.fail('전화번호를 올바르게 입력하십시오. (예: 010-1234-5678)'); end if;
  return jsonb_build_object('ok', true, 'name', n, 'phone', ph,
    'part', left(trim(coalesce(p->>'part', '')), 20), 'memo', left(trim(coalesce(p->>'memo', '')), 100));
end $$;

-- 상품 종료/정리: 이미 시작한 상품은 어제로 종료(기록으로 남김), 오늘 이후 시작이면 삭제
create or replace function public.end_product_row(pid bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare t date := public.app_today();
begin
  if exists (select 1 from public.products where id = pid and start_date < t) then
    update public.products set end_date = least(end_date, t - 1) where id = pid;
  else
    delete from public.products where id = pid;
  end if;
end $$;

-- ===================== 관리자 함수 =====================

-- 예약 목록(보관 기간 안, 본명 표시)
create or replace function public.admin_reservations() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'now', public.app_now(), 'list', coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'date', r.date, 'hour', r.hour, 'name', r.name, 'status', r.status,
             'reason', r.cancel_reason, 'prod', r.product_kind, 'ext', r.is_ext, 'by_admin', r.by_admin, 'user_id', r.user_id,
             'ended', public.slot_ended(r.date, r.hour)) order by r.date, r.hour)
      from public.reservations r where r.date >= public.keep_from()), '[]'));
end $$;

-- 관리자 취소(삭제가 아니라 취소 + 사유)
create or replace function public.admin_cancel(p_id bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare rs text := left(trim(coalesce(p_reason, '')), 50);
begin
  if not public.is_admin() then return public.not_admin(); end if;
  update public.reservations set status = 'cancelled', updated_at = now(),
         cancel_reason = '관리자 취소: ' || case when rs = '' then '사유 없음' else rs end
   where id = p_id and status = 'confirmed';
  if not found then return public.fail('이미 취소되었거나 없는 예약입니다.', true); end if;
  perform public.audit('admin', 'cancel', jsonb_build_object('id', p_id, 'reason', rs));
  return jsonb_build_object('ok', true);
end $$;

-- 관리자 대리 예약: 하루 횟수·등록 여부·상품 확인 없이 예약(상품 횟수도 쓰지 않음).
-- 이미 예약된 시간, 지난 시간, 이용 불가 시간은 막습니다.
create or replace function public.admin_reserve(p_date date, p_hour int, p_name text, p_pw text, p_ext boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); t date := public.app_today(); prob jsonb; rid bigint; uid bigint;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 예약할 수 있습니다.', true); end if;
  if not public.valid_name(n) then return public.fail('본명을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if not public.valid_pw(p_pw) then return public.fail('비밀번호는 숫자 4자리입니다.'); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;
  uid := public.find_user(case when p_ext then 'ext' else 'stu' end, n, p_pw);
  begin
    insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext, by_admin)
    values (p_date, p_hour, n, public.hash_pw(p_pw), uid, coalesce(p_ext, false), true) returning id into rid;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('admin', 'reserve', jsonb_build_object('id', rid));
  return jsonb_build_object('ok', true, 'id', rid, 'date', p_date, 'hour', p_hour, 'name', n, 'ext', coalesce(p_ext, false));
end $$;

-- 이용자 목록(최근 등록이 위). 화면에서 정액권/이용권/일반, 사용만료, 블랙리스트로 나눕니다.
create or replace function public.admin_users() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'now', public.app_now(),
    'users', coalesce((select jsonb_agg(public.user_json(id) order by id desc) from public.users), '[]'));
end $$;

-- 이용자 한 명: 정보 + 상품(보관 기간 안) + 예약 기록(보관 기간 안, 최신순)
create or replace function public.admin_user(p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare kf date := public.keep_from();
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if not exists (select 1 from public.users where id = p_id) then return public.fail('없는 이용자입니다.', true); end if;
  return jsonb_build_object('ok', true, 'now', public.app_now(), 'user', public.user_json(p_id),
    'products', coalesce((select jsonb_agg(public.product_json(id) order by end_date desc, id desc)
                            from public.products where user_id = p_id and end_date >= kf), '[]'),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'date', date, 'hour', hour, 'status', status,
                                 'reason', cancel_reason, 'prod', product_kind, 'ext', is_ext, 'ended', public.slot_ended(date, hour))
                                 order by date desc, hour desc)
                                from public.reservations where user_id = p_id and date >= kf), '[]'));
end $$;

-- 이용자 등록(+ 선택 상품). p = {type, name, pw, phone, part, memo, prod:{kind,start,days,limit,total} 또는 null}
-- 모든 확인을 마친 뒤 한 번에 저장합니다(상품 확인에서 막히면 이용자도 저장 안 됨).
create or replace function public.admin_create_user(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f jsonb; t text := p->>'type'; pr jsonb := nullif(p->'prod', 'null'::jsonb); chk jsonb; uid bigint; h text;
  s date; days int;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  f := public.check_user_fields(p, true);
  if not (f->>'ok')::boolean then return f; end if;
  if exists (select 1 from public.users where type = t and name = f->>'name' and public.pw_ok(p->>'pw', pw_hash)) then
    return public.fail('같은 이름과 비밀번호로 등록된 이용자가 이미 있습니다. 다른 비밀번호를 사용하십시오.'); end if;
  if pr is not null then
    s := (pr->>'start')::date; days := (pr->>'days')::int;
    chk := public.check_product(t, pr->>'kind', s, days, (pr->>'limit')::int, (pr->>'total')::int);
    if chk is not null then return chk; end if;
  end if;
  h := public.hash_pw(p->>'pw');
  insert into public.users (type, name, pw_hash, phone, part, memo)
  values (t, f->>'name', h, f->>'phone', f->>'part', f->>'memo') returning id into uid;
  -- 등록 전에 같은 이름·비밀번호로 한 예약을 이 이용자에게 연결(예약 기록이 이어지도록)
  update public.reservations set user_id = uid where user_id is null and name = f->>'name' and public.pw_ok(p->>'pw', pw_hash);
  if pr is not null then
    insert into public.products (user_id, kind, start_date, end_date, daily_limit, total_count)
    values (uid, pr->>'kind', s, s + days - 1,
            case when pr->>'kind' = 'flat' then (pr->>'limit')::int end,
            case when pr->>'kind' = 'count' then (pr->>'total')::int end);
  end if;
  perform public.fail_reset(k) from unnest(array[f->>'name', 'ext:' || (f->>'name'), 'stu:' || (f->>'name'), 'info:' || (f->>'name')]) k;
  perform public.audit('admin', 'create_user', jsonb_build_object('id', uid));
  return jsonb_build_object('ok', true, 'user', public.user_json(uid));
exception when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range then
  return public.fail('입력값을 확인하십시오.');
end $$;

-- 이용자 수정(+ 현재 상품 수정 또는 새 상품 추가). 모든 확인을 통과해야 한 번에 반영됩니다.
-- p = {id, type, name, pw(바꿀 때만), phone, part, memo,
--      edit_prod:{start, days, limit|total}  ← 현재 상품이 있을 때
--      new_prod:{kind, start, days, limit|total} ← 현재 상품이 없을 때(선택)}
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
    return public.fail('재원생은 이용권을 사용할 수 없습니다. 이용권을 먼저 종료한 뒤 재원생으로 바꾸십시오.'); end if;
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

-- 정액권·이용권 종료(즉시). 이미 확정된 예약은 그대로 둡니다.
create or replace function public.admin_end_product(p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if not exists (select 1 from public.products where id = p_id and end_date >= public.app_today()) then
    return public.fail('이미 끝났거나 없는 상품입니다.', true); end if;
  perform public.end_product_row(p_id);
  perform public.audit('admin', 'end_product', jsonb_build_object('id', p_id));
  return jsonb_build_object('ok', true);
end $$;

-- 이용권 충전: 총 횟수에 더하고(남은 횟수 합침), 기간은 충전일(시작 전이면 시작일)부터 일수만큼(기존 종료일이 더 늦으면 유지)
create or replace function public.admin_topup(p_id bigint, p_add int, p_days int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.products; t date := public.app_today(); e date;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  select * into c from public.products where id = p_id for update;
  if not found or c.kind <> 'count' or c.end_date < t then return public.fail('사용 중인 이용권만 충전할 수 있습니다.', true); end if;
  if p_add is null or p_add not between 1 and 999 then return public.fail('추가 횟수를 1~999 사이의 숫자로 입력하십시오.'); end if;
  if p_days is null or p_days not between 1 and 999 then return public.fail('기간(일)을 1 이상의 숫자로 입력하십시오.'); end if;
  if c.total_count + p_add > 999 then
    return public.fail('총 이용 횟수는 999회를 넘을 수 없습니다. 지금 총 ' || c.total_count || '회입니다.'); end if;
  e := greatest(c.end_date, greatest(t, c.start_date) + p_days - 1);
  if exists (select 1 from public.products where user_id = c.user_id and id <> c.id and start_date <= e and end_date >= c.start_date) then
    return public.fail('충전 후 기간이 이 이용자의 다른 상품과 겹칩니다.'); end if;
  update public.products set total_count = total_count + p_add, end_date = e where id = c.id;
  insert into public.product_topups (product_id, added_count, days) values (c.id, p_add, p_days);
  perform public.audit('admin', 'topup', jsonb_build_object('id', c.id, 'add', p_add, 'days', p_days));
  return jsonb_build_object('ok', true, 'user', public.user_json(c.user_id));
end $$;

-- 이용자 상태 변경: expired 사용만료(쓰던 상품 종료) / active 다시 사용. 블랙리스트 규칙은 아직 미정이라 받지 않습니다.
create or replace function public.admin_set_status(p_id bigint, p_status text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_status not in ('active','expired') then return public.fail('잘못된 요청입니다.'); end if;
  if not exists (select 1 from public.users where id = p_id) then return public.fail('없는 이용자입니다.', true); end if;
  if p_status = 'expired' then
    for pid in select id from public.products where user_id = p_id and end_date >= public.app_today() loop
      perform public.end_product_row(pid);
    end loop;
  end if;
  update public.users set status = p_status, status_at = now() where id = p_id;
  perform public.audit('admin', 'set_status', jsonb_build_object('id', p_id, 'status', p_status));
  return jsonb_build_object('ok', true, 'user', public.user_json(p_id));
end $$;

-- 이용 불가 목록(끝나지 않은 것만, 설정 묶음별)
create or replace function public.admin_blocks() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'list', coalesce((
    select jsonb_agg(g order by g->>'from') from (
      select jsonb_build_object('group_id', group_id, 'reason', min(reason),
               'from', min(date + make_interval(hours => hour)), 'to', max(date + make_interval(hours => hour + 1))) g
        from public.blocked_slots where room_id = 1 group by group_id
       having max(date) >= public.app_today()) x), '[]'));
end $$;

-- 이용 불가 설정: 시작 날짜·시각 ~ 종료 날짜·시각(종료 시각 전까지), 최대 90일.
-- 그 사이 확정 예약이 있으면 p_confirm=false일 때 목록만 돌려주고, true일 때 모두 취소한 뒤 설정합니다.
create or replace function public.admin_block(p_sd date, p_sh int, p_ed date, p_eh int, p_reason text, p_confirm boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a timestamp; b timestamp; rs text := left(trim(coalesce(p_reason, '')), 30); hits jsonb; gid uuid := gen_random_uuid(); n int;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_sd is null or p_sd < public.app_today() then return public.fail('시작 날짜는 오늘 이후로 선택하십시오.'); end if;
  if p_ed is null or p_sh is null or p_eh is null or p_sh not between 0 and 23 or p_eh not between 0 and 23 then
    return public.fail('시간을 확인하십시오. 종료는 시작보다 늦어야 하며, 시각은 0~23이어야 합니다.'); end if;
  a := p_sd + make_interval(hours => p_sh); b := p_ed + make_interval(hours => p_eh);
  if b <= a then return public.fail('시간을 확인하십시오. 종료는 시작보다 늦어야 하며, 시각은 0~23이어야 합니다.'); end if;
  if b - a > interval '90 days' then return public.fail('한 번에 최대 90일까지만 설정할 수 있습니다.'); end if;
  select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'date', date, 'hour', hour) order by date, hour) into hits
    from public.reservations where room_id = 1 and status = 'confirmed'
     and date + make_interval(hours => hour) >= a and date + make_interval(hours => hour) < b;
  if hits is not null and not coalesce(p_confirm, false) then
    return public.fail('이 기간에 예약이 ' || jsonb_array_length(hits) || '건 있습니다.') || jsonb_build_object('need_confirm', true, 'hits', hits);
  end if;
  update public.reservations set status = 'cancelled', updated_at = now(),
         cancel_reason = '관리자 취소: 이용 불가' || case when rs <> '' then ' (' || rs || ')' else '' end
   where room_id = 1 and status = 'confirmed'
     and date + make_interval(hours => hour) >= a and date + make_interval(hours => hour) < b;
  insert into public.blocked_slots (room_id, date, hour, reason, group_id)
  select 1, ts::date, extract(hour from ts)::int, rs, gid from generate_series(a, b - interval '1 hour', interval '1 hour') ts
  on conflict (room_id, date, hour) do nothing;
  get diagnostics n = row_count;
  perform public.audit('admin', 'block', jsonb_build_object('from', a, 'to', b, 'slots', n, 'cancelled', coalesce(jsonb_array_length(hits), 0)));
  return jsonb_build_object('ok', true, 'slots', n, 'cancelled', coalesce(jsonb_array_length(hits), 0));
end $$;

create or replace function public.admin_unblock(p_group uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  delete from public.blocked_slots where group_id = p_group;
  perform public.audit('admin', 'unblock', jsonb_build_object('group_id', p_group));
  return jsonb_build_object('ok', true);
end $$;

-- 비밀번호 잠금 해제(이름 기준)
create or replace function public.admin_unlock(p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name);
begin
  if not public.is_admin() then return public.not_admin(); end if;
  delete from public.login_attempts where key in (n, 'ext:' || n, 'stu:' || n, 'info:' || n);
  return jsonb_build_object('ok', true);
end $$;

-- 권한: 관리자 함수는 로그인한 사람(authenticated)에게만 열고, 함수 안에서 다시 관리자인지 확인합니다.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.public_board() to anon, authenticated;
grant execute on function public.product_info(text, text, text) to anon, authenticated;
grant execute on function public.reserve(date, int, text, text, boolean, text) to anon, authenticated;
grant execute on function public.my_reservations(text, text) to anon, authenticated;
grant execute on function public.cancel_own(bigint, text, text) to anon, authenticated;
grant execute on function public.move_own(bigint, text, text, date, int) to anon, authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.admin_reservations() to authenticated;
grant execute on function public.admin_cancel(bigint, text) to authenticated;
grant execute on function public.admin_reserve(date, int, text, text, boolean) to authenticated;
grant execute on function public.admin_users() to authenticated;
grant execute on function public.admin_user(bigint) to authenticated;
grant execute on function public.admin_create_user(jsonb) to authenticated;
grant execute on function public.admin_update_user(jsonb) to authenticated;
grant execute on function public.admin_end_product(bigint) to authenticated;
grant execute on function public.admin_topup(bigint, int, int) to authenticated;
grant execute on function public.admin_set_status(bigint, text) to authenticated;
grant execute on function public.admin_blocks() to authenticated;
grant execute on function public.admin_block(date, int, date, int, text, boolean) to authenticated;
grant execute on function public.admin_unblock(uuid) to authenticated;
grant execute on function public.admin_unlock(text) to authenticated;
