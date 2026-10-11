# observation 으로 올릴 것

observation 쪽 작업(W24)이 이 파일만 읽고 반영할 수 있게 쓴다.
기준은 observation 하네스 커밋 `7985347490227b69098dc2a5d0aca4488134c24c` 이다.

**실측 칸의 출처**
- 실제 AWS 에 적용한 결과는 아직 없다.
- 실측은 모두 로컬(macOS arm64 · Docker Desktop)이나 Floci(`floci/floci:2.1.0`)에서 했고, 날짜는 모두 2026-10-10 이다.
- **이미지 버전이 하네스와 다르다**(아래 8). 로컬 실측은 새 버전으로 다시 돌린 결과다.
- `apply` 뒤 사용자가 결과를 주면 해당 칸을 갱신한다.

---

## 1. Fargate 에서 에이전트를 앱 이미지 밖에서 주입한다

- **파일**: `ecs/agent-injection.json` · `ecs/README.md`
- **하네스와 다른 점**: 하네스에는 ECS 경로가 없다.
  - 하네스의 세 경로: 호스트 `bootRun` · 컨테이너 jar 마운트 · K8s Operator
  - 여기는 init 컨테이너(`essential: false`)가 작업 볼륨에 jar 을 복사한다. 앱 컨테이너는 `dependsOn: SUCCESS` 로 기다린다.
  - init 이미지는 K8s Operator 와 같은 `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.32.0` 이고, 다이제스트로 고정했다.
- **실측** (로컬)
  - 그 이미지의 `/javaagent.jar` 를 `docker run --platform linux/arm64 … cp` 로 꺼냈다.
    - SHA-256 `f787eb6c…` 는 하네스 `download.sh` 의 고정값(GitHub 릴리스 자산)과 같다.
    - `Implementation-Version: 2.32.0` 이다.
  - 이미지 안에 `/bin/cp`(busybox)가 있고 root 로 돈다.
  - `docker buildx imagetools inspect` 로 `linux/arm64` · `linux/amd64` 매니페스트를 확인했다.
- **미실측**
  - 실제 Fargate 의 동작: init 순서, `readonlyRootFilesystem: true` 에서의 복사, 비 root 앱 사용자의 jar 읽기, 기동 시간 증가
  - ECS 클러스터가 없어서 확인하지 못했다.
- **observation 에 넣을 때 주의**
  - K8s 경로(Operator)와 나란히 "ECS 경로" 로 둔다. 버전 고정 위치가 하나 더 생긴다(`ecs/agent-injection.json` 의 태그 · 다이제스트).
  - `download.sh` · `versions.env` 와 같은 버전인지 보는 검사에 이 파일도 넣는다.

## 2. `JAVA_TOOL_OPTIONS` 는 합쳐서 쓴다

- **파일**: `ecs/README.md` "병합 규칙", `test/agent-probe.sh`
- **하네스와 다른 점**: 하네스는 앱이 `JAVA_TOOL_OPTIONS` 를 쓰지 않아 문제가 없었다.
  ECS 작업 정의의 `environment` 는 이미지 `ENV` 를 통째로 덮으므로, 이미지의 기존 값 뒤에 `-javaagent:` 를 붙인다.
- **실측** (로컬, `test/agent-probe.sh`)
  - JDK 25.0.2 에서 `JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -javaagent:<2.32.0>"` 로 띄웠다.
  - HotSpotDiagnosticMXBean 기준으로 셋 다 적용됐다: `MaxRAMPercentage=75.0` · `ExitOnOutOfMemoryError=true` · javaagent 있음.
  - `JAVA_TOOL_OPTIONS` 는 `jcmd` 에도 적용된다. 에이전트는 `JDK tool detected … agent will not be started` 를 찍고 붙지 않는다.
  - `java Probe.java`(소스 실행)도 JDK 도구로 판정돼 에이전트가 꺼진다. 프로브는 그래서 미리 컴파일한다.
- **미실측**: 실제 nova 이미지 · ECS 태스크에서 `jcmd <pid> VM.flags`. ECS 가 없어서다.
- **observation 에 넣을 때 주의**
  - 온보딩 문서의 "앱이 줄 값" 에 이 규칙을 넣는다.
  - K8s Operator 는 pod spec 에 있는 `JAVA_TOOL_OPTIONS` 에 덧붙인다고 알려져 있다. 그래도 이미지 `ENV` 에만 있는 값은 K8s 에서도 덮일 수 있다. 확인하지 않았으므로 K8s 경로에도 같은 확인 항목을 둔다.

