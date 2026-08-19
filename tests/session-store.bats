#!/usr/bin/env bats
# session-store.sh — sqlite 기반 세션 스토어 (체크포인트/재개)

load helpers

ss() { "$SKILL_DIR/session-store.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-sstore.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  unset OHMYCLAW_SESSION_DB || true
}
teardown() {
  [[ -n "${TMP_HOME:-}" && -d "$TMP_HOME" ]] && rm -rf "$TMP_HOME"
  unset OHMYCLAW_HOME
}

# ──────────────────────────────────────────────
# 초기화 / 수명주기
# ──────────────────────────────────────────────
@test "init is idempotent" {
  run ss init
  [ "$status" -eq 0 ]
  run ss init
  [ "$status" -eq 0 ]
}

@test "start creates session and auto-creates db" {
  run ss start s1 --goal "목표" --mode full
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume_count=0"* ]]
  [ -f "$TMP_HOME/sessions.sqlite" ]
}

@test "start with same id counts as resume" {
  ss start s1 >/dev/null
  run ss start s1
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume_count=1"* ]]
}

@test "invalid session id is rejected" {
  run ss start ""
  [ "$status" -ne 0 ]
  run ss start "bad'quote"
  [ "$status" -ne 0 ]
}

@test "complete and fail change status" {
  ss start s1 >/dev/null
  ss complete s1 >/dev/null
  run ss list --status complete
  [[ "$output" == *"s1"* ]]

  ss start s2 >/dev/null
  ss fail s2 "빌드 실패" >/dev/null
  run ss list --status failed
  [[ "$output" == *"s2"* ]]
}

# ──────────────────────────────────────────────
# 체크포인트
# ──────────────────────────────────────────────
@test "checkpoint increments seq from 1" {
  ss start s1 >/dev/null
  run ss checkpoint s1 --stage plan
  [[ "$output" == *"seq=1"* ]]
  run ss checkpoint s1 --stage work
  [[ "$output" == *"seq=2"* ]]
}

@test "checkpoint requires --stage" {
  ss start s1 >/dev/null
  run ss checkpoint s1 --agent worker
  [ "$status" -ne 0 ]
}

@test "checkpoint rejects invalid status" {
  ss start s1 >/dev/null
  run ss checkpoint s1 --stage work --status bogus
  [ "$status" -ne 0 ]
}

@test "checkpoint payload must be valid JSON" {
  ss start s1 >/dev/null
  run ss checkpoint s1 --stage work --payload 'not-json'
  [ "$status" -ne 0 ]
  run ss checkpoint s1 --stage work --payload '{"ok":1}'
  [ "$status" -eq 0 ]
}

