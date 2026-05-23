#!/usr/bin/env bash
# ohmyclaw skill — engine resolver (ACP boundary, jq-based, deterministic)
#
# 역할: select-model.sh 가 "어떤 모델" 을 정한 뒤, 본 스크립트가 "그 모델을 어떤
#       코딩 에이전트 엔진으로, 어떤 ACP 명령으로" 실행할지 결정한다.
#       oh-my-pi(omp) 를 1순위 엔진으로 쓰되 하드포크하지 않고 acpx(ACP 클라이언트)
#       의 escape hatch('omp acp') 로 spawn 한다. omp 미설치 시 acpx 내장 어댑터
#       (pi/codex/claude) 로, acpx 마저 없으면 직접 CLI 로 graceful fallback 한다.
#
# Usage:
#   engine.sh resolve <model> [authType] [role]   # ENGINE|CMD_TEMPLATE 출력
#   engine.sh acp-config                          # ~/.acpx/config.json omp 등록 스니펫
#   engine.sh doctor                              # 엔진/acpx 점검 리포트
#   engine.sh help
#
# resolve 출력 형식 (한 줄):
#   <engine>|<command-template>
#   - engine        ∈ {omp, pi, codex, claude}
#   - command-template 에는 {{TASK}} / {{CWD}} 플레이스홀더 포함 (호출측이 치환)
#
# 예시:
#   engine.sh resolve glm-5.1 oauth_zai reviewer
#     → omp|acpx --agent "omp acp" --model glm-5.1 --cwd {{CWD}} --approve-reads --format text --timeout 300 {{TASK}}
#   engine.sh resolve gpt-5.4 oauth_codex executor   (omp 부재 시)
#     → codex|acpx --model gpt-5.4 --cwd {{CWD}} --approve-all --format text --timeout 300 codex {{TASK}}
#
# Reads: routing.json (same directory) → .engine.{preferred,providerEngines,acpxAgents,permissions,acpxFlags}
#
# Env overrides:
#   OHMYCLAW_ENGINE=<omp|pi|codex|claude>     특정 엔진 강제 (preferred 무시)
#   OHMYCLAW_ENGINE_FALLBACK=true|false       (기본 true) false 시 1순위 부재면 에러

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTING_FILE="${SCRIPT_DIR}/routing.json"

if [[ ! -f "$ROUTING_FILE" ]]; then
  echo "ERROR: routing.json not found at $ROUTING_FILE" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required (brew install jq)" >&2
  exit 2
fi

# ──────────────────────────────────────────────
# 헬퍼
# ──────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# model → provider (pool.sh 의 pool_for_model 과 동일 규칙)
provider_for_model() {
  case "$1" in
    glm-*)        echo "zai" ;;
    gpt-*)        echo "codex" ;;
    openrouter-*) echo "openrouter" ;;
    *)            echo "" ;;
  esac
}

# 엔진이 실제 실행 가능한지 (ACP 경계 기준)
#   omp            : omp 바이너리 필요 (acpx 있으면 escape hatch, 없으면 omp -p 직접 CLI)
#   pi/codex/claude: acpx(내장 어댑터) 또는 동일 이름 바이너리(직접 CLI)
engine_available() {
  case "$1" in
    omp)    have omp ;;
    pi)     have acpx || have pi ;;
    codex)  have acpx || have codex ;;
    claude) have acpx || have claude ;;
    *)      return 1 ;;
  esac
}

# role → acpx 승인정책 플래그
perm_flag_for_role() {
  local role="${1:-default}" policy
  policy=$(jq -r --arg r "$role" '.engine.permissions[$r] // .engine.permissions.default // "approve-reads"' "$ROUTING_FILE")
  case "$policy" in
    approve-all)   echo "--approve-all" ;;
    deny-all)      echo "--deny-all" ;;
    approve-reads) echo "--approve-reads" ;;
    *)             echo "--approve-reads" ;;
  esac
}

