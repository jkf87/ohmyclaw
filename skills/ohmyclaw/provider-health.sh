#!/usr/bin/env bash
# ohmyclaw skill — provider auth-health gate (openclaw `models status` aware)
#
# openclaw 게이트웨이의 provider별 OAuth 로그인 만료를 사전 감지하여, 만료된
# provider(openai/zai/claude-cli/openrouter) 로의 라우팅을 차단한다.
#
# rate-limit cooldown(pool.sh — 일시적, 지수 백오프, 600s cap)과 달리
# auth-expiry 는 반영구적(재로그인 필요) 상태이므로 별도 격리(quarantine)로 다룬다.
# 격리는 재로그인이 감지될 때(라이브 status=ok/static)까지 유지되며 자동 해제된다.
#
# 왜 필요한가:
#   모델 트래픽은 acpx/omp → openclaw 게이트웨이로 가고, 게이트웨이가 자체 전역
#   provider auth 로 실행한다. openai 로그인이 만료되면 게이트웨이는 스스로
#   zai/glm 으로 폴백하며 exit 0(성공) 을 리턴한다 → ohmyclaw 는 실패를 인지하지
#   못해 라운드로빈이 만료 provider 를 계속 되돌려주고 경고가 무한 반복된다.
#   이 스크립트는 `openclaw models status --json` 의 provider별 status 를 근거로
#   만료 provider 를 폴백 체인에서 사전에 건너뛰게 한다.
#
# Usage:
#   provider-health.sh refresh [--force]         # openclaw models status --json 폴링 → 캐시 갱신
#   provider-health.sh status [--json]           # provider→status 요약
#   provider-health.sh check <model|provider>    # exit 0 정상 / 1 만료·격리
#   provider-health.sh first-healthy <csv-chain> # 폴백 체인에서 첫 정상 모델 (전부 불량 시 헤드 유지)
#   provider-health.sh why <model|provider>      # 차단 사유 텍스트 (예: openai=quarantined(auth_permanent))
#   provider-health.sh provider-of <model>       # 모델 프리픽스 → openclaw provider 이름
#   provider-health.sh quarantine <provider> [reason]  # 격리(재로그인까지)
#   provider-health.sh release <provider>        # 격리 해제
#   provider-health.sh is-quarantined <provider> # exit 0 격리중 / 1 아님 (순수 파일 read, 라이브 폴링 없음)
#   provider-health.sh scan-stderr [file]        # stdin/파일에서 만료 시그니처 감지 → 자동 격리
#
# State: ${OHMYCLAW_STATE_DIR:-~/.cache/ohmyclaw}/provider-health.json
#
# Env:
#   OHMYCLAW_PROVIDER_HEALTH=true|false   전체 on/off (기본 true)
#   OHMYCLAW_PH_TTL=<sec>                 라이브 status 캐시 TTL (기본 45)
#   OHMYCLAW_PH_NOTICE_WINDOW=<sec>       재로그인 안내 dedup 창 (기본 3600)
#   OHMYCLAW_PH_STATUS_CMD=<cmd>          테스트용 openclaw status override (JSON 을 stdout 으로)
#   OHMYCLAW_STATE_DIR                    캐시 위치 (기본 ~/.cache/ohmyclaw)

set -euo pipefail

STATE_DIR="${OHMYCLAW_STATE_DIR:-$HOME/.cache/ohmyclaw}"
STATE_FILE="${STATE_DIR}/provider-health.json"
_LOCKD="${STATE_FILE}.lockdir"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required (brew install jq)" >&2
  exit 2
fi

now() { date +%s; }
_ttl() { echo "${OHMYCLAW_PH_TTL:-45}"; }
_notice_window() { echo "${OHMYCLAW_PH_NOTICE_WINDOW:-3600}"; }

