-- 004_cleanup.sql : 오래된 기록 자동 정리(보관 기간 3개월)
-- 지난 예약과 만료된 정액권·이용권은 3개월 보관 뒤 삭제합니다.
-- 단, 아직 끝나지 않은 상품(이용권)에 연결된 예약은 지우지 않습니다(지우면 사용 횟수가 줄어듦).

create or replace function public.cleanup_old() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare kf date := public.keep_from(); r int; p int;
begin
  delete from public.reservations x
   where x.date < kf
     and not exists (select 1 from public.products q where q.id = x.product_id and q.end_date >= kf);
  get diagnostics r = row_count;
  delete from public.products where end_date < kf;   -- 충전 기록도 함께 삭제됨
  get diagnostics p = row_count;
  delete from public.blocked_slots where date < public.app_today() - 1;
  delete from public.login_attempts where locked_until is null or locked_until < now() - interval '1 day';
  delete from public.audit_log where at < now() - make_interval(months => coalesce(public.setting_int('keep_months'), 3));
  return jsonb_build_object('ok', true, 'reservations', r, 'products', p);
end $$;
revoke execute on function public.cleanup_old() from public, anon, authenticated;

-- 매일 새벽 3시 10분(서울)에 정리. pg_cron 확장이 있는 곳(Supabase)에서만 예약합니다.
-- (pg_cron 시각은 UTC 기준: 18:10 UTC = 다음 날 03:10 KST)
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron with schema pg_catalog';
    execute $c$ select cron.schedule('drum-room-cleanup', '10 18 * * *', 'select public.cleanup_old()') $c$;
  else
    raise notice 'pg_cron이 없어 자동 정리 예약을 건너뜁니다(로컬 시험).';
  end if;
end $$;
