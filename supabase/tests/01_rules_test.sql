-- 로컬 시험: 마이그레이션 001~004를 적용한 빈 DB에서 실행합니다(Supabase에서는 실행하지 않음).
-- 하나라도 틀리면 그 자리에서 멈춥니다(ON_ERROR_STOP). 마지막에 "모든 시험 통과"가 나오면 성공입니다.
\set ON_ERROR_STOP 1
\set QUIET 1
create schema test;
create function test.ok(c boolean, label text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception '실패: %', label; end if;
  raise notice '통과: %', label;
end $$;
-- 권한 거부를 확인하는 도우미: sql을 실행했을 때 권한 오류가 나야 통과
create function test.denied(sql text, label text) returns void language plpgsql as $$
begin
  begin execute sql;
  exception when insufficient_privilege then raise notice '통과(거부됨): %', label; return; end;
  raise exception '실패(거부되지 않음): %', label;
end $$;
grant usage on schema test to anon, authenticated;
grant execute on all functions in schema test to anon, authenticated;

-- 시험 시각: 2026-10-27(화) 14:28 서울
set app.fake_now = '2026-10-27 14:28:00';
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000a', 'admin@test'),
                                          ('00000000-0000-0000-0000-00000000000b', 'other@test');
insert into public.admins (user_id) values ('00000000-0000-0000-0000-00000000000a');

-- ===== 1. 익명(anon) 접근 차단 =====
set role anon;
select test.denied('select * from public.reservations', '익명은 예약 표를 직접 읽을 수 없음');
select test.denied('select * from public.users', '익명은 이용자 표를 직접 읽을 수 없음');
select test.denied($$insert into public.reservations (date,hour,name,pw_hash) values ('2026-10-27',20,'x','x')$$, '익명은 예약 표에 직접 쓸 수 없음');
select test.denied($$select public.hash_pw('1111')$$, '익명은 내부 도우미 함수를 부를 수 없음');
select test.denied($$select public.admin_users()$$, '익명은 관리자 함수를 부를 수 없음');
select test.denied($$select public.cleanup_old()$$, '익명은 정리 함수를 부를 수 없음');

-- ===== 2. 예약 현황 =====
select test.ok(jsonb_array_length(public.public_board()->'slots') = 48, '현황은 오늘·내일 48칸');
select test.ok((select bool_and((s->>'past')::boolean) from jsonb_array_elements(public.public_board()->'slots') s
                 where s->>'date' = '2026-10-27' and (s->>'hour')::int < 14), '오늘 14시 전 칸은 지남');
select test.ok((select not (s->>'past')::boolean from jsonb_array_elements(public.public_board()->'slots') s
                 where s->>'date' = '2026-10-27' and (s->>'hour')::int = 14), '14:28에도 14시 칸은 열려 있음');

-- ===== 3. 재원생 예약 규칙 =====
select test.ok((public.reserve('2026-10-27', 14, '홍 길동', '1111', true, 'stu'))->>'ok' = 'true', '재원생 예약 성공(이름 공백 제거)');
select test.ok((select s->>'masked' = '홍*동' and not (s ? 'name') from jsonb_array_elements(public.public_board()->'slots') s
                 where s->>'date' = '2026-10-27' and (s->>'hour')::int = 14), '현황에는 가린 이름만(홍*동), 원본 이름 없음');
select test.ok(position('1111' in public.public_board()::text) = 0 and position('홍길동' in public.public_board()::text) = 0,
               '현황 응답 어디에도 원본 이름·비밀번호 없음');
select test.ok((public.reserve('2026-10-27', 16, '홍길동', '2222', true, 'stu'))->>'msg' like '하루에 한 번만%', '재원생 하루 1회 제한(이름 기준)');
select test.ok((public.reserve('2026-10-28', 16, '홍길동', '1111', true, 'stu'))->>'ok' = 'true', '내일은 다시 예약 가능');
select test.ok((public.reserve('2026-10-27', 14, '이서연', '2222', true, 'stu'))->>'msg' like '다른 분이 방금%', '이미 예약된 시간은 막힘');
select test.ok((public.reserve('2026-10-27', 13, '이서연', '2222', true, 'stu'))->>'msg' like '이미 지난 시간%', '지난 시간은 막힘');
select test.ok((public.reserve('2026-10-29', 13, '이서연', '2222', true, 'stu'))->>'msg' like '오늘과 내일만%', '모레는 막힘');
select test.ok((public.reserve('2026-10-27', 15, '이서연', '2222', false, 'stu'))->>'msg' like '개인정보%', '동의하지 않으면 막힘');
select test.ok((public.reserve('2026-10-27', 15, '이1', '2222', true, 'stu'))->>'msg' like '본명을%', '이름 형식 확인');
select test.ok((public.reserve('2026-10-27', 15, '이서연', '22a2', true, 'stu'))->>'msg' like '비밀번호는%', '비밀번호 4자리 확인');
select test.ok((public.reserve('2026-10-27', 23, '이서연', '2222', true, 'stu'))->>'ok' = 'true', '23시 칸 예약 가능');

-- ===== 4. 외부 이용자: 미등록은 막힘, 5회 실패 시 잠금 =====
select test.ok((public.reserve('2026-10-27', 18, '박미등', '1234', true, 'ext'))->>'msg' like '등록된 외부 이용자%', '미등록 외부 이용자는 막힘');
select public.reserve('2026-10-27', 18, '박미등', '1234', true, 'ext') from generate_series(1, 4);
select test.ok((public.reserve('2026-10-27', 18, '박미등', '1234', true, 'ext'))->>'msg' like '시도 횟수를 초과%', '5회 실패 후 잠금');

-- ===== 5. 관리자 인증 =====
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
set role authenticated;
select test.ok((public.admin_users())->>'msg' = '관리자 로그인이 필요합니다.', '관리자가 아닌 로그인 계정은 거절');
select test.denied('select * from public.users', '로그인 계정도 표는 직접 못 읽음');
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
select test.ok((public.admin_users())->>'ok' = 'true', '관리자는 이용자 목록 조회 가능');
select test.denied('select * from public.users', '관리자도 표는 직접 못 읽음(함수로만)');

-- ===== 6. 이용자 등록 + 횟수권 =====
select test.ok((public.admin_create_user('{"type":"ext","name":"김외부","pw":"0000","phone":"01000000000","part":"드럼","memo":"",
  "prod":{"kind":"count","start":"2026-10-27","days":30,"total":2}}'))->>'ok' = 'true', '외부 이용자 + 횟수권(총 2회) 등록');
select test.ok((public.admin_create_user('{"type":"ext","name":"김외부","pw":"0000","phone":"01000000000"}'))->>'msg' like '같은 이름과 비밀번호%', '같은 이름+비밀번호 중복 등록 막힘');
select test.ok((public.admin_create_user('{"type":"ext","name":"김외부","pw":"9999","phone":"0123"}'))->>'msg' like '전화번호%', '전화번호 형식 확인');
select test.ok((public.admin_create_user('{"type":"stu","name":"김재원","pw":"1234","phone":"01011112222","prod":{"kind":"count","start":"2026-10-27","days":30,"total":5}}'))->>'msg' like '재원생은 정액권만%', '재원생 횟수권 등록 막힘');
select test.ok(not exists (select 1 from jsonb_array_elements((public.admin_users())->'users') u where u->>'name' = '김재원'), '상품이 막히면 이용자도 저장 안 됨');
select test.ok(((public.admin_users())->'users'->0->'current'->>'end') = '2026-11-25', '30일 = 시작일 + 29일');
reset role;
select id as ext_uid from public.users where name = '김외부' \gset
select id as ext_pid from public.products where user_id = :ext_uid \gset

set role anon;
select test.ok((public.product_info('ext', '김외부', '1111'))->'product' = 'null'::jsonb, '비밀번호가 틀리면 상품 정보 없음');
select test.ok((public.product_info('ext', '김외부', '0000'))->'product'->>'kind' = 'count', '이름+비밀번호가 맞으면 상품 정보');
select test.ok((public.product_info('ext', '김외부', '0000'))->'product'->>'target' = 'ext', '상품 정보에 대상 구분(ext) 포함');
select (public.reserve('2026-10-27', 17, '김외부', '0000', true, 'ext'))->>'id' as e1 \gset
select test.ok(:e1 > 0, '횟수권으로 예약 1');
select test.ok((public.reserve('2026-10-27', 19, '김외부', '0000', true, 'ext'))->>'prod' = 'count', '외부 이용자는 하루 제한 없음(같은 날 2번째)');
select test.ok((public.reserve('2026-10-28', 10, '김외부', '0000', true, 'ext'))->>'msg' like '횟수권 2회를 모두%', '횟수권 횟수 다 쓰면 막힘');
select test.ok((public.cancel_own(:e1, '김외부', '1111'))->>'msg' = '본인의 예약이 아닙니다.', '비밀번호 틀리면 취소 불가');
select test.ok((public.cancel_own(:e1, '김외부', '0000'))->>'ok' = 'true', '본인 취소');
select test.ok((public.my_reservations('김외부', '0000'))->'product'->'left'->>'total' = '1', '취소하면 횟수권 횟수 돌려받음');
select test.ok((public.reserve('2026-10-28', 10, '김외부', '0000', true, 'ext'))->>'ok' = 'true', '돌려받은 횟수로 다시 예약');

-- ===== 7. 횟수권 충전 =====
reset role; set role authenticated;
select test.ok((public.admin_topup(:ext_pid, 5, 30))->'user'->'current'->>'total' = '7', '충전: 총 2 + 5 = 7회');
select test.ok((public.admin_topup(:ext_pid, 995, 30))->>'msg' like '총 이용 횟수는 999회%', '충전 후 999회 초과 막힘');
reset role;
select test.ok((select end_date = '2026-11-25' and total_count = 7 from public.products where id = :ext_pid), '충전 기간: 기존 종료일이 더 늦으면 유지');
select test.ok((select count(*) = 1 from public.product_topups where product_id = :ext_pid), '충전 기록 남음');

-- ===== 8. 재원생 정액권 =====
set role authenticated;
select test.ok((public.admin_create_user('{"type":"stu","name":"김정액","pw":"0000","phone":"010-0000-1111",
  "prod":{"kind":"flat","start":"2026-10-27","days":30,"limit":2}}'))->>'ok' = 'true', '재원생 + 정액권(하루 2회) 등록');
reset role; set role anon;
select (public.reserve('2026-10-27', 20, '김정액', '1111', true, 'stu')) as hm \gset
select test.ok((:'hm'::jsonb)->>'ok' = 'true' and (:'hm'::jsonb)->>'prod' is null, '정액권 재원생과 비밀번호가 다르면 동명이인 일반 재원생으로 예약(008)');
select test.ok((public.cancel_own(((:'hm'::jsonb)->>'id')::bigint, '김정액', '1111'))->>'ok' = 'true', '동명이인 예약 취소');
select (public.reserve('2026-10-27', 20, '김정액', '0000', true, 'stu'))->>'id' as f1 \gset
select test.ok((public.reserve('2026-10-27', 21, '김정액', '0000', true, 'stu'))->>'prod' = 'flat', '정액권은 하루 N회(2번째)');
select test.ok((public.reserve('2026-10-27', 22, '김정액', '0000', true, 'stu'))->>'msg' like '정액권 하루 이용 횟수(2회)%', '정액권 하루 횟수 초과 막힘');
select test.ok((public.reserve('2026-10-28', 20, '김정액', '0000', true, 'stu'))->>'ok' = 'true', '정액권 다음 날 다시 채워짐');
select test.ok((public.reserve('2026-10-28', 21, '김정액', '0000', true, 'stu'))->>'ok' = 'true', '정액권 다음 날 2번째');
select test.ok(jsonb_array_length((public.my_reservations('김정액', '0000'))->'list') = 4, '내 예약 조회: 4건');
select test.ok((public.my_reservations('김정액', '0000'))->'product'->'left'->>'today' = '0', '내 예약: 오늘 남은 횟수 0');
select test.ok((public.my_reservations('김정액', '9999'))->>'ok' = 'false', '비밀번호 틀리면 조회 안 됨');

-- ===== 9. 시간 변경 =====
select test.ok((public.move_own(:f1, '김정액', '0000', '2026-10-28', 22))->>'msg' like '정액권 하루 이용 횟수(2회)를 초과%', '정액권: 옮길 날짜 하루 횟수 확인');
select test.ok((public.move_own(:f1, '김정액', '0000', '2026-10-27', 22))->>'ok' = 'true', '시간 변경 성공');
select test.ok((public.move_own(:f1, '김정액', '0000', '2026-10-27', 23))->>'msg' like '다른 분이 방금%', '이미 예약된 시간으로 변경 불가');
reset role;
set app.fake_now = '2026-10-27 22:10:00';
set role anon;
select test.ok((public.cancel_own(:f1, '김정액', '0000'))->>'msg' like '시작된 예약은%', '시작된 예약은 본인 취소 불가');
select test.ok((public.move_own(:f1, '김정액', '0000', '2026-10-28', 5))->>'msg' like '시작된 예약은%', '시작된 예약은 본인 변경 불가');
reset role;
set app.fake_now = '2026-10-27 14:30:00';

-- ===== 10. 이용자 수정(이름·비밀번호 변경이 예약에도 반영) =====
select id as stu_uid from public.users where name = '김정액' \gset
set role authenticated;
select test.ok((public.admin_update_user(jsonb_build_object('id', :stu_uid, 'type', 'stu', 'name', '김정새', 'pw', '5555',
  'phone', '01000001111', 'part', '드럼', 'memo', '')))->>'ok' = 'true', '이용자 이름·비밀번호 수정');
reset role; set role anon;
select test.ok((public.my_reservations('김정새', '5555'))->>'ok' = 'true' and jsonb_array_length((public.my_reservations('김정새', '5555'))->'list') = 4,
               '새 이름·비밀번호로 예약 조회');
select test.ok((public.my_reservations('김정액', '0000'))->>'ok' = 'false', '옛 이름·비밀번호로는 조회 안 됨');
reset role; set role authenticated;
select test.ok((public.admin_update_user(jsonb_build_object('id', :ext_uid, 'type', 'stu', 'name', '김외부',
  'phone', '01000000000')))->>'msg' like '재원생은 횟수권을 사용할 수 없습니다%', '횟수권 사용 중인 외부 이용자를 재원생으로 변경 막힘');
select test.ok((public.admin_update_user(jsonb_build_object('id', :stu_uid, 'type', 'stu', 'name', '김정새',
  'phone', '01000001111', 'edit_prod', jsonb_build_object('start', '2026-10-27', 'days', 45, 'limit', 3))))->'user'->'current'->>'end' = '2026-12-10',
  '정액권 기간·횟수 수정(45일)');

-- ===== 11. 관리자 예약(일반예약 / 슈퍼패스, 비밀번호 없음)·취소 (007) =====
select test.ok((public.admin_reserve('2026-10-27', 15, '남궁민수', null, true, true))->>'ok' = 'true', '슈퍼패스: 미등록 외부 이용자도 예약');
select (public.admin_reservations())->'list' @> '[{"name":"남궁민수","super":true}]' as sp \gset
select test.ok(:'sp', '관리자 목록에 슈퍼패스 표시');
select test.ok((public.admin_reserve('2026-10-27', 15, '남궁민수', null, false, true))->>'msg' like '다른 분이 방금%', '슈퍼패스도 중복은 막힘');
select test.ok((public.admin_reserve('2026-10-27', 10, '남궁민수', null, false, true))->>'msg' like '이미 지난 시간%', '슈퍼패스도 지난 시간은 막힘');
select test.ok((public.admin_reserve('2026-10-27', 16, '남궁민수', null, true, false))->>'msg' like '등록되지 않은 외부 이용자%', '일반예약: 미등록 외부 이용자 막힘');
select test.ok((public.admin_reserve('2026-10-27', 16, '박재원', null, false, false))->>'ok' = 'true', '일반예약: 미등록 재원생 1회');
select test.ok((public.admin_reserve('2026-10-27', 18, '박재원', null, false, false))->>'msg' like '재원생은 하루에 한 번만%', '일반예약: 재원생 2회째 막힘');
select test.ok((public.admin_reserve('2026-10-27', 18, '박재원', null, false, true))->>'ok' = 'true', '슈퍼패스: 재원생 2회째도 예약');
select test.ok((public.admin_reserve('2026-10-27', 17, '김정새', :ext_uid, false, false))->>'msg' like '선택한 이용자를 찾을 수 없습니다%', '이름과 다른 이용자 번호는 거절');
select test.ok((public.admin_find_users('김정새', '2026-10-27'))->'users'->0->'product'->>'kind' = 'flat', '이름으로 이용자·정액권 찾기');
select test.ok((public.admin_find_users('박재원', '2026-10-27'))->>'day_taken' = 'true' and jsonb_array_length((public.admin_find_users('박재원', '2026-10-27'))->'users') = 0, '미등록 이름: 이용자 없음, 그날 예약 수');
select (public.admin_reserve('2026-10-27', 17, '김정새', :stu_uid, false, false))->>'id' as af1 \gset
reset role;
select test.ok((select product_kind = 'flat' and pw_hash is not null and user_id = :stu_uid from public.reservations where id = :af1), '일반예약: 정액권 차감 + 등록 비밀번호 연결');
set role authenticated;
select test.ok((public.admin_reserve('2026-10-27', 20, '김정새', :stu_uid, false, false))->>'msg' like '정액권 하루 이용 횟수(3회)%', '일반예약: 정액권 하루 횟수 다 쓰면 막힘');
select test.ok((public.admin_reserve('2026-10-27', 20, '김정새', :stu_uid, false, true))->>'prod' is null, '슈퍼패스: 정액권 차감 없이 예약');
select test.ok((public.admin_reserve('2026-10-28', 13, '김외부', :ext_uid, false, false))->>'prod' = 'count', '일반예약: 횟수권 차감(구분은 등록 정보를 따름)');
select test.ok((public.admin_user(:ext_uid))->'user'->'current'->'left'->>'total' = '4', '횟수권 남은 횟수 7-3 = 4');
select test.ok((public.admin_reserve('2026-10-28', 14, '김외부', :ext_uid, false, true))->>'prod' is null
           and (public.admin_user(:ext_uid))->'user'->'current'->'left'->>'total' = '4', '슈퍼패스: 횟수권 차감 없음');
reset role; set role anon;
select test.ok((public.my_reservations('김외부', '0000'))->'list' @> '[{"date":"2026-10-28","hour":13}]', '등록 이용자의 관리자 예약은 내 예약에서 보임');
reset role;
select (select id from public.reservations where name = '박재원' and hour = 16) as pj \gset
set role anon;
select test.ok((public.cancel_own(:pj, '박재원', '0000'))->>'msg' = '본인의 예약이 아닙니다.', '비밀번호 없는 예약은 아무 비밀번호로도 취소 불가');
select test.ok((public.my_reservations('박재원', '0000'))->>'ok' = 'false', '비밀번호 없는 예약은 내 예약에 안 보임');
reset role; set role authenticated;
select test.ok((public.admin_cancel(:af1, '시험'))->>'ok' = 'true', '관리자 예약 취소');
select test.ok((public.admin_cancel(:e1, '중복'))->>'ok' = 'false', '이미 취소된 예약은 다시 취소 안 됨');

-- ===== 11-2. 동명이인 재원생 하루 1회 (008) =====
select test.ok((public.admin_create_user('{"type":"ext","name":"이강현","pw":"1111","phone":"01011110000",
  "prod":{"kind":"count","start":"2026-10-27","days":30,"total":5}}'))->>'ok' = 'true', '횟수권 이용자 이강현 등록');
reset role; set role anon;
select test.ok((public.reserve('2026-10-28', 1, '이강현', '1111', true, 'ext'))->>'prod' = 'count', '횟수권 이강현 예약');
select test.ok((public.reserve('2026-10-28', 2, '이강현', '2222', true, 'stu'))->>'ok' = 'true', '재원생 이강현은 등록 이용자 이강현의 예약과 관계없이 예약(008)');
select test.ok((public.reserve('2026-10-28', 3, '이강현', '3333', true, 'stu'))->>'msg' like '하루에 한 번만%', '미등록 재원생은 같은 이름끼리 하루 1회(비밀번호 바꿔도 막힘)');
select test.ok((public.reserve('2026-10-28', 3, '김정새', '9999', true, 'stu'))->>'ok' = 'true', '정액권 재원생 김정새와 동명이인 재원생도 예약(008)');
select test.ok((public.reserve('2026-10-28', 4, '김정새', '5555', true, 'stu'))->>'prod' = 'flat', '정액권 김정새는 그대로 정액권 예약');
reset role; set role authenticated;
select test.ok((public.admin_find_users('이강현', '2026-10-28'))->>'day_taken' = 'true'
           and (public.admin_find_users('이강현', '2026-10-28'))->'users'->0->>'day_taken' = 'false', '관리자 이름 찾기: 미등록 재원생 쪽만 예약 있음');
select test.ok((public.admin_reserve('2026-10-28', 5, '이강현', null, false, false))->>'msg' like '재원생은 하루에 한 번만%', '관리자 일반예약: 미등록 재원생 이강현 2회째 막힘');
select (public.admin_find_users('이강현', '2026-10-28'))->'users'->0->>'id' as lkh \gset
select test.ok((public.admin_reserve('2026-10-28', 5, '이강현', :lkh, false, false))->>'prod' = 'count', '관리자 일반예약: 횟수권 이강현은 따로 예약');
reset role; set role anon;
select (select (x->>'id')::bigint from jsonb_array_elements((public.my_reservations('이강현', '2222'))->'list') x) as sk \gset
select test.ok((public.move_own(:sk, '이강현', '2222', '2026-10-28', 6))->>'ok' = 'true', '동명이인 이용자 예약이 있어도 시간 변경 가능(008)');
reset role; set role authenticated;

-- ===== 11-2b. 내 예약의 이용자 구분 (012) =====
reset role; set role anon;
select test.ok((public.my_reservations('이강현', '1111'))->>'user_type' = 'ext', '등록 외부 이용자는 구분 ext');
select test.ok((public.my_reservations('이강현', '2222'))->'user_type' = 'null'::jsonb, '미등록 재원생은 구분 없음(null)');
reset role; set role authenticated;

-- ===== 11-3. 출입 비밀번호 (011) =====
reset role; set role anon;
select test.ok((public.my_codes('이강현', '2222'))->'codes'->>'gate' = '0000', '앞으로의 예약이 있으면 출입 비밀번호 받음');
select test.ok((public.my_codes('이강현', '9999'))->'codes' = 'null'::jsonb, '비밀번호가 틀리면 출입 비밀번호 없음');
select test.ok((public.my_codes('예약없음', '1111'))->'codes' = 'null'::jsonb, '앞으로의 예약이 없으면 출입 비밀번호 없음');
select test.denied($$select public.door_codes()$$, '익명은 출입 비밀번호 내부 함수를 부를 수 없음');
select test.denied($$select public.admin_door_codes()$$, '익명은 관리자 출입 비밀번호 보기 불가');
select test.denied($$select public.admin_set_door_codes('{}')$$, '익명은 출입 비밀번호 변경 불가');
reset role; set role authenticated;
select test.ok((public.admin_set_door_codes('{"gate":"1234","room":"","toilet":"9"}'))->>'msg' like '연습실 비밀번호를%', '빈 비밀번호는 저장 안 됨');
select test.ok((public.admin_set_door_codes('{"gate":" 1234 ","room":"5678*","toilet":"9012#"}'))->'codes'->>'gate' = '1234', '관리자 출입 비밀번호 변경(앞뒤 공백 제거)');
select test.ok((public.admin_door_codes())->'codes'->>'toilet' = '9012#', '관리자 출입 비밀번호 보기');
reset role; set role anon;
select test.ok((public.my_codes('이강현', '2222'))->'codes'->>'room' = '5678*', '바뀐 출입 비밀번호가 바로 보임');
reset role; set role authenticated;

-- ===== 12. 이용 불가 설정 =====
select test.ok((public.admin_block('2026-10-28', 9, '2026-10-28', 12, '점검', false))->>'need_confirm' = 'true', '이용 불가 기간에 예약 있으면 확인 요청');
select test.ok((public.admin_block('2026-10-28', 9, '2026-10-28', 12, '점검', true))->>'slots' = '3', '확인하면 3칸 설정');
reset role;
select test.ok((select status = 'cancelled' and cancel_reason = '관리자 취소: 이용 불가 (점검)' from public.reservations where date = '2026-10-28' and hour = 10),
               '걸린 예약은 사유와 함께 취소');
set role anon;
select test.ok((public.reserve('2026-10-28', 11, '최민준', '4444', true, 'stu'))->>'msg' = '이용할 수 없는 시간입니다.', '이용 불가 시간은 예약 막힘');
reset role; set role authenticated;
select (public.admin_blocks())->'list'->0->>'group_id' as gid \gset
select test.ok((public.admin_unblock(:'gid'))->>'ok' = 'true', '이용 불가 해제');

-- ===== 13. 사용만료 =====
select test.ok((public.admin_set_status(:ext_uid, 'expired'))->'user'->>'status' = 'expired', '사용만료 처리');
reset role;
select test.ok(not exists (select 1 from public.products where id = :ext_pid), '사용만료: 오늘 시작한 횟수권은 삭제');
set role anon;
select test.ok((public.reserve('2026-10-28', 13, '김외부', '0000', true, 'ext'))->>'msg' like '등록된 외부 이용자%', '사용만료된 외부 이용자는 예약 불가');
reset role; set role authenticated;
select test.ok((public.admin_set_status(:ext_uid, 'blacklisted'))->>'ok' = 'false', '블랙리스트는 아직 받지 않음');
select test.ok((public.admin_set_status(:ext_uid, 'active'))->'user'->>'status' = 'active', '다시 사용');

-- ===== 14. 30일 뒤 정리 (009) =====
reset role;
set app.fake_now = '2026-12-20 12:00:00';
select test.ok(public.keep_from() = '2026-11-20', '보관 기간 30일(오늘 - 30일)');
select test.ok((public.cleanup_old())->>'ok' = 'true', '정리 함수 실행');
select test.ok(not exists (select 1 from public.reservations r where date < '2026-11-20' and not exists
                 (select 1 from public.products q where q.id = r.product_id and q.end_date >= '2026-11-20')), '30일 지난 예약 삭제');
select test.ok(exists (select 1 from public.reservations r join public.products q on q.id = r.product_id
                 where r.date < '2026-11-20' and q.end_date >= '2026-11-20'), '아직 끝나지 않은 상품의 예약은 남김(사용 횟수 보존)');
select test.ok(not exists (select 1 from public.products where end_date < '2026-11-20'), '30일 지난 상품 삭제');

select test.ok((public.cleanup_status())->>'pg_cron' = 'false', '정리 상태 확인 함수(로컬은 pg_cron 없음)');
set role anon;
select test.denied($$select public.cleanup_status()$$, '익명은 정리 상태 함수를 부를 수 없음');
reset role;

select '모든 시험 통과' as 결과;