# ──────────────────────────────────────────────
# 모델 프리픽스 → openclaw provider 이름
#   openclaw `models status` 의 provider 명칭 기준 (routing.json 의 providerId 와
#   다름에 주의: codex 풀의 providerId 는 "openai-codex" 이지만 게이트웨이 provider 는 "openai")
# ──────────────────────────────────────────────
provider_of_model() {
  case "$1" in
    gpt-*)         echo "openai" ;;
    glm-*)         echo "zai" ;;
    claude-code-*) echo "claude-cli" ;;
    openrouter-*)  echo "openrouter" ;;
    openai|zai|claude-cli|openrouter) echo "$1" ;;  # 이미 provider 이름
    *)             echo "" ;;                        # 미상 → 게이팅 안 함(정상 취급)
  esac
}

# pool 이름/별칭 → provider 정규화
_normalize() {
  case "$1" in
    codex)     echo "openai" ;;
    claudecli) echo "claude-cli" ;;
    *)         echo "$1" ;;
  esac
}

# ──────────────────────────────────────────────
# state I/O
# ──────────────────────────────────────────────
_ensure_state() {
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
}
_lock()   { local n=0; while ! mkdir "$_LOCKD" 2>/dev/null; do sleep 0.02; n=$((n+1)); ((n>250)) && break; done; }
_unlock() { rmdir "$_LOCKD" 2>/dev/null || true; }
_write() {
  local filter="$1"; shift
  _ensure_state
  _lock
  if jq "$@" "$filter" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null; then
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
  else
    rm -f "${STATE_FILE}.tmp"
  fi
  _unlock
}

# provider 의 라이브 status (없으면 unknown)
_live_status() {
  [[ -f "$STATE_FILE" ]] || { echo "unknown"; return; }
  jq -r --arg p "$1" '.live[$p] // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown"
}
# provider 격리 사유 (없으면 빈 문자열)
_quarantine_reason() {
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  jq -r --arg p "$1" '.quarantine[$p].reason // empty' "$STATE_FILE" 2>/dev/null || echo ""
}

# provider 가 사용 불가(만료/누락/격리)인가?
_is_unhealthy() {
  local p="$1"
  [[ -n "$(_quarantine_reason "$p")" ]] && return 0
  case "$(_live_status "$p")" in
    expired|missing) return 0 ;;
    *)               return 1 ;;
  esac
}