# ──────────────────────────────────────────────
# resolve
# ──────────────────────────────────────────────
cmd_resolve() {
  local model="${1:-}" _authType="${2:-}" role="${3:-default}"
  if [[ -z "$model" ]]; then
    echo "ERROR: model required. usage: engine.sh resolve <model> [authType] [role]" >&2
    exit 2
  fi

  local provider
  provider=$(provider_for_model "$model")
  if [[ -z "$provider" ]]; then
    echo "ERROR: unknown model '$model' (expect glm-*, gpt-*, or openrouter-*)" >&2
    exit 3
  fi

  # 후보 엔진 목록: env 강제 > providerEngines[provider] > preferred
  local candidates
  if [[ -n "${OHMYCLAW_ENGINE:-}" ]]; then
    candidates="$OHMYCLAW_ENGINE"
  else
    candidates=$(jq -r --arg p "$provider" '
      (.engine.providerEngines[$p] // .engine.preferred // ["omp","pi","codex","claude"])
      | join(" ")' "$ROUTING_FILE")
  fi

  # 공통 acpx 플래그
  local fmt timeout perm
  fmt=$(jq -r '.engine.acpxFlags.format // "text"' "$ROUTING_FILE")
  timeout=$(jq -r '.engine.acpxFlags.timeoutSeconds // 300' "$ROUTING_FILE")
  perm=$(perm_flag_for_role "$role")

  local fallback="${OHMYCLAW_ENGINE_FALLBACK:-true}"
  local chosen="" engine
  for engine in $candidates; do
    if engine_available "$engine"; then
      chosen="$engine"
      break
    fi
    [[ "$fallback" == "false" ]] && break
  done

  if [[ -z "$chosen" ]]; then
    echo "ERROR: no available engine for model '$model' (provider=$provider, candidates: $candidates). acpx/omp 미설치?" >&2
    exit 4
  fi

  # 명령 템플릿 생성
  local cmd
  if have acpx; then
    case "$chosen" in
      omp)
        local agent
        agent=$(jq -r '.engine.acpxAgents.omp.agent // "omp acp"' "$ROUTING_FILE")
        cmd="acpx --agent \"$agent\" --model $model --cwd {{CWD}} $perm --format $fmt --timeout $timeout {{TASK}}"
        ;;
      pi|codex|claude)
        local sub
        sub=$(jq -r --arg e "$chosen" '.engine.acpxAgents[$e].subcommand // $e' "$ROUTING_FILE")
        cmd="acpx --model $model --cwd {{CWD}} $perm --format $fmt --timeout $timeout $sub {{TASK}}"
        ;;
    esac
  else
    # acpx 부재 → 직접 CLI fallback
    case "$chosen" in
      omp)    cmd="omp -p {{TASK}}" ;;
      pi)     cmd="pi {{TASK}}" ;;
      codex)  cmd="codex exec --full-auto {{TASK}}" ;;
      claude) cmd="claude --permission-mode bypassPermissions --print {{TASK}}" ;;
    esac
  fi

  echo "${chosen}|${cmd}"
}

# ──────────────────────────────────────────────
# acp-config : ~/.acpx/config.json 에 omp 커스텀 에이전트 등록 스니펫
# ──────────────────────────────────────────────
cmd_acp_config() {
  cat <<'JSON'
{
  "agents": {
    "omp": {
      "command": "omp",
      "args": ["acp"]
    }
  }
}
JSON
}

