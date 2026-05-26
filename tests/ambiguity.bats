#!/usr/bin/env bats
# ambiguity.sh — Ambiguity Score calculator (US-003)

load helpers

amb() { "$SKILL_DIR/ambiguity.sh" "$@"; }

# ──────────────────────────────────────────────
# Test 1: Clear task → score < 0.2, ambiguous=false, gate exits 0
# ──────────────────────────────────────────────
@test "clear task: score < 0.2 and ambiguous=false" {
  run amb score "add null check to skills/ohmyclaw/state.sh line 42 (must pass bats tests/state.bats)"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -e '.score')
  ambiguous=$(echo "$output" | jq -r '.ambiguous')
  [ "$ambiguous" = "false" ]
  # score must be < 0.2
  awk "BEGIN{exit ($score < 0.2) ? 0 : 1}"
}

@test "clear task: gate exits 0" {
  run amb gate "add null check to skills/ohmyclaw/state.sh line 42 (must pass bats tests/state.bats)"
  [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────
# Test 2: Vague task → score > 0.5, ambiguous=true, gate exits 11
# ──────────────────────────────────────────────
@test "vague task: score > 0.5 and ambiguous=true" {
  run amb score "이거 해줘"
  [ "$status" -eq 0 ]
  score=$(echo "$output" | jq -e '.score')
  ambiguous=$(echo "$output" | jq -r '.ambiguous')
  [ "$ambiguous" = "true" ]
  awk "BEGIN{exit ($score > 0.5) ? 0 : 1}"
}

@test "vague task: gate exits 11" {
  run amb gate "이거 해줘"
  [ "$status" -eq 11 ]
}

# ──────────────────────────────────────────────
# Test 3: contextClarity differs with/without file path anchor
# ──────────────────────────────────────────────
@test "anchor presence: contextClarity differs with vs without src/foo.ts" {
  run amb score "implement login feature"
  [ "$status" -eq 0 ]
  ctx_without=$(echo "$output" | jq -e '.contextClarity')

  run amb score "implement login feature in src/foo.ts"
  [ "$status" -eq 0 ]
  ctx_with=$(echo "$output" | jq -e '.contextClarity')

  # with anchor should be strictly higher
  awk "BEGIN{exit ($ctx_with > $ctx_without) ? 0 : 1}"
}

# ──────────────────────────────────────────────
# Test 4: Constraint keyword raises constraintClarity
# ──────────────────────────────────────────────
@test "constraint keyword: 'implement X in TypeScript' has constraintClarity=1" {
  run amb score "implement login in TypeScript within 1 hour"
  [ "$status" -eq 0 ]
  cc=$(echo "$output" | jq -r '(.constraintClarity == 1) | tostring')
  [ "$cc" = "true" ]
}

@test "no constraint keyword: 'implement X' has constraintClarity=0" {
  run amb score "implement login feature for users"
  [ "$status" -eq 0 ]
  cc=$(echo "$output" | jq -r '(.constraintClarity == 0) | tostring')
  [ "$cc" = "true" ]
}

# ──────────────────────────────────────────────
# Test 5: DoD/test keyword present → successCriteria=1
# ──────────────────────────────────────────────
@test "DoD keyword: 'test must pass' yields successCriteria=1" {
  run amb score "add retry logic to pool.sh (test must pass)"
  [ "$status" -eq 0 ]
  sc=$(echo "$output" | jq -r '(.successCriteria == 1) | tostring')
  [ "$sc" = "true" ]
}

@test "no DoD keyword: successCriteria=0" {
  run amb score "add retry logic to pool.sh for resilience"
  [ "$status" -eq 0 ]
  sc=$(echo "$output" | jq -r '(.successCriteria == 0) | tostring')
  [ "$sc" = "true" ]
}

# ──────────────────────────────────────────────
# Test 6: --threshold flag override
# ──────────────────────────────────────────────
@test "--threshold override: task borderline passes with higher threshold" {
  # A moderately clear task might be ambiguous at 0.2 but not at 0.5
  run amb score "implement retry logic for resilience" --threshold 0.5
  [ "$status" -eq 0 ]
  thr=$(echo "$output" | jq -e '.threshold')
  [ "$thr" = "0.5" ]
}

@test "--threshold override: gate respects custom threshold" {
  # "implement retry" scores ~0.72 — ambiguous at default 0.2, passes at 0.75
  run amb gate "implement retry" --threshold 0.75
  [ "$status" -eq 0 ]
  # confirm same task fails at default threshold
  run amb gate "implement retry"
  [ "$status" -eq 11 ]
}

# ──────────────────────────────────────────────
# Test 7: help and unknown subcommand exit codes
# ──────────────────────────────────────────────
@test "help subcommand exits 0" {
  run amb help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage"
}

@test "unknown subcommand exits 2" {
  run amb foobar "some task"
  [ "$status" -eq 2 ]
}

@test "missing subcommand exits 2" {
  run amb
  [ "$status" -eq 2 ]
}

# ──────────────────────────────────────────────
# Test 8: JSON validity
# ──────────────────────────────────────────────
@test "score output is valid JSON (jq -e .)" {
  run amb score "implement retry logic for pool.sh (test must pass)"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

@test "JSON contains all required keys" {
  run amb score "fix null pointer in src/engine.ts (must pass tests)"
  [ "$status" -eq 0 ]
  result=$(echo "$output" | jq -r '
    has("score") and has("goalClarity") and has("constraintClarity") and
    has("successCriteria") and has("contextClarity") and has("dimensions") and
    has("weights") and has("threshold") and has("ambiguous") | tostring')
  [ "$result" = "true" ]
}

# ──────────────────────────────────────────────
# Test 9: Weights sum to 1.0
# ──────────────────────────────────────────────
@test "weights sum to 1.0" {
  run amb score "任意タスク for testing"
  [ "$status" -eq 0 ]
  sum=$(echo "$output" | jq -e '.weights.goal + .weights.constraint + .weights.success + .weights.context')
  awk "BEGIN{exit ($sum == 1.0) ? 0 : 1}"
}

# ──────────────────────────────────────────────
# Test 10: score formula integrity — score = 1 - Σ(dim×weight)
# ──────────────────────────────────────────────
@test "score field equals 1 - sum(dim * weight)" {
  run amb score "add null check to skills/ohmyclaw/state.sh (must pass tests)"
  [ "$status" -eq 0 ]
  # Verify formula: score ≈ 1 - (goal*0.35 + constraint*0.25 + success*0.25 + context*0.15)
  result=$(echo "$output" | jq -e '
    (1 - (.dimensions.goal * .weights.goal
        + .dimensions.constraint * .weights.constraint
        + .dimensions.success * .weights.success
        + .dimensions.context * .weights.context)) as $expected
    | ((.score - $expected) | fabs) < 0.05
  ')
  [ "$result" = "true" ]
}