## 3. 에이전트 2.32.0 의 설정 — 속성 이름과 OTLP 프로토콜

- **파일**: `ecs/agent-injection.json` 의 `environment`, `ecs/README.md` "틀리기 쉬운 것"
- **하네스와 다른 점**
  - logback 속성은 새 이름을 쓴다(하네스 결정 문서 §③ 과 같은 내용):
    - `OTEL_INSTRUMENTATION_LOGBACK_APPENDER_EXPERIMENTAL_MDC_ATTRIBUTES_INCLUDED`
    - `OTEL_INSTRUMENTATION_COMMON_LOGGING_STRUCTURED_ATTRIBUTES_INCLUDED`
  - **`OTEL_EXPORTER_OTLP_PROTOCOL=grpc` 를 명시한다.** 하네스는 http(4318)로 보내 드러나지 않았다.
- **실측** (로컬, `test/agent-probe.sh`, JDK 25.0.2 + 2.32.0 + logback-classic 1.5.38)
  - 프로토콜을 주지 않고 `OTEL_EXPORTER_OTLP_ENDPOINT=http://…:4317` 로 보냈다.
    - 에이전트 로그: `ERROR io.opentelemetry.exporter.otlp.internal.HttpExporter - Failed to export 1 logs`
    - Loki: 0건
    - 기본 프로토콜이 `http/protobuf` 라서다.
  - `grpc` 를 주면 `| event_id="…"` 로 찾힌다.
  - structured metadata 에 `event_id` · `aggregate_type`(key-value)과 `traceId`(MDC)가 들어온다.
  - MDC 의 `subject` 는 `MDC_ATTRIBUTES_INCLUDED=traceId` 이므로 저장되지 않는다.
  - key-value 쪽은 이름 목록(`event_id,aggregate_type`)으로 줬다. `*` 는 이번에 다시 재지 않았다(하네스 결정 문서의 실측을 따른다).
- **미실측**: 실제 nova 서비스의 로그(`addKeyValue` 를 쓰는 outbox 로그는 작업 5 뒤에 생긴다).
- **observation 에 넣을 때 주의**
  - 하네스 기본값은 http(4318)다. ECS 문서 · 조각에서만 gRPC 를 쓴다면 프로토콜을 짝으로 적는다.
  - 둘 중 하나로 통일해도 된다.

## 4. Loki 를 S3 에 두고 compactor 로 보존한다

- **파일**: `stack/loki.yaml` (범용 부분 전체), `stack/compose.yaml` 의 `loki` 서비스
- **하네스와 다른 점**
  - 버전: 3.3.2 → 3.7.8 (아래 8)
  - 삭제 요청 API 를 끈다(`limits_config.deletion_mode: disabled`). Loki API 에 인증이 없어서다. 보존 삭제는 compactor 가 따로 한다(retention.sh 로 확인).
  - 저장소: `common.storage.filesystem` → `common.storage.s3`
    - 버킷 · 리전은 환경 변수, 키는 없다(SDK 기본 체인 = instance profile)
    - `schema_config.object_store: s3`, `delete_request_store: s3`
  - 보존: `retention_period: 24h` → `${LOKI_RETENTION_PERIOD}`(nova 는 `2160h`). `max_query_lookback` 를 같은 값으로 새로 둔다.
  - 경로: WAL(`/loki/wal`) · `tsdb_shipper` 활성 인덱스 · 캐시 · compactor 작업 경로를 `/loki` 아래로 명시한다. `/loki` 는 영속 디스크다.
  - `ingester.wal.flush_on_shutdown: true` 를 둔다.
    - `ingester.flush_on_shutdown` 이 아니라 `wal` 아래다. 잘못 두면 `field flush_on_shutdown not found` 로 기동에 실패한다(3.3.2 에서 실측).
  - compose `stop_grace_period: 2m`
  - compactor: `compaction_interval` · `retention_delete_delay` 를 환경 변수로 뺐다(기본 10m · 2h). 보존 시험을 빨리 돌리려고 뺐다.
  - `analytics.reporting_enabled: false`
  - `-config.expand-env=true`
  - 인덱스 라벨 · `otlp_config` 블록은 하네스와 **같다**.
