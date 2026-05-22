#!/usr/bin/env bats
# pool.sh — account pool, worker semaphore, concurrency

load helpers

setup() {
  setup_isolated_state
  pl reset >/dev/null 2>&1 || true
}
teardown() {
  teardown_isolated_state
}

@test "next glm-5 returns zai-primary" {
  run pl next glm-5
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^zai-primary\|oauth_zai\| ]]
}

@test "next unknown prefix exits 1" {
  run pl next bogus-model
  [ "$status" -eq 1 ]
}

@test "next gpt without CODEX_OAUTH_ENABLED exits 1" {
  unset CODEX_OAUTH_ENABLED
  run pl next gpt-5.4
  [ "$status" -eq 1 ]
}

@test "fanout zai lists at least one account" {
  run pl fanout zai
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 1 ]
}

@test "cooldown then release succeeds" {
  pl cooldown zai-primary 2>/dev/null
  run pl release zai-primary
  [ "$status" -eq 0 ]
}

@test "status exits 0" {
  run pl status
  [ "$status" -eq 0 ]
}

@test "reset empties state file" {
  pl cooldown zai-primary 2>/dev/null
  pl reset >/dev/null 2>&1
  local sf="${OHMYCLAW_STATE_DIR}/pool-state.json"
  run jq -r '. == {}' "$sf"
  [ "$output" = "true" ]
}

@test "acquire-worker emits TOKEN= prefix" {
  ZAI_CODING_PLAN=pro run pl acquire-worker
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^TOKEN= ]]
}

@test "acquire 4 pro slots then 5th rejected with exit 11" {
  local tokens=()
  for i in 1 2 3 4; do
    out=$(ZAI_CODING_PLAN=pro pl acquire-worker 2>/dev/null)
    tokens+=("${out#TOKEN=}")
  done
  run env ZAI_CODING_PLAN=pro "$SKILL_DIR/pool.sh" acquire-worker
  [ "$status" -eq 11 ]
  for t in "${tokens[@]}"; do pl release-worker "$t" >/dev/null; done
}

@test "lite plan maxWorkers=2 third attempt rejected" {
  ZAI_CODING_PLAN=lite pl acquire-worker >/dev/null 2>&1
  ZAI_CODING_PLAN=lite pl acquire-worker >/dev/null 2>&1
  run env ZAI_CODING_PLAN=lite "$SKILL_DIR/pool.sh" acquire-worker
  [ "$status" -eq 11 ]
}

@test "max plan maxWorkers=7 eighth attempt rejected" {
  for i in 1 2 3 4 5 6 7; do
    ZAI_CODING_PLAN=max pl acquire-worker >/dev/null 2>&1
  done
  run env ZAI_CODING_PLAN=max "$SKILL_DIR/pool.sh" acquire-worker
  [ "$status" -eq 11 ]
}

@test "release-worker removes slot file" {
  out=$(ZAI_CODING_PLAN=pro pl acquire-worker 2>/dev/null)
  token="${out#TOKEN=}"
  run pl release-worker "$token"
  [ "$status" -eq 0 ]
  [ ! -e "$token" ]
}

@test "release-worker rejects invalid token path" {
  run pl release-worker /tmp/not-a-slot
  [ "$status" -ne 0 ]
}

@test "sweep reaps dead PID slot" {
  out=$(ZAI_CODING_PLAN=pro pl acquire-worker 2>/dev/null)
  token="${out#TOKEN=}"
  echo "999999" > "$token"
  run pl sweep
  [ "$status" -eq 0 ]
  [ ! -e "$token" ]
}

@test "sweep preserves live PID slot" {
  out=$(ZAI_CODING_PLAN=pro pl acquire-worker 2>/dev/null)
  token="${out#TOKEN=}"
  echo "$$" > "$token"
  pl sweep >/dev/null
  [ -e "$token" ]
  pl release-worker "$token" >/dev/null
}

@test "5 parallel next preserves roundRobinIndex numeric" {
  for i in 1 2 3 4 5; do
    pl next glm-5 >/dev/null 2>&1 &
  done
  wait
  local sf="${OHMYCLAW_STATE_DIR}/pool-state.json"
  run jq -r '.zai.roundRobinIndex // "missing"' "$sf"
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "10 parallel acquire/release no slot leak" {
  export ZAI_CODING_PLAN=max
  for i in 1 2 3 4 5 6 7 8 9 10; do
    (
      out=$(pl acquire-worker 2>/dev/null) || exit 0
      token="${out#TOKEN=}"
      echo "$$" > "$token"
      sleep 0.05
      pl release-worker "$token" >/dev/null 2>&1
    ) &
  done
  wait
  pl sweep >/dev/null 2>&1
  local pids_dir="${OHMYCLAW_STATE_DIR}/pids/${OHMYCLAW_SESSION_ID}"
  if [[ -d "$pids_dir" ]]; then
    local remaining
    remaining=$(find "$pids_dir" -name 'slot-*' | wc -l | tr -d ' ')
    [ "$remaining" -eq 0 ]
  fi
}
