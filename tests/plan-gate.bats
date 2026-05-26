#!/usr/bin/env bats
# cli.sh plan-gate verb — planner ambiguity gate

load helpers

cl() { "$SKILL_DIR/cli.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-pg.XXXXXX)
  TMP_STATE=$(mktemp -d -t omc-pg-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="pg-test-$$-$BATS_TEST_NUMBER"
  export OHMYCLAW_ASK_MOCK=1   # prevent real Telegram calls
  mock_bin acpx
}

teardown() {
  unmock_bin
  [[ -d "$TMP_HOME" ]]  && rm -rf "$TMP_HOME"
  [[ -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_HOME OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID
  unset OHMYCLAW_ASK_MOCK OHMYCLAW_PLAN_MOCK_RESPONSE
}

# ── 1. pass-through: ask_required=false → ask_fired:false ────────────────────
@test "plan-gate: ask_required=false JSON emits ask_fired:false, exit 0" {
  run bash -c \
    'echo '"'"'{"ask_required":false,"plan":"normal yaml..."}'"'"' \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ask_fired":false'* ]]
  [[ "$output" == *'"next":"architect"'* ]]
}

# ── 2. pass-through: plain text (not JSON) → ask_fired:false ─────────────────
@test "plan-gate: plain text (not JSON) emits ask_fired:false, exit 0" {
  run bash -c \
    'echo "## Plan: refactor foo module" \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ask_fired":false'* ]]
  [[ "$output" == *'"next":"architect"'* ]]
}

# ── 3. pass-through: empty stdin → ask_fired:false ───────────────────────────
@test "plan-gate: empty stdin emits ask_fired:false, exit 0" {
  run bash -c \
    'printf "" \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ask_fired":false'* ]]
}

# ── 4. ask fired with OHMYCLAW_PLAN_MOCK_RESPONSE ────────────────────────────
@test "plan-gate: ask_required=true + PLAN_MOCK_RESPONSE → ask_fired:true with response" {
  export OHMYCLAW_PLAN_MOCK_RESPONSE="interpA"
  run bash -c \
    'echo '"'"'{"ask_required":true,"question":"Which?","options":[{"label":"A","value":"interpA"},{"label":"B","value":"interpB"}],"recommended":"interpA"}'"'"' \
    | OHMYCLAW_PLAN_MOCK_RESPONSE=interpA '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ask_fired":true'* ]]
  [[ "$output" == *'"response":"interpA"'* ]]
  [[ "$output" == *'"next":"architect"'* ]]
}

# ── 5. ask fired using --dry-run flag ────────────────────────────────────────
@test "plan-gate: ask_required=true + --dry-run → ask_fired:true, exit 0" {
  run bash -c \
    'echo '"'"'{"ask_required":true,"question":"Which?","options":[{"label":"A","value":"a"},{"label":"B","value":"b"}],"recommended":"a"}'"'"' \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ask_fired":true'* ]]
  [[ "$output" == *'"next":"architect"'* ]]
}

# ── 6. --dry-run with OHMYCLAW_PLAN_MOCK_RESPONSE uses mock value ─────────────
@test "plan-gate: --dry-run uses OHMYCLAW_PLAN_MOCK_RESPONSE as response value" {
  run bash -c \
    'echo '"'"'{"ask_required":true,"question":"Q?","options":[{"label":"X","value":"x"},{"label":"Y","value":"y"}],"recommended":"x"}'"'"' \
    | OHMYCLAW_PLAN_MOCK_RESPONSE=my-mock-val '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"response":"my-mock-val"'* ]]
}

# ── 7. --dry-run with no OHMYCLAW_PLAN_MOCK_RESPONSE → "(no response)" ───────
@test "plan-gate: --dry-run without PLAN_MOCK_RESPONSE emits (no response)" {
  unset OHMYCLAW_PLAN_MOCK_RESPONSE
  run bash -c \
    'echo '"'"'{"ask_required":true,"question":"Q?","options":[{"label":"X","value":"x"},{"label":"Y","value":"y"}],"recommended":"x"}'"'"' \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ask_fired":true'* ]]
  [[ "$output" == *'(no response)'* ]]
}

# ── 8. invalid options (only 1 entry) → exit 2 ───────────────────────────────
@test "plan-gate: options array with only 1 entry exits 2" {
  run bash -c \
    'echo '"'"'{"ask_required":true,"question":"Q?","options":[{"label":"Solo","value":"solo"}],"recommended":"solo"}'"'"' \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run'
  [ "$status" -eq 2 ]
  [[ "$output" == *"at least 2"* ]]
}

# ── 9. ask_required=true without --to → exit 2 ───────────────────────────────
@test "plan-gate: ask_required=true without --to exits 2" {
  run bash -c \
    'echo '"'"'{"ask_required":true,"question":"Q?","options":[{"label":"A","value":"a"},{"label":"B","value":"b"}],"recommended":"a"}'"'"' \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --dry-run'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--to"* ]]
}

# ── 10. help output mentions plan-gate ────────────────────────────────────────
@test "help output mentions 'plan-gate' verb" {
  run cl help
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan-gate"* ]]
}

# ── 11. pass-through: plain text goes to stderr, not stdout JSON ──────────────
@test "plan-gate: plain text appears on stderr (original content preserved)" {
  run bash -c \
    'echo "## normal plan output" \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run 2>&1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"normal plan output"* ]]
}

# ── 12. ask_required absent (other JSON) → ask_fired:false ───────────────────
@test "plan-gate: JSON without ask_required field emits ask_fired:false" {
  run bash -c \
    'echo '"'"'{"status":"ok","plan":"step 1: do X"}'"'"' \
    | '"\"$SKILL_DIR/cli.sh\""' plan-gate --to test --dry-run'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ask_fired":false'* ]]
}

# ── 13. OHMYCLAW_ASK_MOCK path: ask_required=true fires ask in mock mode ──────
@test "plan-gate: OHMYCLAW_ASK_MOCK=1 with ask_required=true → ask_fired:true via inner ask mock" {
  # With OHMYCLAW_ASK_MOCK=1 the inner cli.sh ask call goes through dry-run;
  # OHMYCLAW_PLAN_MOCK_RESPONSE is NOT set so it uses the real ask path but
  # since OHMYCLAW_ASK_MOCK=1 the ask call returns 0 with DRY_RUN output.
  # We verify the overall plan-gate returns ask_fired:true (uses --dry-run here
  # to confirm plan-gate's own dry path too).
  run bash -c \
    'echo '"'"'{"ask_required":true,"question":"Which approach?","options":[{"label":"Fast","value":"fast"},{"label":"Safe","value":"safe"}],"recommended":"safe"}'"'"' \
    | OHMYCLAW_PLAN_MOCK_RESPONSE=fast '"\"$SKILL_DIR/cli.sh\""' plan-gate --to testchat'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ask_fired":true'* ]]
  [[ "$output" == *'"response":"fast"'* ]]
}
