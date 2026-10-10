#!/usr/bin/env bash
# OTel Java 에이전트를 붙인 JVM 의 logback 로그가 이 스택까지 오는지 본다. ecs/ 의 주입 조각과 같은 환경 변수를 쓴다.
#   A. OTEL_EXPORTER_OTLP_PROTOCOL 없이 :4317 로 보내면 → 도착하지 않아야 한다(에이전트 기본값은 http/protobuf)
#   B. grpc 로 보내면 → event_id 로 찾히고, MDC 는 traceId 만, JAVA_TOOL_OPTIONS 의 기존 플래그가 살아 있다
#   C. 가짜 ECS 메타데이터 엔드포인트를 주고 AWS 리소스 감지를 끈 채(기본) / 켠 채 → 에이전트가 만든 리소스 속성과
#      Loki 에 저장된 것을 비교한다(Collector 허용 목록이 aws.* 를 버리는지)
#
# 필요: JDK 25(JAVA_HOME_25 또는 macOS java_home), curl, python3. 에이전트·logback jar 은 받아서 체크섬을 확인한다.
set -euo pipefail
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-obs-agent-probe}"
# shellcheck source=test/lib.sh
. "$(dirname "$0")/lib.sh"

AGENT_VERSION=2.32.0
AGENT_SHA256=f787eb6c7f3d18e69a431e108a15278d25ee37f83d68b678f621e063f3988f82
MAVEN=https://repo1.maven.org/maven2
JARS=(
  "ch/qos/logback/logback-classic/1.5.38/logback-classic-1.5.38.jar afb439c61fa287c9e1925523b13baab03617e724406a389d48b61c2c3e46b700"
  "ch/qos/logback/logback-core/1.5.38/logback-core-1.5.38.jar a855a0fc97b1d06f4efb1c3bba5ebd0eb508d8b58e68e89e4bbc23a85135c883"
  "org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar 7b751d952061954d5abfed7181c1f645d336091b679891591d63329c622eb832"
)

JAVA_HOME_25="${JAVA_HOME_25:-$(/usr/libexec/java_home -v 25 2>/dev/null || true)}"
[ -x "${JAVA_HOME_25:-}/bin/java" ] || { echo "NOT RUN — JDK 25 를 찾지 못했다 (JAVA_HOME_25 를 지정한다)"; exit 3; }

fetch() {  # url sha256 dest
  curl -fsSL -o "$3" "$1"
  [ "$(shasum -a 256 "$3" | cut -d' ' -f1)" = "$2" ] || fail "체크섬 불일치: $1"
}
AGENT_JAR="$WORK/opentelemetry-javaagent.jar"
fetch "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v$AGENT_VERSION/opentelemetry-javaagent.jar" \
  "$AGENT_SHA256" "$AGENT_JAR"
CP=""
for j in "${JARS[@]}"; do
  set -- $j
  fetch "$MAVEN/$1" "$2" "$WORK/$(basename "$1")"
  CP="$CP${CP:+:}$WORK/$(basename "$1")"
done
# 미리 컴파일한다. 'java Probe.java'(소스 실행)로 띄우면 에이전트가 JDK 도구로 보고 스스로 꺼진다
# ("JDK tool detected ... agent will not be started").
env -i PATH="$PATH" "$JAVA_HOME_25/bin/javac" -d "$WORK/classes" -cp "$CP" test/agent-probe/Probe.java
CP="$WORK/classes:$CP"

# 사용자 셸의 OTEL_* · JAVA_TOOL_OPTIONS 가 섞이지 않게 env -i 로 돌린다.
run_probe() {  # event_id, 추가 환경 변수(KEY=VALUE ...)
  local id="$1"; shift
  env -i PATH="$PATH" HOME="$HOME" \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -javaagent:$AGENT_JAR" \
    OTEL_SERVICE_NAME=obs-agent-probe \
    OTEL_RESOURCE_ATTRIBUTES=deployment.environment=local,service.namespace=probe \
    OTEL_TRACES_EXPORTER=none OTEL_METRICS_EXPORTER=none \
    OTEL_LOGS_EXPORTER=otlp,logging-otlp \
    OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$OBS_OTLP_GRPC_PORT" \
    OTEL_INSTRUMENTATION_LOGBACK_APPENDER_EXPERIMENTAL_MDC_ATTRIBUTES_INCLUDED=traceId \
    OTEL_INSTRUMENTATION_COMMON_LOGGING_STRUCTURED_ATTRIBUTES_INCLUDED=event_id,aggregate_type \
    "$@" \
    "$JAVA_HOME_25/bin/java" -cp "$CP" Probe "$id" 2>&1
}

