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
#   ZAI_CODING_PLAN, CODEX_OAUTH_ENABLED, OPENROUTER_ENABLED,
#   ZAI_API_KEY, OPENROUTER_API_KEY, OHMYCLAW_STATE_DIR

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
OPENROUTER="${OPENROUTER_ENABLED:-false}"

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
all_pools() { jq -r '.accounts.pools | keys[]' "$ROUTING_FILE"; }

# ──────────────────────────────────────────────
# 사용량 추적 (provider 별 일일 카운터)
# schema: {"date":"2026-04-10","providers":{"zai":{"tokens":0,"requests":0}},"total":{"tokens":0,"requests":0}}
# ──────────────────────────────────────────────
init_usage() {
  local providers_json='{}'
  while read -r pool; do
    [[ -z "$pool" ]] && continue
    providers_json=$(jq -c --arg p "$pool" '. + {($p): {tokens: 0, requests: 0}}' <<< "$providers_json")
  done < <(all_pools)

  jq -n \
    --arg d "$(today)" \
    --argjson providers "$providers_json" \
    '{date:$d, providers:$providers, total:{tokens:0, requests:0}}' > "$USAGE_FILE"
}

ensure_usage() {
  local d
  d=$(jq -r '.date // ""' "$USAGE_FILE" 2>/dev/null || echo "")
  if [[ "$d" != "$(today)" ]]; then
    init_usage
  fi

  if jq -e '.providers' "$USAGE_FILE" >/dev/null 2>&1; then
    while read -r pool; do
      [[ -z "$pool" ]] && continue
      if ! jq -e --arg p "$pool" '.providers[$p]' "$USAGE_FILE" >/dev/null 2>&1; then
        jq --arg p "$pool" '.providers[$p] = {tokens:0, requests:0}' "$USAGE_FILE" > "${USAGE_FILE}.tmp" && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
      fi
    done < <(all_pools)
    return
  fi

  # 마이그레이션: 옛날 flat/provider-top-level 스키마 → providers 맵
  local old_t old_r
  old_t=$(jq -r '.tokens // .total.tokens // 0' "$USAGE_FILE" 2>/dev/null)
  old_r=$(jq -r '.requests // .total.requests // 0' "$USAGE_FILE" 2>/dev/null)
  init_usage
  jq --argjson t "$old_t" --argjson r "$old_r" \
    '.providers.zai.tokens = $t | .providers.zai.requests = $r | .total.tokens = $t | .total.requests = $r' \
    "$USAGE_FILE" > "${USAGE_FILE}.tmp" && mv "${USAGE_FILE}.tmp" "$USAGE_FILE"
}

get_usage() {
  ensure_usage
  jq -r '"\(.total.tokens) \(.total.requests)"' "$USAGE_FILE"
}

get_usage_by_provider() {
  local provider="$1"
  ensure_usage
  jq -r --arg p "$provider" '"\(.providers[$p].tokens // 0) \(.providers[$p].requests // 0)"' "$USAGE_FILE"
}