@test "checkpoint reads payload from stdin" {
  ss start s1 >/dev/null
  run bash -c "echo '{\"from\":\"stdin\"}' | '$SKILL_DIR/session-store.sh' checkpoint s1 --stage work --stdin"
  [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────
# 태스크 원장
# ──────────────────────────────────────────────
@test "task-add then task-set transitions status" {
  ss start s1 >/dev/null
  ss task-add s1 t1 "작업 1" >/dev/null
  ss task-set s1 t1 running >/dev/null
  run ss task-set s1 t1 done --result "완료"
  [ "$status" -eq 0 ]
  run ss status s1
  [[ "$output" == *"t1"* ]]
  [[ "$output" == *"done"* ]]
}

@test "task-set rejects invalid status" {
  ss start s1 >/dev/null
  ss task-add s1 t1 "작업" >/dev/null
  run ss task-set s1 t1 bogus
  [ "$status" -ne 0 ]
}

@test "attempts increments on each running entry" {
  ss start s1 >/dev/null
  ss task-add s1 t1 "작업" >/dev/null
  ss task-set s1 t1 running >/dev/null
  ss task-set s1 t1 failed >/dev/null
  ss task-set s1 t1 running >/dev/null
  run ss status s1
  [[ "$output" == *"attempts=2"* ]]
}

# ──────────────────────────────────────────────
# 재개 — 이 스토어의 존재 이유
# ──────────────────────────────────────────────
@test "resume returns only remaining tasks" {
  ss start s1 --goal "리팩터링" >/dev/null
  ss task-add s1 t1 "A" >/dev/null
  ss task-add s1 t2 "B" >/dev/null
  ss task-add s1 t3 "C" >/dev/null
  ss task-set s1 t1 done >/dev/null

  run ss resume s1
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tasks_done":1'* ]]
  [[ "$output" == *'"remaining_task_ids"'* ]]
  [[ "$output" == *"t2"* ]]
  [[ "$output" == *"t3"* ]]
  # 완료된 t1 은 남은 목록에 없어야 한다
  remaining=$(echo "$output" | sed -n 's/.*"remaining_task_ids":"\([^"]*\)".*/\1/p')
  [[ "$remaining" != *"t1"* ]]
}

@test "resume reclaims orphaned running tasks" {
  ss start s1 >/dev/null
  ss task-add s1 t1 "A" >/dev/null
  ss task-set s1 t1 running >/dev/null   # 여기서 프로세스가 죽었다고 가정

  run ss resume s1
  [ "$status" -eq 0 ]
  [[ "$output" == *'"tasks_pending":1'* ]]
  [[ "$output" == *"t1"* ]]
}

@test "resume returns last checkpoint" {
  ss start s1 >/dev/null
  ss checkpoint s1 --stage plan --payload '{"plan":"3단계"}' >/dev/null
  ss checkpoint s1 --stage work --status started >/dev/null

  run ss resume s1
  [[ "$output" == *'"last_seq":2'* ]]
  [[ "$output" == *'"last_stage":"work"'* ]]
  # last_payload 는 done 인 마지막 체크포인트에서 온다
  [[ "$output" == *"3단계"* ]]
}

@test "resume on missing session fails" {
  ss init >/dev/null
  run ss resume nope
  [ "$status" -ne 0 ]
}

@test "resume bumps resume_count" {
  ss start s1 >/dev/null
  ss resume s1 >/dev/null
  run ss resume s1
  [[ "$output" == *'"resume_count":2'* ]]
}

# ──────────────────────────────────────────────
# 중단 감지
# ──────────────────────────────────────────────
@test "live heartbeat is not interrupted" {
  ss start s1 >/dev/null
  ss heartbeat s1
  run ss interrupted --stale-sec 900
  [ -z "$output" ]
}

@test "stale heartbeat is detected as interrupted" {
  ss start s1 >/dev/null
  sqlite3 "$TMP_HOME/sessions.sqlite" \
    "UPDATE sessions SET heartbeat_at = heartbeat_at - 3600 WHERE id='s1';"
  run ss interrupted --stale-sec 900
  [ "$output" = "s1" ]
}

@test "completed session is not an interrupted candidate" {
  ss start s1 >/dev/null
  sqlite3 "$TMP_HOME/sessions.sqlite" \
    "UPDATE sessions SET heartbeat_at = heartbeat_at - 3600 WHERE id='s1';"
  ss complete s1 >/dev/null
  run ss interrupted --stale-sec 900
  [ -z "$output" ]
}

@test "interrupted rejects non-integer stale-sec" {
  ss init >/dev/null
  run ss interrupted --stale-sec abc
  [ "$status" -ne 0 ]
}

# ──────────────────────────────────────────────
# 동시성 — 여러 워커가 같은 세션에 동시에 쓴다
# ──────────────────────────────────────────────
@test "concurrent checkpoints have no seq collision" {
  ss start s1 >/dev/null
  for i in 1 2 3 4 5 6; do
    ( for _ in 1 2 3 4 5; do
        "$SKILL_DIR/session-store.sh" checkpoint s1 --stage "w$i" >/dev/null 2>&1
      done ) &
  done
  wait

  total=$(sqlite3 "$TMP_HOME/sessions.sqlite" "SELECT count(*) FROM checkpoints;")
  [ "$total" -eq 30 ]
  dupes=$(sqlite3 "$TMP_HOME/sessions.sqlite" \
    "SELECT count(*) FROM (SELECT seq FROM checkpoints GROUP BY seq HAVING count(*) > 1);")
  [ "$dupes" -eq 0 ]
}

# ──────────────────────────────────────────────
# export / gc
# ──────────────────────────────────────────────
@test "export emits valid JSON" {
  ss start s1 --goal "G" >/dev/null
  ss task-add s1 t1 "A" >/dev/null
  ss checkpoint s1 --stage plan >/dev/null
  run bash -c "'$SKILL_DIR/session-store.sh' export s1 | jq empty"
  [ "$status" -eq 0 ]
}

@test "gc removes only old finished sessions" {
  ss start old >/dev/null
  ss complete old >/dev/null
  sqlite3 "$TMP_HOME/sessions.sqlite" \
    "UPDATE sessions SET updated_at = updated_at - 86400*60 WHERE id='old';"
  ss start fresh >/dev/null

  ss gc --older-than-days 30 >/dev/null
  run ss list
  [[ "$output" != *"old"* ]]
  [[ "$output" == *"fresh"* ]]
}

@test "gc keeps running sessions" {
  ss start running_one >/dev/null
  sqlite3 "$TMP_HOME/sessions.sqlite" \
    "UPDATE sessions SET updated_at = updated_at - 86400*60 WHERE id='running_one';"
  ss gc --older-than-days 30 >/dev/null
  run ss list
  [[ "$output" == *"running_one"* ]]
}

# ──────────────────────────────────────────────
# 잡다
# ──────────────────────────────────────────────
@test "unknown action fails" {
  run ss bogus-action
  [ "$status" -ne 0 ]
}

@test "db-path prints resolved path" {
  run ss db-path
  [ "$output" = "$TMP_HOME/sessions.sqlite" ]
}

@test "OHMYCLAW_SESSION_DB overrides db path" {
  export OHMYCLAW_SESSION_DB="$TMP_HOME/custom.sqlite"
  ss start s1 >/dev/null
  [ -f "$TMP_HOME/custom.sqlite" ]
}
