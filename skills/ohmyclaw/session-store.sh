#!/usr/bin/env bash
# ohmyclaw skill — durable session store (sqlite3)
#
# 목적:
#   긴 작업이 타임아웃/크래시/연결끊김으로 중단되어도 처음부터 다시 하지 않는다.
#   단계별 체크포인트와 태스크 진행상황을 sqlite 에 커밋해두고, 재개 시
#   "남은 일" 만 뽑아 오케스트레이터에 되돌려준다.
#
# state.sh 와의 관계:
#   state.sh  = 세션 스코프 key/value (JSON 파일, 휘발성 작업 메모)
#   이 파일   = 세션 수명주기 + 체크포인트 + 태스크 원장 (내구성, 재개용)
#   둘은 독립이며 서로를 호출하지 않는다.
#
# Usage:
#   session-store.sh init
#   session-store.sh start <sid> [--goal G] [--mode solo|parallel|full] [--cwd PATH]
#   session-store.sh heartbeat <sid>
#   session-store.sh checkpoint <sid> --stage S [--agent A] [--model M]
#                                      [--status started|done|failed]
#                                      [--payload JSON | --stdin]
#   session-store.sh task-add  <sid> <task-id> <description> [--group G]
#   session-store.sh task-set  <sid> <task-id> <pending|running|done|failed>
#                                      [--result TEXT] [--model M]
#   session-store.sh resume    <sid>          # 재개 봉투(JSON) — 남은 일만
#   session-store.sh status    <sid>          # 사람이 읽는 요약
#   session-store.sh list [--status S] [--limit N]
#   session-store.sh interrupted [--stale-sec N]   # 재개 후보 세션 ID 목록
#   session-store.sh complete  <sid>
#   session-store.sh fail      <sid> [reason]
#   session-store.sh export    <sid>          # 전체 트라젝토리 JSON (외부 뷰어용)
#   session-store.sh gc [--older-than-days N]
#
# 경로:
#   ${OHMYCLAW_SESSION_DB:-${OHMYCLAW_HOME:-~/.ohmyclaw}/sessions.sqlite}
#
# 동시성:
#   WAL + busy_timeout 으로 sqlite 가 직렬화한다. 파일락 불필요 —
#   여러 워커가 동시에 checkpoint/task-set 을 때려도 안전하다.

set -euo pipefail

OHMYCLAW_HOME="${OHMYCLAW_HOME:-$HOME/.ohmyclaw}"
DB="${OHMYCLAW_SESSION_DB:-$OHMYCLAW_HOME/sessions.sqlite}"
BUSY_TIMEOUT_MS="${OHMYCLAW_SQLITE_BUSY_TIMEOUT_MS:-10000}"
STALE_SEC_DEFAULT="${OHMYCLAW_SESSION_STALE_SEC:-900}"

# ──────────────────────────────────────────────
# sqlite3 래퍼
# ──────────────────────────────────────────────
_need_sqlite() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "ERROR: sqlite3 미설치 — macOS 는 기본 내장, Linux 는 'apt install sqlite3'" >&2
    return 3
  fi
}

# 작은따옴표 이스케이프 (sqlite 리터럴용)
_q() { printf "%s" "${1:-}" | sed "s/'/''/g"; }

_sql() {
  _need_sqlite || return $?
  mkdir -p "$(dirname "$DB")"
  sqlite3 -cmd ".timeout $BUSY_TIMEOUT_MS" "$DB" "$@"
}

# 헤더 없는 파이프 구분 조회
_sql_q() { _sql -noheader -separator '|' "$1"; }

_now() { date +%s; }

_validate_sid() {
  local sid="${1:-}"
  case "$sid" in
    ''|*"'"*|*$'\n'*) echo "ERROR: invalid session id '${sid}'" >&2; return 2 ;;
  esac
}

# ──────────────────────────────────────────────
# 스키마
# ──────────────────────────────────────────────
SCHEMA_VERSION=1

action_init() {
  _need_sqlite || return $?
  mkdir -p "$(dirname "$DB")"
  _sql <<SQL
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
  id            TEXT PRIMARY KEY,
  goal          TEXT    DEFAULT '',
  mode          TEXT    DEFAULT 'solo',
  status        TEXT    DEFAULT 'running',
  cwd           TEXT    DEFAULT '',
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  heartbeat_at  INTEGER NOT NULL,
  resume_count  INTEGER DEFAULT 0,
  fail_reason   TEXT    DEFAULT ''
);

