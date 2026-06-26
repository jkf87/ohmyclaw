#!/usr/bin/env bash
# ohmyclaw → Telegram setMyCommands 재등록 (self-heal)
#
# openclaw 게이트웨이는 시작 시 deleteMyCommands+setMyCommands 로 자기 명령을 재설정하여
# ohmyclaw 의 omc_* 슬래시 명령을 덮어쓴다. 이 스크립트는 활성 텔레그램 봇마다 현재 명령을
# 읽어 기존 명령을 보존-병합한 뒤 omc_* 8개를 다시 등록한다(idempotent).
# launchd(com.ohmyclaw.register-commands)가 로드 시 + 주기(StartInterval)로 실행 → 재시작 후 자동 복구.
#
# 토큰은 로그/표준출력에 절대 노출하지 않는다.
#
# Env overrides:
#   OPENCLAW_JSON   봇 토큰 소스 (기본 ~/.openclaw/openclaw.json)
#   OHMYCLAW_CLI    ohmyclaw cli.sh 경로 (기본 ~/.openclaw/skills/ohmyclaw/cli.sh)
#   OHMYCLAW_REGISTER_LOG  로그 파일 (기본 ~/.openclaw/logs/ohmyclaw-register-commands.log)
#   TELEGRAM_API_BASE      기본 https://api.telegram.org (테스트 시 모킹)
set -uo pipefail
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"

OPENCLAW_JSON="${OPENCLAW_JSON:-$HOME/.openclaw/openclaw.json}"
CLI="${OHMYCLAW_CLI:-$HOME/.openclaw/skills/ohmyclaw/cli.sh}"
LOG="${OHMYCLAW_REGISTER_LOG:-$HOME/.openclaw/logs/ohmyclaw-register-commands.log}"
API="${TELEGRAM_API_BASE:-https://api.telegram.org}"

mkdir -p "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

command -v jq   >/dev/null 2>&1 || { log "ERROR: jq not found"; exit 1; }
command -v curl >/dev/null 2>&1 || { log "ERROR: curl not found"; exit 1; }
[ -f "$OPENCLAW_JSON" ] || { log "ERROR: openclaw.json not found: $OPENCLAW_JSON"; exit 1; }
[ -x "$CLI" ] || [ -f "$CLI" ] || { log "ERROR: ohmyclaw cli not found: $CLI"; exit 1; }

# ohmyclaw 명령 목록(단일 소스) — [{command,description}] x N
OMC=$(OHMYCLAW_HOME="$(mktemp -d)" bash "$CLI" commands json 2>/dev/null)
if ! echo "$OMC" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
  log "ERROR: could not read ohmyclaw commands json"; exit 1
fi
OMC_NAMES=$(echo "$OMC" | jq -r '[.[].command]')

# 활성화된 텔레그램 봇 계정 전부 순회
BOTS=$(jq -r '.channels.telegram.accounts // {} | to_entries[]
  | select((.value.enabled // true) and ((.value.botToken // "")|length>10)) | .key' "$OPENCLAW_JSON")
[ -n "$BOTS" ] || { log "WARN: no enabled telegram bot accounts"; exit 0; }

changed=0 checked=0
while IFS= read -r bot; do
  [ -n "$bot" ] || continue
  checked=$((checked+1))
  TOK=$(jq -r --arg b "$bot" '.channels.telegram.accounts[$b].botToken' "$OPENCLAW_JSON")
  [ -n "$TOK" ] && [ "$TOK" != "null" ] || { log "skip $bot: no token"; continue; }

  CUR=$(curl -s --max-time 15 "$API/bot${TOK}/getMyCommands")
  echo "$CUR" | jq -e '.ok==true' >/dev/null 2>&1 || { log "skip $bot: getMyCommands failed"; continue; }
  EXIST=$(echo "$CUR" | jq '.result // []')

  # read staleness 대비: getMyCommands 결과로 no-op 판단하지 않고 항상 merge+set.
  # 병합 = (omc 와 충돌하지 않는 기존 명령) + omc 전체 → 읽기가 stale 든 fresh 든 결과는
  # 동일하게 openclaw 명령 보존 + omc_* 포함. omc_* 누락 여부는 로그용으로만 계산.
  MISSING=$(jq -n --argjson e "$EXIST" --argjson n "$OMC_NAMES" \
    '[ $n[] | select( ([$e[].command] | index(.)) | not ) ] | length')
  MERGED=$(jq -n --argjson e "$EXIST" --argjson o "$OMC" \
    '($o|map(.command)) as $n | ($e|map(select((.command as $c|$n|index($c))|not))) + $o')
  BODY=$(jq -n --argjson c "$MERGED" '{commands:$c}')
  RES=$(curl -s --max-time 15 -X POST "$API/bot${TOK}/setMyCommands" \
        -H 'Content-Type: application/json' -d "$BODY")
  if echo "$RES" | jq -e '.ok==true' >/dev/null 2>&1; then
    CNT=$(echo "$MERGED" | jq 'length')
    if [ "$MISSING" = "0" ]; then
      log "ok $bot: re-asserted $CNT commands (omc_* already present)"
    else
      log "healed $bot: +$MISSING ohmyclaw commands → $CNT total"
      changed=$((changed+1))
    fi
  else
    log "ERROR $bot: setMyCommands failed: $(echo "$RES" | jq -r '.description // "unknown"')"
  fi
done <<< "$BOTS"

log "done: checked=$checked changed=$changed"
