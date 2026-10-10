# nova-observability

nova 백엔드의 로그를 받아 **90일** 보관하고 Grafana 로 조회하는 관측 스택의 **설정** 저장소다.
OTel Collector · Loki · Grafana 를 docker compose 로 띄운다. 트레이스와 메트릭은 받지 않는다.

이 스택을 띄우는 EC2 · S3 · IAM · 보안 그룹은 **`Grandis-2/nova-infra`** 가 관리한다. 이 저장소에는 인프라 코드가 없다.
호스트는 이 저장소 `main` 의 커밋을 받아 `stack/compose.yaml` 을 띄운다.

```
Private App Subnet A
┌─ obs EC2 (nova-infra)
│   docker compose (이 저장소의 stack/): otel-collector :4317/:4318 · loki · grafana(127.0.0.1:3000)
│   영속 디스크 → OBS_DATA_DIR (Loki WAL · 인덱스 캐시 · compactor, Grafana DB)
└──▶ S3 버킷 (청크 · 인덱스)
ECS 태스크 ──OTLP gRPC──▶ obs.<Cloud Map 네임스페이스>:4317
개발자 ──SSM 포트 포워딩──▶ localhost:3000
```

## 디렉터리

| 경로 | 범위 | 내용 |
|---|---|---|
| `stack/` | 범용 | `compose.yaml` · `otel-collector.yaml`(로그만) · `loki.yaml`(S3 · 보존) · `grafana/`(Loki 데이터소스) |
| `ecs/` | 범용 | 앱 작업 정의에 붙일 에이전트 주입 조각과 `JAVA_TOOL_OPTIONS` 병합 규칙 ([ecs/README.md](ecs/README.md)) |
| `test/` | — | 로컬 시험 (아래 "검증") |

- 범용 부분은 나중에 observation 플랫폼으로 올라간다([UPSTREAM.md](UPSTREAM.md)). nova 값은 이 README 에만 둔다.
- `scripts/check-generic.sh` 는 `stack/` · `ecs/` 에 `nova` 가 들어오면 실패한다. CI(`.github/workflows/checks.yml`)에서도 돈다.

## 출처

- `stack/` 은 observation 하네스 `harness/config/{loki,otel-collector}.yaml` · `harness/docker-compose.yml` 에서 왔다.
  기준 커밋은 `7985347490227b69098dc2a5d0aca4488134c24c`(2026-10-10)이다. 하네스와 다른 점은 [UPSTREAM.md](UPSTREAM.md) 에 있다.
- 이미지는 하네스보다 새 버전이다. 하네스 버전(`0.116.1` · `3.3.2` · `11.5.0`)에는 고칠 수 있는 HIGH · CRITICAL 취약점이 57~83개씩 있었다(trivy, 2026-10-10).
  - `otel/opentelemetry-collector-contrib:0.162.0` · `grafana/loki:3.7.8` · `grafana/grafana:12.4.12`, 다이제스트로 고정했다.
  - 같은 날 HIGH 는 4 · 4 · 12 개, CRITICAL 은 0 이다.
  - 설정은 바꾸지 않고 로컬 시험 셋을 모두 통과했다.
- 에이전트: OpenTelemetry Java agent **2.32.0**. `ecs/` 의 init 이미지 `autoinstrumentation-java:2.32.0` 에 든 jar 은 GitHub 릴리스와 SHA-256 이 같다.
  2.11.0 은 Java 25 에서 경고 없이 아무것도 내보내지 않는다.

## 호스트가 갖춰야 할 것

`stack/compose.yaml` 머리말에 환경 변수 목록이 있다. 호스트(nova-infra)는 아래를 맞춘다.

