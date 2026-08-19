#!/usr/bin/env bats
# glm-5.3 opt-in 게이트 + thinking level(reasoning effort) 배선

load helpers

REASON_TASK="분산 합의 알고리즘 정합성 증명과 lock-free 불변조건 검증 race condition 복잡도"

setup() { unset CODEX_OAUTH_ENABLED OHMYCLAW_THINKING OHMYCLAW_THINKING_SUFFIX OHMYCLAW_GLM53 || true; }

# ──────────────────────────────────────────────
# glm-5.3 — 기본 활성 (pro/max HIGH·reasoning)
# ──────────────────────────────────────────────
@test "glm-5.3 is gated off by default" {
  run sm "$REASON_TASK" reasoning --plan=pro
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5.2" ]
}

@test "glm-5.3 takes reasoning_heavy once enabled" {
  OHMYCLAW_GLM53=true run sm "$REASON_TASK" reasoning --plan=pro
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5.3" ]
}

@test "glm-5.3 is blocked on the lite plan even when enabled" {
  OHMYCLAW_GLM53=true run sm "$REASON_TASK" reasoning --plan=lite
  [ "$output" != "glm-5.3" ]
}

@test "codex frontier still wins over glm-5.3" {
  OHMYCLAW_GLM53=true CODEX_OAUTH_ENABLED=true run sm "$REASON_TASK" reasoning --plan=pro
  [[ "$output" =~ ^gpt-5\.6- ]]
}

@test "glm-5.3 does not take content_creation" {
  run sm "블로그 글 써줘" content_creation --plan=pro
  [ "$output" != "glm-5.3" ]
}

# 카탈로그 미등재 상태이므로 강등 경로가 반드시 있어야 한다
@test "glm-5.2 follows glm-5.3 in every fallback chain" {
  run bash -c "jq -r '.fallbackChains | to_entries[] | .value | to_entries[] | .value | @csv' '$SKILL_DIR/routing.json' | grep 'glm-5.3' | grep -vc 'glm-5.3\",\"glm-5.2'"
  [ "$output" = "0" ]
}

@test "no duplicate entries in fallback chains" {
  run bash -c "jq -r '[.fallbackChains[][] | select(length>0)] | map(select(. as \$a | true)) | length' '$SKILL_DIR/routing.json' >/dev/null; python3 - <<'EOF'
import json
d=json.load(open('$SKILL_DIR/routing.json'))
bad=[f'{g}.{k}' for g,c in d['fallbackChains'].items() for k,v in c.items() if len(v)!=len(set(v))]
print(len(bad))
EOF"
  [ "$output" = "0" ]
}

@test "glm-5.3 is available on pro and max plans" {
  run jq -r '.models["glm-5.3"].plans | join(",")' "$SKILL_DIR/routing.json"
  [ "$output" = "pro,max" ]
}

@test "glm-5.3 context window is 1M" {
  run jq -r '.models["glm-5.3"].contextWindow' "$SKILL_DIR/routing.json"
  [ "$output" = "1000000" ]
}

# ──────────────────────────────────────────────
# thinking level
# ──────────────────────────────────────────────
@test "thinking suffix is off by default" {
  run eg resolve gpt-5.6-sol "" executor
  [ "$status" -eq 0 ]
  [[ "$output" != *"["* ]]
}

@test "HIGH tier gets max thinking once enabled" {
  OHMYCLAW_THINKING_SUFFIX=true run eg resolve gpt-5.6-sol "" executor
  [[ "$output" == *"gpt-5.6-sol[max]"* ]]
}

# 대괄호는 codex-acp 문법이다. zai(pi/omp) 에 붙이면 모델 해석이 깨진다.
@test "no thinking suffix on zai models even when enabled" {
  OHMYCLAW_THINKING_SUFFIX=true run eg resolve glm-5.2 "" reviewer
  [[ "$output" != *"["* ]]
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

# ──────────────────────────────────────────────
# experimental 토글
# ──────────────────────────────────────────────
@test "experimental features are all off by default" {
  run jq -r '[.experimental | to_entries[] | select(.key!="comment") | .value.enabled] | any' "$SKILL_DIR/routing.json"
  [ "$output" = "false" ]
}

@test "experimental list shows both toggles" {
  run "$SKILL_DIR/cli.sh" experimental list
  [ "$status" -eq 0 ]
  [[ "$output" == *"thinkingSuffix"* ]]
  [[ "$output" == *"glm53"* ]]
}

@test "experimental rejects an unknown feature" {
  run "$SKILL_DIR/cli.sh" experimental enable bogus
  [ "$status" -ne 0 ]
}
