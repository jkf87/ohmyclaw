#!/usr/bin/env bash
# ohmyclaw skill — session-scoped state helper (OMC state_* 인터페이스 모방)
#
# Usage:
#   state.sh write <key> <json-value>        # 인라인 값 쓰기
#   state.sh write <key> --file <path>       # 파일에서 쓰기
#   state.sh write <key> --stdin             # stdin 에서 쓰기
#   state.sh read  <key>                     # 값 출력 (없으면 빈 출력 + exit 0)
#   state.sh clear <key>                     # 키 제거
#   state.sh list-active                     # 활성 세션 ID 목록
#   state.sh get-status [sessionId]          # 세션의 key + mtime 표
#   state.sh path  <key>                     # 해결된 경로만 출력
#   state.sh reset [--all]                   # 현 세션(또는 전체) 상태 청소
#
# 경로:
#   세션 모드 (OHMYCLAW_SESSION_ID 설정 시):
#     ${OHMYCLAW_HOME:-~/.ohmyclaw}/state/sessions/<sessionId>/<key>.json
#   글로벌 모드 (세션 ID 없을 때):
#     ${OHMYCLAW_HOME:-~/.ohmyclaw}/state/<key>.json
#
# 동시성:
#   write/clear/reset 은 flock(Linux) 또는 portable mkdir-lock(macOS) 으로 직렬화.
#   read/list/get-status/path 는 lock-free.

set -euo pipefail

# ──────────────────────────────────────────────
# 경로 해석
# ──────────────────────────────────────────────
OHMYCLAW_HOME="${OHMYCLAW_HOME:-$HOME/.ohmyclaw}"

_state_dir() {
  if [[ -n "${OHMYCLAW_SESSION_ID:-}" ]]; then
    echo "$OHMYCLAW_HOME/state/sessions/$OHMYCLAW_SESSION_ID"
  else
    echo "$OHMYCLAW_HOME/state"
  fi
}

_validate_key() {
  local key="$1"
  case "$key" in
    ''|*..*|*/*|.*) echo "ERROR: invalid key '$key' (no empty/slash/'..'/leading dot)" >&2; return 2 ;;
  esac
}
_key_path() {
  echo "$(_state_dir)/$1.json"
}

# ──────────────────────────────────────────────
# Portable lock (flock | mkdir-loop). pool.sh 와 동일 패턴이지만 별도 락 파일.
# ──────────────────────────────────────────────
_lock_root() {
  local d
  d="$(_state_dir)"
  mkdir -p "$d"
  echo "$d/.lock"
}
_LOCK_TIMEOUT_MS="${OHMYCLAW_LOCK_TIMEOUT_MS:-10000}"

with_state_lock() {
  local fn="$1"; shift
  local lock_file lock_dir
  lock_file="$(_lock_root)"
  lock_dir="${lock_file}.dir"
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w "$(( _LOCK_TIMEOUT_MS / 1000 + 1 ))" -x 9 \
        || { echo "ERROR: state.sh flock timeout" >&2; exit 2; }
      "$fn" "$@"
    ) 9>"$lock_file"
  else
    local tries=0 max=$((_LOCK_TIMEOUT_MS / 50))
    while ! mkdir "$lock_dir" 2>/dev/null; do
      sleep 0.05
      tries=$((tries+1))
      if [[ $tries -gt $max ]]; then
        echo "ERROR: state.sh lock timeout (${_LOCK_TIMEOUT_MS}ms) on $lock_dir" >&2
        return 2
      fi
    done
    local rc=0
    "$fn" "$@" || rc=$?
    rmdir "$lock_dir" 2>/dev/null || true
    return $rc
  fi
}

# ──────────────────────────────────────────────
# 액션 — write
# ──────────────────────────────────────────────
_write_inner() {
  local key="$1" content="$2"
  local target dir
  target="$(_key_path "$key")"
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  # JSON 유효성 확인 (jq 가 있을 때만; 없어도 raw 저장 허용)
  if command -v jq >/dev/null 2>&1; then
    if ! echo "$content" | jq empty >/dev/null 2>&1; then
      echo "ERROR: value is not valid JSON for key '$key' (write raw bytes via --stdin only)" >&2
      return 3
    fi
  fi
  local tmp="${target}.tmp.$$"
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

action_write() {
  local key="${1:-}"; shift || true
  _validate_key "$key" || return 2
  local content=""
  case "${1:-}" in
    --file)
      [[ -z "${2:-}" ]] && { echo "ERROR: --file needs path" >&2; return 2; }
      [[ ! -f "$2" ]] && { echo "ERROR: file not found: $2" >&2; return 2; }
      content=$(cat "$2")
      ;;
    --stdin)
      content=$(cat)
      ;;
    *)
      content="${1:-}"
      ;;
  esac
  with_state_lock _write_inner "$key" "$content"
}

# ──────────────────────────────────────────────
# 액션 — read (락 불필요)
# ──────────────────────────────────────────────
action_read() {
  local key="${1:-}"
  _validate_key "$key" || return 2
  local p; p="$(_key_path "$key")"
  if [[ -f "$p" ]]; then cat "$p"; fi
}

# ──────────────────────────────────────────────
# 액션 — clear
# ──────────────────────────────────────────────
_clear_inner() {
  local key="$1"
  local p; p="$(_key_path "$key")"
  rm -f "$p"
}
action_clear() {
  local key="${1:-}"
  _validate_key "$key" || return 2
  with_state_lock _clear_inner "$key"
}

# ──────────────────────────────────────────────
# 액션 — path
# ──────────────────────────────────────────────
action_path() {
  local key="${1:-}"
  _validate_key "$key" || return 2
  _key_path "$key"
}

# ──────────────────────────────────────────────
# 액션 — list-active (세션 ID 목록)
# ──────────────────────────────────────────────
action_list_active() {
  local sessions_dir="$OHMYCLAW_HOME/state/sessions"
  [[ ! -d "$sessions_dir" ]] && return 0
  local s
  for s in "$sessions_dir"/*/; do
    [[ -d "$s" ]] || continue
    # 적어도 1개 *.json 키가 있는 세션만 출력
    if compgen -G "$s/*.json" >/dev/null 2>&1; then
      basename "$s"
    fi
  done
}