# 외부에서 호출: hud.sh log-usage <tokens> <requests> [provider]
log_usage() {
  local tokens="${1:-0}" requests="${2:-1}" provider="${3:-zai}"
  ensure_usage
  jq --argjson t "$tokens" --argjson r "$requests" --arg p "$provider" \
    '.providers[$p].tokens += $t | .providers[$p].requests += $r | .total.tokens += $t | .total.requests += $r' \
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

  ensure_usage
  local codex_req_limit=1500
  local openrouter_req_limit="∞"

  printf "  ${DIM}%-10s %10s %10s${R}\n" "provider" "tokens" "requests"
  printf "  ${DIM}%-10s %10s %10s${R}\n" "──────────" "──────" "────────"

  while read -r pool; do
    [[ -z "$pool" ]] && continue
    read -r pt pr <<< "$(get_usage_by_provider "$pool")"

    if [[ "$pool" == "zai" ]]; then
      local t_pct=0 r_pct=0
      [[ $daily_tokens -gt 0 ]] && t_pct=$(( pt * 100 / daily_tokens ))
      [[ $daily_requests -gt 0 ]] && r_pct=$(( pr * 100 / daily_requests ))
      [[ $t_pct -gt 100 ]] && t_pct=100
      [[ $r_pct -gt 100 ]] && r_pct=100
      printf "  ${GREEN}%-10s${R} %7sK / %sM  " "$pool" "$((pt / 1000))" "$((daily_tokens / 1000000))"
      bar $t_pct
      printf "  %5s / %s  " "$pr" "$daily_requests"
      bar $r_pct
      echo ""
    elif [[ "$pool" == "codex" ]]; then
      if [[ "$CODEX" == "true" ]]; then
        local r_pct=0
        [[ $codex_req_limit -gt 0 ]] && r_pct=$(( pr * 100 / codex_req_limit ))
        [[ $r_pct -gt 100 ]] && r_pct=100
        printf "  ${CYAN}%-10s${R} %7sK / ${DIM}∞${R}      " "$pool" "$((pt / 1000))"
        printf "${DIM}(sub)${R}"
        printf "  %5s / %s  " "$pr" "$codex_req_limit"
        bar $r_pct
        echo ""
      else
        printf "  ${DIM}%-10s${R} ${DIM}(disabled)${R}\n" "$pool"
      fi
    elif [[ "$pool" == "openrouter" ]]; then
      if [[ "$OPENROUTER" == "true" ]]; then
        printf "  ${MAGENTA}%-10s${R} %7sK / ${DIM}∞${R}      " "$pool" "$((pt / 1000))"
        printf "${DIM}(api)${R}"
        printf "  %5s / %s\n" "$pr" "$openrouter_req_limit"
      else
        printf "  ${DIM}%-10s${R} ${DIM}(disabled)${R}\n" "$pool"
      fi
    else
      printf "  %-10s %7sK / ${DIM}?${R}      %5s / ?\n" "$pool" "$((pt / 1000))" "$pr"
    fi
  done < <(all_pools)

  read -r total_t total_r <<< "$(get_usage)"
  local total_t_pct=0
  [[ $daily_tokens -gt 0 ]] && total_t_pct=$(( total_t * 100 / daily_tokens ))
  [[ $total_t_pct -gt 100 ]] && total_t_pct=100
  printf "  ${B}%-10s${R} %7sK / %sM  " "total" "$((total_t / 1000))" "$((daily_tokens / 1000000))"
  bar $total_t_pct
  echo ""
}