- **실측** (로컬, S3 는 Floci 2.1.0 의 S3, path-style · http · 고정 키)
  - `test/smoke.sh`
    - 로그 1건을 Loki API 와 Grafana 프록시에서 `| event_id` 로 찾았다.
    - 인덱스 라벨은 `deployment_environment,service_name,service_namespace` 뿐이고, `event_id` 는 structured metadata 다.
    - Loki 를 SIGKILL 했다. S3 에 청크가 없는 상태였는데 재기동 뒤 WAL 로 찾혔다.
    - 정상 종료 뒤 S3 에 `fake/<hash>/<from>:<through>:<sum>` · `index/index_<day>/…tsdb.gz` · `index/delete_requests/…` 가 생겼다.
    - 로컬 `/loki` 를 비우고 재기동해도 S3 에서 찾혔다.
  - `test/retention.sh` (보존 24h · compaction 20s · 삭제 유예 10s)
    - 72시간 전 로그와 지금 로그를 서로 다른 스트림으로 넣었다.
    - 약 60초 뒤 compactor 가 72시간 전 청크와 그날의 인덱스 테이블을 S3 에서 지웠다.
    - 지금 청크는 남았고 조회도 됐다.
- **미실측**
  - 실제 S3 · instance profile 자격 증명(IMDSv2 hop limit 2), SSE-S3 버킷, 버킷 정책의 TLS 강제
  - 90일 보존이 실제로 지켜지는지, 수명주기 100일 만료와의 관계
  - `index/delete_requests/` 가 100일 동안 바뀌지 않으면 수명주기가 지운다. 로컬 compactor 작업 경로에 사본이 있어 다음 변경 때 다시 올라갈 것으로 보지만 확인하지 않았다.
- **observation 에 넣을 때 주의**
  - 하네스 기본값(로컬 개발, 파일시스템, 24h)을 깨지 않으려면 저장소 종류를 옵션으로 둔다.
    - 예: `loki.yaml` 을 파일시스템판과 S3판 둘로 두거나, compose override 로 S3판을 고른다.
    - `expand-env` 만으로는 `storage.filesystem` ↔ `storage.s3` 블록을 바꿀 수 없다.
  - 로컬에서 S3판을 시험하는 방법은 `test/compose.local.yaml`(Floci S3) 이다. 하네스의 `verify.sh` 에 레인으로 넣을 수 있다.

## 5. 로그 전용 Collector

- **파일**: `stack/otel-collector.yaml`
- **하네스와 다른 점**
  - traces · metrics 파이프라인 · `prometheus` · `otlp/tempo` 익스포터를 뺐다.
  - `debug` 익스포터를 뺐다.
  - `transform/resource-allowlist` 는 `log_statements` 만 남겼다. 목록 자체는 하네스와 같다.
  - `memory_limiter.spike_limit_mib: 128` 을 명시하고, compose `mem_limit: 768m` 을 뒀다.
  - 버전: 0.116.1 → 0.162.0 (아래 8). 설정 문법은 그대로 통과했다.
- **실측** (로컬, `test/smoke.sh`)
  - OTLP/HTTP 로그는 200 이다.
  - `/v1/traces` 는 404 다. 파이프라인이 없으면 receiver 가 그 경로를 열지 않는다.
  - 허용 목록 밖 리소스 속성 `process.pid` 는 Loki 에 저장되지 않았다.
- **미실측**
  - 메모리 한도에 닿았을 때의 거부 동작과 유실량
  - gRPC 로 traces 를 보냈을 때의 응답 코드
- **observation 에 넣을 때 주의**
  - 하네스는 세 신호를 모두 받는다. 이 파일은 "로그만 받는 운영 프로필" 로 따로 둔다.
  - 하네스 파일에서 파이프라인을 빼면 하네스 스모크가 깨진다.

## 6. EC2 + compose 배치와 SSM 접근

이 저장소에는 compose 쪽만 있다. EC2 · 부팅 스크립트 · IAM 은 `Grandis-2/nova-infra` 로 옮긴다(이관 전 보관 중).
호스트 쪽 실측도 그쪽 문서가 정본이다. 여기에는 observation 으로 올릴 때 필요한 요지만 적는다.

