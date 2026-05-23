#!/usr/bin/env bats
# End-to-end integration — verify cli.sh + hooks + state + pool + engine work TOGETHER.
# Unit suites cover each component in isolation; this suite catches coupling defects
# that only appear when the full chain runs as a real user scenario would.

load helpers

cl() { "$SKILL_DIR/cli.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-e2e.XXXXXX)
  TMP_STATE=$(mktemp -d -t omc-e2e-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="e2e-$$-$BATS_TEST_NUMBER"
  export ZAI_CODING_PLAN=pro
  unset CODEX_OAUTH_ENABLED OPENROUTER_ENABLED
  mock_bin acpx
  mkdir -p "$TMP_HOME/hooks"
}
teardown() {
  unmock_bin
  [[ -d "$TMP_HOME" ]]  && rm -rf "$TMP_HOME"
  [[ -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_HOME OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID ZAI_CODING_PLAN
}

@test "e2e full route chain: pre-hook then select-model then post-hook then cleanup" {
  cat > "$TMP_HOME/hooks/pre-route.sh" <<'H'
#!/bin/sh
printf '%s\n%s\n' "$OHMYCLAW_ACTION" "$OHMYCLAW_ARGS_JSON" > "$OHMYCLAW_HOME/pre.log"
H
  chmod +x "$TMP_HOME/hooks/pre-route.sh"

  cat > "$TMP_HOME/hooks/post-route.sh" <<'H'
#!/bin/sh
date -u +%s > "$OHMYCLAW_HOME/post.stamp"
H
  chmod +x "$TMP_HOME/hooks/post-route.sh"

  run cl route "add null check" coding_general --plan=pro
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5" ]

  # pre hook trace
  [ -f "$TMP_HOME/pre.log" ]
  grep -q '^route$' "$TMP_HOME/pre.log"
  grep -q '"coding_general"' "$TMP_HOME/pre.log"

  # post hook fired
  [ -f "$TMP_HOME/post.stamp" ]

  # skill-active cleaned after verb exits
  run "$SKILL_DIR/state.sh" read skill-active
  [ -z "$output" ]
}

@test "e2e pool roundtrip: cli engine resolve is pool-agnostic; cli pool next picks account" {
  run cl engine resolve glm-5 oauth_zai executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(pi|omp)\| ]]

  run cl pool next glm-5
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^zai-primary\|oauth_zai\| ]]

  cl pool cooldown zai-primary >/dev/null 2>&1
  run cl pool release zai-primary
  [ "$status" -eq 0 ]
}

@test "e2e state cross-verb persistence: cli state write then read returns same value" {
  cl state write checkpoint '{"phase":"WORKING","step":3}'
  run cl state read checkpoint
  [ "$status" -eq 0 ]
  [ "$output" = '{"phase":"WORKING","step":3}' ]
  echo "$output" | jq -e '.phase == "WORKING"' >/dev/null
}

@test "e2e pre-hook abort: verb body skipped when pre fails" {
  cat > "$TMP_HOME/hooks/pre-version.sh" <<'H'
#!/bin/sh
date -u +%s > "$OHMYCLAW_HOME/pre.stamp"
exit 99
H
  chmod +x "$TMP_HOME/hooks/pre-version.sh"

  run cl version
  [ "$status" -eq 7 ]
  [ -f "$TMP_HOME/pre.stamp" ]
  # version body would have emitted "ohmyclaw X.Y.Z" — abort means no such line
  [[ ! "$output" =~ ^ohmyclaw\ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "e2e MCP and cli agree on routing decision for same input" {
  local cli_model
  cli_model=$(cl route "add null check" coding_general --plan=pro)
  [ "$cli_model" = "glm-5" ]

  local mcp_bin="$REPO_ROOT/skills/ohmyclaw/dist/mcp-server.js"
  if [[ ! -f "$mcp_bin" ]]; then
    skip "MCP server not built — run npm run build:mcp"
  fi
  local in_file out_file
  in_file=$(mktemp -t mcp-e2e-in.XXXXXX)
  out_file=$(mktemp -t mcp-e2e-out.XXXXXX)
  cat > "$in_file" <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ohmyclaw_route","arguments":{"task":"add null check","category":"coding_general","plan":"pro"}}}
JSON
  node "$mcp_bin" < "$in_file" > "$out_file" 2>/dev/null &
  local pid=$!
  sleep 1.2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  local resp text mcp_model
  resp=$(grep -F '"id":2' "$out_file" | head -1)
  text=$(echo "$resp" | jq -r '.result.content[0].text')
  mcp_model=$(echo "$text" | jq -r '.model')
  [ "$mcp_model" = "$cli_model" ]
  rm -f "$in_file" "$out_file"
}

@test "e2e cancel then re-enter: next verb runs cleanly with fresh skill-active cycle" {
  cl version >/dev/null
  cl cancel >/dev/null
  run cl route "smoke" coding_general --plan=pro
  [ "$status" -eq 0 ]
  run "$SKILL_DIR/state.sh" read skill-active
  [ -z "$output" ]
}

@test "e2e doctor exercises engine plus state plus hooks subsystems" {
  cat > "$TMP_HOME/hooks/pre-route.sh" <<'H'
#!/bin/sh
:
H
  chmod +x "$TMP_HOME/hooks/pre-route.sh"

  run cl doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"── engine ──"* ]]
  [[ "$output" == *"── state ──"* ]]
  [[ "$output" == *"── hooks ──"* ]]
  [[ "$output" == *"pre-route.sh"* ]]
}