CREATE TABLE IF NOT EXISTS checkpoints (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT    NOT NULL,
  seq        INTEGER NOT NULL,
  stage      TEXT    NOT NULL,
  agent      TEXT    DEFAULT '',
  model      TEXT    DEFAULT '',
  status     TEXT    DEFAULT 'done',
  payload    TEXT    DEFAULT '',
  created_at INTEGER NOT NULL,
  UNIQUE(session_id, seq)
);

CREATE TABLE IF NOT EXISTS tasks (
  session_id  TEXT NOT NULL,
  task_id     TEXT NOT NULL,
  description TEXT DEFAULT '',
  task_group  TEXT DEFAULT '',
  status      TEXT DEFAULT 'pending',
  result      TEXT DEFAULT '',
  model       TEXT DEFAULT '',
  attempts    INTEGER DEFAULT 0,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (session_id, task_id)
);

CREATE INDEX IF NOT EXISTS idx_ckpt_session ON checkpoints(session_id, seq);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(session_id, status);
CREATE INDEX IF NOT EXISTS idx_sessions_st  ON sessions(status, heartbeat_at);

INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', '${SCHEMA_VERSION}');
SQL
  echo "session-store 초기화 완료: $DB"
}

_ensure_init() {
  if [[ ! -f "$DB" ]]; then
    action_init >/dev/null
    return 0
  fi
  # 기존 파일이지만 스키마가 없는 경우(중단된 init 등) 보정
  local has
  has=$(_sql_q "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='sessions';" 2>/dev/null || echo 0)
  [[ "$has" == "1" ]] || action_init >/dev/null
}

# ──────────────────────────────────────────────
# start
# ──────────────────────────────────────────────
action_start() {
  local sid="${1:-}"; shift || true
  _validate_sid "$sid" || return 2
  _ensure_init

  local goal="" mode="solo" cwd="${PWD}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal) goal="${2:-}"; shift 2 ;;
      --mode) mode="${2:-solo}"; shift 2 ;;
      --cwd)  cwd="${2:-}"; shift 2 ;;
      *) echo "ERROR: unknown flag '$1'" >&2; return 2 ;;
    esac
  done

  local now; now=$(_now)
  # 이미 있으면 재개로 간주 — resume_count 증가, status 를 running 으로 되돌림
  _sql <<SQL
INSERT INTO sessions(id, goal, mode, status, cwd, created_at, updated_at, heartbeat_at)
VALUES('$(_q "$sid")', '$(_q "$goal")', '$(_q "$mode")', 'running', '$(_q "$cwd")', $now, $now, $now)
ON CONFLICT(id) DO UPDATE SET
  status       = 'running',
  updated_at   = $now,
  heartbeat_at = $now,
  resume_count = resume_count + 1,
  goal         = CASE WHEN '$(_q "$goal")' = '' THEN goal ELSE '$(_q "$goal")' END;
SQL
  local rc; rc=$(_sql_q "SELECT resume_count FROM sessions WHERE id='$(_q "$sid")';")
  echo "session: $sid (resume_count=$rc)"
}

action_heartbeat() {
  local sid="${1:-}"
  _validate_sid "$sid" || return 2
  _ensure_init
  _sql "UPDATE sessions SET heartbeat_at=$(_now), updated_at=$(_now) WHERE id='$(_q "$sid")';"
}

