#!/usr/bin/env bash
# 저장 전 마스킹(stack/otel-collector.yaml 의 transform/mask)을 본다.
#   전화번호 · 이메일 · MySQL 중복 키 값을 로그 본문(문자열 · 맵) · 속성 · exception.message · exception.stacktrace 에 넣어 보내고
#   → Loki 에 저장된 줄과 structured metadata 에 원문이 없고 마스킹 표시만 있는지
#   → event_id · traceId · UUID · aggregate_id(UUID) · destination(큐 이름) · 13자리 epoch ms · 숫자 ID · 긴 숫자열은 그대로인지
# 값은 모두 가짜다. 어디서 샜는지 알 수 있게 위치마다 끝자리를 다르게 둔다.
set -euo pipefail
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-masking}"
SERVICE=obs-masking
# shellcheck source=test/lib.sh
. "$(dirname "$0")/lib.sh"

# 걸리면 안 되는 값. 일부러 전화번호처럼 보이는 숫자를 섞었다.
TRACE_ID=01012345678901234567890123456789
REF_UUID=01012345-0101-4567-8901-010123456789
EPOCH_MS=1760000000000
AGG_ID=01012345-6789-4abc-8def-010000000000   # nova 의 aggregate_id 는 UUID 문자열이다
NUM_ID=1234567
DEST=preorder-events.fifo
LONG_DIGITS=01000000000123

send() {  # body JSON 값
  local now_ns code
  now_ns="$(python3 -I -c 'import time; print(time.time_ns())')"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$OBS_OTLP_HTTP_PORT/v1/logs" \
    -H 'Content-Type: application/json' -d @- <<JSON
{"resourceLogs":[{"resource":{"attributes":[
  {"key":"service.name","value":{"stringValue":"$SERVICE"}},
  {"key":"deployment.environment","value":{"stringValue":"local"}}
 ]},
 "scopeLogs":[{"scope":{"name":"masking"},"logRecords":[{
  "timeUnixNano":"$now_ns","severityText":"ERROR","severityNumber":17,
  "body":$1,
  "attributes":[
    {"key":"event_id","value":{"stringValue":"$EVENT_ID"}},
    {"key":"traceId","value":{"stringValue":"$TRACE_ID"}},
    {"key":"ref","value":{"stringValue":"$REF_UUID"}},
    {"key":"aggregate_type","value":{"stringValue":"MASKING"}},
    {"key":"aggregate_id","value":{"stringValue":"$AGG_ID"}},
    {"key":"event_type","value":{"stringValue":"Created"}},
    {"key":"destination","value":{"stringValue":"$DEST"}},
    {"key":"order_id","value":{"stringValue":"$NUM_ID"}},
    {"key":"at_ms","value":{"stringValue":"$EPOCH_MS"}},
    {"key":"digits","value":{"stringValue":"$LONG_DIGITS"}},
    {"key":"contact","value":{"stringValue":"010 0000 0011"}},
    {"key":"mail","value":{"stringValue":"user11@example.com"}},
    {"key":"exception.message","value":{"stringValue":"could not execute statement [Duplicate entry 'kakao-0000012' for key 'uq_customer_kakao']"}},
    {"key":"exception.stacktrace","value":{"stringValue":"org.example.DataIntegrityViolation: Duplicate entry '010-0000-0013' for key 't.uq_phone'\n\tat org.example.Repo.save(Repo.java:42)\nCaused by: java.sql.SQLException: Duplicate entry 'user13@example.com' for key 't.uq_email'\n\tcontact=+82 10 0000 0014 mail=user14@example.com\n\tat org.example.Foo@1a2b3c"}}
  ]
 }]}]}]}
JSON
)"
  [ "$code" = 200 ] || fail "Collector 응답 $code"
}