| 무엇 | 값 |
|---|---|
| 필수 환경 변수 | `OBS_DATA_DIR` · `LOKI_S3_BUCKET` · `LOKI_S3_REGION` · `LOKI_RETENTION_PERIOD`(nova: `2160h`) · `GRAFANA_ADMIN_PASSWORD_FILE` |
| 영속 디스크 | `OBS_DATA_DIR/loki` 는 UID 10001, `OBS_DATA_DIR/grafana` 는 UID 472 소유. 재부팅에도 남는 디스크여야 한다(WAL) |
| 비밀번호 파일 | 한 줄, UID 472 가 읽을 수 있게 |
| S3 권한 | 그 버킷에 `s3:ListBucket`, 객체에 `s3:GetObject` · `s3:PutObject` · `s3:DeleteObject`. 키 없이 SDK 기본 체인(instance profile) |
| S3 설정 | 버전 관리 **끔**(켜면 compactor 가 지운 객체가 남는다). 만료 수명주기를 두면 보존 기간보다 길게(nova: 100일) |
| 자격 증명 노출 | Loki 만 클라우드 자격 증명이 필요하다. Loki 는 고정 IP(`OBS_LOKI_IPV4`, 기본 `172.30.255.10`)를 갖는다. 호스트는 IMDS 를 그 IP 에만 연다 |
| 포트 | 4317/4318 은 모든 인터페이스. 접근 제어는 보안 그룹이 한다. 3000 · 3100 은 127.0.0.1 에만 묶인다 |
| 정지 | `docker compose stop` 은 Loki 에 2분을 준다(`flush_on_shutdown`). 호스트 종료 절차가 이것을 끊지 않아야 한다 |
| 버전 | 이 저장소 `main` 의 커밋 SHA 로 고정해 받는다. 새 커밋이면 compose 가 세 컨테이너를 다시 만든다 |

## 조회 — Grafana

Grafana 는 호스트의 127.0.0.1:3000 에만 열려 있다. SSM 포트 포워딩으로 들어간다. 명령은 nova-infra 문서에 있다.
익명 접근 · 가입은 꺼져 있고 admin 으로 로그인한다.

```
{service_name="nova-preorder", deployment_environment="prod"} | event_id="<uuid>"
{service_name=~"nova-.+"} | aggregate_type="PREORDER" | aggregate_id="<uuid>"
```

**admin 비밀번호 교체.** `GF_SECURITY_ADMIN_PASSWORD__FILE` 는 Grafana 를 처음 띄울 때만 적용된다.
이미 있는 admin 의 비밀번호는 비밀번호 파일을 새 값으로 바꾼 뒤 호스트에서 아래로 바꾼다(로컬에서 확인).
파일은 UID 472 만 읽을 수 있으므로 파일도 `sudo` 로 읽는다. 셸 리다이렉션(`<`)에는 `sudo` 가 걸리지 않는다.

```bash
sudo cat <비밀번호 파일 경로> \
  | sudo docker exec -i obs-stack-grafana-1 grafana cli admin reset-admin-password --password-from-stdin
```

## 앱이 줄 값 (nova)

작업 정의에 넣는 방법과 병합 규칙은 [ecs/README.md](ecs/README.md) 에 있다. nova 값은 다음과 같다.

```
JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -javaagent:/otel/javaagent.jar
OTEL_SERVICE_NAME=nova-<svc>
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=prod,service.namespace=nova
OTEL_LOGS_EXPORTER=otlp
OTEL_TRACES_EXPORTER=none
OTEL_METRICS_EXPORTER=none
OTEL_EXPORTER_OTLP_ENDPOINT=http://obs.<Cloud Map 네임스페이스>:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc                                     # 빼면 로그가 하나도 오지 않는다
OTEL_INSTRUMENTATION_LOGBACK_APPENDER_EXPERIMENTAL_MDC_ATTRIBUTES_INCLUDED=traceId
OTEL_INSTRUMENTATION_COMMON_LOGGING_STRUCTURED_ATTRIBUTES_INCLUDED=event_id,aggregate_type,aggregate_id,event_type,destination
```

- `JAVA_TOOL_OPTIONS` 앞의 두 플래그는 nova 앱 이미지(`docker/Dockerfile`)의 값이다. 이미지가 바뀌면 다시 확인한다.
- MDC 는 `traceId`(요청 ID)만 받는다. `subject`(회원 ID)는 받지 않는다.
- `aggregate_id` 는 숫자가 아니라 **UUID 문자열**이다. `destination` 은 outbox 가 발행한 큐 이름이다.

## 보안 판단 (스택)