# ──────────────────────────────────────────────
# 액션 — get-status [sessionId]
# ──────────────────────────────────────────────
action_get_status() {
  local sid="${1:-${OHMYCLAW_SESSION_ID:-}}"
  local dir
  if [[ -n "$sid" ]]; then
    dir="$OHMYCLAW_HOME/state/sessions/$sid"
  else
    dir="$OHMYCLAW_HOME/state"
  fi
  if [[ ! -d "$dir" ]]; then
    echo "(no state for ${sid:-<global>})"
    return 0
  fi
  echo "── ${sid:-<global>} (${dir}) ──"
  local f mtime
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    mtime=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$f" 2>/dev/null \
         || stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
    printf "  %-32s %s\n" "$(basename "$f" .json)" "$mtime"
  done
}

# ──────────────────────────────────────────────
# 액션 — recent (TTL 기반 prefetch)
# state.sh recent <key> [ttl-sec]
#   ttl=0 (기본) → 그냥 read 와 동일
#   ttl>0       → 현재 시각 - mtime 이 ttl 이내면 내용 출력, 초과면 빈 출력
#   파일 부재   → 빈 출력
# 반환: 항상 exit 0 (정책: caller 가 빈 출력 으로 부재 판단)
# ──────────────────────────────────────────────
action_recent() {
  local key="${1:-}"
  local ttl="${2:-0}"
  _validate_key "$key" || return 2
  if ! [[ "$ttl" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ttl-sec must be a non-negative integer (got: $ttl)" >&2
    return 2
  fi
  local p; p="$(_key_path "$key")"
  [[ ! -f "$p" ]] && return 0
  if [[ "$ttl" -eq 0 ]]; then
    cat "$p"
    return 0
  fi
  # mtime 추출 (macOS 와 Linux 둘 다 지원)
  local mtime now age
  mtime=$(stat -f '%m' "$p" 2>/dev/null || stat -c '%Y' "$p" 2>/dev/null)
  now=$(date +%s)
  age=$(( now - mtime ))
  if [[ "$age" -le "$ttl" ]]; then
    cat "$p"
  fi
  # else: 빈 출력
  return 0
}

# ──────────────────────────────────────────────
# 액션 — reset
# ──────────────────────────────────────────────
_reset_inner() {
  local target_dir="$1"
  rm -rf "$target_dir"
}
action_reset() {
  if [[ "${1:-}" == "--all" ]]; then
    with_state_lock _reset_inner "$OHMYCLAW_HOME/state"
    echo "[state] reset --all → $OHMYCLAW_HOME/state cleared" >&2
  else
    with_state_lock _reset_inner "$(_state_dir)"
    echo "[state] reset → $(_state_dir) cleared" >&2
  fi
}

# ──────────────────────────────────────────────
# 디스패치
# ──────────────────────────────────────────────
case "${1:-}" in
  write)        shift; action_write "$@" ;;
  read)         shift; action_read "$@" ;;
  recent)       shift; action_recent "$@" ;;
  clear)        shift; action_clear "$@" ;;
  path)         shift; action_path "$@" ;;
  list-active)  shift; action_list_active "$@" ;;
  get-status)   shift; action_get_status "$@" ;;
  reset)        shift; action_reset "$@" ;;
  help|-h|--help)
    cat <<'USAGE'
state.sh — ohmyclaw 세션 격리 state (OMC state_* 인터페이스 모방)

  write <key> <json>           세션 state 에 키=값 쓰기
  write <key> --file <path>    파일에서 쓰기
  write <key> --stdin          stdin 에서 쓰기
  read  <key>                  값 출력 (없으면 빈 출력)
  recent <key> [ttl-sec]       TTL 기반 prefetch (mtime ≤ ttl 시만 출력)
  clear <key>                  키 제거
  list-active                  활성 세션 ID 목록
  get-status [sessionId]       세션 key + mtime 표
  path  <key>                  해결된 키 경로 출력
  reset [--all]                현 세션(또는 전체) 청소

Env:
  OHMYCLAW_HOME        ~/.ohmyclaw  (state 루트)
  OHMYCLAW_SESSION_ID  세션 모드 활성 (미설정 시 글로벌)
  OHMYCLAW_LOCK_TIMEOUT_MS  10000   (락 타임아웃)
USAGE
    ;;
  *)
    echo "ERROR: unknown subcommand '${1:-}'. try: state.sh help" >&2
    exit 2
    ;;
esac