- **파일**: `stack/compose.yaml` (호스트 쪽은 nova-infra 의 관측 호스트 모듈과 부팅 스크립트)
- **하네스와 다른 점 — compose**
  - 하네스는 로컬 개발용이다(익명 Admin, 모든 포트 공개). 여기서는 다음을 바꿨다.
    - Grafana: 익명 · 가입을 끄고, admin 비밀번호를 `GF_SECURITY_ADMIN_PASSWORD__FILE` + compose `secrets` 로 받는다.
    - Grafana · Loki 포트는 `127.0.0.1` 에만 묶는다.
    - 데이터는 `OBS_DATA_DIR` 바인드 마운트로 둔다.
    - 모든 컨테이너: `cap_drop: [ALL]` · `no-new-privileges`. Grafana 플러그인 관리 끔.
    - 전용 망(`OBS_DOCKER_SUBNET`)에 Loki 만 고정 IP(`OBS_LOKI_IPV4`)를 준다. 호스트가 클라우드 자격 증명(IMDS)을 그 IP 에만 열기 위해서다.
    - 컨테이너 로그를 회전한다(json-file 10m × 5).
    - `restart: unless-stopped`
    - 포트를 환경 변수로 바꿀 수 있다.
- **하네스와 다른 점 — 호스트 (nova-infra)**
  - 호스트가 이 공개 저장소의 **커밋 SHA** tarball 을 받는다. 커밋이 `main` 에 들어간 것인지 GitHub compare API 로 확인한다.
    포크의 커밋도 원래 저장소 주소로 받아지기 때문이다.
  - 저장소 · 경로 · 브랜치는 user_data 에만 둔다. 커밋 SHA · Loki 값 · 비밀 ARN 은 SSM 파라미터에 둔다.
    변경은 파라미터를 바꾸고 SSM Run Command 로 배포 스크립트를 돌린다.
  - IMDS hop limit 2 는 그대로 두되, 호스트 방화벽(`DOCKER-USER`)이 IMDS 를 Loki 고정 IP 에만 연다.
  - Docker 는 데이터 디스크 마운트를 요구한다(systemd `RequiresMountsFor`).
  - 부팅 스크립트는 멱등이고 네트워크 단계를 다시 시도한다.
- **실측** (로컬)
  - Grafana 12.4.12: 익명 요청은 401, admin 로그인으로 Loki 데이터소스 프록시 조회가 됐다(`test/smoke.sh`).
  - `grafana cli admin reset-admin-password --password-from-stdin` 뒤 이전 비밀번호는 401, 새 비밀번호는 200 이었다(12.4.12).
  - 호스트 쪽(Floci 적용, IMDS 가드, 배포 스크립트의 거부 경로)은 nova-infra 인계 문서에 결과가 있다.
- **미실측**
  - 실제 EC2 에서의 전부: 부트스트랩, SSM 포트 포워딩 · Run Command, AL2023(iptables-nft · Docker 25)에서의 IMDS 가드, 자동 복구
- **observation 에 넣을 때 주의**
  - 하네스 compose 의 익명 Admin 은 로컬 개발 편의라 그대로 둔다. 운영 프로필(이 `stack/compose.yaml`)을 따로 둔다.
  - Loki 고정 IP 와 호스트의 IMDS 가드는 짝이다. IMDS hop limit 2 를 쓰는 어느 호스트에나 필요하다.
  - "공개 저장소에서 커밋 SHA 로 받기" 는 저장소가 공개라는 전제다.
    - observation 은 비공개라 이 방법을 그대로 쓸 수 없다.
    - 대안: 설정을 S3 객체나 SSM 문서로 올리기

## 7. ECS 리소스 속성 — 어떤 `aws.ecs.*` 가 들어오나

