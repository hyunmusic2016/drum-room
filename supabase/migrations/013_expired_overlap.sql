-- 013_expired_overlap.sql : 이미 끝난(만료된) 정액권·횟수권과는 기간이 겹쳐도 새 상품을 넣을 수 있게(2026-10-30 사용자 요청)
-- 문제: 만료된 횟수권(9/30~10/29)이 있는 이용자에게 시작일 10/1로 새 상품을 넣으면
--       "시작일이 지난 상품 기간과 겹칩니다"로 막혔음. 이미 끝난 상품은 앞으로의 예약에 쓰이지 않으므로 겹쳐도 문제없음.
-- 바꾼 점: 이용자 수정(admin_update_user)의 기간 겹침 확인에서 종료일이 어제 이전인 상품은 빼고 셈.
--          아직 끝나지 않은(사용 중·시작 예정) 상품과 겹치는 것은 계속 막음.
-- 함수 내용은 010의 admin_update_user와 같고 겹침 확인 두 줄만 다릅니다.

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
    if exists (select 1 from public.products where user_id = u.id and id <> c.id and start_date <= e and end_date >= s
                 and end_date >= public.app_today()) then  -- 이미 끝난 상품은 겹쳐도 됨(013)
      return public.fail('이 이용자의 다른 상품과 기간이 겹칩니다.'); end if;
  elsif c.id is null and np is not null then
    s := (np->>'start')::date; days := (np->>'days')::int;
    chk := public.check_product(nt, np->>'kind', s, days, (np->>'limit')::int, (np->>'total')::int);
    if chk is not null then return chk; end if;
    if exists (select 1 from public.products where user_id = u.id and end_date >= s
                 and end_date >= public.app_today()) then  -- 이미 끝난 상품은 겹쳐도 됨(013)
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

revoke execute on function public.admin_update_user(jsonb) from public, anon, authenticated;
grant execute on function public.admin_update_user(jsonb) to authenticated;
