-- 011_door_codes.sql : 출입 비밀번호(정문·연습실·화장실)(2026-10-28 사용자 결정)
-- · 비밀번호는 서버(settings 표)에만 저장합니다. 화면 코드·GitHub에는 넣지 않습니다(공개 저장소).
-- · 예약·시간 변경·내 예약 조회에 성공한 사람 중, 아직 끝나지 않은 확정 예약이 있는 사람에게만 보여 줍니다.
-- · 관리자는 설정 > 출입 비밀번호에서 직접 바꿉니다.

insert into public.settings (key, value) values ('door_codes', '{"gate":"0000","room":"0000","toilet":"0000"}')
  on conflict (key) do nothing;

create or replace function public.door_codes() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.settings where key = 'door_codes'), '{}'::jsonb)
$$;

-- 이름+비밀번호가 맞는, 아직 끝나지 않은 확정 예약이 있으면 출입 비밀번호를 줍니다.
-- 맞히기 시도를 막기 위해 없으면 실패 횟수를 셉니다(내 예약 조회와 같은 이름 잠금).
create or replace function public.my_codes(p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name);
begin
  if public.is_locked(n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
  if exists (select 1 from public.reservations
              where name = n and status = 'confirmed' and not public.slot_ended(date, hour) and public.pw_ok(p_pw, pw_hash)) then
    return jsonb_build_object('ok', true, 'codes', public.door_codes());
  end if;
  perform public.fail_hit(n);
  return jsonb_build_object('ok', true, 'codes', null);
end $$;

-- 관리자: 출입 비밀번호 보기·바꾸기(각 1~20자)
create or replace function public.admin_door_codes() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'codes', public.door_codes());
end $$;

create or replace function public.admin_set_door_codes(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text; v text; c jsonb := '{}'::jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  foreach k in array array['gate','room','toilet'] loop
    v := trim(coalesce(p->>k, ''));
    if v = '' or char_length(v) > 20 then
      return public.fail(case k when 'gate' then '정문' when 'room' then '연습실' else '화장실' end || ' 비밀번호를 1~20자로 입력하십시오.');
    end if;
    c := c || jsonb_build_object(k, v);
  end loop;
  insert into public.settings (key, value) values ('door_codes', c)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'door_codes', '{}'::jsonb);  -- 비밀번호 자체는 기록에 남기지 않음
  return jsonb_build_object('ok', true, 'codes', c);
end $$;

revoke execute on function public.door_codes() from public, anon, authenticated;
revoke execute on function public.my_codes(text, text) from public, anon, authenticated;
revoke execute on function public.admin_door_codes() from public, anon, authenticated;
revoke execute on function public.admin_set_door_codes(jsonb) from public, anon, authenticated;
grant execute on function public.my_codes(text, text) to anon, authenticated;
grant execute on function public.admin_door_codes() to authenticated;
grant execute on function public.admin_set_door_codes(jsonb) to authenticated;
