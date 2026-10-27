-- 007_admin_reserve_modes.sql : 관리자 예약을 "일반예약 / 슈퍼패스"로 나누고 비밀번호 입력을 없앰(2026-10-27 사용자 결정)
-- · 관리자는 비밀번호 없이 이름으로 예약합니다. 등록 이용자는 목록에서 고르고(p_user_id), 그 사람의 비밀번호가
--   예약에 그대로 붙어 '내 예약'에서 보입니다. 미등록 이름의 예약은 비밀번호가 없어 관리자만 볼 수 있습니다.
-- · 일반예약: 일반 이용자와 같은 규칙(재원생 하루 1회, 정액권·이용권 횟수 차감·다 쓰면 막음, 미등록 외부 이용자 막음).
-- · 슈퍼패스: 하루 횟수·등록·상품 확인 없이 바로 확정, 횟수 차감 없음(이미 예약된·지난·이용 불가 시간만 막음).
-- 006의 admin_reserve(비밀번호를 받던 것)는 지웁니다.

-- 미등록 이름의 관리자 예약은 비밀번호가 없습니다.
alter table public.reservations alter column pw_hash drop not null;
-- 슈퍼패스 예약 표시
alter table public.reservations add column if not exists is_super boolean not null default false;

-- 비밀번호가 없는 예약은 어떤 비밀번호와도 맞지 않음(본인 취소·변경·조회 불가)
create or replace function public.pw_ok(p text, h text) returns boolean
language sql stable set search_path = '' as $$ select coalesce(p, '') <> '' and h is not null and h = extensions.crypt(p, h) $$;

-- 예약 창에서 이름을 넣으면: 그 이름의 등록 이용자(사용 중)와, 그 날짜에 쓸 수 있는 정액권·이용권, 그날 그 이름의 확정 예약 수
create or replace function public.admin_find_users(p_name text, p_date date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name);
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'name', n,
    'day_count', (select count(*) from public.reservations where name = n and date = p_date and status = 'confirmed'),
    'users', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'type', u.type, 'name', u.name,
                 'phone4', right(u.phone, 4), 'part', u.part,
                 'product', public.product_json(public.product_on(u.id, p_date))) order by u.id desc)
               from public.users u where u.name = n and u.status = 'active'), '[]'));
end $$;

drop function if exists public.admin_reserve(date, int, text, text, boolean);

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
      if exists (select 1 from public.reservations where date = p_date and name = n and status = 'confirmed') then
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

-- 관리자 예약 목록에 슈퍼패스 표시 추가
create or replace function public.admin_reservations() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'now', public.app_now(), 'list', coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'date', r.date, 'hour', r.hour, 'name', r.name, 'status', r.status,
             'reason', r.cancel_reason, 'prod', r.product_kind, 'ext', r.is_ext, 'by_admin', r.by_admin, 'super', r.is_super,
             'user_id', r.user_id, 'ended', public.slot_ended(r.date, r.hour)) order by r.date, r.hour)
      from public.reservations r where r.date >= public.keep_from()), '[]'));
end $$;

revoke execute on function public.pw_ok(text, text) from public, anon, authenticated;
revoke execute on function public.admin_find_users(text, date) from public, anon, authenticated;
revoke execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean) from public, anon, authenticated;
revoke execute on function public.admin_reservations() from public, anon, authenticated;
grant execute on function public.admin_find_users(text, date) to authenticated;
grant execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean) to authenticated;
grant execute on function public.admin_reservations() to authenticated;
