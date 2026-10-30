-- 014_dormant_users.sql : 휴면 이용자(90일 이상 이용 없음)(2026-10-30 사용자 결정)
-- · 마지막 이용일 = 확정 예약의 이용 날짜 중 가장 늦은 날(취소한 예약은 세지 않음). 예약이 한 번도 없으면 등록일.
-- · 마지막 이용일로부터 90일이 지났고, 사용 중·시작 예정인 정액권·횟수권이 없으면 "휴면"으로 표시합니다.
--   화면(설정 > 휴면 이용자)은 이 표시로 목록을 나눌 뿐이며, 휴면 이용자도 예약은 그대로 할 수 있습니다.
-- · 다시 예약하면 마지막 이용일이 바뀌어 자동으로 이용자 현황으로 돌아갑니다(따로 옮기는 작업 없음).
-- · 예약 기록은 30일 뒤 지워지므로, 지우기 전에 이용 날짜를 users.last_used에 남겨 둡니다(cleanup_old).

alter table public.users add column if not exists last_used date;

insert into public.settings (key, value) values ('dormant_days', '90')
  on conflict (key) do nothing;

-- 이미 있는 확정 예약으로 처음 값 채우기
update public.users u set last_used = m.d
  from (select user_id, max(date) d from public.reservations
         where status = 'confirmed' and user_id is not null group by user_id) m
 where m.user_id = u.id and (u.last_used is null or u.last_used < m.d);

-- 마지막 이용일: 남겨 둔 날짜, 지금 남아 있는 확정 예약, 등록일 중 가장 늦은 날
create or replace function public.user_last_used(uid bigint) returns date
language sql stable security definer set search_path = '' as $$
  select greatest(u.last_used,
                  (select max(r.date) from public.reservations r where r.user_id = u.id and r.status = 'confirmed'),
                  (u.created_at at time zone 'Asia/Seoul')::date)
    from public.users u where u.id = uid
$$;

-- 휴면 여부: 마지막 이용일로부터 90일 이상 지났고 사용 중·시작 예정 상품이 없음
create or replace function public.user_dormant(uid bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.current_product(uid) is null
     and public.app_today() - public.user_last_used(uid) >= coalesce(public.setting_int('dormant_days'), 90)
$$;

-- 이용자 정보 묶음에 마지막 이용일·휴면 여부 추가(나머지는 003과 같음)
create or replace function public.user_json(uid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', u.id, 'type', u.type, 'name', u.name, 'phone', u.phone, 'part', u.part, 'memo', u.memo,
    'status', u.status, 'status_at', u.status_at, 'created_at', u.created_at,
    'current', public.product_json(public.current_product(u.id)),
    'last', public.product_json((select id from public.products where user_id = u.id order by end_date desc, id desc limit 1)),
    'last_used', public.user_last_used(u.id), 'dormant', public.user_dormant(u.id))
  from public.users u where u.id = uid
$$;

-- 자동 정리: 예약을 지우기 전에 그 이용 날짜를 이용자의 마지막 이용일로 남김(나머지는 009와 같음)
create or replace function public.cleanup_old() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare kf date := public.keep_from(); r int; p int;
begin
  update public.users u set last_used = m.d
    from (select user_id, max(date) d from public.reservations
           where status = 'confirmed' and user_id is not null and date < kf group by user_id) m
   where m.user_id = u.id and (u.last_used is null or u.last_used < m.d);
  delete from public.reservations x
   where x.date < kf
     and not exists (select 1 from public.products q where q.id = x.product_id and q.end_date >= kf);
  get diagnostics r = row_count;
  delete from public.products where end_date < kf;   -- 충전 기록도 함께 삭제됨
  get diagnostics p = row_count;
  delete from public.blocked_slots where date < public.app_today() - 1;
  delete from public.login_attempts where locked_until is null or locked_until < now() - interval '1 day';
  delete from public.audit_log where at < now() - make_interval(days => coalesce(public.setting_int('keep_days'), 30));
  return jsonb_build_object('ok', true, 'reservations', r, 'products', p);
end $$;

revoke execute on function public.user_last_used(bigint) from public, anon, authenticated;
revoke execute on function public.user_dormant(bigint) from public, anon, authenticated;
revoke execute on function public.user_json(bigint) from public, anon, authenticated;
revoke execute on function public.cleanup_old() from public, anon, authenticated;