# ──────────────────────────────────────────────
# doctor
# ──────────────────────────────────────────────
cmd_doctor() {
  local rc=0
  echo "=== ohmyclaw engine doctor ==="

  # 1) routing.json engine 블록
  if jq -e '.engine.boundary == "acp" and .engine.client == "acpx"' "$ROUTING_FILE" >/dev/null 2>&1; then
    echo "✓ routing.json engine block (boundary=acp, client=acpx)"
  else
    echo "✗ routing.json engine block missing/invalid"; rc=1
  fi

  # 2) acpx (ACP 경계 — 권장, 부재 시 직접 CLI 폴백)
  if have acpx; then
    echo "✓ acpx ($(acpx --version 2>/dev/null | head -1))"
  else
    echo "⚠ acpx 미설치 — 'npm i -g @openclaw/acpx' 권장. 부재 시 직접 CLI 폴백 동작."
  fi

  # 3) omp (1순위 엔진 — 부재 시 폴백 가능하므로 warn)
  if have omp; then
    echo "✓ omp (preferred engine) — $(command -v omp)"
  else
    echo "⚠ omp 미설치 — pi/codex/claude 로 폴백됨. 'curl -fsSL https://omp.sh/install | sh' 또는 'bun install -g @oh-my-pi/pi-coding-agent'"
  fi

  # 4) 폴백 엔진
  for b in pi codex claude; do
    have "$b" && echo "✓ $b ($(command -v $b))" || echo "ℹ $b 미설치 (acpx 내장 어댑터로 대체 가능)"
  done

  # 5) resolve smoke test — 적어도 하나의 엔진이 가용할 때만 실제 검증
  echo "--- resolve smoke ---"
  local any_engine=false
  if have omp || have acpx || have pi || have codex || have claude; then any_engine=true; fi
  if ! $any_engine; then
    echo "ℹ 엔진 0개 가용 — smoke 건너뜀 (CI/fresh 환경에서는 정상. 'engine.sh acp-config' 설치 가이드 참조)"
  else
    local out
    for m in glm-5.1 gpt-5.4; do
      if out=$(cmd_resolve "$m" "" reviewer 2>&1); then
        echo "✓ resolve $m → ${out%%|*}"
      else
        echo "✗ resolve $m 실패: $out"; rc=1
      fi
    done
  fi

  # 6) acp-config 유효성
  if cmd_acp_config | jq empty >/dev/null 2>&1; then
    echo "✓ acp-config 스니펫 유효 JSON"
  else
    echo "✗ acp-config 스니펫 무효"; rc=1
  fi

  # 7) JSON Schema 검증 (ajv-cli 가 있을 때만) — P4/F3
  local schema="$SCRIPT_DIR/schemas/routing.schema.json"
  if [[ -f "$schema" ]]; then
    if command -v ajv >/dev/null 2>&1; then
      if ajv validate --spec=draft2020 -s "$schema" -d "$ROUTING_FILE" >/dev/null 2>&1; then
        echo "✓ routing.json against schema (ajv)"
      else
        echo "✗ routing.json schema violation — run: ajv validate --spec=draft2020 -s $schema -d $ROUTING_FILE"; rc=1
      fi
    elif command -v npx >/dev/null 2>&1; then
      if npx -y ajv-cli@5 validate --spec=draft2020 -s "$schema" -d "$ROUTING_FILE" >/dev/null 2>&1; then
        echo "✓ routing.json against schema (npx ajv-cli)"
      else
        echo "✗ routing.json schema violation"; rc=1
      fi
    else
      echo "ℹ ajv 미설치 — schema 검증 건너뜀 (CI 에서만 강제)"
    fi
  fi

  echo "=== doctor rc=$rc ==="
  return $rc
}

# ──────────────────────────────────────────────
# main
# ──────────────────────────────────────────────
case "${1:-help}" in
  resolve)    shift; cmd_resolve "$@" ;;
  acp-config) cmd_acp_config ;;
  doctor)     cmd_doctor ;;
  help|-h|--help)
    cat <<'USAGE'
engine.sh — ohmyclaw ACP 엔진 리졸버

  resolve <model> [authType] [role]   ENGINE|CMD_TEMPLATE 출력 (omp 우선, 폴백)
  acp-config                          ~/.acpx/config.json omp 등록 스니펫
  doctor                              엔진/acpx 점검

엔진 경계: select-model.sh(모델 선택) → engine.sh(엔진/ACP 명령) → acpx(실행).
omp 는 하드포크 없이 acpx --agent "omp acp" 로 spawn. 미설치 시 graceful fallback.
USAGE
    ;;
  *)
    echo "ERROR: unknown subcommand '${1}'. try: engine.sh help" >&2
    exit 2
    ;;
esac
