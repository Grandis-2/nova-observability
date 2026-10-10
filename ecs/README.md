# ECS 작업 정의에 OTel Java 에이전트 붙이기 (로그 전용)

앱 이미지를 고치지 않고 작업 정의만 바꾼다. 조각은 [`agent-injection.json`](agent-injection.json) 이다.
`<...>` 는 시스템마다 채울 값이다.

## 무엇을 바꾸나

| 어디 | 무엇 |
|---|---|
| `volumes` | `otel-agent` 볼륨 추가 (Fargate 태스크 임시 저장소) |
| `containerDefinitions` | `otel-agent-init` 추가. jar 만 든 이미지에서 jar 을 볼륨으로 복사하고 끝난다(`essential: false`) |
| 앱 컨테이너 | `appContainerPatch` 의 세 필드를 기존 값에 합친다(통째로 바꾸지 않는다). `dependsOn`(init 이 `SUCCESS` 로 끝날 때까지 기다림) · `mountPoints`(읽기 전용)는 덧붙인다. `environment` 는 **이름이 이미 있으면 그 항목의 값을 바꾸고, 없는 이름만 덧붙인다** — 같은 이름이 두 번 있으면 어느 값이 쓰일지 정해져 있지 않다. `JAVA_TOOL_OPTIONS` 는 아래 병합 규칙의 값으로 바꾼다 |

init 이미지는 OpenTelemetry Operator 가 쓰는 `autoinstrumentation-java` 다.
- 태그와 다이제스트로 고정했다.
- jar 경로 `/javaagent.jar` 를 확인했다.
- 그 jar 의 SHA-256 이 GitHub 릴리스 자산과 같은 `f787eb6c…` 인 것을 확인했다.
- 이미지에 busybox `cp` 가 있다.
- `linux/arm64` · `linux/amd64` 매니페스트가 있다.

ghcr.io 에서 받으므로 태스크가 인터넷(NAT)에 닿아야 한다. 닿지 않는 서브넷이면 ECR 로 옮겨 쓴다.

## `JAVA_TOOL_OPTIONS` 병합 규칙

작업 정의의 `environment` 는 이미지의 `ENV` 를 **통째로 덮는다**. `-javaagent:` 만 넣으면 이미지가 넣어 둔
`-XX:MaxRAMPercentage=…` 같은 값이 경고 없이 사라진다.

1. 이미지의 기존 값을 확인한다: `docker image inspect <image> --format '{{json .Config.Env}}'`
   (작업 정의에 이미 `JAVA_TOOL_OPTIONS` 가 있으면 그 값이 기준이다)
2. 새 값 = **기존 값 + 공백 + `-javaagent:/otel/javaagent.jar`**. 순서는 상관없지만 기존 플래그를 하나도 빼지 않는다
3. 배포 뒤 확인: `jcmd <pid> VM.flags` 에 기존 플래그가 남아 있는지 본다.
   `JAVA_TOOL_OPTIONS` 는 `jcmd` 같은 JDK 도구에도 적용된다. 그래도 에이전트는 도구를 알아보고 붙지 않는다(`JDK tool detected … agent will not be started`).

## 환경 변수에서 틀리기 쉬운 것

- **`OTEL_EXPORTER_OTLP_PROTOCOL=grpc` 를 빼지 않는다.** 에이전트 기본값은 `http/protobuf` 다.
  gRPC 포트 4317 로 http 를 보내면 앱 로그에 `Failed to export … logs` 한 줄이 남고, 수집 쪽에는 아무것도 오지 않는다.
  http 로 보내려면 포트를 4318 로 바꾼다.
- `deployment.environment` 를 넣는다. `deployment.environment.name` 만 넣으면 조회 셀렉터가 `deployment_environment` 를 못 찾는다
  (스택은 둘 다 인덱스 라벨로 받는다).
- 2.32.0 의 logback 속성은 새 이름을 쓴다. 옛 이름(`…capture-mdc-attributes` · `…capture-key-value-pair-attributes`)은 폐기 예정 경고가 난다.
  새 이름은 `true` 를 받지 않는다. `*` 나 쉼표로 이은 이름 목록을 준다.
- MDC 는 필요한 키만 준다. 회원 ID 같은 값이 MDC 에 있으면 `*` 로는 그것까지 저장된다.
- 트레이스·메트릭은 `none` 이다. 이 스택은 로그만 받는다.

## 확인하지 않은 것

- 실제 Fargate 에서의 동작 전체(init 컨테이너 순서, `readonlyRootFilesystem`, 볼륨 권한). 위 내용은 로컬 JVM 과 이미지 검사로 확인한 것이다
- 에이전트를 붙인 뒤의 기동 시간 증가. 헬스체크 유예 시간은 배포하면서 잰다
- init 컨테이너에 메모리 예약을 따로 주지 않았다. 태스크 메모리 안에서 잠깐 돌고 끝난다
