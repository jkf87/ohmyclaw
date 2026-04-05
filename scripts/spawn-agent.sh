#!/usr/bin/env bash
# OpenClaw 하네스 — 에이전트 생성 헬퍼
# sessions_spawn 개념에 맞춘 래퍼
# 사용법: ./spawn-agent.sh <에이전트명> <태스크설명> [모델오버라이드]
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENTS_DIR="${HARNESS_DIR}/agents"
SCRIPT_DIR="${HARNESS_DIR}/scripts"

AGENT_NAME="${1:-}"
TASK_DESC="${2:-}"
MODEL_OVERRIDE="${3:-}"

if [[ -z "$AGENT_NAME" ]] || [[ -z "$TASK_DESC" ]]; then
    echo "사용법: $0 <에이전트명> <태스크설명> [모델오버라이드]" >&2
    echo "에이전트: planner, worker, reviewer, debugger, bridge" >&2
    exit 1
fi

AGENT_FILE="${AGENTS_DIR}/${AGENT_NAME}.md"
if [[ ! -f "$AGENT_FILE" ]]; then
    echo "에러: 에이전트 정의 파일을 찾을 수 없습니다: ${AGENT_FILE}" >&2
    exit 1
fi

extract_frontmatter() {
    sed -n '/^---$/,/^---$/p' "$AGENT_FILE" | sed '1d;$d'
}

extract_prompt() {
    sed -n '/^---$/,/^---$/!p' "$AGENT_FILE" | tail -n +2
}

FRONTMATTER=$(extract_frontmatter)
PROMPT=$(extract_prompt)

get_yaml_value() {
    local key="$1"
    echo "$FRONTMATTER" \
        | grep -E "^${key}:" \
        | head -1 \
        | sed "s/^${key}:[[:space:]]*//" \
        | sed 's/[[:space:]]*#.*$//' \
        | sed 's/^"//' \
        | sed 's/"$//' \
        | xargs
}

get_nested_value() {
    local key="$1"
    echo "$FRONTMATTER" \
        | grep -E "^[[:space:]]+${key}:" \
        | head -1 \
        | sed "s/.*${key}:[[:space:]]*//" \
        | sed 's/[[:space:]]*#.*$//' \
        | sed 's/^"//' \
        | sed 's/"$//' \
        | xargs
}

MODEL_TIER=$(get_yaml_value "model_tier")
SESSION_TYPE=$(get_nested_value "session_type")
TIMEOUT_MS=$(get_nested_value "timeout_ms")
MAX_TOKENS=$(get_nested_value "max_tokens")

SESSION_TYPE="${SESSION_TYPE:-isolated}"
TIMEOUT_MS="${TIMEOUT_MS:-300000}"
MAX_TOKENS="${MAX_TOKENS:-32000}"

default_model_for_tier() {
    local tier="$1"
    case "$tier" in
        LOW)    echo "glm-5-turbo" ;;
        MEDIUM) echo "gpt-5.3-codex" ;;
        HIGH)   echo "glm-5.1" ;;
        *)      echo "gpt-5.3-codex" ;;
    esac
}

if [[ -n "$MODEL_OVERRIDE" ]]; then
    SELECTED_MODEL="$MODEL_OVERRIDE"
else
    AGENT_MODEL_OVERRIDE=$(get_yaml_value "model_override")
    if [[ -n "$AGENT_MODEL_OVERRIDE" ]] && [[ "$AGENT_MODEL_OVERRIDE" != "null" ]]; then
        SELECTED_MODEL="$AGENT_MODEL_OVERRIDE"
    else
        # Planner/Reviewer/Bridge는 역할 특성이 강해서 태스크 문장보다 에이전트 tier를 우선한다.
        case "$AGENT_NAME" in
            planner|reviewer|bridge)
                SELECTED_MODEL=$(default_model_for_tier "$MODEL_TIER")
                ;;
            *)
                ROUTING_RESULT=$("${SCRIPT_DIR}/route-task.sh" "$TASK_DESC" "auto" "standard" 2>/dev/null || true)
                if [[ -n "$ROUTING_RESULT" ]]; then
                    SELECTED_MODEL=$(echo "$ROUTING_RESULT" | grep "model:" | head -1 | sed 's/.*model:[[:space:]]*//' | xargs)
                else
                    SELECTED_MODEL=$(default_model_for_tier "$MODEL_TIER")
                fi
                ;;
        esac
    fi
fi

build_context() {
    cat <<CONTEXT_EOF
# 에이전트: ${AGENT_NAME}
# 모델: ${SELECTED_MODEL}
# 세션 유형: ${SESSION_TYPE}

## 태스크

${TASK_DESC}

## 에이전트 지침

${PROMPT}
CONTEXT_EOF
}

CONTEXT=$(build_context)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 에이전트 스포닝: ${AGENT_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  모델: ${SELECTED_MODEL}"
echo "  세션 유형: ${SESSION_TYPE}"
echo "  타임아웃: $((TIMEOUT_MS / 1000))초"
echo "  최대 토큰: ${MAX_TOKENS}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 현재 공개 openclaw CLI만으로는 sessions_spawn 툴 호출을 재현할 수 없어서
# 로컬 스크립트 테스트에서는 안전하게 시뮬레이션 모드로 동작한다.
echo "[시뮬레이션] 실제 채팅 런타임에서는 sessions_spawn 툴로 대응, CLI 테스트에서는 구조/라우팅 검증만 수행" >&2
echo "spawn_result:"
echo "  agent: ${AGENT_NAME}"
echo "  model: ${SELECTED_MODEL}"
echo "  session_type: ${SESSION_TYPE}"
echo "  timeout_ms: ${TIMEOUT_MS}"
echo "  max_tokens: ${MAX_TOKENS}"
echo "  status: simulated"
echo "  context_preview: |"
printf '%s\n' "$CONTEXT" | sed 's/^/    /'
