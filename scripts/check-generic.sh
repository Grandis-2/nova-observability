#!/usr/bin/env bash
# 범용 디렉터리(stack/ · ecs/)에 nova 이름이 들어오면 실패한다.
# 이 디렉터리들은 나중에 observation 플랫폼으로 그대로 올라간다. nova 값은 README 에만 둔다.
set -euo pipefail
cd "$(dirname "$0")/.."
if grep -rnIiw nova stack ecs; then
  echo "FAIL — 범용 디렉터리에 'nova' 가 있다 (위 줄). 값은 README 로 옮긴다"
  exit 1
fi
echo "OK — stack/ ecs/ 에 'nova' 없음"
