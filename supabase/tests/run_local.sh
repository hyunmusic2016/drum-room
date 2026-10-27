#!/usr/bin/env bash
# 로컬 PostgreSQL에 빈 DB를 만들고 마이그레이션 + 시험을 실행합니다.
# 사용법: PGHOST=<소켓 폴더> PGPORT=<포트> bash supabase/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
P="psql -U postgres -v ON_ERROR_STOP=1 -q -tA"
$P -c "drop database if exists drum_test" -c "create database drum_test"
for f in supabase/tests/00_local_shim.sql supabase/migrations/0*.sql supabase/tests/01_rules_test.sql; do
  echo "== $f"
  $P -d drum_test -f "$f"
done
