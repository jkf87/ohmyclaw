#!/usr/bin/env bats
# cli.sh commands verb — Telegram 슬래시 명령어 매니페스트 (list/json/botfather/register/dispatch/menu)

load helpers

cl() { "$SKILL_DIR/cli.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-cmd.XXXXXX)
  TMP_STATE=$(mktemp -d -t omc-cmd-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="cmd-test-$$-$BATS_TEST_NUMBER"
  export OHMYCLAW_COMMANDS_MOCK=1   # 기본: 부수효과 없는 dry-run
  mock_bin acpx
}

teardown() {
  unmock_bin
  [[ -d "$TMP_HOME" ]]  && rm -rf "$TMP_HOME"
  [[ -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_HOME OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID OHMYCLAW_COMMANDS_MOCK
}

# ── 1. help 가 commands 를 언급 ──────────────────────────────────────────────
@test "help output mentions 'commands' verb" {
  run cl help
  [ "$status" -eq 0 ]
  [[ "$output" == *"commands"* ]]
}

# ── 2. list: 사람용 표 + 화살표 매핑 ─────────────────────────────────────────
@test "list shows commands with verb mapping" {
  run cl commands list
  [ "$status" -eq 0 ]
  [[ "$output" == *"/omc_interview"* ]]
  [[ "$output" == *"→ cli.sh interview"* ]]
}

# ── 3. json: setMyCommands 페이로드 (유효 JSON 배열) ─────────────────────────
@test "json emits valid setMyCommands payload array" {
  run cl commands json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array"' >/dev/null
  echo "$output" | jq -e '.[0] | has("command") and has("description")' >/dev/null
}

# ── 4. json: 모든 command 이름이 Telegram 규격 (^[a-z0-9_]{1,32}$) ──────────
@test "json command names are valid Telegram tokens" {
  run cl commands json
  [ "$status" -eq 0 ]
  # 규격 위반 항목 수가 0 이어야 함
  local bad
  bad=$(echo "$output" | jq -r '[.[] | select(.command | test("^[a-z0-9_]{1,32}$") | not)] | length')
  [ "$bad" -eq 0 ]
}

# ── 5. botfather: "cmd - desc" 형식 (선행 슬래시 없음) ───────────────────────
@test "botfather format has no leading slash" {
  run cl commands botfather
  [ "$status" -eq 0 ]
  [[ "$output" == *"omc_interview - "* ]]
  [[ "$output" != *"/omc_interview"* ]]
}

# ── 6. register: setMyCommands JSON 페이로드 + 적용 가이드 emit ──────────────
@test "register emits setMyCommands payload and apply guidance" {
  run cl commands register --to default
  [ "$status" -eq 0 ]
  [[ "$output" == *"SET_MY_COMMANDS_JSON"* ]]
  [[ "$output" == *"setMyCommands"* ]]
  # payload 는 유효 JSON 배열
  local p
  p=$(echo "$output" | grep '^SET_MY_COMMANDS_JSON:' | sed 's/^SET_MY_COMMANDS_JSON: //')
  echo "$p" | jq -e 'type == "array" and (.[0]|has("command"))' >/dev/null
}

# ── 7. register: openclaw CLI 와 무관하게 동작 (호출 안 함) ──────────────────
@test "register works regardless of openclaw presence" {
  unset OHMYCLAW_COMMANDS_MOCK
  run cl commands register
  [ "$status" -eq 0 ]
  [[ "$output" == *"SET_MY_COMMANDS_JSON"* ]]
  [[ "$output" == *"BotFather"* ]]
}

# ── 8. menu --dry-run: command-action presentation, __menu__ 제외 ───────────
@test "menu dry-run emits command-action buttons excluding __menu__" {
  run cl commands menu --to chat9 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"buttons"'* ]]
  [[ "$output" == *'"command":"/omc_interview"'* ]]
  [[ "$output" == *'"type":"command"'* ]]
  # __menu__ 자기 자신은 팔레트에 없음
  [[ "$output" != *'"command":"/omc_menu"'* ]]
}

# ── 9. dispatch (mock): omc_ 접두 → verb 해석 ───────────────────────────────
@test "dispatch resolves omc_-prefixed command to verb" {
  run cl commands dispatch --to c1 "/omc_interview API 마이그레이션"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.resolved')" = "interview" ]
  [ "$(echo "$output" | jq -r '.args')" = "API 마이그레이션" ]
  [ "$(echo "$output" | jq -r '.to')" = "c1" ]
}

# ── 10. dispatch (mock): 친근한 bare alias ──────────────────────────────────
@test "dispatch resolves bare alias to verb" {
  run cl commands dispatch "/exec 로그인 고쳐줘"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.resolved')" = "exec" ]
  [ "$(echo "$output" | jq -r '.args')" = "로그인 고쳐줘" ]
}

# ── 11. dispatch: @botname 제거 ──────────────────────────────────────────────
@test "dispatch strips @botname suffix" {
  run cl commands dispatch "/omc_pool@MyBot status"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.resolved')" = "pool" ]
  [ "$(echo "$output" | jq -r '.args')" = "status" ]
}

# ── 12. dispatch: 2토큰 alias ("ohmyclaw interview") ────────────────────────
@test "dispatch resolves two-token alias" {
  run cl commands dispatch --to c2 "/ohmyclaw interview 결제 모듈"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.resolved')" = "interview" ]
  [ "$(echo "$output" | jq -r '.args')" = "결제 모듈" ]
}

# ── 13. dispatch: menu 의사-verb ─────────────────────────────────────────────
@test "dispatch resolves menu pseudo-verb" {
  run cl commands dispatch --to c1 "/omc_menu"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.resolved')" = "menu" ]
}

# ── 14. dispatch: 알 수 없는 명령 → exit 2 ──────────────────────────────────
@test "dispatch unknown command exits 2" {
  run cl commands dispatch "/nope foo"
  [ "$status" -eq 2 ]
  [[ "$output" == *"알 수 없는 명령"* ]]
}

# ── 15. dispatch: 메시지 누락 → exit 2 ──────────────────────────────────────
@test "dispatch without message exits 2" {
  run cl commands dispatch --to c1
  [ "$status" -eq 2 ]
}

# ── 16. 알 수 없는 하위명령 → exit 2 ─────────────────────────────────────────
@test "unknown subcommand exits 2" {
  run cl commands frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"알 수 없는 하위명령"* ]]
}

# ── 17. 매니페스트 verb 가 실제 cli.sh verb 와 정합 ──────────────────────────
@test "manifest verbs map to real cli.sh dispatch targets" {
  run cl commands json
  [ "$status" -eq 0 ]
  # interview/ask/exec/route/pool/doctor/cancel 는 실제 디스패치 대상
  run cl commands list
  [[ "$output" == *"cli.sh interview"* ]]
  [[ "$output" == *"cli.sh exec"* ]]
  [[ "$output" == *"cli.sh cancel"* ]]
}
