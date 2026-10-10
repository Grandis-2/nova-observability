#!/usr/bin/env bash
# 저장 전 마스킹(stack/otel-collector.yaml 의 transform/mask)을 본다. 로그 세 건을 보낸다.
#   1. 문자열 본문 + 속성: 사례마다 속성 하나, 본문에는 전부를 이어 붙이고 걸리면 안 되는 ID 를 섞는다
#   2. 맵 본문(맵 · 목록이 중첩된)   3. 목록 본문
# 저장된 본문과 속성을 **필드마다 기대값과 정확히** 비교한다. 다른 필드가 마스킹 표시를 채워 주는 일이 없게 한다.
# 값은 모두 가짜다(가운데 7777, 끝 91NN 은 사례 번호).
set -euo pipefail
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-masking}"
SERVICE=obs-masking
# shellcheck source=test/lib.sh
. "$(dirname "$0")/lib.sh"

CASES="$WORK/cases.py"
cat > "$CASES" <<'PY'
import json, sys

P, E, D = "<masked:phone>", "<masked:email>", "Duplicate entry '<masked>' for key"
# (입력, 저장 기대값). "\\n" · "\\t" 는 역슬래시 + 글자다(JSON 으로 이스케이프된 텍스트 흉내).
CASES = [
    ("010-7777-9101", P),
    ("010 7777 9102", P),
    ("01077779103", P),
    ("+82-10-7777-9104", P),
    ("+821077779105", P),
    ("\\n010-7777-9106", "\\n" + P),
    ("\\t010-7777-9107", "\\t" + P),
    ("u_010-7777-9108", "u_" + P),
    ("user_01077779109_x", "user_" + P + "_x"),
    ("(010)7777-9110", P),
    ("+82 (0)10-7777-9111", P),
    ("0082-10-7777-9112", P),
    ("%2B821077779113", P),
    ("user14%40example.com", E),
    ("hong.01077779115@example.com", E),
    ("010-7777-9116 010-7777-9117", P + " " + P),
    ("010-7777-9118,010-7777-9119", P + "," + P),
    ("전화010-7777-9120번", "전화" + P + "번"),
    ("user21@example.com", E),
    ("Duplicate entry 'kakao-9122' for key 'uq_customer_kakao'", D + " 'uq_customer_kakao'"),
    ("Duplicate entry 'a-9123' for key 'k1'\nKEEP-LINE\nDuplicate entry 'b-9124' for key 'k2'",
     D + " 'k1'\nKEEP-LINE\n" + D + " 'k2'"),
    # 앞의 것에 for key 가 없으면 다음 줄의 for key 까지 지우지 않는다(한 줄 안에서만 건다)
    ("Duplicate entry 'cut'\nKEEP-LINE-2\nDuplicate entry 'd-9126' for key 'k3'",
     "Duplicate entry 'cut'\nKEEP-LINE-2\n" + D + " 'k3'"),
]
# 걸리면 안 되는 값
KEEP = {
    "traceId": "01012345678901234567890123456789",
    "ref": "01012345-0101-4567-8901-010123456789",
    "aggregate_id": "01012345-6789-4abc-8def-010000000000",  # nova 의 aggregate_id 는 UUID 문자열이다
    "aggregate_type": "MASKING",
    "event_type": "Created",
    "destination": "preorder-events.fifo",
    "at_ms": "1760000000000",
    "digits": "01000000000123",
    "order_id": "1234567",
    "hex_id": "010a1b2c3d4e5f60",
    "obj": "Foo@1a2b3c",
}
EXC_MSG = ("could not execute statement [Duplicate entry 'kakao-9131' for key 'uq_customer_kakao']",
           "could not execute statement [" + D + " 'uq_customer_kakao']")
EXC_STACK = ("x.DataIntegrityViolation: Duplicate entry '010-7777-9132' for key 't.uq_phone'\n\tat x.Repo.save(Repo.java:42)\n"
             "Caused by: java.sql.SQLException: Duplicate entry 'user33@example.com' for key 't.uq_email'\n"
             "\tcontact=+82 10 7777 9134 mail=user35@example.com\n\tat x.Foo@1a2b3c",
             "x.DataIntegrityViolation: " + D + " 't.uq_phone'\n\tat x.Repo.save(Repo.java:42)\n"
             "Caused by: java.sql.SQLException: " + D + " 't.uq_email'\n"
             "\tcontact=" + P + " mail=" + E + "\n\tat x.Foo@1a2b3c")
SEP = " ; "
BODY = (SEP.join(c[0] for c in CASES) + SEP + SEP.join(f"{k}={v}" for k, v in KEEP.items()),
        SEP.join(c[1] for c in CASES) + SEP + SEP.join(f"{k}={v}" for k, v in KEEP.items()))
MAP = ({"msg": "a 010-7777-9141", "inner": {"to": "user42@example.com", "deep": {"p": "+82 10 7777 9143"}},
        "arr": ["010-7777-9144", {"m": "user45%40example.com"}], "n": 7, "keep": KEEP["ref"]},
       {"msg": "a " + P, "inner": {"to": E, "deep": {"p": P}}, "arr": [P, {"m": E}], "n": 7, "keep": KEEP["ref"]})
LIST = (["010-7777-9151", 5, {"e": "user52@example.com"}], [P, 5, {"e": E}])
BODIES = {"string": BODY, "map": MAP, "list": LIST}


