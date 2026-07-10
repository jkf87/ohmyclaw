#!/usr/bin/env bats
# provider-health.sh sync-auth-order — 멀티계정 auth-order health sync
#   PATH mock openclaw 로 결정 로직(clear/set/alert)을 실 openclaw 없이 검증.

load helpers

setup() {
  setup_isolated_state
  MOCK_BIN=$(mktemp -d -t oc-mock.XXXXXX)
  PROBE_FILE="${OHMYCLAW_STATE_DIR}/probe.json"
  ORDER_LOG="${OHMYCLAW_STATE_DIR}/order.log"
  : > "$ORDER_LOG"
  export MOCK_PROBE_FILE="$PROBE_FILE"
  export MOCK_ORDER_LOG="$ORDER_LOG"
  export MOCK_AGENTS_OPENAI="ainewbot main testbot todobot"
  export OHMYCLAW_PH_AGENTS="ainewbot main testbot todobot claude codex pi"
  _write_mock_openclaw
  export PATH="$MOCK_BIN:$PATH"
}
teardown() {
  [[ -n "${MOCK_BIN:-}" && -d "$MOCK_BIN" ]] && rm -rf "$MOCK_BIN"
  teardown_isolated_state
  unset MOCK_PROBE_FILE MOCK_ORDER_LOG MOCK_AGENTS_OPENAI OHMYCLAW_PH_AGENTS
}

# 프로파일별 probe status 를 세팅 ($1=default status, $2=jjoongoo status)
set_probe() {
  cat > "$PROBE_FILE" <<JSON
{"auth":{"probes":{"results":[
  {"profileId":"openai:default","status":"$1"},
  {"profileId":"openai:jjoongoo@gmail.com","status":"$2"}
]}}}
JSON
}

_write_mock_openclaw() {
  cat > "$MOCK_BIN/openclaw" <<'MOCK'
#!/usr/bin/env bash
# 최소 openclaw mock — sync-auth-order 가 부르는 서브커맨드만 처리
args="$*"
case "$args" in
  *"models auth list"*"--provider openai"*)
    echo '{"profiles":[{"id":"openai:default","provider":"openai"},{"id":"openai:jjoongoo@gmail.com","provider":"openai"}]}' ;;
  *"models auth list"*"--provider anthropic"*)
    echo '{"profiles":[{"id":"anthropic:claude-cli","provider":"anthropic"}]}' ;;
  *"models auth list"*"--provider zai"*)
    echo '{"profiles":[{"id":"zai:default","provider":"zai"}]}' ;;
  *"models auth list"*)   # provider 목록용 (프로파일별 provider)
    echo '{"profiles":[{"provider":"openai"},{"provider":"anthropic"},{"provider":"zai"}]}' ;;
  *"models status --probe --probe-provider openai"*)
    cat "$MOCK_PROBE_FILE" ;;
  *"models status --agent "*"--json"*)
    # 어느 agent 인지 추출
    a=""; prev=""
    for w in $args; do [[ "$prev" == "--agent" ]] && a="$w"; prev="$w"; done
    if printf ' %s ' "$MOCK_AGENTS_OPENAI" | grep -q " $a "; then
      echo '{"auth":{"oauth":{"providers":[{"provider":"openai","status":"ok","effectiveProfiles":[{"profileId":"openai:jjoongoo@gmail.com"}]}]}}}'
    else
      echo '{"auth":{"oauth":{"providers":[]}}}'
    fi ;;
  *"models auth order set"*|*"models auth order clear"*)
    echo "$args" >> "$MOCK_ORDER_LOG" ;;
  *) echo '{}' ;;
esac
MOCK
  chmod +x "$MOCK_BIN/openclaw"
}

@test "profiles lists both openai profiles" {
  run "$SKILL_DIR/provider-health.sh" profiles openai
  [ "$status" -eq 0 ]
  [[ "$output" == *"openai:default"* ]]
  [[ "$output" == *"openai:jjoongoo@gmail.com"* ]]
}

@test "agents-using openai returns only openai agents" {
  run "$SKILL_DIR/provider-health.sh" agents-using openai
  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]]
  [[ "$output" == *"ainewbot"* ]]
  [[ "$output" != *"claude"* ]]
  [[ "$output" != *"pi"* ]]
}

@test "all healthy → clear order for each openai agent (round-robin preserved)" {
  set_probe ok ok
  run "$SKILL_DIR/provider-health.sh" sync-auth-order --apply
  [ "$status" -eq 0 ]
  # 4개 openai agent 전부 clear
  run grep -c "models auth order clear --provider openai" "$ORDER_LOG"
  [ "$output" -eq 4 ]
  run grep -c "models auth order set" "$ORDER_LOG"
  [ "$output" -eq 0 ]
}

