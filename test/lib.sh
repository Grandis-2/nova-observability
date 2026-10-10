# smoke.sh · retention.sh · masking.sh · agent-probe.sh 가 같이 쓴다. source 해서 쓴다.
# stack/ 을 test/compose.local.yaml(S3 대신 Floci)과 함께 띄우는 데 필요한 값과 함수.
# 포트는 다른 스택과 겹치지 않게 1xxxx 를 쓴다. KEEP=1 이면 끝나도 내리지 않는다.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SERVICE="${SERVICE:-obs-smoke}"

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-test}"
export OBS_OTLP_GRPC_PORT="${OBS_OTLP_GRPC_PORT:-14317}"
export OBS_OTLP_HTTP_PORT="${OBS_OTLP_HTTP_PORT:-14318}"
export OBS_GRAFANA_PORT="${OBS_GRAFANA_PORT:-13000}"
export OBS_LOKI_PORT="${OBS_LOKI_PORT:-13100}"
export LOKI_S3_BUCKET="${LOKI_S3_BUCKET:-obs-smoke-loki}"
export LOKI_S3_REGION="${LOKI_S3_REGION:-ap-northeast-2}"
export LOKI_RETENTION_PERIOD="${LOKI_RETENTION_PERIOD:-24h}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/$COMPOSE_PROJECT_NAME.XXXXXX")"
export OBS_DATA_DIR="$WORK/data"
export GRAFANA_ADMIN_PASSWORD_FILE="$WORK/grafana_admin_password"
mkdir -p "$OBS_DATA_DIR/loki" "$OBS_DATA_DIR/grafana"
# 컨테이너 UID(10001 · 472)와 맞지 않는 Linux 호스트를 위해 열어 둔다. 시험용 임시 디렉터리다.
chmod 777 "$OBS_DATA_DIR/loki" "$OBS_DATA_DIR/grafana"
GRAFANA_PASSWORD="smoke-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s' "$GRAFANA_PASSWORD" > "$GRAFANA_ADMIN_PASSWORD_FILE"
chmod 644 "$GRAFANA_ADMIN_PASSWORD_FILE"

DC=(docker compose -f stack/compose.yaml -f test/compose.local.yaml)
LOKI="http://127.0.0.1:$OBS_LOKI_PORT"
GRAFANA="http://127.0.0.1:$OBS_GRAFANA_PORT"

# 컨테이너가 만든 파일(UID 10001 · 472, 0750)은 Linux 호스트 사용자가 지우지 못한다. 같은 바인드 마운트를 단 컨테이너 안에서 지운다.
wipe() {
  docker run --rm -v "$1:/d" alpine:3.20 find /d -mindepth 1 -delete
}

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then
    echo "KEEP=1 — 내리지 않는다. 내릴 때: COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME ${DC[*]} down -v; rm -rf $WORK"
    echo "Grafana admin 비밀번호 파일: $GRAFANA_ADMIN_PASSWORD_FILE"
    return
  fi
  "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  wipe "$OBS_DATA_DIR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; exit 1; }

wait_ready() {
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$LOKI/ready")" = 200 ] && return 0
    sleep 2
  done
  "${DC[@]}" logs loki | tail -30
  fail "Loki /ready 가 180초 안에 200 이 아니다"
}

# event_id 로 찾은 줄 수. 첫 인자는 기준 URL, 나머지는 curl 옵션.
count_event() {
  local base="$1"; shift
  local q="{service_name=\"$SERVICE\", deployment_environment=\"local\"} | event_id=\"$EVENT_ID\""
  curl -s -G "$@" "$base/loki/api/v1/query_range" \
    --data-urlencode "query=$q" --data-urlencode "since=1h" --data-urlencode "limit=10" \
    | python3 -I -c 'import sys,json; d=json.load(sys.stdin); print(sum(len(s["values"]) for s in d["data"]["result"]))' 2>/dev/null \
    || echo 0
}

poll_event() {
  local n=0
  for _ in $(seq 1 30); do
    n="$(count_event "$@")"
    [ "$n" -ge 1 ] && { echo "$n"; return 0; }
    sleep 2
  done
  echo "$n"
}

# 로그 1건을 OTLP/HTTP 로 보낸다. 첫 인자: 몇 시간 전 시각으로 찍을지(기본 0).
send_log() {
  local now_ns code
  now_ns="$(python3 -I -c "import time; print(time.time_ns() - int(${1:-0} * 3600e9))")"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$OBS_OTLP_HTTP_PORT/v1/logs" \
    -H 'Content-Type: application/json' -d @- <<JSON
{"resourceLogs":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"$SERVICE"}},
  {"key":"service.namespace","value":{"stringValue":"smoke"}},
  {"key":"deployment.environment","value":{"stringValue":"local"}},
  {"key":"process.pid","value":{"intValue":"4242"}}
 ]},
 "scopeLogs":[{"scope":{"name":"smoke"},"logRecords":[{
  "timeUnixNano":"$now_ns","severityText":"INFO","severityNumber":9,
  "body":{"stringValue":"outbox published"},
  "attributes":[{"key":"event_id","value":{"stringValue":"$EVENT_ID"}},
                {"key":"aggregate_type","value":{"stringValue":"SMOKE"}}]
 }]}]}]}
JSON
)"
  [ "$code" = 200 ] && pass "Collector 가 받음 (HTTP 200, event_id=$EVENT_ID)" || fail "Collector 응답 $code"
}

s3_objects() {
  "${DC[@]}" run --rm --no-deps -T --entrypoint aws s3-bucket --endpoint-url http://s3:4566 \
    s3 ls "s3://$LOKI_S3_BUCKET" --recursive 2>/dev/null || true
}


up() {
  echo "── 띄우기 ($COMPOSE_PROJECT_NAME, 작업 디렉터리 $WORK)"
  "${DC[@]}" up -d --quiet-pull
  wait_ready
  pass "Loki ready"
}
