#!/usr/bin/env bash
# ohmyclaw → openclaw auth-order health sync (self-heal, 멀티계정 자동 라우팅)
#
# provider(openai 등) 안에 auth 프로파일이 여러 개일 때, openclaw 는 order override
# 가 없으면 라운드로빈으로 번갈아 쓴다 → 만료된 프로파일에 걸려 "Model login expired"
# 경고가 반복된다. 이 스크립트는 provider-health.sh sync-auth-order 를 주기적으로
# 실행하여, 프로파일별 라이브 health 를 보고 openclaw `models auth order` 를 동적으로
# 조정한다(정상만 사용, 만료 제외, 회복 시 라운드로빈 복귀).
#
# launchd(com.ohmyclaw.auth-order-sync)가 로드 시 + 주기적으로 실행.
# 토큰/크레덴셜은 로그에 절대 노출하지 않는다(profileId 만 기록).
set -uo pipefail
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:${HOME}/.local/bin:${PATH:-}"

SKILL_DIR="${OHMYCLAW_SKILL_DIR:-$HOME/.openclaw/skills/ohmyclaw}"
PH="${SKILL_DIR}/provider-health.sh"
LOG="${OHMYCLAW_AUTH_ORDER_LOG:-$HOME/.openclaw/logs/ohmyclaw-auth-order-sync.log}"

mkdir -p "$(dirname "$LOG")"
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

command -v openclaw >/dev/null 2>&1 || { echo "$(ts) ERROR: openclaw not on PATH" >> "$LOG"; exit 1; }
command -v jq       >/dev/null 2>&1 || { echo "$(ts) ERROR: jq not found" >> "$LOG"; exit 1; }
[ -x "$PH" ] || { echo "$(ts) ERROR: provider-health.sh not found/executable: $PH" >> "$LOG"; exit 1; }

{
  echo "── $(ts) auth-order-sync ──"
  "$PH" sync-auth-order --apply 2>&1
} >> "$LOG" 2>&1

# 로그 회전(간단): 2000줄 초과 시 마지막 1000줄만 유지
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d ' ')" -gt 2000 ]; then
  tail -1000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
