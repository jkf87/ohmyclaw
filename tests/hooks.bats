#!/usr/bin/env bats
# hooks.sh — pre/post hook dispatcher

load helpers

hk() { "$SKILL_DIR/hooks.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-hooks.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  mkdir -p "$TMP_HOME/hooks"
}
teardown() {
  [[ -n "${TMP_HOME:-}" && -d "$TMP_HOME" ]] && rm -rf "$TMP_HOME"
  unset OHMYCLAW_HOME OHMYCLAW_SESSION_ID
}

@test "fire with absent hook is silent no-op exit 0" {
  run hk fire pre doctor
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fire pre hook executes and propagates exit 0" {
  cat > "$TMP_HOME/hooks/pre-doctor.sh" <<'H'
#!/bin/sh
echo "fired pre-doctor"
exit 0
H
  chmod +x "$TMP_HOME/hooks/pre-doctor.sh"
  run hk fire pre doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired pre-doctor"* ]]
}

@test "fire pre hook failure returns exit 7 (action abort)" {
  cat > "$TMP_HOME/hooks/pre-route.sh" <<'H'
#!/bin/sh
echo "deny" >&2
exit 99
H
  chmod +x "$TMP_HOME/hooks/pre-route.sh"
  run hk fire pre route "task"
  [ "$status" -eq 7 ]
}

@test "fire post hook failure does NOT abort (exit 0 + warning)" {
  cat > "$TMP_HOME/hooks/post-route.sh" <<'H'
#!/bin/sh
exit 5
H
  chmod +x "$TMP_HOME/hooks/post-route.sh"
  run hk fire post route
  [ "$status" -eq 0 ]
  [[ "$output" == *"post-route hook failed"* ]]
}

@test "hook receives OHMYCLAW_ACTION/PHASE/HOME/SESSION env" {
  cat > "$TMP_HOME/hooks/pre-exec.sh" <<'H'
#!/bin/sh
printf 'A=%s P=%s S=%s H=%s\n' "$OHMYCLAW_ACTION" "$OHMYCLAW_PHASE" "$OHMYCLAW_SESSION" "$OHMYCLAW_HOME"
H
  chmod +x "$TMP_HOME/hooks/pre-exec.sh"
  OHMYCLAW_SESSION_ID=mysess run hk fire pre exec
  [ "$status" -eq 0 ]
  [[ "$output" == *"A=exec"* ]]
  [[ "$output" == *"P=pre"* ]]
  [[ "$output" == *"S=mysess"* ]]
  [[ "$output" == *"H=$TMP_HOME"* ]]
}

@test "hook receives OHMYCLAW_ARGS_JSON as JSON array of args" {
  cat > "$TMP_HOME/hooks/pre-team.sh" <<'H'
#!/bin/sh
printf 'JSON=%s' "$OHMYCLAW_ARGS_JSON"
H
  chmod +x "$TMP_HOME/hooks/pre-team.sh"
  run hk fire pre team 3 "refactor X"
  [ "$status" -eq 0 ]
  [[ "$output" == *'JSON=["3","refactor X"]'* ]]
}

@test "non-executable hook is ignored (no-op)" {
  echo "should not run" > "$TMP_HOME/hooks/pre-debug.sh"
  # NOT chmod +x
  run hk fire pre debug
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "invalid phase rejected exit 2" {
  run hk fire BOGUS doctor
  [ "$status" -eq 2 ]
}

@test "missing args usage" {
  run hk fire
  [ "$status" -eq 2 ]
}

@test "list with no hooks reports absence cleanly" {
  rm -rf "$TMP_HOME/hooks"
  run hk list
  [ "$status" -eq 0 ]
  [[ "$output" == *"hooks dir absent"* ]]
}

@test "list shows installed hooks with executable marker" {
  cat > "$TMP_HOME/hooks/pre-doctor.sh" <<'H'
#!/bin/sh
:
H
  chmod +x "$TMP_HOME/hooks/pre-doctor.sh"
  echo "raw" > "$TMP_HOME/hooks/post-doctor.sh"   # not executable
  run hk list
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-doctor.sh*"* ]]
  [[ "$output" == *"post-doctor.sh (not executable)"* ]]
}
