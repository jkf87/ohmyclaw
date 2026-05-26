#!/usr/bin/env bats
# cli.sh gap-gate — GAP_DETECTED 후속 결정 게이트 (Anchor 2)

load helpers

cl() { "$SKILL_DIR/cli.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-gap.XXXXXX)
  TMP_STATE=$(mktemp -d -t omc-gap-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="gap-test-$$-$BATS_TEST_NUMBER"
  mock_bin acpx
}
teardown() {
  unmock_bin
  [[ -d "$TMP_HOME"  ]] && rm -rf "$TMP_HOME"
  [[ -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_HOME OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID
  unset OHMYCLAW_ASK_MOCK OHMYCLAW_GAP_MOCK_RESPONSE
}

@test "gap-gate APPROVE verdict passes through with action=none" {
  run bash -c 'echo "{\"verdict\":\"APPROVE\"}" | "$0" gap-gate --to test --dry-run' "$SKILL_DIR/cli.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "none"' >/dev/null
  echo "$output" | jq -e '.verdict == "APPROVE"' >/dev/null
}

@test "gap-gate REQUEST_CHANGES verdict passes through with action=none" {
  run bash -c 'echo "{\"verdict\":\"REQUEST_CHANGES\"}" | "$0" gap-gate --to test --dry-run' "$SKILL_DIR/cli.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "none"' >/dev/null
  echo "$output" | jq -e '.verdict == "REQUEST_CHANGES"' >/dev/null
}

@test "gap-gate non-JSON stdin passes through with action=none verdict=unknown" {
  run bash -c 'echo "not json text" | "$0" gap-gate --to test --dry-run' "$SKILL_DIR/cli.sh"
  [ "$status" -eq 0 ]
  # action=none verdict=unknown — but stderr has the original text
  [[ "$output" == *'"action":"none"'* ]]
  [[ "$output" == *'"verdict":"unknown"'* ]]
}

@test "gap-gate GAP_DETECTED apply-fix returns action=fix-loop with direction" {
  export OHMYCLAW_ASK_MOCK=1
  export OHMYCLAW_GAP_MOCK_RESPONSE=apply-fix
  run bash -c 'echo "{\"verdict\":\"GAP_DETECTED\",\"gapType\":\"scope_creep\",\"gapReason\":\"X added\",\"fixDirection\":\"remove X\"}" | "$0" gap-gate --to test' "$SKILL_DIR/cli.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "fix-loop"' >/dev/null
  echo "$output" | jq -e '.verdict == "GAP_DETECTED"' >/dev/null
  echo "$output" | jq -e '.direction == "remove X"' >/dev/null
}

@test "gap-gate GAP_DETECTED ignore-gap returns action=force-approve" {
  export OHMYCLAW_ASK_MOCK=1
  export OHMYCLAW_GAP_MOCK_RESPONSE=ignore-gap
  run bash -c 'echo "{\"verdict\":\"GAP_DETECTED\",\"gapType\":\"scope_creep\",\"gapReason\":\"X\",\"fixDirection\":\"Y\"}" | "$0" gap-gate --to test' "$SKILL_DIR/cli.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "force-approve"' >/dev/null
  echo "$output" | jq -e '.verdict == "APPROVE"' >/dev/null
}

@test "gap-gate GAP_DETECTED free-text returns action=escalated" {
  export OHMYCLAW_ASK_MOCK=1
  export OHMYCLAW_GAP_MOCK_RESPONSE="rework from scratch"
  run bash -c 'echo "{\"verdict\":\"GAP_DETECTED\",\"gapType\":\"scope_creep\",\"gapReason\":\"X\",\"fixDirection\":\"Y\"}" | "$0" gap-gate --to test' "$SKILL_DIR/cli.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "escalated"' >/dev/null
  echo "$output" | jq -e '.verdict == "ESCALATED"' >/dev/null
  echo "$output" | jq -e '.userInput == "rework from scratch"' >/dev/null
}

@test "gap-gate GAP_DETECTED without --to exits 2" {
  run bash -c 'echo "{\"verdict\":\"GAP_DETECTED\",\"gapType\":\"scope_creep\",\"gapReason\":\"X\",\"fixDirection\":\"Y\"}" | "$0" gap-gate' "$SKILL_DIR/cli.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--to is required"* ]]
}

@test "gap-gate --timeout invalid exits 2" {
  run cl gap-gate --to test --timeout 999
  [ "$status" -eq 2 ]
}

@test "gap-gate --dry-run defaults to apply-fix when no mock env" {
  run bash -c 'echo "{\"verdict\":\"GAP_DETECTED\",\"gapType\":\"scope_creep\",\"gapReason\":\"X\",\"fixDirection\":\"Y\"}" | "$0" gap-gate --to test --dry-run' "$SKILL_DIR/cli.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.action == "fix-loop"' >/dev/null
}

@test "gap-gate help mentions verb" {
  run cl help
  [[ "$output" == *"gap-gate"* ]]
}
