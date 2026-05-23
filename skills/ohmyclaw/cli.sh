#!/usr/bin/env bash
# ohmyclaw skill — unified standalone dispatcher
#
# Usage:
#   cli.sh <verb> [args...]
#
# Verbs:
#   doctor                                전체 점검 (engine + state + hooks)
#   route <task> [category] [--plan=...]  모델 라우팅 (select-model.sh)
#   pool <action> [args...]               계정 풀 액션 (pool.sh)
#   engine <action> [args...]             ACP 엔진 액션 (engine.sh)
#   state <action> [args...]              세션 state 액션 (state.sh)
#   hooks <action> [args...]              훅 액션 (hooks.sh)
#   cancel [--force]                      라이프사이클 정리
#   version                               버전 출력
#   help | --help | -h                    사용법
#
# 라이프사이클:
#   - 각 verb 진입: pre-<verb> 훅 발화 + skill-active state 작성
#   - 정상/실패 종료: trap 으로 post-<verb> 훅 발화 + skill-active 청소
#   - pre 훅 exit 7 시 verb abort

set -uo pipefail   # set -e 는 verb 별 종료코드를 통제하기 위해 적용 안 함

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SH="$SCRIPT_DIR/hooks.sh"
STATE_SH="$SCRIPT_DIR/state.sh"

OHMYCLAW_HOME="${OHMYCLAW_HOME:-$HOME/.ohmyclaw}"
export OHMYCLAW_HOME

# ──────────────────────────────────────────────
# 라이프사이클 헬퍼
# ──────────────────────────────────────────────
_VERB=""
_LIFECYCLE_DONE=0

_lifecycle_exit() {
  # 첫 줄에서 즉시 $? 캡쳐 — 이후 어떤 평가도 $? 를 덮어쓸 수 있으므로.
  local rc=$?
  # 멱등성 보장 (trap 이 EXIT + INT + TERM 셋에 동시 매핑돼도 한 번만 실행)
  [[ $_LIFECYCLE_DONE -eq 1 ]] && return 0
  _LIFECYCLE_DONE=1
  if [[ -n "$_VERB" ]]; then
    # post 훅 (실패 비차단)
    "$HOOKS_SH" fire post "$_VERB" 2>/dev/null || true
    # skill-active 청소 (실패 무시)
    "$STATE_SH" clear skill-active 2>/dev/null || true
  fi
  exit "$rc"
}

_skill_active_write() {
  local verb="$1"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  "$STATE_SH" write skill-active "{\"active\":true,\"action\":\"$verb\",\"pid\":$$,\"started_at\":\"$now\"}" 2>/dev/null || true
}

# ──────────────────────────────────────────────
# Verb 실행 래퍼 — pre 훅 + skill-active + 본체 + (trap 이 post + cleanup)
# ──────────────────────────────────────────────
_run_verb() {
  local verb="$1"; shift
  _VERB="$verb"
  trap _lifecycle_exit EXIT INT TERM

  # pre 훅 — 원본 종료코드 캡쳐 (`! cmd` 패턴은 $? 가 0 으로 덮여서 못 씀)
  local prh_rc=0
  "$HOOKS_SH" fire pre "$verb" "$@" || prh_rc=$?
  if [[ $prh_rc -eq 7 ]]; then
    echo "[cli] pre-${verb} 훅이 action 을 거부 (exit 7) — abort" >&2
    exit 7
  fi

  _skill_active_write "$verb"

  # 본체 디스패치
  case "$verb" in
    doctor)  cmd_doctor  "$@"; exit $? ;;
    route)   "$SCRIPT_DIR/select-model.sh" "$@"; exit $? ;;
    pool)    "$SCRIPT_DIR/pool.sh"         "$@"; exit $? ;;
    engine)  "$SCRIPT_DIR/engine.sh"       "$@"; exit $? ;;
    state)   "$STATE_SH"                   "$@"; exit $? ;;
    hooks)   "$HOOKS_SH"                   "$@"; exit $? ;;
    cancel)  cmd_cancel "$@"; exit $? ;;
    version) cmd_version "$@"; exit $? ;;
    *)
      echo "ERROR: unknown verb '$verb'. try: cli.sh help" >&2
      exit 2
      ;;
  esac
}