# ──────────────────────────────────────────────
# 라이브 status 폴링 (TTL 게이트)
#   openclaw 부재 / 실패 시 무해하게 no-op (격리 정보만 유지)
# ──────────────────────────────────────────────
_refresh_if_stale() {
  [[ "${OHMYCLAW_PROVIDER_HEALTH:-true}" != "true" ]] && return 0
  local cmd="${OHMYCLAW_PH_STATUS_CMD:-}"
  if [[ -z "$cmd" ]] && ! command -v openclaw >/dev/null 2>&1; then
    return 0   # openclaw 부재 → 라이브 갱신 불가. 명시 격리만 반영.
  fi
  _ensure_state
  local now_t polled ttl
  now_t=$(now); ttl=$(_ttl)
  polled=$(jq -r '.polledAt // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  (( now_t - polled < ttl )) && return 0

  local raw
  if [[ -n "$cmd" ]]; then raw=$(eval "$cmd" 2>/dev/null || echo "")
  else raw=$(openclaw models status --json 2>/dev/null || echo ""); fi

  if [[ -z "$raw" ]] || ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    _write '.polledAt = ($now|tonumber)' --arg now "$now_t"   # 과도 호출 방지
    return 0
  fi

  local live
  live=$(printf '%s' "$raw" | jq -c '
      ((.auth.oauth.providers // []) | map({key:.provider, value:.status}) | from_entries)
    * ((.auth.unusableProfiles // [])
        | map(select(((.reason // "")=="auth_permanent") or ((.kind // "")=="disabled"))
              | {key:.provider, value:"expired"}) | from_entries)
  ' 2>/dev/null || echo '{}')

  # reconcile: 라이브가 ok/static 인 provider 는 격리 자동 해제(재로그인 감지)
  _write '
      .polledAt = ($now|tonumber)
    | .live = $live
    | .quarantine = ( (.quarantine // {})
        | with_entries( select( ($live[.key] // "unknown") as $s
              | ($s != "ok" and $s != "static") ) ) )
  ' --arg now "$now_t" --argjson live "$live"
}

# ──────────────────────────────────────────────
# 재로그인 안내 (dedup — provider당 창 내 1회)
# ──────────────────────────────────────────────
_maybe_notice() {
  local provider="$1" from="$2" to="$3" now_t last win
  [[ -z "$provider" ]] && return 0
  now_t=$(now); win=$(_notice_window)
  last=$(jq -r --arg p "$provider" '.notified[$p] // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  if (( now_t - last >= win )); then
    echo "⚠️  provider '${provider}' 로그인 만료 — '${from}' → '${to}' 로 강등했습니다." >&2
    echo "    복구: openclaw models auth login --provider ${provider} --force" >&2
    _write '.notified[$p] = ($now|tonumber)' --arg p "$provider" --arg now "$now_t"
  fi
}

# ──────────────────────────────────────────────
# actions
# ──────────────────────────────────────────────
action_refresh() {
  [[ "${1:-}" == "--force" ]] && _write '.polledAt = 0'
  _refresh_if_stale
}

action_status() {
  _ensure_state
  _refresh_if_stale
  if [[ "${1:-}" == "--json" ]]; then cat "$STATE_FILE"; return; fi
  echo "── provider health ──"
  jq -r '(.live // {}) | to_entries[] | "  \(.key): \(.value)"' "$STATE_FILE" 2>/dev/null || true
  local qn; qn=$(jq -r '(.quarantine // {}) | length' "$STATE_FILE" 2>/dev/null || echo 0)
  if [[ "$qn" != "0" ]]; then
    echo "── quarantined (재로그인 필요) ──"
    jq -r '(.quarantine // {}) | to_entries[] | "  \(.key): \(.value.reason)  → openclaw models auth login --provider \(.key) --force"' "$STATE_FILE" 2>/dev/null || true
  fi
}

action_check() {
  local arg="${1:?Usage: check <model|provider>}"
  local p; p=$(provider_of_model "$arg"); [[ -z "$p" ]] && exit 0   # 미상 → 정상
  _refresh_if_stale
  _is_unhealthy "$p" && exit 1 || exit 0
}

action_why() {
  local arg="${1:?Usage: why <model|provider>}"
  local p; p=$(provider_of_model "$arg"); [[ -z "$p" ]] && p=$(_normalize "$arg")
  local r; r=$(_quarantine_reason "$p")
  if [[ -n "$r" ]]; then echo "${p}=quarantined(${r})"; return; fi
  echo "${p}=$(_live_status "$p")"
}

action_first_healthy() {
  local chain="${1:-}"
  [[ -z "$chain" ]] && return 0
  _refresh_if_stale
  local first="" chosen="" model provider
  local IFS=,
  for model in $chain; do
    [[ -z "$model" ]] && continue
    [[ -z "$first" ]] && first="$model"
    provider=$(provider_of_model "$model")
    if [[ -z "$provider" ]] || ! _is_unhealthy "$provider"; then
      chosen="$model"; break
    fi
  done
  if [[ -z "$chosen" ]]; then echo "$first"; return 0; fi   # 전부 불량 → 헤드 유지(악화 방지)
  if [[ "$chosen" != "$first" ]]; then
    _maybe_notice "$(provider_of_model "$first")" "$first" "$chosen"
  fi
  echo "$chosen"
}

action_quarantine() {
  local p; p=$(_normalize "${1:?Usage: quarantine <provider> [reason]}")
  local reason="${2:-auth_expired}"
  _write '.quarantine[$p] = {reason:$r, since:($now|tonumber), source:"marked"}' \
    --arg p "$p" --arg r "$reason" --arg now "$(now)"
  echo "[provider-health] quarantined '${p}' (${reason}) — 재로그인까지 유지." >&2
  echo "    복구: openclaw models auth login --provider ${p} --force  (그 후 자동 해제)" >&2
}

action_release() {
  local p; p=$(_normalize "${1:?Usage: release <provider>}")
  _write 'del(.quarantine[$p]) | del(.notified[$p])' --arg p "$p"
  echo "[provider-health] released '${p}'" >&2
}

action_is_quarantined() {
  local p; p=$(_normalize "${1:?Usage: is-quarantined <provider>}")
  [[ -n "$(_quarantine_reason "$p")" ]]
}

# stdin/파일에서 openclaw 만료 시그니처를 감지해 해당 provider 를 격리.
# 게이트웨이는 만료 시 폴백 후 exit 0 을 리턴하므로 exit code 로는 감지 불가 →
# stderr 텍스트 패턴매칭이 유일한 반응형 신호다.
action_scan_stderr() {
  local src="${1:-}" text provider=""
  if [[ -n "$src" && -f "$src" ]]; then text=$(cat "$src"); else text=$(cat); fi

  # "Model login expired on the gateway for <provider>."
  #   (grep 무매치 시 pipefail 로 인한 조기 종료 방지 위해 각 파이프라인에 || true)
  provider=$(printf '%s' "$text" \
    | grep -oiE "login expired on the gateway for [a-z0-9_-]+" | head -1 \
    | sed -E 's/.*[Ff]or //' | tr -cd 'a-zA-Z0-9_-' || true)
  # "openclaw models auth login --provider '<provider>'"
  if [[ -z "$provider" ]]; then
    provider=$(printf '%s' "$text" \
      | grep -oiE "models auth login --provider '?[a-z0-9_-]+" | head -1 \
      | sed -E "s/.*--provider '?//" | tr -cd 'a-zA-Z0-9_-' || true)
  fi
  # "Model Fallback: ... (selected <provider>/<model>; auth permanent ...)"
  if [[ -z "$provider" ]] && printf '%s' "$text" | grep -qiE "auth[ _]permanent"; then
    provider=$(printf '%s' "$text" \
      | grep -oiE "selected [a-z0-9_-]+/" | head -1 \
      | sed -E 's/[Ss]elected //; s#/##' | tr -cd 'a-zA-Z0-9_-' || true)
  fi

  [[ -z "$provider" ]] && return 1   # 시그니처 없음
  action_quarantine "$provider" "auth_permanent(reactive)"
  return 0
}

# ──────────────────────────────────────────────
# dispatch
# ──────────────────────────────────────────────
case "${1:-}" in
  refresh)         shift; action_refresh "${1:-}" ;;
  status)          shift; action_status "${1:-}" ;;
  check)           shift; action_check "${1:-}" ;;
  why)             shift; action_why "${1:-}" ;;
  first-healthy)   shift; action_first_healthy "${1:-}" ;;
  provider-of)     shift; provider_of_model "${1:-}" ;;
  quarantine)      shift; action_quarantine "$@" ;;
  release)         shift; action_release "${1:-}" ;;
  is-quarantined)  shift; action_is_quarantined "${1:-}" ;;
  scan-stderr)     shift; action_scan_stderr "${1:-}" ;;
  *)
    cat <<EOF >&2
Usage: $0 <action> [args...]

  refresh [--force]          openclaw models status --json 폴링 → 캐시 갱신
  status [--json]            provider→status 요약
  check <model|provider>     exit 0 정상 / 1 만료·격리
  first-healthy <csv-chain>  폴백 체인에서 첫 정상 모델 (전부 불량 시 헤드 유지)
  why <model|provider>       차단 사유 텍스트
  provider-of <model>        모델 프리픽스 → openclaw provider 이름
  quarantine <provider> [r]  격리(재로그인까지, 라이브 status=ok 시 자동 해제)
  release <provider>         격리 해제
  is-quarantined <provider>  exit 0 격리중 / 1 아님 (순수 read)
  scan-stderr [file]         stderr 에서 만료 시그니처 감지 → 자동 격리

Env: OHMYCLAW_PROVIDER_HEALTH, OHMYCLAW_PH_TTL, OHMYCLAW_PH_NOTICE_WINDOW,
     OHMYCLAW_PH_STATUS_CMD, OHMYCLAW_STATE_DIR
EOF
    exit 1
    ;;
esac
