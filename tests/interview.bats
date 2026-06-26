#!/usr/bin/env bats
# cli.sh interview verb — Socratic 인터뷰 (우로보로스 정합)
# 4차원 명확성 버튼 질문 + crystallize 누적 + ambiguity 조기 종료

load helpers

cl() { "$SKILL_DIR/cli.sh" "$@"; }

# 출력에서 마지막 JSON 라인만 추출 (lifecycle/state 부수 출력 무시)
json_line() { echo "$1" | grep -E '^\{' | tail -1; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-iv.XXXXXX)
  TMP_STATE=$(mktemp -d -t omc-iv-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="iv-test-$$-$BATS_TEST_NUMBER"
  mock_bin acpx
}

teardown() {
  unmock_bin
  [[ -d "$TMP_HOME" ]]  && rm -rf "$TMP_HOME"
  [[ -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_HOME OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID OHMYCLAW_INTERVIEW_MOCK_RESPONSES
}

# ── 1. help 가 interview 를 언급 ──────────────────────────────────────────────
@test "help output mentions 'interview' verb" {
  run cl help
  [ "$status" -eq 0 ]
  [[ "$output" == *"interview"* ]]
}

# ── 2. dry-run: 4 차원 키보드 모두 컴파일 ─────────────────────────────────────
@test "dry-run emits one keyboard per dimension (goal/constraint/success/context)" {
  run cl interview --to chat1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY_RUN_DIMENSION: goal"* ]]
  [[ "$output" == *"DRY_RUN_DIMENSION: constraint"* ]]
  [[ "$output" == *"DRY_RUN_DIMENSION: success"* ]]
  [[ "$output" == *"DRY_RUN_DIMENSION: context"* ]]
}

# ── 3. dry-run: 각 차원에 presentation buttons + Other 버튼 ──────────────────
@test "dry-run keyboards contain presentation buttons and Other button" {
  run cl interview --to chat1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"buttons"'* ]]
  [[ "$output" == *'"value":"__other__"'* ]]
}

# ── 4. 조기 종료: 기본 threshold 0.2 → goal+constraint+success 후 중단 ───────
@test "mock responses early-stop at ambiguity<=0.2 (context skipped)" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests,module"
  run cl interview ""
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.rounds')" -eq 3 ]
  [ "$(echo "$j" | jq -r '.ambiguous')" = "false" ]
  # context 차원은 묻지 않았다
  [ "$(echo "$j" | jq -r '[.answers[].dimension] | index("context") // "none"')" = "none" ]
}

# ── 5. 낮은 threshold → 4 차원 모두 질문 ──────────────────────────────────────
@test "lower threshold 0.1 asks all four dimensions" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests,module"
  run cl interview "" --threshold 0.1
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.rounds')" -eq 4 ]
  [ "$(echo "$j" | jq -r '.answers | length')" -eq 4 ]
}

# ── 6. 이미 명확한 topic → 0 라운드 (질문 없음) ──────────────────────────────
@test "already-clear topic yields zero rounds" {
  run cl interview "src/auth.ts 의 login() 버그 수정 작업, 기존 동작 보존(스택 유지), 테스트 통과 완료조건"
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.rounds')" -eq 0 ]
  [ "$(echo "$j" | jq -r '.ambiguous')" = "false" ]
}

# ── 7. Other 자유응답은 절(clause)로 그대로 매핑 ─────────────────────────────
@test "free-text (Other) answer maps verbatim into clause" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="우리만의 자유로운 목표 서술"
  run cl interview "" --threshold 0.9
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.answers[0].answer')" = "우리만의 자유로운 목표 서술" ]
  [[ "$(echo "$j" | jq -r '.answers[0].clause')" == *"우리만의 자유로운 목표 서술"* ]]
}

# ── 8. 결과가 state(interview-result)에 저장 ─────────────────────────────────
@test "result persisted to state under interview-result" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests"
  run cl interview ""
  [ "$status" -eq 0 ]
  run cl state read interview-result
  [ "$status" -eq 0 ]
  [[ "$output" == *'"savedBy":"interview"'* ]]
  [[ "$output" == *'"crystallized"'* ]]
}

# ── 9. --save-as 커스텀 키 ────────────────────────────────────────────────────
@test "--save-as writes to a custom state key" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests"
  run cl interview "" --save-as my-seed
  [ "$status" -eq 0 ]
  run cl state read my-seed
  [ "$status" -eq 0 ]
  [[ "$output" == *'"savedBy":"interview"'* ]]
}

# ── 10. crystallized 는 topic + 절을 누적 ────────────────────────────────────
@test "crystallized accumulates topic and clauses" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests"
  run cl interview "결제 모듈"
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [[ "$(echo "$j" | jq -r '.crystallized')" == "결제 모듈"* ]]
  [[ "$(echo "$j" | jq -r '.crystallized')" == *"목표:"* ]]
  [[ "$(echo "$j" | jq -r '.crystallized')" == *"제약:"* ]]
}

# ── 11. answers 길이 == rounds ────────────────────────────────────────────────
@test "answers length equals rounds" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests,module"
  run cl interview "" --threshold 0.1
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  local rounds alen
  rounds=$(echo "$j" | jq -r '.rounds')
  alen=$(echo "$j" | jq -r '.answers | length')
  [ "$rounds" -eq "$alen" ]
}

# ── 12. 알 수 없는 인자 → exit 2 ─────────────────────────────────────────────
@test "unknown argument exits 2" {
  run cl interview "" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

# ── 13. mock 응답이 부족하면 recommended 로 폴백 ─────────────────────────────
@test "missing mock response falls back to recommended" {
  # 응답 1개만 제공, threshold 0.1 로 더 많은 질문 유도 → 2번째부터 recommended
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature"
  run cl interview "" --threshold 0.1
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  # constraint 의 recommended 는 no-break
  [ "$(echo "$j" | jq -r '.answers[1].answer')" = "no-break" ]
}

# ── 14. mock 응답은 fallback 아님 → degraded:false (정직성 B) ──────────────────
@test "mock-mode answers are not fallback (degraded false)" {
  export OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests"
  run cl interview "결제"
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.degraded')" = "false" ]
  [ "$(echo "$j" | jq -r '.fallbackCount')" -eq 0 ]
  [ "$(echo "$j" | jq -r '[.answers[].fallback] | any')" = "false" ]
}

# ── 15. 응답 채널 없으면 degraded + 답변별 fallback 표시 (조용한 가짜 성공 방지) ──
@test "real-mode without response channel flags degraded + per-answer fallback" {
  # openclaw 스텁: message send 성공, events wait 실패 → recommended 폴백 유도 (실 네트워크 없음)
  local stub; stub=$(mktemp -d)
  cat > "$stub/openclaw" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "message send") exit 0 ;;
  "events wait")  exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$stub/openclaw"
  local oldpath="$PATH"; export PATH="$stub:$PATH"
  run cl interview "결제"
  export PATH="$oldpath"; rm -rf "$stub"
  [ "$status" -eq 0 ]
  local j; j=$(json_line "$output")
  [ "$(echo "$j" | jq -r '.degraded')" = "true" ]
  local rounds fb; rounds=$(echo "$j" | jq -r '.rounds'); fb=$(echo "$j" | jq -r '.fallbackCount')
  [ "$fb" -eq "$rounds" ]
  [ "$(echo "$j" | jq -r '[.answers[].fallback] | all')" = "true" ]
  # 폴백 답변은 recommended 기본값
  [ "$(echo "$j" | jq -r '.answers[0].answer')" = "feature" ]
  # stderr 경고 노출
  [[ "$output" == *"DEGRADED"* ]]
}