# ──────────────────────────────────────────────
# checkpoint
# ──────────────────────────────────────────────
action_checkpoint() {
  local sid="${1:-}"; shift || true
  _validate_sid "$sid" || return 2
  _ensure_init

  local stage="" agent="" model="" status="done" payload="" read_stdin=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage)   stage="${2:-}";   shift 2 ;;
      --agent)   agent="${2:-}";   shift 2 ;;
      --model)   model="${2:-}";   shift 2 ;;
      --status)  status="${2:-}";  shift 2 ;;
      --payload) payload="${2:-}"; shift 2 ;;
      --stdin)   read_stdin=true;  shift ;;
      *) echo "ERROR: unknown flag '$1'" >&2; return 2 ;;
    esac
  done
  [[ -n "$stage" ]] || { echo "ERROR: --stage 필수" >&2; return 2; }
  case "$status" in
    started|done|failed) ;;
    *) echo "ERROR: --status 는 started|done|failed" >&2; return 2 ;;
  esac
  $read_stdin && payload="$(cat)"

  # payload 가 있으면 JSON 유효성 확인 (jq 있을 때만)
  if [[ -n "$payload" ]] && command -v jq >/dev/null 2>&1; then
    if ! printf '%s' "$payload" | jq empty >/dev/null 2>&1; then
      echo "ERROR: --payload 는 유효한 JSON 이어야 합니다" >&2
      return 2
    fi
  fi

  local now; now=$(_now)
  _sql <<SQL
INSERT INTO checkpoints(session_id, seq, stage, agent, model, status, payload, created_at)
SELECT '$(_q "$sid")',
       COALESCE((SELECT MAX(seq) FROM checkpoints WHERE session_id='$(_q "$sid")'), 0) + 1,
       '$(_q "$stage")', '$(_q "$agent")', '$(_q "$model")', '$(_q "$status")',
       '$(_q "$payload")', $now;
UPDATE sessions SET updated_at=$now, heartbeat_at=$now WHERE id='$(_q "$sid")';
SQL
  local seq; seq=$(_sql_q "SELECT MAX(seq) FROM checkpoints WHERE session_id='$(_q "$sid")';")
  echo "checkpoint: seq=${seq} stage=${stage} status=${status}"
}

# ──────────────────────────────────────────────
# tasks
# ──────────────────────────────────────────────
action_task_add() {
  local sid="${1:-}" tid="${2:-}" desc="${3:-}"; shift 3 2>/dev/null || true
  _validate_sid "$sid" || return 2
  [[ -n "$tid" ]] || { echo "ERROR: task-id 필수" >&2; return 2; }
  _ensure_init

  local group=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --group) group="${2:-}"; shift 2 ;;
      *) echo "ERROR: unknown flag '$1'" >&2; return 2 ;;
    esac
  done

  local now; now=$(_now)
  _sql <<SQL
INSERT INTO tasks(session_id, task_id, description, task_group, status, updated_at)
VALUES('$(_q "$sid")', '$(_q "$tid")', '$(_q "$desc")', '$(_q "$group")', 'pending', $now)
ON CONFLICT(session_id, task_id) DO UPDATE SET
  description = '$(_q "$desc")',
  task_group  = '$(_q "$group")',
  updated_at  = $now;
SQL
  echo "task: $tid (pending)"
}

action_task_set() {
  local sid="${1:-}" tid="${2:-}" status="${3:-}"; shift 3 2>/dev/null || true
  _validate_sid "$sid" || return 2
  [[ -n "$tid" ]] || { echo "ERROR: task-id 필수" >&2; return 2; }
  case "$status" in
    pending|running|done|failed) ;;
    *) echo "ERROR: status 는 pending|running|done|failed" >&2; return 2 ;;
  esac
  _ensure_init

  local result="" model=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result) result="${2:-}"; shift 2 ;;
      --model)  model="${2:-}";  shift 2 ;;
      *) echo "ERROR: unknown flag '$1'" >&2; return 2 ;;
    esac
  done

  local now; now=$(_now)
  # running 진입마다 attempts 증가 → 재시도 상한 판정에 사용
  local bump=0
  [[ "$status" == "running" ]] && bump=1

  _sql <<SQL
INSERT INTO tasks(session_id, task_id, status, result, model, attempts, updated_at)
VALUES('$(_q "$sid")', '$(_q "$tid")', '$(_q "$status")', '$(_q "$result")', '$(_q "$model")', $bump, $now)
ON CONFLICT(session_id, task_id) DO UPDATE SET
  status     = '$(_q "$status")',
  result     = CASE WHEN '$(_q "$result")' = '' THEN result ELSE '$(_q "$result")' END,
  model      = CASE WHEN '$(_q "$model")'  = '' THEN model  ELSE '$(_q "$model")'  END,
  attempts   = attempts + $bump,
  updated_at = $now;
UPDATE sessions SET updated_at=$now, heartbeat_at=$now WHERE id='$(_q "$sid")';
SQL
  echo "task: $tid -> $status"
}

