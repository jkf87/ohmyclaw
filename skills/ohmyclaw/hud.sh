#!/usr/bin/env bash
# ohmyclaw HUD — 계정/플랜/quota/라우팅 대시보드
#
# Usage:
#   hud.sh              # 전체 대시보드
#   hud.sh --compact    # 한 줄 요약
#   hud.sh --accounts   # 계정만
#   hud.sh --quota      # quota만
#   hud.sh --routing    # 라우팅 설정만
#
# 환경변수:
#   ZAI_CODING_PLAN, CODEX_OAUTH_ENABLED, ZAI_API_KEY, OHMYCLAW_STATE_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTING_FILE="${SCRIPT_DIR}/routing.json"
STATE_DIR="${OHMYCLAW_STATE_DIR:-$HOME/.cache/ohmyclaw}"
STATE_FILE="${STATE_DIR}/pool-state.json"
USAGE_FILE="${STATE_DIR}/usage-today.json"

[[ ! -f "$STATE_FILE" ]] && mkdir -p "$STATE_DIR" && echo '{}' > "$STATE_FILE"
[[ ! -f "$USAGE_FILE" ]] && echo '{"date":"","tokens":0,"requests":0}' > "$USAGE_FILE"

PLAN="${ZAI_CODING_PLAN:-pro}"
CODEX="${CODEX_OAUTH_ENABLED:-false}"

# ──────────────────────────────────────────────
# 색상
# ──────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0m' B='\033[1m' DIM='\033[2m'
  GREEN='\033[32m' YELLOW='\033[33m' RED='\033[31m' CYAN='\033[36m' BLUE='\033[34m' MAGENTA='\033[35m'
else
  R='' B='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' BLUE='' MAGENTA=''
fi

# ──────────────────────────────────────────────
# 유틸
# ──────────────────────────────────────────────
bar() {
  local pct=$1 width=20 filled empty
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  local color="$GREEN"
  [[ $pct -ge 80 ]] && color="$YELLOW"
  [[ $pct -ge 95 ]] && color="$RED"
  printf "${color}"
  printf '█%.0s' $(seq 1 $filled 2>/dev/null) || true
  printf "${DIM}"
  printf '░%.0s' $(seq 1 $empty 2>/dev/null) || true
  printf "${R} %d%%" "$pct"
}

now_epoch() { date +%s; }
today() { date +%Y-%m-%d; }

# ──────────────────────────────────────────────
# 사용량 추적 (provider 별 일일 카운터)
# schema: {"date":"2026-04-10","zai":{"tokens":0,"requests":0},"codex":{"tokens":0,"requests":0},"total":{"tokens":0,"requests":0}}
# ──────────────────────────────────────────────
init_usage() {
  echo '{"date":"'"$(today)"'","zai":{"tokens":0,"requests":0},"codex":{"tokens":0,"requests":0},"total":{"tokens":0,"requests":0}}' > "$USAGE_FILE"
}

ensure_usage() {
  local d
  d=$(jq -r '.date // ""' "$USAGE_FILE" 2>/dev/null || echo "")
  if [[ "$d" != "$(today)" ]]; then
    init_usage
  fi
  # 마이그레이션: 옛날 flat 스키마 → provider 별
  if ! jq -e '.zai' "$USAGE_FILE" >/dev/null 2>&1; then
    local old_t old_r
    old_t=$(jq -r '.tokens // 0' "$USAGE_FILE")
    old_r=$(jq -r '.requests // 0' "$USAGE_FILE")
    init_usage
    jq --argjson t "$old_t" --argjson r "$old_r" \
      '.zai.tokens = $t | .zai.requests = $r | .total.tokens = $t | .total.requests = $r' \
      "$USAGE_FILE" > "${USAGE_FILE}.tmp" && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
  fi
}

get_usage() {
  ensure_usage
  jq -r '"\(.total.tokens) \(.total.requests)"' "$USAGE_FILE"
}

get_usage_by_provider() {
  local provider="$1"
  ensure_usage
  jq -r --arg p "$provider" '"\(.[$p].tokens // 0) \(.[$p].requests // 0)"' "$USAGE_FILE"
}

# 외부에서 호출: hud.sh log-usage <tokens> <requests> [provider]
# provider: zai | codex (기본: zai)
log_usage() {
  local tokens="${1:-0}" requests="${2:-1}" provider="${3:-zai}"
  ensure_usage
  jq --argjson t "$tokens" --argjson r "$requests" --arg p "$provider" \
    '.[$p].tokens += $t | .[$p].requests += $r | .total.tokens += $t | .total.requests += $r' \
    "$USAGE_FILE" > "${USAGE_FILE}.tmp" && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
}