# event_id 로 찾은 첫 줄의 본문과 structured metadata 를 JSON 한 줄로
stored() {
  curl -s -G "$LOKI/loki/api/v1/query_range" -H 'X-Loki-Response-Encoding-Flags: categorize-labels' \
    --data-urlencode "query={service_name=\"$SERVICE\"} | event_id=\"$EVENT_ID\"" --data-urlencode "since=1h" \
    | python3 -I -c '
import sys, json
r = json.load(sys.stdin)["data"]["result"]
v = [v for s in r for v in s["values"]][0]
print(json.dumps({"line": v[1], "meta": v[2].get("structuredMetadata", {})}, ensure_ascii=False))'
}

# 원문 조각이 하나라도 남았으면 실패
LEAKS=(
  0000-0001 "0000 0002" 01000000003 0000-0004 0000-0005 "0000 0011" 0000-0013 "0000 0014"
  user1@ user2@ user11@ user13@ user14@ kakao-0000
)
check() {  # 이름 · stored JSON · 반드시 있어야 할 마스킹 표시들
  local name="$1" got="$2"; shift 2
  local leak tok
  for leak in "${LEAKS[@]}"; do
    case "$got" in *"$leak"*) echo "    $got"; fail "$name: 원문 '$leak' 이 저장됐다";; esac
  done
  for tok in "$@"; do
    case "$got" in *"$tok"*) ;; *) echo "    $got"; fail "$name: '$tok' 이 없다";; esac
  done
  pass "$name: 원문 없음, 마스킹 표시 있음"
}

# 걸리면 안 되는 값이 그대로인지. meta 의 키별로 정확히 비교한다.
check_kept() {
  python3 -I - "$1" "$EVENT_ID" "$TRACE_ID" "$REF_UUID" "$AGG_ID" "$EPOCH_MS" "$LONG_DIGITS" "$NUM_ID" "$DEST" <<'PY' || fail "식별자가 바뀌었다"
import sys, json
got, eid, tid, ref, agg, ms, digits, num, dest = sys.argv[1:]
m = json.loads(got)["meta"]
want = {"event_id": eid, "traceId": tid, "ref": ref, "aggregate_id": agg, "aggregate_type": "MASKING",
        "event_type": "Created", "at_ms": ms, "digits": digits, "order_id": num, "destination": dest}
bad = {k: (m.get(k), v) for k, v in want.items() if m.get(k) != v}
if bad:
    print("    다름(저장값, 기대값):", bad); sys.exit(1)
PY
  pass "event_id · traceId · UUID · aggregate_id(UUID) · destination · epoch ms · 숫자 ID · 긴 숫자열은 그대로"
}

up

echo "── 문자열 본문"
EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
send '{"stringValue":"가입 실패 phone=010-0000-0001 alt=010 0000 0002 raw=01000000003 intl=+82-10-0000-0004 +821000000005 mail=user1@example.com, user2@sub.example.co.kr"}'
[ "$(poll_event "$LOKI")" -ge 1 ] || fail "event_id 로 못 찾음"
got="$(stored)"
echo "    본문: $(echo "$got" | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["line"])')"
check "문자열 본문 + 속성" "$got" '<masked:phone>' '<masked:email>' \
  "Duplicate entry '<masked>' for key 'uq_customer_kakao'" "Duplicate entry '<masked>' for key 't.uq_phone'" \
  "Duplicate entry '<masked>' for key 't.uq_email'" 'Foo@1a2b3c'
echo "$got" | python3 -I -c '
import sys, json
m = json.load(sys.stdin)["meta"]
assert m["contact"] == "<masked:phone>", m["contact"]
assert m["mail"] == "<masked:email>", m["mail"]
' || fail "속성 contact · mail 이 마스킹 표시로 바뀌지 않았다"
pass "속성 contact · mail · exception.message · exception.stacktrace 마스킹"
check_kept "$got"

echo "── 맵 본문"
EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
send '{"kvlistValue":{"values":[{"key":"msg","value":{"stringValue":"phone 010-0000-0005"}},{"key":"to","value":{"stringValue":"user2@example.com"}}]}}'
[ "$(poll_event "$LOKI")" -ge 1 ] || fail "event_id 로 못 찾음"
got="$(stored)"
echo "    본문: $(echo "$got" | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["line"])')"
check "맵 본문" "$got" '<masked:phone>' '<masked:email>'
check_kept "$got"

echo "통과"