# ──────────────────────────────────────────────
# resume — 재개 봉투 (JSON)
#   오케스트레이터가 이걸 읽고 "남은 일" 만 다시 배정한다.
# ──────────────────────────────────────────────
action_resume() {
  local sid="${1:-}"
  _validate_sid "$sid" || return 2
  _ensure_init

  local exists
  exists=$(_sql_q "SELECT count(*) FROM sessions WHERE id='$(_q "$sid")';")
  if [[ "$exists" != "1" ]]; then
    echo "ERROR: 세션 '$sid' 없음" >&2
    return 4
  fi

  # 재개 시도 기록
  _sql "UPDATE sessions SET status='running', resume_count=resume_count+1, heartbeat_at=$(_now), updated_at=$(_now) WHERE id='$(_q "$sid")';"

  # running 상태로 죽은 태스크는 pending 으로 되돌린다 (고아 회수)
  _sql "UPDATE tasks SET status='pending', updated_at=$(_now) WHERE session_id='$(_q "$sid")' AND status='running';"

  _sql -json "
SELECT
  s.id            AS session_id,
  s.goal          AS goal,
  s.mode          AS mode,
  s.cwd           AS cwd,
  s.resume_count  AS resume_count,
  (SELECT COALESCE(MAX(seq),0) FROM checkpoints WHERE session_id=s.id) AS last_seq,
  (SELECT stage FROM checkpoints WHERE session_id=s.id ORDER BY seq DESC LIMIT 1) AS last_stage,
  (SELECT payload FROM checkpoints WHERE session_id=s.id AND status='done' ORDER BY seq DESC LIMIT 1) AS last_payload,
  (SELECT count(*) FROM tasks WHERE session_id=s.id AND status='done')    AS tasks_done,
  (SELECT count(*) FROM tasks WHERE session_id=s.id AND status='failed')  AS tasks_failed,
  (SELECT count(*) FROM tasks WHERE session_id=s.id AND status='pending') AS tasks_pending,
  (SELECT group_concat(task_id, ',') FROM tasks WHERE session_id=s.id AND status IN ('pending','failed')) AS remaining_task_ids
FROM sessions s WHERE s.id='$(_q "$sid")';"
}

# ──────────────────────────────────────────────
# status / list / interrupted
# ──────────────────────────────────────────────
action_status() {
  local sid="${1:-}"
  _validate_sid "$sid" || return 2
  _ensure_init

  local row
  row=$(_sql_q "SELECT status, mode, resume_count, created_at, heartbeat_at, goal FROM sessions WHERE id='$(_q "$sid")';")
  if [[ -z "$row" ]]; then
    echo "(세션 '$sid' 없음)"
    return 0
  fi
  local st mode rc created hb goal
  IFS='|' read -r st mode rc created hb goal <<<"$row"

  echo "── 세션 ${sid} ──"
  echo "  상태      : ${st}  (mode=${mode}, 재개 ${rc}회)"
  echo "  목표      : ${goal:-(없음)}"
  echo "  마지막 신호: $(( $(_now) - hb ))초 전"
  echo "  체크포인트:"
  _sql -noheader -separator '  ' \
    "SELECT '    #' || seq, stage, status, COALESCE(NULLIF(model,''),'-') FROM checkpoints WHERE session_id='$(_q "$sid")' ORDER BY seq;"
  echo "  태스크:"
  _sql -noheader -separator '  ' \
    "SELECT '    ' || task_id, status, 'attempts=' || attempts FROM tasks WHERE session_id='$(_q "$sid")' ORDER BY task_id;"
}

action_list() {
  _ensure_init
  local want_status="" limit=50
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) want_status="${2:-}"; shift 2 ;;
      --limit)  limit="${2:-50}"; shift 2 ;;
      *) echo "ERROR: unknown flag '$1'" >&2; return 2 ;;
    esac
  done
  local where=""
  [[ -n "$want_status" ]] && where="WHERE status='$(_q "$want_status")'"
  _sql -noheader -separator '  ' \
    "SELECT id, status, mode, 'resumes=' || resume_count, datetime(updated_at,'unixepoch','localtime')
     FROM sessions $where ORDER BY updated_at DESC LIMIT $limit;"
}