# ──────────────────────────────────────────────
# doctor — 전체 점검 (engine + state + hooks)
# ──────────────────────────────────────────────
cmd_doctor() {
  local rc=0
  echo "═══ ohmyclaw skill doctor ═══"
  echo ""

  # 1) engine doctor (기존)
  echo "── engine ──"
  "$SCRIPT_DIR/engine.sh" doctor || rc=1
  echo ""

  # 2) state smoke
  echo "── state ──"
  local probe="probe-$$"
  if "$STATE_SH" write "$probe" '{"smoke":true}' >/dev/null 2>&1 \
     && [[ "$("$STATE_SH" read "$probe")" == '{"smoke":true}' ]] \
     && "$STATE_SH" clear "$probe" >/dev/null 2>&1; then
    echo "✓ state.sh write/read/clear OK ($OHMYCLAW_HOME)"
  else
    echo "✗ state.sh smoke 실패"; rc=1
  fi
  echo ""

  # 3) hooks 점검
  echo "── hooks ──"
  "$HOOKS_SH" list
  echo ""

  echo "═══ doctor rc=$rc ═══"
  return $rc
}

# ──────────────────────────────────────────────
# version — VERSION 파일 또는 routing.json
# ──────────────────────────────────────────────
cmd_version() {
  local v
  if [[ -f "$SCRIPT_DIR/../../VERSION" ]]; then
    v=$(cat "$SCRIPT_DIR/../../VERSION")
  else
    v=$(jq -r '.version // "unknown"' "$SCRIPT_DIR/routing.json" 2>/dev/null || echo unknown)
  fi
  echo "ohmyclaw $v"
}

# ──────────────────────────────────────────────
# cancel — skill-active + pool sweep + 세션 state 청소 + (force 시 전체)
# ──────────────────────────────────────────────
cmd_cancel() {
  local force=""
  [[ "${1:-}" == "--force" ]] && force="--force"

  echo "[cli] cancel 시작 (session=${OHMYCLAW_SESSION_ID:-<global>}, force=${force:-no})"

  # 1) cancel-signal (우로보로스 ESCALATED 정합)
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  "$STATE_SH" write cancel-signal "{\"active\":true,\"mode\":\"cli\",\"source\":\"cli.sh cancel\",\"ts\":\"$now\"}" 2>/dev/null || true

  # 2) pool sweep (dead PID 슬롯 회수)
  "$SCRIPT_DIR/pool.sh" sweep 2>/dev/null || true

  # 3) skill-active 청소
  "$STATE_SH" clear skill-active 2>/dev/null || true

  # 4) 세션 state reset (force 면 전체)
  if [[ -n "$force" ]]; then
    "$STATE_SH" reset --all 2>/dev/null || true
  else
    "$STATE_SH" reset 2>/dev/null || true
  fi

  echo "[cli] cancel 완료"
}

# ──────────────────────────────────────────────
# help
# ──────────────────────────────────────────────
cmd_help() {
  cat <<'USAGE'
ohmyclaw cli — unified skill dispatcher

Usage:
  cli.sh <verb> [args...]

Verbs:
  doctor                          종합 점검 (engine + state + hooks)
  route <task> [cat] [--plan=]    모델 라우팅 → select-model.sh
  pool <action> [args]            계정 풀 (next/status/cooldown/release/sweep/...)
  engine <action> [args]          ACP 엔진 (resolve/acp-config/doctor)
  state <action> [args]           세션 state (write/read/clear/list-active/...)
  hooks <action> [args]           훅 (fire/list)
  cancel [--force]                라이프사이클 정리 + (force 시 전체)
  version                         버전 출력
  help                            본 사용법

Lifecycle:
  각 verb 진입 시 pre-<verb> 훅 + skill-active state 작성.
  종료 시 post-<verb> 훅 + skill-active 청소 (trap EXIT/INT/TERM).
  pre 훅 exit 7 → verb abort.

Env:
  OHMYCLAW_HOME        ~/.ohmyclaw (state + hooks 루트)
  OHMYCLAW_SESSION_ID  세션 격리 활성화
  OHMYCLAW_STATE_DIR   ~/.cache/ohmyclaw (pool-state, legacy)
  ZAI_CODING_PLAN      lite|pro|max
  CODEX_OAUTH_ENABLED  true|false
USAGE
}

# ──────────────────────────────────────────────
# 디스패치
# ──────────────────────────────────────────────
VERB="${1:-help}"; shift || true

case "$VERB" in
  help|-h|--help) cmd_help ;;
  doctor|route|pool|engine|state|hooks|cancel|version)
    _run_verb "$VERB" "$@"
    ;;
  *)
    echo "ERROR: unknown verb '$VERB'. try: cli.sh help" >&2
    exit 2
    ;;
esac
