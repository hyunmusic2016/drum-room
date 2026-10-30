-- 021_fee.sql : 1회 이용료(일반회원)를 따로 저장·변경(2026-10-30 사용자 요청)
-- · 관리자 > 설정 > 이용료 변경에서 1회 이용료만 바꿉니다(admin_set_fee). 값은 018의 pay_account.fee에 저장하므로
--   공개 함수 pay_info가 계좌와 함께 그대로 내려 줍니다(학원 이용료는 공개 정보).
-- · 입금 계좌 변경(admin_set_pay)은 이제 fee를 보내지 않으면 저장된 이용료를 그대로 둡니다(018에서는 빈 값으로 덮었음).

-- 입금 계좌 저장: fee가 없으면 기존 이용료 유지(나머지는 018과 같음)
create or replace function public.admin_set_pay(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare bank text := trim(coalesce(p->>'bank', '')); holder text := trim(coalesce(p->>'holder', ''));
  num text := trim(coalesce(p->>'number', '')); fee text; c jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p ? 'fee' then fee := replace(replace(trim(coalesce(p->>'fee', '')), ',', ''), '원', '');
  else fee := coalesce((select value->>'fee' from public.settings where key = 'pay_account'), ''); end if;
  if bank = '' or char_length(bank) > 20 then return public.fail('은행명을 1~20자로 입력하십시오.'); end if;
  if holder = '' or char_length(holder) > 20 then return public.fail('예금주를 1~20자로 입력하십시오.'); end if;
  if num !~ '^[0-9][0-9-]{4,28}[0-9]$' then return public.fail('계좌번호는 숫자와 -(하이픈)만 6~30자로 입력하십시오.'); end if;
  if fee <> '' and fee !~ '^[0-9]{1,7}$' then return public.fail('이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  c := jsonb_build_object('bank', bank, 'holder', holder, 'number', num, 'fee', fee);
  insert into public.settings (key, value) values ('pay_account', c)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'pay_account', '{}'::jsonb);
  return jsonb_build_object('ok', true) || c;
end $$;

-- 1회 이용료만 저장(숫자 7자리까지, "5,000원"처럼 넣어도 숫자만, 비우면 이용료 표시 없음). 계좌는 그대로.
create or replace function public.admin_set_fee(p_fee text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare fee text := replace(replace(replace(trim(coalesce(p_fee, '')), ',', ''), '원', ''), ' ', ''); c jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if fee <> '' and fee !~ '^[0-9]{1,7}$' then return public.fail('이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  fee := coalesce(nullif(ltrim(fee, '0'), ''), case when fee = '' then '' else '0' end);
  c := coalesce((select value from public.settings where key = 'pay_account'), '{"bank":"","holder":"","number":""}'::jsonb)
       || jsonb_build_object('fee', fee);
  insert into public.settings (key, value) values ('pay_account', c)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'fee', '{}'::jsonb);
  return jsonb_build_object('ok', true) || c;
end $$;

revoke execute on function public.admin_set_pay(jsonb) from public, anon, authenticated;
revoke execute on function public.admin_set_fee(text) from public, anon, authenticated;
grant execute on function public.admin_set_pay(jsonb) to authenticated;
grant execute on function public.admin_set_fee(text) to authenticated;
