#!/usr/bin/env bash
# 동시 예약 시험: 접속 두 개가 거의 동시에 예약합니다. 먼저 run_local.sh로 drum_test DB를 만든 뒤 실행하십시오.
# A는 예약 후 2초 동안 확정(commit)을 미루고, 그 사이 B가 예약을 시도합니다.
set -euo pipefail
P="psql -U postgres -d drum_test -v ON_ERROR_STOP=1 -q -tA"
NOW="set app.fake_now = '2026-10-27 14:30:00'; set role anon;"
$P -c "delete from public.reservations where date >= '2026-10-27'"

echo "[1] 같은 시간(내일 9시)을 서로 다른 두 사람이 동시에 예약"
$P -c "$NOW begin; select public.reserve('2026-10-28', 9, '정동시', '1111', true, 'stu')->>'ok'; select pg_sleep(2); commit;" > /tmp/drum_a.txt &
sleep 0.5
B=$($P -c "$NOW select public.reserve('2026-10-28', 9, '한동시', '2222', true, 'stu')->>'msg';")
wait
echo "  A: $(tr -d '\n' < /tmp/drum_a.txt)   B: $B"
N=$($P -c "select count(*) from public.reservations where date = '2026-10-28' and hour = 9 and status = 'confirmed'")
[ "$N" = "1" ] && [[ "$B" == 다른\ 분이\ 방금* ]] && echo "  통과: 한 명만 예약됨" || { echo "  실패: 확정 예약 $N건"; exit 1; }

echo "[2] 같은 재원생이 서로 다른 시간을 동시에 예약(하루 1회 제한)"
$P -c "$NOW begin; select public.reserve('2026-10-28', 10, '정하루', '1111', true, 'stu')->>'ok'; select pg_sleep(2); commit;" > /tmp/drum_a.txt &
sleep 0.5
B=$($P -c "$NOW select public.reserve('2026-10-28', 11, '정하루', '1111', true, 'stu')->>'msg';")
wait
echo "  A: $(tr -d '\n' < /tmp/drum_a.txt)   B: $B"
N=$($P -c "select count(*) from public.reservations where date = '2026-10-28' and name = '정하루' and status = 'confirmed'")
[ "$N" = "1" ] && [[ "$B" == 하루에\ 한\ 번만* ]] && echo "  통과: 하루 1건만 예약됨" || { echo "  실패: 정하루 확정 예약 $N건"; exit 1; }
rm -f /tmp/drum_a.txt
echo "동시 예약 시험 통과"
