-- 005_product_target.sql : 상품 정보에 대상 구분(target: stu 재원생 / ext 외부 이용자)을 함께 보냅니다.
-- 화면(내 예약)에서 상품 글자색을 재원생 청록 / 외부 이용자 테라코타로 나누는 데 씁니다.
-- create or replace라 기존 권한은 그대로 유지됩니다(이 함수는 화면에서 직접 부를 수 없는 내부 함수).
create or replace function public.product_json(pid bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare p public.products; t date := public.app_today(); used int;
  lf jsonb; tg text;
begin
  select * into p from public.products where id = pid;
  if not found then return null; end if;
  select type into tg from public.users where id = p.user_id;
  used := public.product_used(p.id);
  if p.kind = 'flat' then
    lf := jsonb_build_object(
      'today', case when t between p.start_date and p.end_date then greatest(p.daily_limit - public.product_used(p.id, t), 0) end,
      'tomorrow', case when t + 1 between p.start_date and p.end_date then greatest(p.daily_limit - public.product_used(p.id, t + 1), 0) end);
  else
    lf := jsonb_build_object('total', greatest(p.total_count - used, 0));
  end if;
  return jsonb_build_object('id', p.id, 'kind', p.kind, 'target', tg, 'start', p.start_date, 'end', p.end_date,
    'limit', p.daily_limit, 'total', p.total_count, 'used', used, 'left', lf,
    'topups', coalesce((select jsonb_agg(jsonb_build_object('date', (created_at at time zone 'Asia/Seoul')::date,
                         'add', added_count, 'days', days) order by id) from public.product_topups where product_id = p.id), '[]'));
end $$;
revoke execute on function public.product_json(bigint) from public, anon, authenticated;