# logging-otlp 가 찍은 OTLP JSON 에서 리소스 속성 키만 뽑는다.
resource_keys() {
  python3 -I -c '
import sys, json, re
keys = set()
for line in sys.stdin:
    i = line.find("{\"resource\"")
    if i < 0: continue
    try: d = json.loads(line[i:])
    except ValueError: continue
    keys.update(a["key"] for a in d["resource"]["attributes"])
print(",".join(sorted(keys)))'
}

# Loki 에 저장된 structured metadata 키
stored_keys() {
  curl -s -G "$LOKI/loki/api/v1/query_range" -H 'X-Loki-Response-Encoding-Flags: categorize-labels' \
    --data-urlencode "query={service_name=\"$SERVICE\"} | event_id=\"$EVENT_ID\"" --data-urlencode "since=1h" \
    | python3 -I -c '
import sys, json
r = json.load(sys.stdin)["data"]["result"]
keys = set()
for s in r:
    for v in s["values"]:
        keys.update(v[2].get("structuredMetadata", {}).keys())
print(",".join(sorted(keys)))'
}

up
SERVICE=obs-agent-probe

echo "── A. 프로토콜을 정하지 않고 :$OBS_OTLP_GRPC_PORT(gRPC 포트)로"
EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
out="$(run_probe "$EVENT_ID")"
echo "$out" | grep -E 'probe:|Failed to export|WARN|ERROR|agent will not' | head -4 | cut -c1-240 | sed 's/^/    /'
sleep 5
[ "$(count_event "$LOKI")" = 0 ] && pass "도착하지 않음 — 에이전트 기본 프로토콜은 http/protobuf, :4317 은 gRPC 다"
echo "$out" | grep -q 'javaagent=true' && ! echo "$out" | grep -q 'agent will not be started' \
  || fail "에이전트가 붙지 않은 상태라 A 의 결과가 프로토콜 때문인지 알 수 없다" \
  || fail "프로토콜 없이도 도착했다 — 이 시험의 전제가 틀렸다"

echo "── B. OTEL_EXPORTER_OTLP_PROTOCOL=grpc"
EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
out="$(run_probe "$EVENT_ID" OTEL_EXPORTER_OTLP_PROTOCOL=grpc)"
echo "$out" | grep 'probe:' | sed 's/^/    /'
echo "$out" | grep -q 'MaxRAMPercentage=75.0 ExitOnOutOfMemoryError=true javaagent=true' \
  && pass "JAVA_TOOL_OPTIONS 병합: 기존 플래그 둘 + -javaagent 가 모두 적용됨" || fail "JAVA_TOOL_OPTIONS 병합 결과가 다르다"
n="$(poll_event "$LOKI")"
[ "$n" -ge 1 ] && pass "Java 25 + 에이전트 $AGENT_VERSION 의 logback 로그를 event_id 로 찾음" || fail "event_id 로 못 찾음"
keys="$(stored_keys)"
echo "    저장된 structured metadata 키: $keys"
echo ",$keys," | grep -q ',event_id,' && echo ",$keys," | grep -q ',traceId,' || fail "event_id · traceId 가 없다"
echo ",$keys," | grep -q ',subject,' && fail "MDC 의 subject 가 저장됐다 — traceId 만 받아야 한다"
pass "event_id(key-value) · traceId(MDC) 는 있고 subject(MDC) 는 없다"

echo "── C. 가짜 ECS 메타데이터(v4) 위에서 리소스 속성"
META_PORT=17999
python3 -I test/agent-probe/fake-ecs-metadata.py "$META_PORT" &
META_PID=$!
trap 'kill $META_PID 2>/dev/null || true; cleanup' EXIT
sleep 1
for aws in default true; do
  EVENT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
  extra=(OTEL_EXPORTER_OTLP_PROTOCOL=grpc ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:$META_PORT/v4/probe")
  [ "$aws" = true ] && extra+=(OTEL_RESOURCE_PROVIDERS_AWS_ENABLED=true)
  out="$(run_probe "$EVENT_ID" "${extra[@]}")"
  emitted="$(echo "$out" | resource_keys)"
  poll_event "$LOKI" >/dev/null
  stored="$(stored_keys)"
  echo "    AWS 리소스 감지=$aws"
  echo "      에이전트가 만든 리소스 속성: $emitted"
  echo "      Loki structured metadata:   $stored"
  [ -n "$emitted" ] || fail "logging-otlp 출력에서 리소스 속성을 읽지 못했다"
  echo ",$stored," | grep -q ',aws_' && fail "aws.* 리소스 속성이 Collector 허용 목록을 통과했다"
done
pass "어느 쪽이든 aws.* 는 Loki 에 저장되지 않는다"

echo "통과"
