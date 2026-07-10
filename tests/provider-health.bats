#!/usr/bin/env bats
# provider-health.sh — auth-expiry gate (openclaw models status aware)

load helpers

setup() {
  setup_isolated_state
  STATUS_JSON="${OHMYCLAW_STATE_DIR}/status.json"
}
teardown() {
  teardown_isolated_state
}

# openai=expired 인 mock openclaw status 를 파일로 준비하고 STATUS_CMD 로 연결
mock_status_openai_expired() {
  cat > "$STATUS_JSON" <<'JSON'
{"auth":{"oauth":{"providers":[
  {"provider":"openai","status":"expired"},
  {"provider":"zai","status":"static"},
  {"provider":"claude-cli","status":"expiring"}
]},"unusableProfiles":[],"missingProvidersInUse":[]}}
JSON
  export OHMYCLAW_PH_STATUS_CMD="cat $STATUS_JSON"
}
mock_status_all_ok() {
  cat > "$STATUS_JSON" <<'JSON'
{"auth":{"oauth":{"providers":[
  {"provider":"openai","status":"ok"},
  {"provider":"zai","status":"static"}
]},"unusableProfiles":[]}}
JSON
  export OHMYCLAW_PH_STATUS_CMD="cat $STATUS_JSON"
}

@test "provider-of maps model prefixes to openclaw providers" {
  [ "$(ph provider-of gpt-5.5)" = "openai" ]
  [ "$(ph provider-of glm-5.2)" = "zai" ]
  [ "$(ph provider-of claude-code-experimental)" = "claude-cli" ]
  [ "$(ph provider-of openrouter-claude-opus-4)" = "openrouter" ]
  [ -z "$(ph provider-of mystery-model)" ]
}

@test "first-healthy demotes expired openai chain to first glm" {
  mock_status_openai_expired
  run ph_out first-healthy "gpt-5.5,gpt-5.4,glm-5.2,glm-5.1,glm-5"
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5.2" ]
}

@test "first-healthy leaves healthy head untouched" {
  mock_status_openai_expired
  run ph_out first-healthy "glm-5.2,glm-5"
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5.2" ]
}

@test "first-healthy keeps head when all providers unhealthy (no worse than status quo)" {
  cat > "$STATUS_JSON" <<'JSON'
{"auth":{"oauth":{"providers":[
  {"provider":"openai","status":"expired"},
  {"provider":"zai","status":"expired"}
]}}}
JSON
  export OHMYCLAW_PH_STATUS_CMD="cat $STATUS_JSON"
  run ph_out first-healthy "gpt-5.5,glm-5.2"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.5" ]
}

@test "check exits 1 for expired provider, 0 for healthy" {
  mock_status_openai_expired
  run ph check gpt-5.5
  [ "$status" -eq 1 ]
  run ph check glm-5.2
  [ "$status" -eq 0 ]
}

@test "check exits 0 for unknown model (never gate what we don't map)" {
  mock_status_openai_expired
  run ph check totally-unknown-model
  [ "$status" -eq 0 ]
}

@test "why reports live status and quarantine reason" {
  mock_status_openai_expired
  ph refresh >/dev/null 2>&1
  run ph_out why gpt-5.5
  [ "$status" -eq 0 ]
  [ "$output" = "openai=expired" ]
}

@test "quarantine + is-quarantined + release round-trip" {
  run ph is-quarantined openai
  [ "$status" -eq 1 ]                 # 처음엔 격리 아님
  ph quarantine openai auth_permanent >/dev/null 2>&1
  run ph is-quarantined openai
  [ "$status" -eq 0 ]                 # 격리됨
  run ph release openai
  [ "$status" -eq 0 ]
  run ph is-quarantined openai
  [ "$status" -eq 1 ]                 # 해제됨
}

@test "pool alias normalizes to provider (codex→openai)" {
  ph quarantine codex >/dev/null 2>&1
  run ph is-quarantined openai
  [ "$status" -eq 0 ]                 # codex 별칭이 openai 로 정규화되어 격리
}

@test "scan-stderr detects the real gateway expiry message and quarantines" {
  printf '%s\n' "⚠️ Model login expired on the gateway for openai. Re-auth with openclaw models auth login --provider openai, then try again." \
    | ph scan-stderr >/dev/null 2>&1
  run ph is-quarantined openai
  [ "$status" -eq 0 ]
}

@test "scan-stderr detects Model Fallback auth-permanent line" {
  printf '%s\n' "🔁 Model Fallback: zai/glm-4.7 (selected openai/gpt-5.5; auth permanent (+1 more attempts))" \
    | ph scan-stderr >/dev/null 2>&1
  run ph is-quarantined openai
  [ "$status" -eq 0 ]
}

@test "scan-stderr is a no-op on clean output (exit 1, nothing quarantined)" {
  run bash -c "printf 'all good, no errors here\n' | '$SKILL_DIR/provider-health.sh' scan-stderr"
  [ "$status" -eq 1 ]
  run ph is-quarantined openai
  [ "$status" -eq 1 ]
}

@test "refresh auto-releases quarantine once provider reports ok (re-auth recovery)" {
  ph quarantine openai auth_permanent >/dev/null 2>&1
  run ph is-quarantined openai
  [ "$status" -eq 0 ]
  mock_status_all_ok
  ph refresh --force >/dev/null 2>&1   # 라이브 status=ok → reconcile 로 자동 해제
  run ph is-quarantined openai
  [ "$status" -eq 1 ]
}

@test "OHMYCLAW_PROVIDER_HEALTH=false skips live polling (no gating)" {
  mock_status_openai_expired
  OHMYCLAW_PROVIDER_HEALTH=false run ph_out first-healthy "gpt-5.5,glm-5.2"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.5" ]           # 라이브 폴링 안 함 → 강등 없음
}

@test "openclaw absent is harmless (no status cmd, no openclaw) → all healthy" {
  unset OHMYCLAW_PH_STATUS_CMD
  # PATH 에서 openclaw 를 가린 상태로 실행
  run bash -c "PATH=/usr/bin:/bin '$SKILL_DIR/provider-health.sh' first-healthy 'gpt-5.5,glm-5.2' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5.5" ]
}

@test "unusableProfiles with auth_permanent marks provider expired" {
  cat > "$STATUS_JSON" <<'JSON'
{"auth":{"oauth":{"providers":[{"provider":"openai","status":"ok"}]},
 "unusableProfiles":[{"profileId":"openai:x","provider":"openai","kind":"disabled","reason":"auth_permanent"}]}}
JSON
  export OHMYCLAW_PH_STATUS_CMD="cat $STATUS_JSON"
  run ph check gpt-5.5
  [ "$status" -eq 1 ]
}