- **OTLP 에 TLS · 토큰을 붙이지 않는다.** VPC 안 통신이고, 보낼 수 있는 쪽은 호스트의 보안 그룹이 정한다.
  보내는 쪽이 로그를 읽을 수 있는 경로는 없다. 대신 아래를 받아들인다.
  - 보낼 수 있는 곳이면 로그를 지어내 넣을 수 있다. **로그의 진위는 보장하지 않는다.**
  - 많이 보내면 Collector 메모리 한도에 걸려 다른 서비스의 로그까지 버려진다.
- Loki API 에는 인증이 없다(`auth_enabled: false`). 같은 컨테이너 망과 호스트에서만 닿는다.
  삭제 요청 API 는 꺼 두었다(`deletion_mode: disabled`, 시험에서 403). 보존 기간에 따른 삭제는 compactor 가 따로 한다.
- 컨테이너는 모든 리눅스 권한을 버리고(`cap_drop: ALL`) `no-new-privileges` 로 돈다. Grafana 플러그인 관리는 꺼져 있다.
- Collector 는 리소스 속성을 허용 목록으로만 남긴다. ECS 감지를 켜면 붙는 `aws.ecs.*` · `cloud.account.id` 는 계정 ID 를 담는데, 이것도 버린다(UPSTREAM 7).

## 저장 전 마스킹

Collector 가 Loki 에 넘기기 전에 개인정보 원문을 고정 표시로 바꾼다(`stack/otel-collector.yaml` 의 `transform/mask`).

- **왜 저장 전인가.** 조회 경로에서 가리면 Grafana Explore · Loki API 로 직접 볼 때 가려지지 않는다.
  저장 전에 지우면 Loki 에서는 어느 경로로 읽어도 원문이 없다.
- **무엇을** — 이 순서로 바꾼다

  | 대상 | 바뀐 모습 |
  |---|---|
  | MySQL 중복 키 값 — `Duplicate entry '<값>' for key '<키>'` 의 `<값>`. 키 이름과 상관없이, 한 줄 안에서만 | `Duplicate entry '<masked>' for key '<키>'` |
  | 이메일 — `local@domain.tld`, URL 인코딩된 `local%40domain.tld` | `<masked:email>` |
  | 국제 형식 휴대전화 — `+82` · `%2B82` · `0082`, `(0)` 허용 | `<masked:phone>` |
  | 휴대전화 — `010` · `011` · `016`~`019`. 괄호(`(010)`) · 구분자(`-` `.` 공백) 있거나 없거나 | `<masked:phone>` |

  - 이메일을 전화보다 먼저 바꾼다. 그래야 `hong.01012345678@…` 같은 주소가 통째로 가려진다.
  - **경계.** 번호 앞뒤가 16진수 문자(`0-9` `a-f` `A-F`)가 아니어야 건다.
    그래서 UUID · trace ID · 16진수 ID 안의 숫자는 걸리지 않고, 이스케이프된 `\n`(역슬래시 + n) · `_` · 한글 바로 옆에 붙은 번호는 걸린다.
- **어디에**
  - 로그 본문. 맵 · 목록 본문은 먼저 JSON 문자열로 바꾼 뒤 건다. 그래서 중첩된 값까지 가려진다.
    Loki 는 원래도 맵 본문을 같은 JSON 으로 저장하므로 저장 모습과 `| json` 조회는 바뀌지 않는다(로컬에서 앞뒤를 비교했다).
  - 로그 레코드 속성의 모든 문자열 값. `exception.message` · `exception.stacktrace` 도 속성이라 같이 걸린다.
- **바뀌지 않는 것** (`test/masking.sh` 가 확인한다)
  - `event_id` · `traceId` · `aggregate_id`(UUID) · `destination`
  - 13자리 epoch ms, `1234567` 같은 숫자 ID, `010…` 으로 시작하는 14자리 숫자열 · 16진수 ID, `Foo@1a2b3c`
  - 단, 0 을 채운 `010…` 10~11자리 숫자 ID 는 전화번호와 구별되지 않아 가려진다. nova 의 `aggregate_id` 는 UUID 라 해당하지 않는다.
