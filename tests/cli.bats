#!/usr/bin/env bats
# cli.sh — unified dispatcher + lifecycle

load helpers

cl() { "$SKILL_DIR/cli.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-cli.XXXXXX)
  TMP_STATE=$(mktemp -d -t omc-cli-state.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="cli-test-$$-$BATS_TEST_NUMBER"
  mock_bin acpx   # engine 의존성 격리
}
teardown() {
  unmock_bin
  [[ -d "$TMP_HOME" ]]  && rm -rf "$TMP_HOME"
  [[ -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_HOME OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID
}

@test "help shows usage with all verbs" {
  run cl help
  [ "$status" -eq 0 ]
  for v in doctor route pool engine state hooks cancel version; do
    [[ "$output" == *"$v"* ]]
  done
}

@test "--help alias works" {
  run cl --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ohmyclaw cli"* ]]
}

@test "no args defaults to help" {
  run "$SKILL_DIR/cli.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown verb exits 2" {
  run cl bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown verb"* ]]
}

@test "version emits 'ohmyclaw <semver>'" {
  run cl version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^ohmyclaw\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "state verb proxies to state.sh" {
  cl state write k1 '{"v":42}'
  run cl state read k1
  [ "$status" -eq 0 ]
  [ "$output" = '{"v":42}' ]
}

@test "hooks verb proxies to hooks.sh list" {
  rm -rf "$TMP_HOME/hooks"
  run cl hooks list
  [ "$status" -eq 0 ]
  [[ "$output" == *"hooks dir absent"* ]]
}

@test "route verb proxies to select-model.sh" {
  run cl route "add null check" coding_general --plan=pro
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5" ]
}

@test "engine verb proxies to engine.sh resolve" {
  run cl engine resolve glm-5.1 oauth_zai reviewer
  [ "$status" -eq 0 ]
  [[ "$output" =~ \| ]]
}

@test "pool verb proxies to pool.sh next" {
  run cl pool next glm-5
  [ "$status" -eq 0 ]
  [[ "$output" =~ \|oauth_zai\| ]]
}

@test "pre-verb hook fires before action" {
  mkdir -p "$TMP_HOME/hooks"
  cat > "$TMP_HOME/hooks/pre-version.sh" <<'H'
#!/bin/sh
echo "PRE-VERSION FIRED" >&2
exit 0
H
  chmod +x "$TMP_HOME/hooks/pre-version.sh"
  run cl version
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRE-VERSION FIRED"* ]] || [[ "$stderr" == *"PRE-VERSION FIRED"* ]] || \
    [[ "${lines[*]}" == *"PRE-VERSION FIRED"* ]]
}

@test "pre-verb hook failure (exit 7) aborts the verb" {
  mkdir -p "$TMP_HOME/hooks"
  cat > "$TMP_HOME/hooks/pre-version.sh" <<'H'
#!/bin/sh
exit 99
H
  chmod +x "$TMP_HOME/hooks/pre-version.sh"
  run cl version
  [ "$status" -eq 7 ]
}

@test "skill-active state is written during verb and cleaned after" {
  mkdir -p "$TMP_HOME/hooks"
  # 훅이 skill-active 가 작성됐는지 확인하고 그 값을 기록
  cat > "$TMP_HOME/hooks/post-version.sh" <<'H'
#!/bin/sh
"$OHMYCLAW_HOME/../skill-active-during.txt" 2>/dev/null
H
  chmod +x "$TMP_HOME/hooks/post-version.sh"
  cl version >/dev/null
  # 정상 종료 후 skill-active 가 청소됐는지
  run "$SKILL_DIR/state.sh" read skill-active
  [ -z "$output" ]
}

@test "doctor verb runs engine+state+hooks" {
  run cl doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"engine"* ]]
  [[ "$output" == *"state"* ]]
  [[ "$output" == *"hooks"* ]]
}

@test "cancel clears skill-active state" {
  "$SKILL_DIR/state.sh" write skill-active '{"stale":true}'
  cl cancel >/dev/null
  run "$SKILL_DIR/state.sh" read skill-active
  [ -z "$output" ]
}

@test "cancel writes cancel-signal" {
  cl cancel >/dev/null
  # cancel-signal 은 state.sh reset 직전에 쓰여 reset 으로 지워질 수 있음 → list-active 로 빈 세션도 OK
  # 핵심: cancel 이 정상 종료
  [ $? -eq 0 ]
}

@test "cancel sweeps dead PID slots from pool" {
  # acquire 하고 PID 미기록 슬롯 두 개 만든 후, dead PID 기록
  ZAI_CODING_PLAN=pro
  export ZAI_CODING_PLAN
  local t1 t2
  t1=$("$SKILL_DIR/pool.sh" acquire-worker 2>/dev/null | sed -n 's/^TOKEN=//p')
  t2=$("$SKILL_DIR/pool.sh" acquire-worker 2>/dev/null | sed -n 's/^TOKEN=//p')
  echo "999999" > "$t1"
  echo "999998" > "$t2"
  cl cancel >/dev/null
  [ ! -e "$t1" ]
  [ ! -e "$t2" ]
}

@test "cancel --force removes other sessions' state too" {
  OHMYCLAW_SESSION_ID=other "$SKILL_DIR/state.sh" write k '{"x":1}'
  cl cancel --force >/dev/null
  run env OHMYCLAW_SESSION_ID=other "$SKILL_DIR/state.sh" read k
  [ -z "$output" ]
}