# 하트비트가 끊긴 running 세션 = 재개 후보
action_interrupted() {
  _ensure_init
  local stale="$STALE_SEC_DEFAULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stale-sec) stale="${2:-$STALE_SEC_DEFAULT}"; shift 2 ;;
      *) echo "ERROR: unknown flag '$1'" >&2; return 2 ;;
    esac
  done
  if ! [[ "$stale" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --stale-sec 는 정수" >&2; return 2
  fi
  _sql_q "SELECT id FROM sessions
          WHERE status='running' AND heartbeat_at < $(( $(_now) - stale ))
          ORDER BY heartbeat_at;"
}

action_complete() {
  local sid="${1:-}"
  _validate_sid "$sid" || return 2
  _ensure_init
  _sql "UPDATE sessions SET status='complete', updated_at=$(_now), heartbeat_at=$(_now) WHERE id='$(_q "$sid")';"
  echo "session: $sid -> complete"
}

action_fail() {
  local sid="${1:-}" reason="${2:-}"
  _validate_sid "$sid" || return 2
  _ensure_init
  _sql "UPDATE sessions SET status='failed', fail_reason='$(_q "$reason")', updated_at=$(_now) WHERE id='$(_q "$sid")';"
  echo "session: $sid -> failed"
}

# ──────────────────────────────────────────────
# export — 전체 트라젝토리 JSON
#   외부 뷰어(trackio 등)로 넘길 때 쓰는 단일 출구.
# ──────────────────────────────────────────────
action_export() {
  local sid="${1:-}"
  _validate_sid "$sid" || return 2
  _ensure_init
  echo '{'
  echo '  "session":'
  _sql -json "SELECT * FROM sessions WHERE id='$(_q "$sid")';" | sed 's/^/  /'
  echo '  ,"checkpoints":'
  _sql -json "SELECT seq, stage, agent, model, status, payload, created_at FROM checkpoints WHERE session_id='$(_q "$sid")' ORDER BY seq;" | sed 's/^/  /'
  echo '  ,"tasks":'
  _sql -json "SELECT task_id, description, task_group, status, result, model, attempts, updated_at FROM tasks WHERE session_id='$(_q "$sid")' ORDER BY task_id;" | sed 's/^/  /'
  echo '}'
}

action_gc() {
  _ensure_init
  local days=30
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --older-than-days) days="${2:-30}"; shift 2 ;;
      *) echo "ERROR: unknown flag '$1'" >&2; return 2 ;;
    esac
  done
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --older-than-days 는 정수" >&2; return 2
  fi
  local cutoff=$(( $(_now) - days * 86400 ))
  local n
  n=$(_sql_q "SELECT count(*) FROM sessions WHERE status IN ('complete','failed') AND updated_at < $cutoff;")
  _sql <<SQL
DELETE FROM checkpoints WHERE session_id IN
  (SELECT id FROM sessions WHERE status IN ('complete','failed') AND updated_at < $cutoff);
DELETE FROM tasks WHERE session_id IN
  (SELECT id FROM sessions WHERE status IN ('complete','failed') AND updated_at < $cutoff);
DELETE FROM sessions WHERE status IN ('complete','failed') AND updated_at < $cutoff;
VACUUM;
SQL
  echo "gc: ${n}개 세션 정리 (${days}일 초과)"
}

# ──────────────────────────────────────────────
# 디스패치
# ──────────────────────────────────────────────
usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local action="${1:-}"; shift || true
  case "$action" in
    init)        action_init "$@" ;;
    start)       action_start "$@" ;;
    heartbeat)   action_heartbeat "$@" ;;
    checkpoint)  action_checkpoint "$@" ;;
    task-add)    action_task_add "$@" ;;
    task-set)    action_task_set "$@" ;;
    resume)      action_resume "$@" ;;
    status)      action_status "$@" ;;
    list)        action_list "$@" ;;
    interrupted) action_interrupted "$@" ;;
    complete)    action_complete "$@" ;;
    fail)        action_fail "$@" ;;
    export)      action_export "$@" ;;
    gc)          action_gc "$@" ;;
    db-path)     echo "$DB" ;;
    ''|-h|--help|help) usage ;;
    *) echo "ERROR: unknown action '$action' (see --help)" >&2; return 2 ;;
  esac
}

main "$@"