- **파일**: `stack/otel-collector.yaml` 의 `transform/resource-allowlist` (목록은 바꾸지 않았다)
- **하네스와 다른 점**: 없다. 허용 목록에 `aws.ecs.*` · `cloud.*` 를 넣지 않았다.
- **실측** (로컬, `test/agent-probe.sh` C)
  - 2.32.0 에이전트에 가짜 ECS 태스크 메타데이터 v4 엔드포인트(`ECS_CONTAINER_METADATA_URI_V4`)를 줬다.
  - AWS 리소스 감지 기본값(꺼짐): 에이전트가 만든 리소스 속성에 `aws.*` · `cloud.*` 가 없다.
    - 있는 것: `host.*` · `os.*` · `process.*` · `service.*` · `telemetry.*` · `deployment.environment`
  - `OTEL_RESOURCE_PROVIDERS_AWS_ENABLED=true` 를 주면 다음이 생긴다.
    - `aws.ecs.cluster.arn` · `aws.ecs.container.arn` · `aws.ecs.container.image.id` · `aws.ecs.launchtype`
    - `aws.ecs.task.arn` · `aws.ecs.task.family` · `aws.ecs.task.revision`
    - `aws.log.group.{arns,names}` · `aws.log.stream.{arns,names}`
    - `cloud.account.id` · `cloud.availability_zone` · `cloud.platform` · `cloud.provider` · `cloud.region` · `cloud.resource_id`
    - `container.{id,name,image.name,image.tags}`
  - 두 경우 모두 Loki 에 저장된 리소스 속성은 허용 목록의 것(`service.instance.id` · `host.name` 등)뿐이다.
    `aws.*` · `cloud.*` 는 Collector 에서 버려졌다.
- **판단**: 허용 목록에 넣지 않는다. ARN 들과 `cloud.account.id` 에 계정 ID 가 들어 있다.
  태스크를 가리키는 데는 `service.instance.id` 와 `host.name` 으로 충분하다. nova 작업 정의에서도 AWS 감지를 켜지 않는다.
- **미실측**
  - 실제 Fargate 메타데이터 응답으로 만든 속성
  - Fargate 에서 `host.name` 값이 무엇인지
- **observation 에 넣을 때 주의**: 나중에 태스크 단위 조회(예: `aws.ecs.task.family`)가 필요해지면 그 키만 허용 목록에 더한다.
  ARN 계열은 계정 ID 를 담으므로 공개 저장소의 예시 · 시험 데이터에 실제 값을 쓰지 않는다.

## 8. 이미지 버전을 올린다

- **파일**: `stack/compose.yaml`
- **하네스와 다른 점**: 모두 태그와 다이제스트로 고정한다.

  | | 하네스 | 여기 |
  |---|---|---|
  | Collector | `0.116.1` | `0.162.0` |
  | Loki | `3.3.2` | `3.7.8` |
  | Grafana | `11.5.0` | `12.4.12` |

- **실측** (trivy 0.75.0 `image --severity HIGH,CRITICAL --platform linux/arm64`, 2026-10-10)

  | 이미지 | 하네스 버전 (HIGH · CRITICAL) | 여기 버전 (HIGH · CRITICAL) |
  |---|---|---|
  | Collector | 76 · 7 | 4 · 0 |
  | Loki | 55 · 2 | 4 · 0 |
  | Grafana | 11.5.0 은 재지 않았다. 11.6.16 이 69 · 1 | 12 · 0 |

  - Grafana 13.2.3 은 64 · 0 이라 12.4.12 를 골랐다.
  - 새 버전으로 smoke · retention · agent-probe 를 모두 다시 통과했다. 설정 문법은 바꾸지 않았다.
- **미실측**: 하네스의 트레이스 · 메트릭 경로(Tempo · Prometheus 익스포터 · exemplar)를 새 Collector 로 돌린 것
- **observation 에 넣을 때 주의**
  - 하네스는 세 신호를 다 쓰므로 Collector 를 올리면 하네스 스모크 전체를 다시 돌린다.
  - Loki 3.3 → 3.7 은 이 저장소의 로그 경로에서만 확인했다.

## 9. 저장 전 마스킹

