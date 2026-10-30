-- 024_delete_user.sql : 이용자 삭제(2026-10-30 사용자 요청)
-- · 관리자 > 이용자 수정 맨 아래 [이용자 삭제]에서 부릅니다.
-- · 앞으로의(이용 시간이 끝나지 않은) 확정 예약은 "관리자 취소: 이용자 삭제"로 먼저 취소합니다(사용자 결정: 자동 취소).
-- · 이용자 행을 지우면 이름·비밀번호·전화번호·파트·메모·블랙리스트 사유가 함께 지워지고,
--   정액권·횟수권(products)과 충전 기록은 표의 설정(on delete cascade)으로 함께 지워집니다.
--   지난 예약·취소된 예약은 이용자 연결만 끊기고(user_id·product_id = null) 30일 보관 뒤 자동 정리됩니다.
-- · 되돌릴 수 없습니다. 작업 기록(audit_log)에는 이용자 번호와 취소 건수만 남깁니다(개인정보 없음).

create or replace function public.admin_delete_user(p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare nc int := 0;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  perform 1 from public.users where id = p_id for update;
  if not found then return public.fail('없는 이용자입니다. 이미 삭제되었을 수 있습니다.', true); end if;
  update public.reservations set status = 'cancelled', updated_at = now(), cancel_reason = '관리자 취소: 이용자 삭제'
   where user_id = p_id and status = 'confirmed' and not public.slot_ended(date, hour);
  get diagnostics nc = row_count;
  delete from public.users where id = p_id;
  perform public.audit('admin', 'delete_user', jsonb_build_object('id', p_id, 'cancelled', nc));
  return jsonb_build_object('ok', true, 'cancelled', nc);
end $$;

revoke execute on function public.admin_delete_user(bigint) from public, anon, authenticated;
grant execute on function public.admin_delete_user(bigint) to authenticated;
