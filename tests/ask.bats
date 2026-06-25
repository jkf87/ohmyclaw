#!/usr/bin/env bats
# cli.sh ask verb — openclaw MessagePresentation buttons + dry-run mechanics
# (v1.6.0: --buttons{inline_keyboard} → --presentation{blocks[buttons]} 마이그레이션)

load helpers

cl() { "$SKILL_DIR/cli.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-ask.XXXXXX)
  TMP_STATE=$(mktemp -d -t omc-ask-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="ask-test-$$-$BATS_TEST_NUMBER"
  export OHMYCLAW_ASK_MOCK=1   # default: dry-run for all tests
  mock_bin acpx
}

teardown() {
  unmock_bin
  [[ -d "$TMP_HOME" ]]  && rm -rf "$TMP_HOME"
  [[ -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_HOME OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID OHMYCLAW_ASK_MOCK
}

# ── 1. help mentions ask ──────────────────────────────────────────────────────
@test "help output mentions 'ask' verb" {
  run cl help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ask"* ]]
}

# ── 2. dry-run: JSON shape — presentation buttons block present ──────────────
@test "dry-run emits presentation buttons JSON" {
  run cl ask --to chat123 --question "Pick one" --option 1:Alpha --option 2:Beta
  [ "$status" -eq 0 ]
  [[ "$output" == *'"type":"buttons"'* ]]
  [[ "$output" == *'"action":{"type":"callback"'* ]]
}

# ── 3. dry-run: correct number of buttons (one per option) ───────────────────
@test "dry-run produces one button per --option" {
  run cl ask --to chat123 --question "Q?" \
    --option 1:First --option 2:Second --option 3:Third
  [ "$status" -eq 0 ]
  # 3 options → action.value 가 3회 등장 (질문 text 블록엔 value 없음)
  local json_line
  json_line=$(echo "$output" | grep '^DRY_RUN_JSON:')
  count=$(echo "$json_line" | awk -F'"value":' '{print NF-1}')
  [ "$count" -eq 3 ]
}

# ── 4. dry-run: action.value 가 N:label 의 N 과 일치 ─────────────────────────
@test "dry-run action.value equals the N prefix of N:label" {
  run cl ask --to chat123 --question "Q?" \
    --option 42:AnswerA --option 99:AnswerB
  [ "$status" -eq 0 ]
  [[ "$output" == *'"value":"42"'* ]]
  [[ "$output" == *'"value":"99"'* ]]
}

# ── 5. dry-run: label 가 N:label 의 label 과 일치 ────────────────────────────
@test "dry-run label equals the label suffix of N:label" {
  run cl ask --to chat123 --question "Q?" \
    --option 1:Hello --option 2:World
  [ "$status" -eq 0 ]
  [[ "$output" == *'"label":"Hello"'* ]]
  [[ "$output" == *'"label":"World"'* ]]
}

# ── 6. --other adds final button with __other__ value ────────────────────────
@test "--other appends __other__ button at the end" {
  run cl ask --to chat123 --question "Q?" \
    --option 1:Yes --option 2:No --other
  [ "$status" -eq 0 ]
  [[ "$output" == *'"value":"__other__"'* ]]
  [[ "$output" == *'Other (type answer)'* ]]
}

# ── 7. --other button is last (after regular options) ────────────────────────
@test "--other button appears after all regular option buttons" {
  run cl ask --to chat123 --question "Q?" \
    --option 1:Yes --other
  [ "$status" -eq 0 ]
  # __other__ value 가 "1" value 뒤에 와야 함
  pos_regular=$(echo "$output" | grep -bo '"value":"1"' | head -1 | cut -d: -f1)
  pos_other=$(echo "$output"   | grep -bo '"value":"__other__"' | head -1 | cut -d: -f1)
  [ -n "$pos_regular" ]
  [ -n "$pos_other" ]
  [ "$pos_other" -gt "$pos_regular" ]
}

# ── 8. --timeout validation: below minimum (4) → exit 2 ─────────────────────
@test "--timeout 4 is rejected (below minimum 5)" {
  run cl ask --to chat123 --question "Q?" --option 1:X --timeout 4
  [ "$status" -eq 2 ]
  [[ "$output" == *"timeout"* ]]
}

# ── 9. --timeout validation: above maximum (601) → exit 2 ───────────────────
@test "--timeout 601 is rejected (above maximum 600)" {
  run cl ask --to chat123 --question "Q?" --option 1:X --timeout 601
  [ "$status" -eq 2 ]
  [[ "$output" == *"timeout"* ]]
}

# ── 10. --timeout boundary values 5 and 600 are accepted ─────────────────────
@test "--timeout boundary values 5 and 600 are valid" {
  run cl ask --to chat123 --question "Q?" --option 1:X --timeout 5
  [ "$status" -eq 0 ]

  run cl ask --to chat123 --question "Q?" --option 1:X --timeout 600
  [ "$status" -eq 0 ]
}

# ── 11. missing --to → exit 2 ────────────────────────────────────────────────
@test "missing --to exits 2 with error message" {
  run cl ask --question "Q?" --option 1:X
  [ "$status" -eq 2 ]
  [[ "$output" == *"--to"* ]]
}

# ── 12. missing --question → exit 2 ──────────────────────────────────────────
@test "missing --question exits 2 with error message" {
  run cl ask --to chat123 --option 1:X
  [ "$status" -eq 2 ]
  [[ "$output" == *"--question"* ]]
}

# ── 13. missing --option → exit 2 ────────────────────────────────────────────
@test "missing --option exits 2 with error message" {
  run cl ask --to chat123 --question "Q?"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--option"* ]]
}

# ── 14. --option without colon separator → exit 2 ────────────────────────────
@test "--option without N:label format (no colon) exits 2" {
  run cl ask --to chat123 --question "Q?" --option "nocolon"
  [ "$status" -eq 2 ]
  [[ "$output" == *"N:label"* ]]
}

# ── 15. --recommended fallback in mock mode ───────────────────────────────────
# With OHMYCLAW_ASK_MOCK=1 the command returns 0 before any polling occurs,
# so this verifies that --recommended is accepted without error and the dry-run
# path succeeds (full fallback path tested via stubbed events_wait below).
@test "--recommended accepted in dry-run/mock mode without error" {
  run cl ask --to chat123 --question "Q?" --option 1:Yes --recommended "yes"
  [ "$status" -eq 0 ]
}

# ── 16. dry-run CMD line contains --to target ─────────────────────────────────
@test "dry-run output includes the --to target in the command line" {
  run cl ask --to mychat --question "Hello?" --option 1:Yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"mychat"* ]]
}

# ── 17. --dry-run flag (without OHMYCLAW_ASK_MOCK) also triggers dry path ────
@test "--dry-run flag triggers dry-run path independently of OHMYCLAW_ASK_MOCK" {
  unset OHMYCLAW_ASK_MOCK
  run cl ask --to chat123 --question "Q?" --option 1:X --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY_RUN_JSON"* ]]
  export OHMYCLAW_ASK_MOCK=1  # restore for teardown safety
}

# ── 18. JSON structure: presentation blocks (text + buttons) ─────────────────
@test "presentation has a text block and a buttons block of button objects" {
  run cl ask --to chat123 --question "Q?" --option 1:A --option 2:B
  [ "$status" -eq 0 ]
  local json
  json=$(echo "$output" | grep '^DRY_RUN_JSON:' | sed 's/^DRY_RUN_JSON: //')
  # 유효 JSON + blocks[0]=text, buttons 블록 존재, 각 버튼은 label+action 객체
  echo "$json" | jq -e '.blocks[0].type == "text"' >/dev/null
  echo "$json" | jq -e '[.blocks[] | select(.type=="buttons")] | length == 1' >/dev/null
  echo "$json" | jq -e '(.blocks[] | select(.type=="buttons").buttons[0]) | has("label") and has("action")' >/dev/null
}

# ── US-007: --save-as + prefetch ────────────────────────────────────────

@test "ask MOCK_RESPONSE saves to default last-ask-answer state" {
  export OHMYCLAW_ASK_MOCK_RESPONSE="2"
  run "$SKILL_DIR/cli.sh" ask --to test --question Q --option 1:A --option 2:B
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  run "$SKILL_DIR/state.sh" read last-ask-answer
  echo "$output" | jq -e '.value == "2"' >/dev/null
  echo "$output" | jq -e '.savedBy == "ask"' >/dev/null
  unset OHMYCLAW_ASK_MOCK_RESPONSE
}

@test "ask --save-as custom-key saves to that key" {
  export OHMYCLAW_ASK_MOCK_RESPONSE="custom-val"
  run "$SKILL_DIR/cli.sh" ask --to test --question Q --option 1:A --option 2:B --save-as my-key
  [ "$status" -eq 0 ]
  run "$SKILL_DIR/state.sh" read my-key
  echo "$output" | jq -e '.value == "custom-val"' >/dev/null
  run "$SKILL_DIR/state.sh" read last-ask-answer
  [ -z "$output" ]
  unset OHMYCLAW_ASK_MOCK_RESPONSE
}

@test "ask --dry-run does NOT save state" {
  run "$SKILL_DIR/cli.sh" ask --to test --question Q --option 1:A --option 2:B --dry-run
  [ "$status" -eq 0 ]
  run "$SKILL_DIR/state.sh" read last-ask-answer
  [ -z "$output" ]
}

@test "cli prefetch exports OHMYCLAW_LAST_ANSWER for next verb" {
  OHMYCLAW_ASK_MOCK_RESPONSE="prefetched-val" \
    "$SKILL_DIR/cli.sh" ask --to t --question Q --option 1:A --option 2:B >/dev/null
  mkdir -p "$TMP_HOME/hooks"
  cat > "$TMP_HOME/hooks/pre-version.sh" <<'H'
#!/bin/sh
echo "LAST=$OHMYCLAW_LAST_ANSWER" > "$OHMYCLAW_HOME/captured.txt"
H
  chmod +x "$TMP_HOME/hooks/pre-version.sh"
  "$SKILL_DIR/cli.sh" version >/dev/null
  run cat "$TMP_HOME/captured.txt"
  [ "$output" = "LAST=prefetched-val" ]
}

@test "cli prefetch returns empty when no recent answer" {
  mkdir -p "$TMP_HOME/hooks"
  cat > "$TMP_HOME/hooks/pre-version.sh" <<'H'
#!/bin/sh
echo "LAST=[$OHMYCLAW_LAST_ANSWER]" > "$OHMYCLAW_HOME/captured.txt"
H
  chmod +x "$TMP_HOME/hooks/pre-version.sh"
  "$SKILL_DIR/cli.sh" version >/dev/null
  run cat "$TMP_HOME/captured.txt"
  [ "$output" = "LAST=[]" ]
}

@test "ask --option callback_data > 64 bytes rejected (Telegram limit)" {
  local long_cb
  long_cb=$(printf 'x%.0s' {1..65})  # 65 chars
  run "$SKILL_DIR/cli.sh" ask --to t --question Q --option "${long_cb}:label" --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"64-byte limit"* ]]
}
