#!/usr/bin/env bats
# mcp-server.ts — stdio JSON-RPC 2.0 handshake + tool list + tool call

load helpers

MCP_BIN() { echo "$REPO_ROOT/skills/ohmyclaw/dist/mcp-server.js"; }

setup() {
  if [[ ! -f "$(MCP_BIN)" ]]; then
    skip "MCP server not built — run: npm run build:mcp"
  fi
  TMP_IN=$(mktemp -t mcp-in.XXXXXX)
  TMP_OUT=$(mktemp -t mcp-out.XXXXXX)
  TMP_ERR=$(mktemp -t mcp-err.XXXXXX)
  mock_bin acpx
}
teardown() {
  unmock_bin
  rm -f "$TMP_IN" "$TMP_OUT" "$TMP_ERR"
}

# Run a sequence of JSON-RPC messages through the MCP server, capture stdout.
_run_mcp() {
  local input="$1"
  printf '%s\n' "$input" > "$TMP_IN"
  node "$(MCP_BIN)" < "$TMP_IN" > "$TMP_OUT" 2> "$TMP_ERR" &
  local pid=$!
  sleep 1.2
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  cat "$TMP_OUT"
}

@test "initialize handshake returns protocolVersion + serverInfo.name=ohmyclaw" {
  local input
  input='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bats","version":"0"}}}'
  run _run_mcp "$input"
  [ "$status" -eq 0 ]
  echo "$output" | head -1 | jq -e '.result.protocolVersion == "2024-11-05"' >/dev/null
  echo "$output" | head -1 | jq -e '.result.serverInfo.name == "ohmyclaw"' >/dev/null
}

@test "tools/list enumerates exactly 5 ohmyclaw_* tools" {
  local input
  input=$(cat <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bats","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
JSON
)
  run _run_mcp "$input"
  [ "$status" -eq 0 ]
  local list_resp
  list_resp=$(echo "$output" | grep -F '"id":2' | head -1)
  [ -n "$list_resp" ]
  local count
  count=$(echo "$list_resp" | jq '.result.tools | length')
  [ "$count" -eq 5 ]
  echo "$list_resp" | jq -e '.result.tools | map(.name) | contains(["ohmyclaw_route","ohmyclaw_pool_status","ohmyclaw_engine_resolve","ohmyclaw_doctor","ohmyclaw_version"])' >/dev/null
}

@test "tools/call ohmyclaw_version returns text content" {
  local input
  input=$(cat <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bats","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ohmyclaw_version","arguments":{}}}
JSON
)
  run _run_mcp "$input"
  local resp
  resp=$(echo "$output" | grep -F '"id":3' | head -1)
  [ -n "$resp" ]
  echo "$resp" | jq -e '.result.content[0].type == "text"' >/dev/null
  echo "$resp" | jq -e '.result.content[0].text | test("^ohmyclaw [0-9]+\\.[0-9]+\\.[0-9]+$")' >/dev/null
}

@test "tools/call ohmyclaw_route returns JSON decision with model field" {
  local input
  input=$(cat <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bats","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ohmyclaw_route","arguments":{"task":"add null check","category":"coding_general","plan":"pro"}}}
JSON
)
  run _run_mcp "$input"
  local resp
  resp=$(echo "$output" | grep -F '"id":4' | head -1)
  [ -n "$resp" ]
  local text
  text=$(echo "$resp" | jq -r '.result.content[0].text')
  echo "$text" | jq -e '.model' >/dev/null
  [ "$(echo "$text" | jq -r '.activePlan')" = "pro" ]
}

@test "tools/call unknown tool returns isError" {
  local input
  input=$(cat <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bats","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope_tool","arguments":{}}}
JSON
)
  run _run_mcp "$input"
  local resp
  resp=$(echo "$output" | grep -F '"id":5' | head -1)
  [ -n "$resp" ]
  # MCP SDK returns proper JSON-RPC error (-32602) for unknown tool, OR result with isError. Accept either.
  echo "$resp" | jq -e '.error // (.result.isError == true)' >/dev/null
}

@test "tools/call ohmyclaw_route rejects missing task (input schema violation)" {
  local input
  input=$(cat <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bats","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ohmyclaw_route","arguments":{}}}
JSON
)
  run _run_mcp "$input"
  local resp
  resp=$(echo "$output" | grep -F '"id":6' | head -1)
  [ -n "$resp" ]
  echo "$resp" | jq -e '.error // (.result.isError == true)' >/dev/null
}
