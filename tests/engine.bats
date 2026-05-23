#!/usr/bin/env bats
# engine.sh — ACP engine resolver

load helpers

setup() {
  setup_isolated_state
  unset OHMYCLAW_ENGINE OHMYCLAW_ENGINE_FALLBACK
  # 기본 mock: acpx 가 PATH 에 있도록 (CI/fresh 환경에서도 결정론적 테스트)
  # 개별 테스트가 omp 등을 추가 mock 하면 자동 확장됨
  mock_bin acpx
}
teardown() {
  unmock_bin
  teardown_isolated_state
}

@test "glm-5.1 omp absent falls back to pi" {
  run eg resolve glm-5.1 oauth_zai reviewer
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^pi\| ]]
  [[ "$output" =~ acpx ]]
  [[ "$output" =~ --approve-reads ]]
}

@test "gpt-5.4 omp absent falls back to codex" {
  run eg resolve gpt-5.4 oauth_codex executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^codex\| ]]
  [[ "$output" =~ --approve-all ]]
}

@test "openrouter model omp absent falls back" {
  run eg resolve openrouter-claude-opus-4 api_key executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(omp|codex)\| ]]
}

@test "omp mock present glm-5.1 selects omp escape hatch" {
  mock_bin omp
  run eg resolve glm-5.1 oauth_zai reviewer
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^omp\| ]]
  [[ "$output" =~ "acpx --agent \"omp acp\" --model glm-5.1" ]]
  [[ "$output" =~ --approve-reads ]]
}

@test "omp mock executor role gets approve-all" {
  mock_bin omp
  run eg resolve glm-5 oauth_zai executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ --approve-all ]]
}

@test "omp mock gpt-5.5 frontier selects omp" {
  mock_bin omp
  run eg resolve gpt-5.5 oauth_codex executor
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^omp\| ]]
  [[ "$output" =~ "--model gpt-5.5" ]]
}

@test "planner role approve-reads" {
  run eg resolve glm-5 oauth_zai planner
  [[ "$output" =~ --approve-reads ]]
}
@test "critic role approve-reads" {
  run eg resolve glm-5 oauth_zai critic
  [[ "$output" =~ --approve-reads ]]
}
@test "debugger role approve-all" {
  run eg resolve glm-5 oauth_zai debugger
  [[ "$output" =~ --approve-all ]]
}
@test "verifier role approve-reads" {
  run eg resolve glm-5 oauth_zai verifier
  [[ "$output" =~ --approve-reads ]]
}
@test "unknown role uses default approve-reads" {
  run eg resolve glm-5 oauth_zai notarole
  [[ "$output" =~ --approve-reads ]]
}

@test "unknown model prefix exits 3" {
  run eg resolve bogus-model "" executor
  [ "$status" -eq 3 ]
  [[ "$output" =~ "unknown model" ]]
}
@test "missing model arg exits 2" {
  run eg resolve
  [ "$status" -eq 2 ]
}

@test "OHMYCLAW_ENGINE omp forces selection when present" {
  mock_bin omp
  OHMYCLAW_ENGINE=omp run eg resolve glm-5.1 oauth_zai reviewer
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^omp\| ]]
}
@test "OHMYCLAW_ENGINE_FALLBACK false errors when forced engine absent" {
  OHMYCLAW_ENGINE=omp OHMYCLAW_ENGINE_FALLBACK=false run eg resolve glm-5.1 oauth_zai reviewer
  [ "$status" -ne 0 ]
}

@test "acp-config emits valid JSON" {
  run eg acp-config
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.agents.omp.args == ["acp"]' >/dev/null
  echo "$output" | jq -e '.agents.omp.command == "omp"' >/dev/null
}

@test "doctor exits 0 even when omp absent" {
  run eg doctor
  [ "$status" -eq 0 ]
}
@test "doctor reports routing engine block" {
  run eg doctor
  [[ "$output" =~ "routing.json engine block" ]]
}

@test "help shows usage" {
  run eg help
  [[ "$output" =~ "engine.sh" ]]
  [[ "$output" =~ "resolve" ]]
}
@test "unknown subcommand exits 2" {
  run eg nopecommand
  [ "$status" -eq 2 ]
}
