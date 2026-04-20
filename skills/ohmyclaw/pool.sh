#!/usr/bin/env bash
# ohmyclaw skill — multi-account pool manager (round-robin / cooldown / fan-out)
#
# Usage:
#   pool.sh next <model>          # round-robin pick → "id|authType|authValue|plan"
#   pool.sh fanout <providerId>   # fan-out 모드: 모든 enabled 계정 newline 출력
#   pool.sh status [providerId]   # 풀 상태 + cooldown 잔여 시간
#   pool.sh cooldown <id>         # 계정 cooldown 마킹 (rate limit hit 시)
#   pool.sh release <id>          # cooldown 해제
#   pool.sh reset                 # 전체 state 리셋
#
# State: ~/.cache/ohmyclaw/pool-state.json (또는 OHMYCLAW_STATE_DIR 환경변수)
# Reads: routing.json (스크립트 디렉토리)
#
# 모델 → 풀 매핑 규칙:
#   glm-*    → zai 풀
#   gpt-*    → codex 풀 (codex_oauth_enabled 일 때만)
#   claude-code-* → claudecli 풀 (claudecli_delegation_enabled 일 때만)
#   openrouter-* → openrouter 풀 (openrouter_enabled 일 때만)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTING_FILE="${SCRIPT_DIR}/routing.json"
STATE_DIR="${OHMYCLAW_STATE_DIR:-$HOME/.cache/ohmyclaw}"
STATE_FILE="${STATE_DIR}/pool-state.json"

mkdir -p "$STATE_DIR"
[[ ! -f "$STATE_FILE" ]] && echo '{}' > "$STATE_FILE"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required (brew install jq)" >&2
  exit 2
fi

now() { date +%s; }

# ──────────────────────────────────────────────
# 모델 → 풀 ID 매핑
# ──────────────────────────────────────────────
pool_for_model() {
  local model="$1"
  case "$model" in
    glm-*) echo "zai" ;;
    gpt-*) echo "codex" ;;
    claude-code-*) echo "claudecli" ;;
    openrouter-*)  echo "openrouter" ;;
    *) echo "" ;;
  esac
}

