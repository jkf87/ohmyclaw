#!/usr/bin/env bats
# cli.sh interview start/answer/status/cancel — 비동기 상태머신 (command 버튼 → 에이전트 재개)
# 클릭 응답은 실제값이므로 degraded:false (동기 폴백과 대비).

load helpers

cl() { "$SKILL_DIR/cli.sh" "$@"; }
json_line() { echo "$1" | grep -E '^\{' | tail -1; }
dry_json() { echo "$1" | grep '^DRY_RUN_JSON:' | head -1 | sed 's/^DRY_RUN_JSON: //'; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-iva.XXXXXX)
  TMP_STATE=$(mktemp -d -t omc-iva-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="iva-$$-$BATS_TEST_NUMBER"
  export OHMYCLAW_ASK_MOCK=1   # presentation 발화 dry-run (실 openclaw 미호출)
  mock_bin acpx
}
teardown() {
  unmock_bin
  [[ -d "$TMP_HOME" ]]  && rm -rf "$TMP_HOME"
  [[ -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_HOME OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID OHMYCLAW_ASK_MOCK
}

# ── 1. start: command-action 버튼 발화 + 세션 awaiting=goal ───────────────────
@test "start emits command-action buttons and awaits goal" {
  run cl interview start "결제 모듈" --to 12345
  [ "$status" -eq 0 ]
  local j; j=$(dry_json "$output")
  [ "$(echo "$j" | jq -r '.blocks[1].buttons[0].action.type')" = "command" ]
  [ "$(echo "$j" | jq -r '.blocks[1].buttons[0].action.command')" = "/omc_iv feature" ]
  [[ "$j" == *'/omc_iv __other__'* ]]
  run cl interview status
  [ "$(echo "$output" | jq -r '.awaiting')" = "goal" ]
}

# ── 2. start --to 누락 → exit 2 ──────────────────────────────────────────────
@test "start without --to exits 2" {
  run cl interview start "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"chatId"* ]]
}

# ── 3. answer 가 차원을 진행시킨다 ───────────────────────────────────────────
@test "answer advances through dimensions" {
  cl interview start "결제" --to 7 >/dev/null
  run cl interview answer feature
  [ "$status" -eq 0 ]
  [ "$(echo "$(json_line "$output")" | jq -r '.dimension')" = "constraint" ]
  run cl interview answer no-break
  [ "$(echo "$(json_line "$output")" | jq -r '.dimension')" = "success" ]
}

# ── 4. 전체 시퀀스 → finalize: mode:async, degraded:false, 실제 답변 ──────────
@test "full sequence finalizes with degraded:false and real answers" {
  cl interview start "결제" --to 7 >/dev/null
  cl interview answer feature  >/dev/null
  cl interview answer no-break >/dev/null
  run cl interview answer tests
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.mode')" = "async" ]
  [ "$(echo "$j" | jq -r '.degraded')" = "false" ]
  [ "$(echo "$j" | jq -r '.fallbackCount')" -eq 0 ]
  [ "$(echo "$j" | jq -r '[.answers[].fallback] | any')" = "false" ]
  [ "$(echo "$j" | jq -r '.answers[0].answer')" = "feature" ]
}

# ── 5. 조기 종료: goal+constraint+success 후 context 생략 (rounds=3) ──────────
@test "early-stop skips context after three answers" {
  cl interview start "결제" --to 7 >/dev/null
  cl interview answer feature  >/dev/null
  cl interview answer no-break >/dev/null
  run cl interview answer tests
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.rounds')" -eq 3 ]
  [ "$(echo "$j" | jq -r '[.answers[].dimension] | index("context") // "none"')" = "none" ]
}

# ── 6. finalize 후 세션 청소 + interview-result(async) 저장 ──────────────────
@test "session cleared and interview-result persisted after finalize" {
  cl interview start "결제" --to 7 >/dev/null
  cl interview answer feature  >/dev/null
  cl interview answer no-break >/dev/null
  cl interview answer tests    >/dev/null
  run cl interview status
  [ "$(echo "$output" | jq -r '.status')" = "none" ]
  run cl state read interview-result
  [ "$(echo "$output" | jq -r '.mode')" = "async" ]
  [ "$(echo "$output" | jq -r '.degraded')" = "false" ]
}

# ── 7. Other → 자유입력 요청, awaiting 유지 → free-text 처리 ─────────────────
@test "other prompts free-text and keeps awaiting; free text recorded" {
  cl interview start "X" --to 7 >/dev/null
  run cl interview answer __other__
  [ "$(echo "$(json_line "$output")" | jq -r '.status')" = "awaiting-freetext" ]
  run cl interview status
  [ "$(echo "$output" | jq -r '.awaiting')" = "goal" ]
  cl interview answer "새 결제 API 구현 작업" >/dev/null
  run cl interview status
  [ "$(echo "$output" | jq -r '.answers')" -eq 1 ]
  [[ "$(echo "$output" | jq -r '.crystallized')" == *"새 결제 API 구현 작업"* ]]
}

# ── 8. 세션 없이 answer → exit 2 ─────────────────────────────────────────────
@test "answer without session exits 2" {
  run cl interview answer feature
  [ "$status" -eq 2 ]
  [[ "$output" == *"세션 없음"* ]]
}

# ── 9. cancel 이 세션 청소 ───────────────────────────────────────────────────
@test "cancel clears the session" {
  cl interview start "X" --to 7 >/dev/null
  run cl interview cancel
  [ "$(echo "$output" | jq -r '.status')" = "cancelled" ]
  run cl interview status
  [ "$(echo "$output" | jq -r '.status')" = "none" ]
}

# ── 10. 이미 명확한 topic → start 즉시 finalize (0 라운드) ────────────────────
@test "already-clear topic finalizes immediately at start" {
  run cl interview start "src/auth.ts 의 login() 버그 수정 작업, 기존 동작 보존(스택 유지), 테스트 통과 완료조건" --to 7
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.rounds')" -eq 0 ]
  [ "$(echo "$j" | jq -r '.degraded')" = "false" ]
}

# ── 11. 동기 모드는 그대로 (회귀 가드) ───────────────────────────────────────
@test "synchronous interview <topic> still works (no subcommand)" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests"
  run cl interview "결제"
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.rounds')" -eq 3 ]
  [ "$(echo "$j" | jq -r '.degraded')" = "false" ]
}