- **파일**: `stack/otel-collector.yaml` 의 `transform/mask`, `test/masking.sh`, README "저장 전 마스킹"
- **하네스와 다른 점**
  - 하네스는 조회 경로에서 가린다는 결정이다. 여기는 **저장 전**에 Collector 에서 바꾼다.
    조회 경로에서 가리면 Grafana Explore · Loki API 로 직접 보면 가려지지 않기 때문이다.
  - logs 파이프라인: `memory_limiter` → `transform/resource-allowlist` → **`transform/mask`** → `batch`
  - 순서: 중복 키 값(한 줄 안) → 이메일(`@` · `%40`) → `+82` · `%2B82` · `0082` 전화 → `010` · `011` · `016`~`019` 전화.
    이메일이 전화보다 먼저여야 `hong.010…@…` 이 통째로 가려진다.
  - 경계: RE2 에 앞뒤 보기가 없어 "16진수가 아닌 문자 또는 줄 끝" 을 잡았다가 `${1}` · `${2}` 로 되돌린다(설정 파일에서는 `$` 를 `$$` 로 쓴다).
    경계 문자를 하나 소비하므로 붙어 있는 두 번호를 위해 전화 패턴을 두 번씩 건다.
    `+82` · `%2B82` 앞에는 경계를 두지 않는다. `+` · `%` 는 16진수 ID 에 없으니 ID 를 자를 일이 없고, 경계를 두면 `abc+8210…` · `phone+82 10-…` 을 놓친다.
    `\b` 를 쓰면 이스케이프된 `\n` · `_` 옆의 번호를 놓친다(`n` · `_` 가 단어 문자라서).
  - 범위
    - 본문: 맵 · 목록이면 `set(log.body, String(log.body))` 로 JSON 문자열로 바꾼 뒤 문자열 패턴을 건다.
      `replace_all_patterns` 는 맵의 첫 단계 문자열만 보기 때문이다.
    - 속성: `replace_all_patterns(log.attributes, "value", …)`. `exception.message` · `exception.stacktrace` 포함.
  - `error_mode: ignore`. `propagate` 는 문 하나의 실패로 배치 전체를 버린다(503).
- **실측** (로컬 + Floci, `test/masking.sh`, 2026-10-11)
  - 사례 22개를 속성 하나씩, 그리고 본문 한 줄에 이어 붙여 보냈다. 저장된 본문과 각 속성이 **필드마다 기대값과 정확히** 같다.
    - 사례: 구분자 세 가지 · 붙여 쓰기 · `+82` 다섯 형식 · `(010)` · 이스케이프된 `\n` `\t` 옆 · `_` 옆 · 한글 옆 · 붙어 있는 두 번호 ·
      `%40` 이메일 · 번호가 든 이메일 · 중복 키(한 줄, 두 줄에 걸친 두 개, `for key` 없는 앞의 것)
    - `exception.message` · 여러 줄 `exception.stacktrace` 도 기대값과 같다.
  - 바뀌지 않아야 할 11개가 그대로다: `010…` 으로 시작하는 trace ID · UUID · 16진수 ID, UUID `aggregate_id`, 큐 이름 `destination`,
    13자리 epoch ms, 7자리 숫자 ID, 14자리 숫자열, `Foo@1a2b3c` 등
  - 맵 본문(맵 · 목록 중첩)과 목록 본문의 중첩된 값까지 가려진다.
    본문을 문자열로 바꾸기 전과 뒤에 Loki 에 저장된 줄을 비교했다. 맵 · 목록 본문의 JSON 모양(키 순서 · 숫자 타입)은 같고, 가려진 값만 다르다.
    숫자 · 불리언 · 바이트 · 빈 본문은 앞뒤가 같다.
  - 대조군
    - `transform/mask` 를 빼면 첫 비교에서 실패한다.
    - 이 항목의 첫 판(`\b` 경계, 전화 → 이메일 순서)으로 돌리면 `\n` · `_` 옆, `(010)`, `+82 (0)`, `0082`, `%2B82`, `%40`,
      번호가 든 이메일 사례에서 실패하고, `for key` 없는 앞의 중복 키부터 다음 줄의 `for key` 까지를 통째로 지운다.
- **미실측**
  - 처리량에 대한 영향(정규식 문 13개 × 속성 수). 로그량을 아직 재지 않았다.
  - 실제 앱 예외(Hibernate · Spring 이 감싼 메시지)의 모양. 시험 문자열은 MySQL 메시지 형식을 손으로 만든 것이다.
- **observation 에 넣을 때 주의**
  - 하네스의 "조회 경로 마스킹" 결정 문서를 이 결정으로 바꾸거나, 두 경로를 나란히 둔다는 것을 적는다.
  - 패턴은 한국 휴대전화 기준이다. 다른 나라 번호 · 유선 전화 · 실명 · 주소는 걸리지 않는다. 범용으로 쓰려면 패턴 목록을 설정으로 뺀다.
  - 알려진 구멍과 오탐(README "걸리지 않는 것" · "오탐")을 같이 옮긴다.
  - 되돌릴 수 없다. 하네스의 디버깅 흐름이 원문을 기대한다면 로컬 프로필에서는 끌 수 있게 한다.
