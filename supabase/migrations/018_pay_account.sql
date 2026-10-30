-- 018_pay_account.sql : 입금 계좌(은행명·예금주·계좌번호·일반 이용료)를 서버에 저장하고 관리자가 바꾸기(2026-10-30 사용자 요청)
-- · 관리자 > 설정 > 입금 계좌 변경에서 저장하면, 계좌가 보이는 모든 화면(상품 만료 안내 창 등)이 열릴 때마다 서버에서 새로 받아 오므로 바로 바뀝니다.
-- · 학원 입금 계좌는 손님에게 보여 주는 정보라 공개 함수(pay_info)로 줍니다. 이용자 개인정보는 없습니다.
-- · 처음 값은 비어 있음 → 화면은 "입금 계좌가 아직 등록되지 않았습니다" 안내.

insert into public.settings (key, value) values ('pay_account', '{"bank":"","holder":"","number":"","fee":""}')
  on conflict (key) do nothing;

create or replace function public.pay_info() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true) || coalesce((select value from public.settings where key = 'pay_account'),
         '{"bank":"","holder":"","number":"","fee":""}'::jsonb)
$$;

-- 관리자: 저장(은행명·예금주 각 20자까지, 계좌번호는 숫자와 - 만 6~30자, 이용료는 숫자 7자리까지·비워도 됨)
create or replace function public.admin_set_pay(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare bank text := trim(coalesce(p->>'bank', '')); holder text := trim(coalesce(p->>'holder', ''));
  num text := trim(coalesce(p->>'number', '')); fee text := replace(replace(trim(coalesce(p->>'fee', '')), ',', ''), '원', '');
  c jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
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

revoke execute on function public.pay_info() from public, anon, authenticated;
revoke execute on function public.admin_set_pay(jsonb) from public, anon, authenticated;
grant execute on function public.pay_info() to anon, authenticated;
grant execute on function public.admin_set_pay(jsonb) to authenticated;