- **되돌릴 수 없다.** Loki 에는 원문이 남지 않는다. 조사에는 원문이 필요 없으므로 받아들인다.
  같은 로그의 CloudWatch(`awslogs`) 사본은 이 Collector 를 거치지 않으므로 **원문 그대로 남는다.**
- **안전망이다.** 1차 방어는 앱이 애초에 남기지 않는 것이다(outbox payload 를 로그에 넣지 않는다 등).
- **`error_mode: ignore`.** 문 하나가 실패하면 그 문만 건너뛰고 다음 문으로 간다. 그 로그는 그 패턴이 덜 가려진 채 저장된다.
  `propagate` 는 0.162.0 에서 배치 전체를 버린다(보낸 쪽에 503). 관측 경로 때문에 로그를 통째로 잃는 쪽을 택하지 않았다.
- **걸리지 않는 것**
  - 패턴 밖의 개인정보: 실명 · 주소 · 유선 전화 · 외국 번호 · 카카오 ID 단독
  - 16진수 글자 바로 옆에 붙은 번호: `phone01012345678`(`e`) · `01012345678abc`
  - `for key` 가 같은 줄에 없는 중복 키 메시지(잘린 메시지)의 값
  - 맵 · 목록 **속성** 안에 중첩된 값, 바이트 본문(Loki 는 base64 로 저장), 스코프 속성
  - 리소스 속성. 허용 목록이 서비스 · 호스트 식별자만 남겨 사용자 값이 들어올 자리가 없다.
- **오탐**: 경계만 맞으면 번호가 아닌 것도 가린다
  - `0.0101234567` → `0.<masked:phone>`
  - `010-1234-5678-90` → `<masked:phone>-90`

## 하지 않는 것

- **outbox 정본 보관.** 이 경로는 손실을 허용한다.
  - Collector 에 디스크 큐가 없다.
  - 메모리가 차면 받기를 거부한다.
  - 호스트가 내려가 있는 동안의 로그는 오지 않는다.
  - 로그가 있다는 것을 정본의 근거로 쓰지 않는다.
- 인프라(EC2 · S3 · IAM · 보안 그룹 · DNS) — nova-infra.
- 트레이스 · 메트릭 · Prometheus · Tempo · 관제 API · 대시보드.
- 앱 쪽 작업 정의(작업 2).

## 검증

| 무엇 | 명령 | 어디서 |
|---|---|---|
| 끝까지 한 건 | `test/smoke.sh` | 로컬 Docker, S3 는 Floci |
| 보존 기간이 지나면 compactor 가 S3 에서 지운다 | `test/retention.sh` | 로컬 Docker, S3 는 Floci |
| Java 25 + 에이전트 2.32.0 + logback → 스택 | `test/agent-probe.sh` | 로컬 JDK 25 |
| 저장 전 마스킹 — 원문이 저장되지 않고 식별자는 그대로 | `test/masking.sh` | 로컬 Docker, S3 는 Floci |
| 범용 디렉터리에 nova 없음 | `scripts/check-generic.sh` | 로컬 · CI |

`smoke.sh` 는 아래를 차례로 확인한다.
1. OTLP 로그 1건을 Loki API 와 Grafana(admin 로그인) 에서 `| event_id="..."` 로 찾는다.
2. `event_id` 는 인덱스 라벨이 아니라 structured metadata 다.
3. 허용 목록 밖 리소스 속성(`process.pid`)은 버려진다.
4. 트레이스는 받지 않는다.
5. 익명 요청은 401 이고, Loki 삭제 요청 API 는 꺼져 있다.
6. Loki SIGKILL 뒤 WAL 로 되살아난다.
7. 정상 종료하면 청크 · 인덱스가 S3 로 올라간다.
8. 로컬 디스크를 비워도 S3 에서 읽힌다.

`test/compose.local.yaml` 은 S3 대신 Floci 를 쓴다. 실제 AWS 와 다른 점(고정 키 · path-style · http)은 그 파일 머리말에 있다.
실제 AWS 에서 확인한 것은 아직 없다. 적용 뒤 결과로 [UPSTREAM.md](UPSTREAM.md) 의 "실측" 칸을 갱신한다.
