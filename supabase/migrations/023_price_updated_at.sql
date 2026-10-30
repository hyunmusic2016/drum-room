-- 023_price_updated_at.sql : 이용료 표의 마지막 수정 날짜(2026-10-30 사용자 요청)
-- · 관리자가 이용료 변경에서 [저장]할 때, 1회 이용료나 상품 가격 표가 실제로 바뀌었으면 그날(서울 날짜)을 price_list.updated_at에 남깁니다.
--   아무것도 안 바꾸고 저장하면 날짜는 그대로입니다.
-- · price_info(공개)가 updated_at을 함께 주므로, 손님용 [이용료 보기]와 관리자 화면에 "○월 ○일 기준" 날짜를 보여 줍니다.
-- · 나머지 검사·저장 동작은 022와 같습니다.

create or replace function public.admin_set_prices(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  fee text := replace(replace(replace(trim(coalesce(p->>'fee', '')), ',', ''), '원', ''), ' ', '');
  k text; lbl text; maxn int; arr jsonb; row jsonb; n text; pr text; out jsonb := '{}'; lst jsonb; i int;
  old jsonb; old_fee text; upd text;
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
  -- 바뀐 것이 있을 때만 수정 날짜를 오늘로
  old := coalesce((select value from public.settings where key = 'price_list'), '{}'::jsonb);
  old_fee := coalesce((select value->>'fee' from public.settings where key = 'pay_account'), '');
  upd := old->>'updated_at';
  if upd is null or (old - 'updated_at') is distinct from out or old_fee is distinct from fee then
    upd := public.app_today()::text;
  end if;
  out := out || jsonb_build_object('updated_at', upd);
  insert into public.settings (key, value) values ('price_list', out)
    on conflict (key) do update set value = excluded.value;
  update public.settings set value = value || jsonb_build_object('fee', fee) where key = 'pay_account';
  if not found then
    insert into public.settings (key, value) values ('pay_account', jsonb_build_object('bank','','holder','','number','','fee',fee));
  end if;
  perform public.audit('admin', 'price_list', '{}'::jsonb);
  return public.price_info();
end $$;

revoke execute on function public.admin_set_prices(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_prices(jsonb) to authenticated;