# ──────────────────────────────────────────────
# 풀의 enabled 계정 목록 (cooldown 해제된 것만)
# 출력: id|authType|authValue|plan|weight  (한 줄 한 계정)
# ──────────────────────────────────────────────
get_eligible_accounts() {
  local pool="$1" current_time
  current_time=$(now)

  jq -r --arg pool "$pool" --arg now "$current_time" --slurpfile state "$STATE_FILE" '
    .accounts.pools[$pool].accounts[]?
    | select(.enabled == true)
    | . as $acct
    | (
        ($state[0][$pool][.id].cooldownUntil // 0) | tonumber
      ) as $cooldownUntil
    | select(($now | tonumber) >= $cooldownUntil)
    | [
        .id,
        .authType,
        (.openclawProfile // .codexHome // .claudeHome // .envKey // ""),
        (.plan // "any"),
        (.weight // 1)
      ]
    | join("|")
  ' "$ROUTING_FILE"
}

# ──────────────────────────────────────────────
# next: round-robin (가중치 무시 단순 회전)
# ──────────────────────────────────────────────
action_next() {
  local model="$1"
  local pool
  pool=$(pool_for_model "$model")
  if [[ -z "$pool" ]]; then
    echo "ERROR: unknown model prefix for '$model' (expect glm-*, gpt-*, claude-code-*, or openrouter-*)" >&2
    exit 1
  fi

  # codex 풀은 CODEX_OAUTH_ENABLED 게이트
  if [[ "$pool" == "codex" && "${CODEX_OAUTH_ENABLED:-false}" != "true" ]]; then
    echo "ERROR: codex pool not enabled (set CODEX_OAUTH_ENABLED=true)" >&2
    exit 1
  fi

  # claudecli 풀은 CLAUDECLI_DELEGATION_ENABLED 게이트
  if [[ "$pool" == "claudecli" && "${CLAUDECLI_DELEGATION_ENABLED:-false}" != "true" ]]; then
    echo "ERROR: claudecli pool not enabled (set CLAUDECLI_DELEGATION_ENABLED=true and enable an account in routing.json)" >&2
    exit 1
  fi

  # openrouter 풀은 OPENROUTER_ENABLED 게이트
  if [[ "$pool" == "openrouter" && "${OPENROUTER_ENABLED:-false}" != "true" ]]; then
    echo "ERROR: openrouter pool not enabled (set OPENROUTER_ENABLED=true and OPENROUTER_API_KEY)" >&2
    exit 1
  fi

  local accounts
  accounts=$(get_eligible_accounts "$pool")
  if [[ -z "$accounts" ]]; then
    echo "ERROR: no eligible accounts in pool '$pool' (cooldown 또는 enabled=false)" >&2
    exit 1
  fi

  local total
  total=$(echo "$accounts" | wc -l | tr -d ' ')

  # 현재 인덱스 읽고 +1 (mod total)
  local idx
  idx=$(jq -r --arg p "$pool" '.[$p].roundRobinIndex // 0' "$STATE_FILE")
  local pick_idx=$(( idx % total + 1 ))

  local picked
  picked=$(echo "$accounts" | sed -n "${pick_idx}p")

  # 인덱스 증가 + 마지막 사용 기록
  local picked_id
  picked_id=$(echo "$picked" | cut -d'|' -f1)

  jq --arg p "$pool" \
     --arg id "$picked_id" \
     --arg now "$(now)" \
     --argjson next "$pick_idx" \
     '
       .[$p].roundRobinIndex = $next
       | .[$p][$id].lastUsed = ($now | tonumber)
       | .[$p][$id].cooldownUntil //= 0
     ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

  echo "$picked"
}

# ──────────────────────────────────────────────
# fanout: 풀의 모든 enabled 계정 출력
# ──────────────────────────────────────────────
action_fanout() {
  local pool="$1"
  if [[ -z "$pool" ]]; then
    echo "Usage: $0 fanout <providerId>" >&2
    exit 1
  fi
  get_eligible_accounts "$pool"
}

# ──────────────────────────────────────────────
# cooldown: 계정 마킹 (지수 백오프)
# ──────────────────────────────────────────────
action_cooldown() {
  local id="$1"
  if [[ -z "$id" ]]; then
    echo "Usage: $0 cooldown <id>" >&2
    exit 1
  fi

  local base
  base=$(jq -r '.accounts.poolDefaults.cooldownSeconds // 60' "$ROUTING_FILE")
  local mult
  mult=$(jq -r '.accounts.poolDefaults.backoffMultiplier // 2' "$ROUTING_FILE")
  local maxc
  maxc=$(jq -r '.accounts.poolDefaults.maxCooldownSeconds // 600' "$ROUTING_FILE")

  # 풀 찾기
  local pool
  pool=$(jq -r --arg id "$id" '
    .accounts.pools | to_entries[]
    | select(.value.accounts[]? | .id == $id)
    | .key
  ' "$ROUTING_FILE" | head -1)

  if [[ -z "$pool" ]]; then
    echo "ERROR: account '$id' not found in any pool" >&2
    exit 1
  fi

  local now_t
  now_t=$(now)

  jq --arg p "$pool" \
     --arg id "$id" \
     --arg now "$now_t" \
     --argjson base "$base" \
     --argjson mult "$mult" \
     --argjson maxc "$maxc" \
     '
       .[$p][$id].consecutiveFailures = ((.[$p][$id].consecutiveFailures // 0) + 1)
       | .[$p][$id].cooldownDuration = (
           [($base * (pow($mult; .[$p][$id].consecutiveFailures - 1))), $maxc]
           | min
         )
       | .[$p][$id].cooldownUntil = (($now | tonumber) + .[$p][$id].cooldownDuration)
     ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

  local until
  until=$(jq -r --arg p "$pool" --arg id "$id" '.[$p][$id].cooldownUntil' "$STATE_FILE")
  echo "[pool] ${id} (${pool}) cooldown until $(date -r $until '+%Y-%m-%d %H:%M:%S')" >&2
}

# ──────────────────────────────────────────────
# release: cooldown 해제 + 카운터 리셋
# ──────────────────────────────────────────────
action_release() {
  local id="$1"
  local pool
  pool=$(jq -r --arg id "$id" '
    .accounts.pools | to_entries[]
    | select(.value.accounts[]? | .id == $id) | .key
  ' "$ROUTING_FILE" | head -1)
  if [[ -z "$pool" ]]; then echo "ERROR: $id not found" >&2; exit 1; fi

  jq --arg p "$pool" --arg id "$id" '
    .[$p][$id].cooldownUntil = 0
    | .[$p][$id].consecutiveFailures = 0
  ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "[pool] released $id ($pool)" >&2
}

# ──────────────────────────────────────────────
# status: 풀 + 계정 상태 출력
# ──────────────────────────────────────────────
action_status() {
  local pool_filter="${1:-}"
  local now_t
  now_t=$(now)

  jq -r --arg now "$now_t" --arg filter "$pool_filter" --slurpfile state "$STATE_FILE" '
    .accounts.pools | to_entries[]
    | select($filter == "" or .key == $filter)
    | "── \(.key) (\(.value.providerId)) ──",
      (
        .value.accounts[]?
        | . as $a
        | (
            ($state[0][.id].cooldownUntil // $state[0]
              | (. // {})
            ) | empty
          ) // (
            ($state[0][$a.id].cooldownUntil // 0) | tonumber
          ) as $cu
        | "  \($a.id) [\($a.authType)] enabled=\($a.enabled) plan=\($a.plan // "any") weight=\($a.weight // 1)"
      )
  ' "$ROUTING_FILE" 2>/dev/null || true

  # 간단한 cooldown 잔여 시간 표시 (별도 출력)
  echo ""
  echo "── cooldown 상태 ──"
  jq -r --arg now "$now_t" '
    to_entries[]
    | .key as $pool
    | .value | to_entries[]
    | select(.key | test("^(zai-|codex-|claudecli-|openrouter-)"))
    | select(.value.cooldownUntil != null and (.value.cooldownUntil | tonumber) > ($now | tonumber))
    | "  \(.key) (\($pool)): \(((.value.cooldownUntil | tonumber) - ($now | tonumber)))s 남음"
  ' "$STATE_FILE" 2>/dev/null
  if [[ -z "$(jq -r 'to_entries[] | .value | to_entries[] | select(.value.cooldownUntil != null) | .key' "$STATE_FILE" 2>/dev/null)" ]]; then
    echo "  (cooldown 중인 계정 없음)"
  fi
}

# ──────────────────────────────────────────────
# reset: state 전체 리셋
# ──────────────────────────────────────────────
action_reset() {
  echo '{}' > "$STATE_FILE"
  echo "[pool] state reset → $STATE_FILE" >&2
}

# ──────────────────────────────────────────────
# 디스패치
# ──────────────────────────────────────────────
case "${1:-}" in
  next)     shift; action_next "${1:-}" ;;
  fanout)   shift; action_fanout "${1:-}" ;;
  cooldown) shift; action_cooldown "${1:-}" ;;
  release)  shift; action_release "${1:-}" ;;
  status)   shift; action_status "${1:-}" ;;
  reset)    action_reset ;;
  *)
    cat <<EOF >&2
Usage: $0 <action> [args...]

Actions:
  next <model>          Round-robin 픽 → "id|authType|authValue|plan|weight"
  fanout <providerId>   풀의 enabled 계정 전부 출력
  cooldown <id>         계정 cooldown 마킹 (rate limit 히트 시)
  release <id>          cooldown 해제
  status [providerId]   풀 상태 + cooldown 잔여 시간
  reset                 state 전체 리셋

Env:
  OHMYCLAW_STATE_DIR    state 디렉토리 (기본: ~/.cache/ohmyclaw)
  CODEX_OAUTH_ENABLED   codex 풀 사용 시 true 필수
  CLAUDECLI_DELEGATION_ENABLED  claudecli 풀 사용 시 true 필수
  OPENROUTER_ENABLED    openrouter 풀 사용 시 true 필수 (OPENROUTER_API_KEY 도 필요)
EOF
    exit 1
    ;;
esac