# ──────────────────────────────────────────────
# 섹션: 플랜
# ──────────────────────────────────────────────
section_plan() {
  local price daily_tokens daily_requests max_workers
  price=$(jq -r --arg p "$PLAN" '.plans[$p].priceUsdMonth' "$ROUTING_FILE")
  daily_tokens=$(jq -r --arg p "$PLAN" '.plans[$p].quota.dailyTokens' "$ROUTING_FILE")
  daily_requests=$(jq -r --arg p "$PLAN" '.plans[$p].quota.dailyRequests' "$ROUTING_FILE")
  max_workers=$(jq -r --arg p "$PLAN" '.plans[$p].concurrency.maxWorkers' "$ROUTING_FILE")

  local plan_upper
  plan_upper=$(echo "$PLAN" | tr '[:lower:]' '[:upper:]')

  local plan_color="$CYAN"
  [[ "$PLAN" == "max" ]] && plan_color="$MAGENTA"
  [[ "$PLAN" == "lite" ]] && plan_color="$YELLOW"

  printf "  ${B}Plan${R}  ${plan_color}${B}%s${R} (\$%s/월)  " "$plan_upper" "$price"
  printf "Workers: ${B}%s${R}\n" "$max_workers"
  echo ""

  # provider 별 사용량
  ensure_usage
  local codex_req_limit=1500  # codex_oauth_addon quota

  printf "  ${DIM}%-8s %10s %10s${R}\n" "provider" "tokens" "requests"
  printf "  ${DIM}%-8s %10s %10s${R}\n" "────────" "──────" "────────"

  # zai
  read -r zai_t zai_r <<< "$(get_usage_by_provider zai)"
  local zai_t_pct=0 zai_r_pct=0
  [[ $daily_tokens -gt 0 ]] && zai_t_pct=$(( zai_t * 100 / daily_tokens ))
  [[ $daily_requests -gt 0 ]] && zai_r_pct=$(( zai_r * 100 / daily_requests ))
  [[ $zai_t_pct -gt 100 ]] && zai_t_pct=100
  [[ $zai_r_pct -gt 100 ]] && zai_r_pct=100
  printf "  ${GREEN}%-8s${R} %7sK / %sM  " "zai" "$((zai_t / 1000))" "$((daily_tokens / 1000000))"
  bar $zai_t_pct
  printf "  %5s / %s  " "$zai_r" "$daily_requests"
  bar $zai_r_pct
  echo ""

  # codex
  read -r codex_t codex_r <<< "$(get_usage_by_provider codex)"
  if [[ "$CODEX" == "true" ]]; then
    local codex_r_pct=0
    [[ $codex_req_limit -gt 0 ]] && codex_r_pct=$(( codex_r * 100 / codex_req_limit ))
    [[ $codex_r_pct -gt 100 ]] && codex_r_pct=100
    printf "  ${CYAN}%-8s${R} %7sK / ${DIM}∞${R}      " "codex" "$((codex_t / 1000))"
    printf "${DIM}(sub)${R}"
    printf "  %5s / %s  " "$codex_r" "$codex_req_limit"
    bar $codex_r_pct
  else
    printf "  ${DIM}%-8s${R} ${DIM}(disabled)${R}" "codex"
  fi
  echo ""

  # total
  read -r total_t total_r <<< "$(get_usage)"
  local total_t_pct=0
  [[ $daily_tokens -gt 0 ]] && total_t_pct=$(( total_t * 100 / daily_tokens ))
  [[ $total_t_pct -gt 100 ]] && total_t_pct=100
  printf "  ${B}%-8s${R} %7sK / %sM  " "total" "$((total_t / 1000))" "$((daily_tokens / 1000000))"
  bar $total_t_pct
  echo ""
}

