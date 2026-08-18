#!/usr/bin/env bats
# glm-5.3 opt-in 게이트 + thinking level(reasoning effort) 배선

load helpers

REASON_TASK="분산 합의 알고리즘 정합성 증명과 lock-free 불변조건 검증 race condition 복잡도"

setup() { unset ZAI_GLM53_ENABLED CODEX_OAUTH_ENABLED OHMYCLAW_THINKING OHMYCLAW_THINKING_SUFFIX || true; }

# ──────────────────────────────────────────────
# glm-5.3 — 기본 비활성 (OpenClaw 카탈로그 미등재)
# ──────────────────────────────────────────────
@test "glm-5.3 is not selected by default" {
  run sm "$REASON_TASK" reasoning --plan=pro
  [ "$status" -eq 0 ]
  [ "$output" != "glm-5.3" ]
}

@test "glm-5.3 is selected when explicitly enabled" {
  ZAI_GLM53_ENABLED=true run sm "$REASON_TASK" reasoning --plan=pro
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5.3" ]
}

@test "glm-5.3 stays off on the lite plan" {
  ZAI_GLM53_ENABLED=true run sm "$REASON_TASK" reasoning --plan=lite
  [ "$output" != "glm-5.3" ]
}

@test "codex frontier still wins over glm-5.3" {
  ZAI_GLM53_ENABLED=true CODEX_OAUTH_ENABLED=true run sm "$REASON_TASK" reasoning --plan=pro
  [[ "$output" =~ ^gpt-5\.6- ]]
}

@test "glm-5.3 does not take content_creation" {
  ZAI_GLM53_ENABLED=true run sm "블로그 글 써줘" content_creation --plan=pro
  [ "$output" != "glm-5.3" ]
}

@test "glm-5.3 carries the opt-in env marker in routing.json" {
  run jq -r '.models["glm-5.3"].requiresEnv' "$SKILL_DIR/routing.json"
  [ "$output" = "ZAI_GLM53_ENABLED" ]
}

# ──────────────────────────────────────────────
# thinking level
# ──────────────────────────────────────────────
@test "no thinking suffix unless explicitly enabled" {
  run eg resolve gpt-5.6-sol "" executor
  [ "$status" -eq 0 ]
  [[ "$output" != *"["* ]]
}

@test "HIGH tier gets max thinking when suffix enabled" {
  OHMYCLAW_THINKING_SUFFIX=true run eg resolve gpt-5.6-sol "" executor
  [[ "$output" == *"gpt-5.6-sol[max]"* ]]
}

@test "explicit OHMYCLAW_THINKING overrides tier policy" {
  OHMYCLAW_THINKING_SUFFIX=true OHMYCLAW_THINKING=low run eg resolve gpt-5.6-sol "" executor
  [[ "$output" == *"gpt-5.6-sol[low]"* ]]
}

# supportsUltra:false 를 jq 의 `//` 가 삼키던 버그의 회귀 방지
@test "ultra downgrades to max on models without ultra support" {
  OHMYCLAW_THINKING_SUFFIX=true OHMYCLAW_THINKING=ultra run eg resolve gpt-5.6-luna "" executor
  [[ "$output" == *"gpt-5.6-luna[max]"* ]]
  [[ "$output" != *"[ultra]"* ]]
}

@test "ultra is preserved on models that support it" {
  OHMYCLAW_THINKING_SUFFIX=true OHMYCLAW_THINKING=ultra run eg resolve gpt-5.6-sol "" executor
  [[ "$output" == *"gpt-5.6-sol[ultra]"* ]]
}

# ──────────────────────────────────────────────
# 실측 정정 회귀
# ──────────────────────────────────────────────
@test "glm-5.2 context window matches the measured 1M" {
  run jq -r '.models["glm-5.2"].contextWindow' "$SKILL_DIR/routing.json"
  [ "$output" = "1000000" ]
}

@test "gpt-5.6 variants share identical hard specs" {
  local ctx tok
  for m in gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna; do
    ctx=$(jq -r --arg m "$m" '.models[$m].contextWindow' "$SKILL_DIR/routing.json")
    tok=$(jq -r --arg m "$m" '.models[$m].maxTokens'     "$SKILL_DIR/routing.json")
    [ "$ctx" = "1050000" ]
    [ "$tok" = "128000" ]
  done
}
