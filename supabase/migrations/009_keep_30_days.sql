-- 009_keep_30_days.sql : 보관 기간 3개월 → 30일(2026-10-28 사용자 결정) + 자동 정리 상태 확인
-- · 예약 기록: 이용일로부터 30일 뒤 삭제(아직 끝나지 않은 정액권·이용권으로 한 예약은 그 상품 종료 30일 뒤).
-- · 지난 정액권·이용권: 종료일 30일 뒤 삭제. 관리자 작업 기록: 30일 뒤 삭제.
-- · 등록 이용자 정보(이름·비밀번호·전화번호·파트·메모)는 자동 삭제 대상이 아닙니다(관리자가 지울 때까지 보관).
-- 이 파일을 실행하면 맨 마지막에 자동 정리(pg_cron) 상태가 결과로 나옵니다.

insert into public.settings (key, value) values ('keep_days', '30')
  on conflict (key) do update set value = excluded.value;
delete from public.settings where key = 'keep_months';

-- 보관 시작일: 오늘 - 30일(이 날보다 오래된 기록이 삭제 대상)
create or replace function public.keep_from() returns date
language sql stable security definer set search_path = '' as $$
  select public.app_today() - coalesce(public.setting_int('keep_days'), 30)
$$;

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
  delete from public.audit_log where at < now() - make_interval(days => coalesce(public.setting_int('keep_days'), 30));
  return jsonb_build_object('ok', true, 'reservations', r, 'products', p);
end $$;

-- 자동 정리 상태: pg_cron 설치 여부, 예약된 작업, 최근 실행 결과 5개
create or replace function public.cleanup_status() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare jobs jsonb; runs jsonb;
begin
  if to_regclass('cron.job') is null then
    return jsonb_build_object('pg_cron', false);
  end if;
  execute $q$ select coalesce(jsonb_agg(jsonb_build_object('jobname', jobname, 'schedule', schedule, 'command', command, 'active', active)), '[]')
                from cron.job $q$ into jobs;
  execute $q$ select coalesce(jsonb_agg(x), '[]') from (
                select status, start_time, end_time, return_message from cron.job_run_details d
                 where d.jobid in (select jobid from cron.job where jobname = 'drum-room-cleanup')
                 order by start_time desc limit 5) x $q$ into runs;
  return jsonb_build_object('pg_cron', true, 'jobs', jobs, 'recent_runs', runs);
end $$;

revoke execute on function public.keep_from() from public, anon, authenticated;
revoke execute on function public.cleanup_old() from public, anon, authenticated;
revoke execute on function public.cleanup_status() from public, anon, authenticated;

-- 매일 새벽 3시 10분(서울) 정리 예약을 다시 확인(같은 이름이면 덮어씀). pg_cron이 없으면 건너뜀.
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('drum-room-cleanup', '10 18 * * *', 'select public.cleanup_old()');
  end if;
end $$;

-- 결과 확인용(SQL Editor 아래 Results에 표시됨)
select public.cleanup_status() as "자동 정리 상태";