# ──────────────────────────────────────────────
# 섹션: 계정
# ──────────────────────────────────────────────
section_accounts() {
  local now_t
  now_t=$(now_epoch)

  while read -r pool; do
    [[ -z "$pool" ]] && continue

    if [[ "$pool" == "codex" && "$CODEX" != "true" ]]; then
      printf "  ${DIM}%-10s${R}  ${DIM}(disabled)${R}\n" "$pool"
      continue
    fi
    if [[ "$pool" == "openrouter" && "$OPENROUTER" != "true" ]]; then
      printf "  ${DIM}%-10s${R}  ${DIM}(disabled)${R}\n" "$pool"
      continue
    fi

    printf "  ${B}%-10s${R}  " "$pool"

    local accounts
    accounts=$(jq -r --arg p "$pool" '
      .accounts.pools[$p].accounts[]
      | "\(.id)|\(.enabled)|\(.authType)|\(.plan // "any")"
    ' "$ROUTING_FILE" 2>/dev/null)

    local first=true
    while IFS='|' read -r id enabled auth_type acct_plan; do
      [[ -z "$id" ]] && continue
      [[ "$first" != "true" ]] && printf "            "
      first=false

      local status_icon="${GREEN}●${R}"
      if [[ "$enabled" != "true" ]]; then
        status_icon="${DIM}○${R}"
      else
        local cu
        cu=$(jq -r --arg p "$pool" --arg id "$id" '.[$p][$id].cooldownUntil // 0' "$STATE_FILE" 2>/dev/null || echo 0)
        if [[ $(echo "$cu" | tr -d '.') -gt $now_t ]]; then
          local remain=$(( ${cu%.*} - now_t ))
          status_icon="${RED}◉${R} ${DIM}(${remain}s)${R}"
        fi
      fi

      printf "%s %-18s ${DIM}%s${R} ${DIM}plan=%s${R}\n" "$status_icon" "$id" "$auth_type" "$acct_plan"
    done <<< "$accounts"
  done < <(all_pools)
}

# ──────────────────────────────────────────────
# 섹션: 모델
# ──────────────────────────────────────────────
section_models() {
  local allowed blocked extras=""
  allowed=$(jq -r --arg p "$PLAN" '.plans[$p].allowedModels | join(", ")' "$ROUTING_FILE")
  blocked=$(jq -r --arg p "$PLAN" '(.plans[$p].blockedModels // []) | if length == 0 then "(none)" else join(", ") end' "$ROUTING_FILE")

  [[ "$CODEX" == "true" ]] && extras="${extras}, gpt-5.5, gpt-5.4"
  if [[ "$OPENROUTER" == "true" ]]; then
    local or_models
    or_models=$(jq -r '[.models | to_entries[] | select(.value.plans | index("openrouter")) | .key] | join(", ")' "$ROUTING_FILE")
    [[ -n "$or_models" ]] && extras="${extras}, ${or_models}"
  fi
  extras=$(echo "$extras" | sed 's/^, //')

  printf "  ${B}Models${R}   ${GREEN}%s${R}" "$allowed"
  [[ -n "$extras" ]] && printf ", ${MAGENTA}%s${R}" "$extras"
  echo ""
  if [[ "$blocked" != "(none)" ]]; then
    printf "  ${DIM}Blocked${R}  ${RED}%s${R}\n" "$blocked"
  fi
}


# ──────────────────────────────────────────────
# 섹션: 라우팅 요약
# ──────────────────────────────────────────────
section_routing() {
  local args=()
  [[ "$CODEX" == "true" ]] && args+=(--codex)
  [[ "$OPENROUTER" == "true" ]] && args+=(--openrouter)
  [[ "${OPENROUTER_PREFER_FREE:-false}" == "true" ]] && args+=(--openrouter-prefer-free)

  printf "  ${DIM}HIGH coding_arch${R}  → "
  ZAI_CODING_PLAN=$PLAN $SCRIPT_DIR/select-model.sh "architecture task with migration refactoring 아키텍처 마이그레이션 리팩토링 설계" coding_arch "${args[@]}" 2>/dev/null
  printf "  ${DIM}HIGH reasoning${R}    → "
  ZAI_CODING_PLAN=$PLAN $SCRIPT_DIR/select-model.sh "prove algorithm invariant 증명 알고리즘 불변" reasoning "${args[@]}" 2>/dev/null
  printf "  ${DIM}LOW general${R}       → "
  ZAI_CODING_PLAN=$PLAN $SCRIPT_DIR/select-model.sh "add type" coding_general "${args[@]}" 2>/dev/null
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
  read -r openrouter_t openrouter_r <<< "$(get_usage_by_provider openrouter)"
  read -r total_t total_r <<< "$(get_usage)"

  local pct=0
  [[ $daily_tokens -gt 0 ]] && pct=$(( total_t * 100 / daily_tokens ))

  local zai_enabled openrouter_enabled
  zai_enabled=$(jq -r '.accounts.pools.zai.accounts | map(select(.enabled == true)) | length' "$ROUTING_FILE")
  openrouter_enabled=$(jq -r '.accounts.pools.openrouter.accounts | map(select(.enabled == true)) | length' "$ROUTING_FILE" 2>/dev/null || echo 0)

  printf "🦞 ${B}%s${R} | zai:%sK/%s acct | " "$plan_upper" "$((zai_t/1000))" "$zai_enabled"
  if [[ "$CODEX" == "true" ]]; then
    printf "codex:%sK/%sr | " "$((codex_t/1000))" "$codex_r"
  else
    printf "codex:off | "
  fi
  if [[ "$OPENROUTER" == "true" ]]; then
    printf "or:%sK/%s acct | " "$((openrouter_t/1000))" "$openrouter_enabled"
  else
    printf "or:off | "
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
  local active_flags="${PLAN}"
  [[ "$CODEX" == "true" ]] && active_flags+=" +codex"
  [[ "$OPENROUTER" == "true" ]] && active_flags+=" +openrouter"
  printf "  ${B}Routing${R} (active plan: ${active_flags})\n"
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
