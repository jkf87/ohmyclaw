#!/usr/bin/env bats
# state.sh — session-scoped state helper

load helpers

st() { "$SKILL_DIR/state.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  unset OHMYCLAW_SESSION_ID
}
teardown() {
  [[ -n "${TMP_HOME:-}" && -d "$TMP_HOME" ]] && rm -rf "$TMP_HOME"
  unset OHMYCLAW_HOME OHMYCLAW_SESSION_ID
}

@test "write+read global mode" {
  st write k1 '{"x":1}'
  run st read k1
  [ "$status" -eq 0 ]
  [ "$output" = '{"x":1}' ]
}

@test "read missing key returns empty exit 0" {
  run st read nope
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "write rejects invalid JSON" {
  run st write k1 'not-json'
  [ "$status" -ne 0 ]
}

@test "write --stdin reads from stdin" {
  echo '{"from":"stdin"}' | st write k2 --stdin
  run st read k2
  [ "$output" = '{"from":"stdin"}' ]
}

@test "write --file reads from path" {
  echo '{"from":"file"}' > "$TMP_HOME/src.json"
  st write k3 --file "$TMP_HOME/src.json"
  run st read k3
  [ "$output" = '{"from":"file"}' ]
}

@test "session isolation: A and B keys do not cross" {
  OHMYCLAW_SESSION_ID=A st write greeting '{"who":"A"}'
  OHMYCLAW_SESSION_ID=B st write greeting '{"who":"B"}'
  run env OHMYCLAW_SESSION_ID=A "$SKILL_DIR/state.sh" read greeting
  [ "$output" = '{"who":"A"}' ]
  run env OHMYCLAW_SESSION_ID=B "$SKILL_DIR/state.sh" read greeting
  [ "$output" = '{"who":"B"}' ]
}

@test "global and session do not collide" {
  st write greeting '{"who":"global"}'
  OHMYCLAW_SESSION_ID=A st write greeting '{"who":"A"}'
  run st read greeting
  [ "$output" = '{"who":"global"}' ]
}

@test "clear removes key" {
  st write k1 '{"x":1}'
  st clear k1
  run st read k1
  [ -z "$output" ]
}

@test "path returns resolved path under global" {
  run st path mykey
  [[ "$output" == "$TMP_HOME/state/mykey.json" ]]
}

@test "path returns session path when session set" {
  OHMYCLAW_SESSION_ID=zz run env OHMYCLAW_SESSION_ID=zz OHMYCLAW_HOME="$TMP_HOME" "$SKILL_DIR/state.sh" path mykey
  [[ "$output" == "$TMP_HOME/state/sessions/zz/mykey.json" ]]
}

@test "list-active enumerates sessions with state" {
  OHMYCLAW_SESSION_ID=alpha st write k '{"x":1}'
  OHMYCLAW_SESSION_ID=beta  st write k '{"x":2}'
  run st list-active
  [[ "$output" == *alpha* ]]
  [[ "$output" == *beta* ]]
}

@test "list-active does not list empty session dirs" {
  mkdir -p "$TMP_HOME/state/sessions/empty"
  run st list-active
  [[ "$output" != *empty* ]]
}

@test "get-status shows keys with mtime" {
  OHMYCLAW_SESSION_ID=gs st write foo '{"a":1}'
  OHMYCLAW_SESSION_ID=gs st write bar '{"b":2}'
  run st get-status gs
  [[ "$output" == *foo* ]]
  [[ "$output" == *bar* ]]
}

@test "reset clears current session only" {
  OHMYCLAW_SESSION_ID=keepit st write k '{"x":1}'
  OHMYCLAW_SESSION_ID=killit st write k '{"x":1}'
  OHMYCLAW_SESSION_ID=killit st reset
  run env OHMYCLAW_SESSION_ID=killit "$SKILL_DIR/state.sh" read k
  [ -z "$output" ]
  run env OHMYCLAW_SESSION_ID=keepit "$SKILL_DIR/state.sh" read k
  [ "$output" = '{"x":1}' ]
}

@test "reset --all clears everything" {
  st write g '{"x":1}'
  OHMYCLAW_SESSION_ID=a st write k '{"x":1}'
  st reset --all
  run st read g
  [ -z "$output" ]
  run env OHMYCLAW_SESSION_ID=a "$SKILL_DIR/state.sh" read k
  [ -z "$output" ]
}

@test "invalid key with traversal rejected exit 2" {
  run st write '../escape' '{}'
  [ "$status" -eq 2 ]
}

@test "invalid key with slash rejected exit 2" {
  run st write 'a/b' '{}'
  [ "$status" -eq 2 ]
}

@test "empty key rejected exit 2" {
  run st write '' '{}'
  [ "$status" -eq 2 ]
}

@test "leading dot key rejected exit 2" {
  run st write '.hidden' '{}'
  [ "$status" -eq 2 ]
}

@test "10 parallel writes to same key under lock: final content valid JSON" {
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( st write race "{\"i\":$i}" ) &
  done
  wait
  run st read race
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

@test "write then read round-trip preserves bytes exactly" {
  local val='{"nested":{"a":[1,2,3]},"s":"hello"}'
  st write rt "$val"
  run st read rt
  [ "$output" = "$val" ]
}

# ── recent action (US-007) ──────────────────────────────────────────────

@test "recent with ttl=0 returns content (read-equivalent)" {
  st write k1 '{"v":1}'
  run st recent k1 0
  [ "$status" -eq 0 ]
  [ "$output" = '{"v":1}' ]
}

@test "recent within ttl returns content" {
  st write k1 '{"v":1}'
  run st recent k1 60
  [ "$status" -eq 0 ]
  [ "$output" = '{"v":1}' ]
}

@test "recent past ttl returns empty" {
  st write k1 '{"v":1}'
  # set mtime to 1970 (way past)
  touch -t 197001020000 "$TMP_HOME/state/k1.json" 2>/dev/null || \
    touch -d "1970-01-02" "$TMP_HOME/state/k1.json"
  run st recent k1 60
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "recent missing key returns empty exit 0" {
  run st recent nope 60
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "recent missing arg exits 2" {
  run st recent
  [ "$status" -eq 2 ]
}

@test "recent invalid ttl exits 2" {
  st write k1 '{"v":1}'
  run st recent k1 abc
  [ "$status" -eq 2 ]
}