@test "one expired (default) → set healthy-only, excluding expired" {
  set_probe expired ok
  run "$SKILL_DIR/provider-health.sh" sync-auth-order --apply
  [ "$status" -eq 0 ]
  # jjoongoo 만 order 에 들어가고 default 는 제외
  run grep -c "models auth order set --provider openai --agent .* openai:jjoongoo@gmail.com" "$ORDER_LOG"
  [ "$output" -eq 4 ]
  ! grep -q "openai:default" "$ORDER_LOG"
  ! grep -q "order clear" "$ORDER_LOG"
}

@test "the OTHER one expired (jjoongoo) → set default-only" {
  set_probe ok expired
  run "$SKILL_DIR/provider-health.sh" sync-auth-order --apply
  [ "$status" -eq 0 ]
  run grep -c "order set --provider openai --agent .* openai:default" "$ORDER_LOG"
  [ "$output" -eq 4 ]
  ! grep -q "jjoongoo" "$ORDER_LOG"
}

@test "all expired → alert only, no order writes" {
  set_probe expired expired
  run "$SKILL_DIR/provider-health.sh" sync-auth-order --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL"*"expired"* ]]
  [[ "$output" == *"models auth login --provider openai --force"* ]]
  run wc -l < "$ORDER_LOG"
  [ "${output// /}" -eq 0 ]
}

@test "dry-run (no --apply) writes nothing" {
  set_probe expired ok
  run "$SKILL_DIR/provider-health.sh" sync-auth-order
  [ "$status" -eq 0 ]
  [[ "$output" == *"set"* ]]        # 계획은 출력
  run wc -l < "$ORDER_LOG"
  [ "${output// /}" -eq 0 ]         # 실제 write 는 없음
}

@test "empty probe (offline) → skip safely, no writes" {
  echo '{"auth":{"probes":{"results":[]}}}' > "$PROBE_FILE"
  run "$SKILL_DIR/provider-health.sh" sync-auth-order --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
  run wc -l < "$ORDER_LOG"
  [ "${output// /}" -eq 0 ]
}

@test "OHMYCLAW_PROVIDER_HEALTH=false disables sync" {
  set_probe expired ok
  OHMYCLAW_PROVIDER_HEALTH=false run "$SKILL_DIR/provider-health.sh" sync-auth-order --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled"* ]]
  run wc -l < "$ORDER_LOG"
  [ "${output// /}" -eq 0 ]
}

@test "cold-start: empty provider list on first call → retry recovers" {
  # 콜드스타트 재현: 'auth list --json'(provider 목록용) 첫 호출은 빈 결과, 이후 정상.
  local counter="${OHMYCLAW_STATE_DIR}/al_count"; echo 0 > "$counter"
  cat > "$MOCK_BIN/openclaw" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"models auth list"*"--provider openai"*)
    echo '{"profiles":[{"id":"openai:default","provider":"openai"},{"id":"openai:jjoongoo@gmail.com","provider":"openai"}]}' ;;
  *"models auth list"*)
    c=\$(cat "$counter"); echo \$((c+1)) > "$counter"
    if [ "\$c" -eq 0 ]; then echo '{"profiles":[]}'; else echo '{"profiles":[{"provider":"openai"}]}'; fi ;;
  *"models status --probe --probe-provider openai"*) cat "$MOCK_PROBE_FILE" ;;
  *"models status --agent "*"--json"*)
    a=""; prev=""; for w in \$args; do [ "\$prev" = "--agent" ] && a="\$w"; prev="\$w"; done
    if printf ' %s ' "\$MOCK_AGENTS_OPENAI" | grep -q " \$a "; then
      echo '{"auth":{"oauth":{"providers":[{"provider":"openai"}]}}}'
    else echo '{"auth":{"oauth":{"providers":[]}}}'; fi ;;
  *"models auth order"*) echo "\$args" >> "\$MOCK_ORDER_LOG" ;;
  *) echo '{}' ;;
esac
MOCK
  chmod +x "$MOCK_BIN/openclaw"
  set_probe expired ok
  run "$SKILL_DIR/provider-health.sh" sync-auth-order --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"openai"* ]]                    # 재시도로 openai 발견·처리
  run grep -c "order set --provider openai" "$ORDER_LOG"
  [ "$output" -eq 4 ]
}

@test "cold-start: OHMYCLAW_PH_NO_RETRY=1 skips retry (empty stays empty)" {
  local counter="${OHMYCLAW_STATE_DIR}/al_count2"; echo 0 > "$counter"
  cat > "$MOCK_BIN/openclaw" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"models auth list"*"--provider"*) echo '{"profiles":[]}' ;;
  *"models auth list"*) echo '{"profiles":[]}' ;;
  *) echo '{}' ;;
esac
MOCK
  chmod +x "$MOCK_BIN/openclaw"
  OHMYCLAW_PH_NO_RETRY=1 run "$SKILL_DIR/provider-health.sh" sync-auth-order --apply
  [ "$status" -eq 0 ]
  run wc -l < "$ORDER_LOG"
  [ "${output// /}" -eq 0 ]
}