# ──────────────────────────────────────────────
# 섹션: 계정
# ──────────────────────────────────────────────
section_accounts() {
  local now_t
  now_t=$(now_epoch)

  for pool in zai codex; do
    local provider
    provider=$(jq -r --arg p "$pool" '.accounts.pools[$p].providerId // "?"' "$ROUTING_FILE")

    # codex 풀은 CODEX_OAUTH_ENABLED 게이트
    if [[ "$pool" == "codex" && "$CODEX" != "true" ]]; then
      printf "  ${DIM}%-6s${R}  ${DIM}(disabled)${R}\n" "$pool"
      continue
    fi

    printf "  ${B}%-6s${R}  " "$pool"

    local accounts
    accounts=$(jq -r --arg p "$pool" '
      .accounts.pools[$p].accounts[]
      | "\(.id)|\(.enabled)|\(.authType)|\(.plan // "any")"
    ' "$ROUTING_FILE" 2>/dev/null)

    local first=true
    while IFS='|' read -r id enabled auth_type acct_plan; do
      [[ -z "$id" ]] && continue
      [[ "$first" != "true" ]] && printf "          "
      first=false

      local status_icon="${GREEN}●${R}"
      if [[ "$enabled" != "true" ]]; then
        status_icon="${DIM}○${R}"
      else
        # cooldown 체크
        local cu
        cu=$(jq -r --arg p "$pool" --arg id "$id" '.[$p][$id].cooldownUntil // 0' "$STATE_FILE" 2>/dev/null || echo 0)
        if [[ $(echo "$cu" | tr -d '.') -gt $now_t ]]; then
          local remain=$(( ${cu%.*} - now_t ))
          status_icon="${RED}◉${R} ${DIM}(${remain}s)${R}"
        fi
      fi

      printf "%s %-18s ${DIM}%s${R} ${DIM}plan=%s${R}\n" "$status_icon" "$id" "$auth_type" "$acct_plan"
    done <<< "$accounts"
  done
}

# ──────────────────────────────────────────────
# 섹션: 모델
# ──────────────────────────────────────────────
section_models() {
  local allowed
  allowed=$(jq -r --arg p "$PLAN" '.plans[$p].allowedModels | join(", ")' "$ROUTING_FILE")
  local blocked
  blocked=$(jq -r --arg p "$PLAN" '(.plans[$p].blockedModels // []) | if length == 0 then "(none)" else join(", ") end' "$ROUTING_FILE")

  printf "  ${B}Models${R}   ${GREEN}%s${R}" "$allowed"
  [[ "$CODEX" == "true" ]] && printf " + ${CYAN}gpt-5.4${R}"
  echo ""
  [[ "$blocked" != "(none)" ]] && printf "  ${DIM}Blocked${R}  ${RED}%s${R}\n" "$blocked"
}

# ──────────────────────────────────────────────
# 섹션: 라우팅 요약
# ──────────────────────────────────────────────
section_routing() {
  printf "  ${DIM}HIGH coding_arch${R}  → "
  ZAI_CODING_PLAN=$PLAN $SCRIPT_DIR/select-model.sh "architecture task with migration refactoring 아키텍처 마이그레이션 리팩토링 설계" coding_arch ${CODEX:+--codex} 2>/dev/null
  printf "  ${DIM}HIGH reasoning${R}    → "
  ZAI_CODING_PLAN=$PLAN $SCRIPT_DIR/select-model.sh "prove algorithm invariant 증명 알고리즘 불변" reasoning ${CODEX:+--codex} 2>/dev/null
  printf "  ${DIM}LOW general${R}       → "
  ZAI_CODING_PLAN=$PLAN $SCRIPT_DIR/select-model.sh "add type" coding_general 2>/dev/null
}

# ──────────────────────────────────────────────
# Compact (한 줄)
# ──────────────────────────────────────────────
compact() {
  ensure_usage
  local plan_upper
  plan_upper=$(echo "$PLAN" | tr '[:lower:]' '[:upper:]')

  local daily_tokens
  daily_tokens=$(jq -r --arg p "$PLAN" '.plans[$p].quota.dailyTokens' "$ROUTING_FILE")

  read -r zai_t zai_r <<< "$(get_usage_by_provider zai)"
  read -r codex_t codex_r <<< "$(get_usage_by_provider codex)"
  read -r total_t total_r <<< "$(get_usage)"

  local pct=0
  [[ $daily_tokens -gt 0 ]] && pct=$(( total_t * 100 / daily_tokens ))

  local zai_enabled
  zai_enabled=$(jq -r '.accounts.pools.zai.accounts | map(select(.enabled == true)) | length' "$ROUTING_FILE")

  printf "🦞 ${B}%s${R} | zai:%sK/%s acct | " "$plan_upper" "$((zai_t/1000))" "$zai_enabled"
  if [[ "$CODEX" == "true" ]]; then
    printf "codex:%sK/%sr | " "$((codex_t/1000))" "$codex_r"
  else
    printf "codex:off | "
  fi
  printf "total:%d%% %sr" "$pct" "$total_r"
  echo ""
}

# ──────────────────────────────────────────────
# 풀 대시보드
# ──────────────────────────────────────────────
full_hud() {
  echo ""
  printf "  ${B}🦞 ohmyclaw HUD${R}  $(date '+%Y-%m-%d %H:%M')\n"
  echo "  ─────────────────────────────────────────"
  echo ""
  section_plan
  echo ""
  echo "  ─────────────────────────────────────────"
  printf "  ${B}Accounts${R}\n"
  section_accounts
  echo ""
  echo "  ─────────────────────────────────────────"
  section_models
  echo ""
  echo "  ─────────────────────────────────────────"
  printf "  ${B}Routing${R} (active plan: ${PLAN}${CODEX:+ +codex})\n"
  section_routing
  echo ""
  echo "  ─────────────────────────────────────────"
  echo ""
}

# ──────────────────────────────────────────────
# 디스패치
# ──────────────────────────────────────────────
case "${1:-}" in
  --compact)   compact ;;
  --accounts)  section_accounts ;;
  --quota)     section_plan ;;
  --routing)   section_routing ;;
  --models)    section_models ;;
  log-usage)   shift; log_usage "${1:-0}" "${2:-1}" "${3:-zai}" ;;
  *)           full_hud ;;
esac