def otlp(v):  # 파이썬 값 → OTLP JSON AnyValue
    if isinstance(v, str): return {"stringValue": v}
    if isinstance(v, bool): return {"boolValue": v}
    if isinstance(v, int): return {"intValue": str(v)}
    if isinstance(v, list): return {"arrayValue": {"values": [otlp(x) for x in v]}}
    return {"kvlistValue": {"values": [{"key": k, "value": otlp(x)} for k, x in v.items()]}}


def attrs(kind, event_id, i):  # i=0 보낼 값, i=1 저장 기대값(Loki 는 속성 이름의 . 을 _ 로 바꾼다)
    a = {"event_id": event_id, **KEEP}
    if kind == "string":
        a.update({f"c{n:02d}": c[i] for n, c in enumerate(CASES, 1)})
        exc = "exception." if i == 0 else "exception_"
        a.update({exc + "message": EXC_MSG[i], exc + "stacktrace": EXC_STACK[i]})
    return a


def payload(kind, service, event_id, now_ns):
    return {"resourceLogs": [{"resource": {"attributes": [
        {"key": "service.name", "value": otlp(service)},
        {"key": "deployment.environment", "value": otlp("local")}]},
        "scopeLogs": [{"scope": {"name": "masking"}, "logRecords": [{
            "timeUnixNano": now_ns, "severityText": "ERROR", "severityNumber": 17,
            "body": otlp(BODIES[kind][0]),
            "attributes": [{"key": k, "value": otlp(v)} for k, v in attrs(kind, event_id, 0).items()]}]}]}]}


def check(kind, event_id, stored):
    """stored: Loki query_range 응답. 필드마다 기대값과 비교하고 다른 것을 모두 찍는다."""
    vals = [v for s in json.loads(stored)["data"]["result"] for v in s["values"]]
    if not vals:
        print("    저장된 줄이 없다"); return False
    line, meta = vals[0][1], vals[0][2].get("structuredMetadata", {})
    bad = []
    got_body = line if kind == "string" else json.loads(line)
    if got_body != BODIES[kind][1]:
        bad.append(("본문", got_body, BODIES[kind][1]))
    for k, want in attrs(kind, event_id, 1).items():
        if meta.get(k) != want:
            bad.append((k, meta.get(k), want))
    for name, got, want in bad:
        print(f"    {name}: 저장 {got!r}\n    {name}: 기대 {want!r}")
    return not bad


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "payload":
        print(json.dumps(payload(*sys.argv[2:6])))
    elif cmd == "check":
        sys.exit(0 if check(sys.argv[2], sys.argv[3], sys.stdin.read()) else 1)
    elif cmd == "count":
        print(len(CASES), len(KEEP))
PY

send() {  # 종류(string|map|list)
  local now_ns code
  now_ns="$(python3 -I -c 'import time; print(time.time_ns())')"
  code="$(python3 -I "$CASES" payload "$1" "$SERVICE" "$EVENT_ID" "$now_ns" \
    | curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$OBS_OTLP_HTTP_PORT/v1/logs" \
        -H 'Content-Type: application/json' -d @-)"
  [ "$code" = 200 ] || fail "Collector 응답 $code"
}

stored() {
  curl -s -G "$LOKI/loki/api/v1/query_range" -H 'X-Loki-Response-Encoding-Flags: categorize-labels' \
    --data-urlencode "query={service_name=\"$SERVICE\"} | event_id=\"$EVENT_ID\"" --data-urlencode "since=1h"
}

up

read -r n_cases n_keep <<<"$(python3 -I "$CASES" count)"
echo "── 1. 문자열 본문 + 속성 (사례 ${n_cases}개, 걸리면 안 되는 값 ${n_keep}개)"
EVENT_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
send string
[ "$(poll_event "$LOKI")" -ge 1 ] || fail "event_id 로 못 찾음"
stored | python3 -I "$CASES" check string "$EVENT_ID" || fail "문자열 본문 · 속성이 기대와 다르다"
pass "본문: 사례마다 원문 대신 마스킹 표시, 걸리면 안 되는 값은 그대로 — 본문 전체가 기대값과 같다"
pass "속성: 사례마다 하나씩 + exception.message · exception.stacktrace — 필드마다 기대값과 같다"
pass "event_id · traceId · UUID · aggregate_id(UUID) · destination · epoch ms · 숫자 ID · 16진수 ID · 긴 숫자열 · Foo@1a2b3c 는 그대로"

echo "── 2. 맵 본문(맵 · 목록이 중첩된)"
EVENT_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
send map
[ "$(poll_event "$LOKI")" -ge 1 ] || fail "event_id 로 못 찾음"
stored | python3 -I "$CASES" check map "$EVENT_ID" || fail "맵 본문이 기대와 다르다"
pass "맵 본문: 중첩된 맵 · 목록 안의 값까지 마스킹, 숫자 · UUID 는 그대로, 저장 모습은 JSON 그대로"

echo "── 3. 목록 본문"
EVENT_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
send list
[ "$(poll_event "$LOKI")" -ge 1 ] || fail "event_id 로 못 찾음"
stored | python3 -I "$CASES" check list "$EVENT_ID" || fail "목록 본문이 기대와 다르다"
pass "목록 본문: 안의 맵까지 마스킹"

echo "통과"
