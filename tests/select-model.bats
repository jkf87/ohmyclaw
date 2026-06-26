#!/usr/bin/env bats
# select-model.sh — routing matrix, priority rules, reasoning detection, plan cap

load helpers

setup() {
  unset CODEX_OAUTH_ENABLED OPENROUTER_ENABLED OPENROUTER_PREFER_FREE ZAI_CODING_PLAN
}

@test "P0 default coding_general pro low -> glm-5" {
  run sm "add null check" coding_general --plan=pro
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5" ]
}

@test "matrix pro coding_general HIGH -> glm-5.2 or gpt-5.x" {
  run sm "복잡한 트랜잭션 처리 + 동시성 + 분산 시스템 + 캐시 무효화 + 멀티 테넌시 + 마이크로서비스 + race condition + state machine + invariant + algorithm" coding_general --plan=pro
  [ "$status" -eq 0 ]
  [[ "$output" == "glm-5.2" || "$output" == "gpt-5.5" || "$output" == "gpt-5.4" ]]
}

@test "matrix pro security MEDIUM -> glm-5 or glm-5.1" {
  run sm "input validation review" security --plan=pro
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(glm-5|glm-5.1)$ ]]
}

@test "P95 lite cap blocks glm-5.1 even for coding_arch" {
  run sm "복잡한 아키텍처" coding_arch --plan=lite
  [ "$status" -eq 0 ]
  [ "$output" != "glm-5.1" ]
}

@test "lite plan caps reasoning keyword too" {
  run sm "분산 합의 알고리즘 정합성 증명" reasoning --plan=lite
  [ "$status" -eq 0 ]
  [ "$output" != "glm-5.1" ]
  [[ "$output" =~ ^glm- ]]
}

@test "P81 reasoning_heavy + pro -> glm-5.2" {
  run sm "분산 합의 정합성 증명 invariant" reasoning --plan=pro
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5.2" ]
}

@test "P81 reasoning_heavy + max -> glm-5.2" {
  run sm "lock-free 알고리즘 정합성 증명" reasoning --plan=max
  [ "$status" -eq 0 ]
  [ "$output" = "glm-5.2" ]
}

@test "P82 reasoning_heavy + codex -> gpt-5.x" {
  CODEX_OAUTH_ENABLED=true run sm "분산 합의 정합성 증명 algorithm invariant" reasoning --plan=pro
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^gpt-5\.(4|5)$ ]]
}

@test "codex overlay coding_arch HIGH -> gpt-5.x" {
  CODEX_OAUTH_ENABLED=true run sm "전체 인증 시스템 마이그레이션 + 신규 SSO + 캐시 + 모니터링 + 분산 + 큐 + 페일오버 + 다중 region + zero downtime + 점진 배포" coding_arch --plan=pro
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^gpt-5\.(4|5)$ ]]
}

@test "codex disabled never recommends gpt" {
  run sm "코딩 일반 작업" coding_general --plan=pro
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ ^gpt- ]]
}

@test "openrouter overlay reasoning HIGH" {
  OPENROUTER_ENABLED=true run sm "분산 합의 정합성 증명 invariant + 복잡한 알고리즘 분석 + 다중 시나리오 검증 + tradeoff + race condition + lock-free + byzantine + state machine" reasoning --plan=pro
  [ "$status" -eq 0 ]
  # reasoning_heavy → P81 (glm-5.2) 이 openrouter overlay(P79) 보다 우선
  [[ "$output" =~ ^(openrouter-|gpt-|glm-5\.2) ]]
}

@test "openrouter prefer-free LOW uses free model" {
  OPENROUTER_ENABLED=true OPENROUTER_PREFER_FREE=true run sm "간단한 코드 수정" coding_general --plan=pro
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(openrouter-|glm-) ]]
}

@test "korean nlp prefers glm series" {
  run sm "한국어 문서 자동 요약 및 토큰화 처리 추가 필요" korean_nlp --plan=pro
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^glm- ]]
}

@test "auto short english task" {
  run sm "add type" auto --plan=pro
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(glm-|gpt-) ]]
}

@test "auto korean coding task" {
  run sm "이 함수에 한국어 주석 추가" auto --plan=pro
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^glm- ]]
}

@test "json output has required keys" {
  run sm "API 마이그레이션 설계" coding_arch --plan=pro --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.model' >/dev/null
  echo "$output" | jq -e '.category' >/dev/null
  echo "$output" | jq -e '.complexity.tier' >/dev/null
  echo "$output" | jq -e '.activePlan' >/dev/null
}

@test "json fallbackChain length gt 1" {
  run sm "정합성 증명" reasoning --plan=pro --json
  [ "$status" -eq 0 ]
  len=$(echo "$output" | jq -r '.fallbackChain | length')
  [ "$len" -gt 1 ]
}

@test "ZAI_CODING_PLAN env sets default plan" {
  ZAI_CODING_PLAN=max run sm "복잡한 보안 감사" security
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^glm- ]] || [[ "$output" =~ ^gpt- ]]
}

@test "--plan flag overrides env" {
  ZAI_CODING_PLAN=max run sm "복잡한 아키텍처 설계" coding_arch --plan=lite
  [ "$status" -eq 0 ]
  [ "$output" != "glm-5.1" ]
}

@test "regression pro coding_general medium = glm-5" {
  run sm "add null check" coding_general --plan=pro
  [ "$output" = "glm-5" ]
}

@test "regression lite never outputs glm-5.1" {
  for q in "간단" "코딩 작업" "리뷰" "디버그" "복잡한 아키텍처"; do
    out=$(sm "$q" auto --plan=lite)
    [ "$out" != "glm-5.1" ]
  done
}

# ── GLM-5.2 (차세대 플래그십) ─────────────────────────────────────────────────
@test "regression lite never outputs glm-5.2 blocked and capped" {
  for q in "간단" "코딩 작업" "복잡한 아키텍처 재설계" "분산 합의 증명 algorithm invariant"; do
    out=$(sm "$q" reasoning --plan=lite)
    [ "$out" != "glm-5.2" ]
  done
}

@test "glm-5.2 registered in routing.json (pro/max allowed, lite blocked)" {
  run jq -e '(.models["glm-5.2"]) and (.plans.pro.allowedModels|index("glm-5.2")) and (.plans.max.allowedModels|index("glm-5.2")) and (.plans.lite.blockedModels|index("glm-5.2"))' "$SKILL_DIR/routing.json"
  [ "$status" -eq 0 ]
}

@test "glm-5.2 is the top glm in pro/max coding+reasoning fallback chains" {
  run jq -e '.fallbackChains.pro.coding[0]=="glm-5.2" and .fallbackChains.max.reasoning[0]=="glm-5.2"' "$SKILL_DIR/routing.json"
  [ "$status" -eq 0 ]
}

@test "matrix HIGH coding/reasoning routes to glm-5.2 (pro+max)" {
  run jq -e '.matrix.pro.coding_arch.HIGH=="glm-5.2" and .matrix.pro.coding_general.HIGH=="glm-5.2" and .matrix.pro.reasoning.HIGH=="glm-5.2" and .matrix.max.coding_arch.HIGH=="glm-5.2" and .matrix.max.reasoning.HIGH=="glm-5.2"' "$SKILL_DIR/routing.json"
  [ "$status" -eq 0 ]
}
