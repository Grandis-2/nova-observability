#!/usr/bin/env bash
# 보존 기간이 지난 로그를 compactor 가 S3 에서 지우는지 본다.
#   보존 24h · compaction 20s · 삭제 유예 10s 로 띄운다(기본값은 10m · 2h — 시험을 빨리 돌리려고 줄였다)
#   72시간 전 시각의 로그(스트림 A)와 지금 로그(스트림 B)를 넣고 Loki 를 정상 종료해 S3 로 올린다
#   → 다시 띄우면 compactor 가 A 의 청크만 지우고 B 는 남겨야 한다
# 스트림을 나누는 이유: 한 스트림이면 두 로그가 한 청크에 들어가고, 청크 끝이 "지금" 이라 지워지지 않는다.
set -euo pipefail
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-retention}"
export LOKI_RETENTION_PERIOD=24h
export LOKI_COMPACTION_INTERVAL=20s
export LOKI_RETENTION_DELETE_DELAY=10s
# shellcheck source=test/lib.sh
. "$(dirname "$0")/lib.sh"

# 청크 키는 <테넌트>/<스트림 해시>/<from 16진 ms>:<through 16진 ms>:<체크섬> 이다. through 가 보존 경계보다 이전인 것을 센다.
chunks_by_age() {
  python3 -I -c '
import sys, time
cut = (time.time() - 24 * 3600) * 1000
old = new = 0
for line in sys.stdin:
    key = line.split()[-1] if line.strip() else ""
    if key.startswith("index/") or key.count(":") != 2:
        continue
    through = int(key.rsplit("/", 1)[-1].split(":")[1], 16)
    if through < cut: old += 1
    else: new += 1
print(old, new)'
}

up

echo "── 72시간 전 로그(스트림 A) · 지금 로그(스트림 B)"
SERVICE=obs-retention-old EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
send_log 72
SERVICE=obs-retention-new EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
send_log 0
n="$(poll_event "$LOKI")"
[ "$n" -ge 1 ] || fail "지금 로그를 Loki 에서 못 찾음"

echo "── 정상 종료로 S3 에 올리기"
"${DC[@]}" stop loki >/dev/null
objs="$(s3_objects)"
echo "$objs" | sed 's/^/    /'
read -r old new <<<"$(echo "$objs" | chunks_by_age)"
[ "$old" -ge 1 ] && [ "$new" -ge 1 ] || fail "S3 에 오래된 청크($old) · 새 청크($new) 가 각각 1개 이상이어야 한다"
pass "S3: 보존 경계 밖 청크 ${old}개 · 안 청크 ${new}개"

echo "── 다시 띄워 compactor 를 기다린다 (최대 4분)"
"${DC[@]}" start loki >/dev/null
wait_ready
for i in $(seq 1 48); do
  sleep 5
  objs="$(s3_objects)"
  read -r old new <<<"$(echo "$objs" | chunks_by_age)"
  [ "$old" = 0 ] && break
done
echo "$objs" | sed 's/^/    /'
[ "$old" = 0 ] || fail "4분 안에 보존 경계 밖 청크가 지워지지 않았다 (남은 수 $old)"
[ "$new" -ge 1 ] || fail "보존 기간 안의 청크까지 지워졌다"
pass "compactor 가 보존 경계 밖 청크만 지웠다 (약 $((i * 5))초, 남은 새 청크 ${new}개)"
n="$(poll_event "$LOKI")"
[ "$n" -ge 1 ] && pass "보존 기간 안의 로그는 그대로 찾힘" || fail "보존 기간 안의 로그를 못 찾음"

echo "통과"
