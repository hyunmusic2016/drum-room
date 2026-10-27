-- 001_schema.sql : 표(테이블)와 기본 보안 설정
-- 현실용음악학원 드럼 연습실 예약 시스템
-- 원칙: 모든 표는 RLS로 잠그고 정책을 두지 않습니다. 브라우저(anon/authenticated)는 표를 직접 읽거나 쓸 수 없고,
--       002·003 파일의 함수(RPC)만 부를 수 있습니다.

create extension if not exists pgcrypto with schema extensions;

-- 새로 만드는 함수는 기본적으로 아무나 실행할 수 없게 합니다(필요한 함수만 따로 GRANT).
alter default privileges in schema public revoke execute on functions from public;

-- 연습실(지금은 1개)
create table public.rooms (
  id smallint primary key,
  name text not null,
  active boolean not null default true,
  sort smallint not null default 0
);
insert into public.rooms (id, name) values (1, '드럼 연습실');

-- 이용자(재원생 stu / 외부 이용자 ext)
-- status: active 사용 중 / expired 사용만료 / blacklisted 블랙리스트(동작 규칙은 아직 미정)
create table public.users (
  id bigint generated always as identity primary key,
  type text not null check (type in ('stu','ext')),
  name text not null,
  pw_hash text not null,
  phone text not null default '',
  part text not null default '',
  memo text not null default '',
  status text not null default 'active' check (status in ('active','expired','blacklisted')),
  status_at timestamptz,
  created_at timestamptz not null default now()
);
create index users_name_idx on public.users (name);

-- 정액권(flat: 하루 daily_limit회) / 이용권(count: 기간 내 총 total_count회)
create table public.products (
  id bigint generated always as identity primary key,
  user_id bigint not null references public.users(id) on delete cascade,
  kind text not null check (kind in ('flat','count')),
  start_date date not null,
  end_date date not null,
  daily_limit smallint check (daily_limit between 1 and 99),
  total_count smallint check (total_count between 1 and 999),
  created_at timestamptz not null default now(),
  check (end_date >= start_date),
  check ((kind = 'flat' and daily_limit is not null and total_count is null)
      or (kind = 'count' and total_count is not null and daily_limit is null))
);
create index products_user_idx on public.products (user_id, end_date);

-- 이용권 충전 기록
create table public.product_topups (
  id bigint generated always as identity primary key,
  product_id bigint not null references public.products(id) on delete cascade,
  added_count smallint not null check (added_count between 1 and 999),
  days smallint not null check (days between 1 and 999),
  created_at timestamptz not null default now()
);

-- 예약. status: confirmed 확정 / cancelled 취소
create table public.reservations (
  id bigint generated always as identity primary key,
  room_id smallint not null default 1 references public.rooms(id),
  date date not null,
  hour smallint not null check (hour between 0 and 23),
  name text not null,
  pw_hash text not null,
  user_id bigint references public.users(id) on delete set null,
  is_ext boolean not null default false,
  product_id bigint references public.products(id) on delete set null,
  product_kind text check (product_kind in ('flat','count')),
  status text not null default 'confirmed' check (status in ('confirmed','cancelled')),
  cancel_reason text not null default '',
  by_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- 같은 연습실·날짜·시간에는 확정 예약이 하나만 (동시에 눌러도 한 명만 성공)
create unique index reservations_slot_uniq on public.reservations (room_id, date, hour) where status = 'confirmed';
create index reservations_name_idx on public.reservations (name, date);
create index reservations_product_idx on public.reservations (product_id) where product_id is not null;
create index reservations_user_idx on public.reservations (user_id) where user_id is not null;

-- 이용 불가 시간(1시간 단위). group_id로 한 번에 설정한 묶음을 구분
create table public.blocked_slots (
  id bigint generated always as identity primary key,
  room_id smallint not null default 1 references public.rooms(id),
  date date not null,
  hour smallint not null check (hour between 0 and 23),
  reason text not null default '',
  group_id uuid not null,
  created_at timestamptz not null default now(),
  unique (room_id, date, hour)
);

-- 설정값
create table public.settings (
  key text primary key,
  value jsonb not null
);
insert into public.settings (key, value) values
  ('keep_months', '3'),        -- 지난 예약·만료 상품 보관 기간(개월)
  ('period_days', '30'),       -- 상품 기본 기간(일)
  ('lock_fails', '5'),         -- 비밀번호 몇 번 틀리면 잠글지
  ('lock_minutes', '15');      -- 잠금 시간(분)

-- 비밀번호 실패 기록(5회 실패 시 15분 잠금)
create table public.login_attempts (
  key text primary key,
  fails smallint not null default 0,
  locked_until timestamptz
);

-- 관리자(Supabase 로그인 계정과 연결, 1명)
create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- 변경 이력
create table public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor text not null,
  action text not null,
  detail jsonb not null default '{}'
);

-- 모든 표: RLS 켜고 정책 없음 = 브라우저에서 직접 접근 불가
alter table public.rooms enable row level security;
alter table public.users enable row level security;
alter table public.products enable row level security;
alter table public.product_topups enable row level security;
alter table public.reservations enable row level security;
alter table public.blocked_slots enable row level security;
alter table public.settings enable row level security;
alter table public.login_attempts enable row level security;
alter table public.admins enable row level security;
alter table public.audit_log enable row level security;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
