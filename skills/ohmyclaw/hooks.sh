#!/usr/bin/env bash
# ohmyclaw skill — pre/post hook dispatcher
#
# 사용자가 ${OHMYCLAW_HOME:-~/.ohmyclaw}/hooks/{pre,post}-<action>.sh 를 두면
# cli.sh 의 각 verb 진입/종료 시 자동 실행. 사용자 확장 진입점.
#
# Usage:
#   hooks.sh fire <phase> <action> [args...]
#     phase = pre | post
#     action = doctor/route/pool/engine/exec/plan/team/ralph/review/debug/cancel/...
#
# 동작:
#   - ${OHMYCLAW_HOME}/hooks/<phase>-<action>.sh 가 존재 + executable 이면 실행
#   - env export: OHMYCLAW_ACTION, OHMYCLAW_SESSION, OHMYCLAW_HOME,
#                 OHMYCLAW_PHASE, OHMYCLAW_ARGS (\0-구분), OHMYCLAW_ARGS_JSON
#
# 정책:
#   - pre 훅 실패: exit 7 — 호출자(cli.sh)가 이 코드를 감지해 action 을 abort 해야 함
#   - post 훅 실패: 경고만 출력하고 exit 0 (파이프라인 비차단)
#
# 부재 시: 무동작, exit 0 (fast path)

set -euo pipefail

OHMYCLAW_HOME="${OHMYCLAW_HOME:-$HOME/.ohmyclaw}"

cmd_fire() {
  local phase="${1:-}"; local action="${2:-}"; shift 2 || true
  if [[ -z "$phase" || -z "$action" ]]; then
    echo "Usage: hooks.sh fire <pre|post> <action> [args...]" >&2
    return 2
  fi
  case "$phase" in
    pre|post) ;;
    *) echo "ERROR: phase must be 'pre' or 'post' (got: $phase)" >&2; return 2 ;;
  esac

  local hook_file="$OHMYCLAW_HOME/hooks/${phase}-${action}.sh"
  if [[ ! -x "$hook_file" ]]; then
    # 부재 또는 미실행권한 — 빠른 무동작 경로
    return 0
  fi

  # env export — 훅이 사용할 컨텍스트
  export OHMYCLAW_ACTION="$action"
  export OHMYCLAW_PHASE="$phase"
  export OHMYCLAW_HOME
  export OHMYCLAW_SESSION="${OHMYCLAW_SESSION_ID:-}"
  # 인자: \0-구분 (공백 보존)
  local ARGS_NUL=""
  local a
  for a in "$@"; do
    ARGS_NUL+="$a"$'\0'
  done
  export OHMYCLAW_ARGS="$ARGS_NUL"
  # JSON 배열 (jq 가 있으면 정밀하게, 없으면 빈 배열)
  local ARGS_JSON='[]'
  if command -v jq >/dev/null 2>&1; then
    ARGS_JSON=$(printf '%s\n' "$@" | jq -R . | jq -cs .)
  fi
  export OHMYCLAW_ARGS_JSON="$ARGS_JSON"

  # 실행
  local rc=0
  "$hook_file" "$@" || rc=$?

  if [[ $rc -ne 0 ]]; then
    if [[ "$phase" == "pre" ]]; then
      echo "[hooks] pre-${action} hook failed (rc=$rc) — aborting action" >&2
      return 7
    else
      echo "[hooks] post-${action} hook failed (rc=$rc) — continuing (non-blocking)" >&2
      return 0
    fi
  fi
  return 0
}

cmd_list() {
  local d="$OHMYCLAW_HOME/hooks"
  if [[ ! -d "$d" ]]; then
    echo "(hooks dir absent: $d)"
    return 0
  fi
  echo "── hooks in $d ──"
  local f
  for f in "$d"/{pre,post}-*.sh; do
    [[ -e "$f" ]] || continue
    local x=""; [[ -x "$f" ]] && x="*" || x=" (not executable)"
    printf "  %s%s\n" "$(basename "$f")" "$x"
  done
}

case "${1:-}" in
  fire) shift; cmd_fire "$@" ;;
  list) shift; cmd_list "$@" ;;
  help|-h|--help)
    cat <<'USAGE'
hooks.sh — ohmyclaw pre/post hook dispatcher

  fire <pre|post> <action> [args...]   훅 발화 (없으면 무동작)
  list                                  설치된 훅 목록

Env:
  OHMYCLAW_HOME        ~/.ohmyclaw  (hooks 디렉토리 루트)
  OHMYCLAW_SESSION_ID  훅에 전달될 세션 ID

훅 위치: $OHMYCLAW_HOME/hooks/{pre,post}-<action>.sh (executable)

훅이 받는 env:
  OHMYCLAW_ACTION       호출된 verb
  OHMYCLAW_PHASE        pre | post
  OHMYCLAW_SESSION      세션 ID (있으면)
  OHMYCLAW_HOME         ohmyclaw 루트
  OHMYCLAW_ARGS         \\0-구분 원시 인자
  OHMYCLAW_ARGS_JSON    JSON 배열 (jq 가용 시)

종료 정책:
  pre 훅 실패  → exit 7 (호출자가 action abort)
  post 훅 실패 → 경고만 + exit 0 (파이프라인 비차단)
USAGE
    ;;
  *)
    echo "ERROR: unknown subcommand '${1:-}'. try: hooks.sh help" >&2
    exit 2
    ;;
esac
