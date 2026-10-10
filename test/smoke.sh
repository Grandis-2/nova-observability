#!/usr/bin/env bash
# stack/ 을 로컬에서 띄워 로그 한 건이 끝까지 가는지 본다.
#   OTLP/HTTP 로 로그 1건 → Collector → Loki → (Loki API · Grafana 프록시) 에서 event_id 로 찾기
#   → Loki 를 SIGKILL 하고 다시 띄워도 찾히는지(WAL)
#   → 정상 종료(flush_on_shutdown) → S3 에 청크·인덱스가 생겼는지 → 로컬 디스크를 비우고 다시 띄워도 찾히는지
# S3 는 Floci 로 대신한다. 실제 AWS 와 다른 점은 test/compose.local.yaml 머리말.
set -euo pipefail
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-smoke}"
# shellcheck source=test/lib.sh
. "$(dirname "$0")/lib.sh"

up
EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
echo "── 로그 1건 보내기 (OTLP/HTTP)"
send_log
n="$(poll_event "$LOKI")"
[ "$n" -ge 1 ] && pass "Loki API: | event_id=\"$EVENT_ID\" → ${n}줄" || fail "Loki 에서 event_id 로 못 찾음"

labels="$(curl -s "$LOKI/loki/api/v1/labels?since=1h")"
echo "  인덱스 라벨: $(echo "$labels" | python3 -I -c 'import sys,json; print(",".join(json.load(sys.stdin)["data"]))')"
echo "$labels" | grep -q '"event_id"' && fail "event_id 가 인덱스 라벨이 됐다"
echo "$labels" | grep -q '"process_pid"' && fail "허용 목록 밖의 process.pid 가 라벨이 됐다"
pass "event_id · process.pid 는 인덱스 라벨이 아니다"

# structured metadata 로 들어갔는지, 허용 목록 밖 리소스 속성(process.pid)이 버려졌는지
meta="$(curl -s -G "$LOKI/loki/api/v1/query_range" -H 'X-Loki-Response-Encoding-Flags: categorize-labels' \
  --data-urlencode "query={service_name=\"obs-smoke\"} | event_id=\"$EVENT_ID\"" --data-urlencode "since=1h" \
  | python3 -I -c 'import sys,json; d=json.load(sys.stdin)["data"]["result"]; print(json.dumps([v[2] for s in d for v in s["values"]][:1]))')"
echo "  structured metadata: $meta"
echo "$meta" | grep -q '"event_id"' || fail "event_id 가 structured metadata 에 없다"
echo "$meta" | grep -q 'process_pid' && fail "process.pid 가 Collector 허용 목록을 통과했다"
pass "event_id 는 structured metadata, process.pid 는 버려짐"

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$OBS_OTLP_HTTP_PORT/v1/traces" \
  -H 'Content-Type: application/json' -d '{"resourceSpans":[]}')"
[ "$code" != 200 ] && pass "트레이스는 받지 않는다 (/v1/traces → $code)" || fail "트레이스 파이프라인이 열려 있다"

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -G "$LOKI/loki/api/v1/delete" \
  --data-urlencode "query={service_name=\"$SERVICE\"}" --data-urlencode "start=0")"
[ "${code:0:1}" != 2 ] && pass "삭제 요청 API 는 꺼져 있다 (→ $code)" || fail "삭제 요청이 받아졌다 ($code)"

echo "── Grafana"
anon="$(curl -s -o /dev/null -w '%{http_code}' "$GRAFANA/api/datasources")"
[ "$anon" = 401 ] && pass "익명 요청은 401" || fail "익명 요청이 $anon"
n="$(poll_event "$GRAFANA/api/datasources/proxy/uid/loki" -u "admin:$GRAFANA_PASSWORD")"
[ "$n" -ge 1 ] && pass "Grafana(Loki 데이터소스 프록시, admin 로그인): ${n}줄" || fail "Grafana 경유로 못 찾음"

echo "── 비정상 종료(SIGKILL) → 재기동: S3 에 아직 없는 로그를 WAL 이 되살리는가"
EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
send_log
n="$(poll_event "$LOKI")"
[ "$n" -ge 1 ] || fail "Loki 에서 event_id 로 못 찾음"
s3_objects | grep -v 'index/delete_requests' | grep -q . && fail "kill 전에 이미 S3 에 청크가 있다 — 이 단계가 WAL 을 시험하지 못한다"
"${DC[@]}" kill -s SIGKILL loki >/dev/null
"${DC[@]}" start loki >/dev/null
wait_ready
n="$(poll_event "$LOKI")"
[ "$n" -ge 1 ] && pass "S3 에 청크가 없던 로그를 SIGKILL 뒤 WAL 로 되살림 (${n}줄)" || fail "SIGKILL 뒤 WAL 로 못 되살림"

echo "── 정상 종료 → S3 업로드 → 로컬 디스크를 비우고 다시 띄워도 S3 에서 찾히는가"
"${DC[@]}" stop loki >/dev/null
objs="$(s3_objects)"
echo "$objs" | sed 's/^/    /' | head -10
echo "$objs" | grep -q 'index/index_' || fail "S3 에 TSDB 인덱스(index/index_*) 가 없다"
echo "$objs" | grep -v 'index/' | grep -q . || fail "S3 에 청크가 없다"
pass "flush_on_shutdown: 청크·인덱스가 S3 에 올라갔다"
# WAL · 인덱스 캐시를 지운다. 그래도 찾히면 읽기가 S3 에서 왔다는 뜻이다.
rm -rf "${OBS_DATA_DIR:?}/loki/"*
"${DC[@]}" start loki >/dev/null
wait_ready
n="$(poll_event "$LOKI")"
[ "$n" -ge 1 ] && pass "로컬 디스크를 비운 재기동 뒤에도 S3 에서 찾힘 (${n}줄)" || fail "재기동 뒤 못 찾음"

echo "통과"
