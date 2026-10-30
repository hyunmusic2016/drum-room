-- 022_price_list.sql : 이용료 표(1회 이용료 + 정액권·횟수권 상품 가격)(2026-10-30 사용자 요청)
-- · 관리자 > 설정 > 이용료 변경에서 한 번에 저장합니다(admin_set_prices).
--   1회 이용료는 지금처럼 pay_account.fee에(계좌 상자에 보임), 상품 가격 표는 settings.price_list에 저장합니다.
-- · 상품은 모두 30일 기준: 일반회원 정액권(하루 N회)·일반회원 횟수권(총 N회)·재원생 정액권(하루 N회), 종류마다 0~10개.
-- · 학원 이용료는 손님에게 보여 줄 수 있는 정보라 공개 함수(price_info)로 줍니다(나중에 홈 화면 버튼에서 사용 예정).

insert into public.settings (key, value) values ('price_list', '{"ext_flat":[],"ext_count":[],"stu_flat":[]}')
  on conflict (key) do nothing;

-- 공개: 1회 이용료 + 상품 가격 표
create or replace function public.price_info() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'fee', coalesce((select value->>'fee' from public.settings where key = 'pay_account'), ''))
    || coalesce((select value from public.settings where key = 'price_list'), '{"ext_flat":[],"ext_count":[],"stu_flat":[]}'::jsonb)
$$;

-- 관리자: 저장. p = {fee, ext_flat:[{n,price}], ext_count:[{n,price}], stu_flat:[{n,price}]}
-- n은 정액권이면 하루 횟수(1~99), 횟수권이면 총 횟수(1~999). 가격은 숫자 7자리까지("50,000원"처럼 넣어도 숫자만).
-- 횟수·가격이 모두 빈 줄은 버리고, 하나만 빈 줄은 안내 후 저장하지 않습니다.
create or replace function public.admin_set_prices(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  fee text := replace(replace(replace(trim(coalesce(p->>'fee', '')), ',', ''), '원', ''), ' ', '');
  k text; lbl text; maxn int; arr jsonb; row jsonb; n text; pr text; out jsonb := '{}'; lst jsonb; i int;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if fee <> '' and fee !~ '^[0-9]{1,7}$' then return public.fail('1회 이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  foreach k in array array['ext_flat','ext_count','stu_flat'] loop
    lbl := case k when 'ext_flat' then '일반회원 정액권' when 'ext_count' then '일반회원 횟수권' else '재원생 정액권' end;
    maxn := case k when 'ext_count' then 999 else 99 end;
    arr := coalesce(p->k, '[]'::jsonb);
    if jsonb_typeof(arr) <> 'array' then return public.fail('잘못된 요청입니다.'); end if;
    if jsonb_array_length(arr) > 10 then return public.fail(lbl || '은 10개까지 만들 수 있습니다.'); end if;
    lst := '[]'; i := 0;
    for row in select value from jsonb_array_elements(arr) loop
      i := i + 1;
      n := replace(replace(trim(coalesce(row->>'n', '')), '회', ''), ' ', '');
      pr := replace(replace(replace(trim(coalesce(row->>'price', '')), ',', ''), '원', ''), ' ', '');
      continue when n = '' and pr = '';
      if n !~ '^[0-9]{1,3}$' or n::int < 1 or n::int > maxn then
        return public.fail(lbl || ' ' || i || '번째 줄: 횟수를 1~' || maxn || ' 사이 숫자로 입력하십시오.'); end if;
      if pr !~ '^[0-9]{1,7}$' then
        return public.fail(lbl || ' ' || i || '번째 줄: 가격을 숫자로 입력하십시오.'); end if;
      lst := lst || jsonb_build_array(jsonb_build_object('n', n::int, 'price', pr));
    end loop;
    out := out || jsonb_build_object(k, lst);
  end loop;
  insert into public.settings (key, value) values ('price_list', out)
    on conflict (key) do update set value = excluded.value;
  update public.settings set value = value || jsonb_build_object('fee', fee) where key = 'pay_account';
  if not found then
    insert into public.settings (key, value) values ('pay_account', jsonb_build_object('bank','','holder','','number','','fee',fee));
  end if;
  perform public.audit('admin', 'price_list', '{}'::jsonb);
  return public.price_info();
end $$;

revoke execute on function public.price_info() from public, anon, authenticated;
revoke execute on function public.admin_set_prices(jsonb) from public, anon, authenticated;
grant execute on function public.price_info() to anon, authenticated;
grant execute on function public.admin_set_prices(jsonb) to authenticated;
