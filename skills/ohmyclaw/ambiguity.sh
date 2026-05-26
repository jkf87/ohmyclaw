#!/usr/bin/env bash
# ohmyclaw skill — Ambiguity Score calculator (US-003)
#
# Inspired by Ouroboros' 4-dimension weighted clarity formula:
#   Ambiguity = 1 - Σ(clarity_i × weight_i)
#
# Usage:
#   ambiguity.sh score "<task text>" [--threshold <0..0.99>]
#   ambiguity.sh gate  "<task text>" [--threshold <0..0.99>]
#   ambiguity.sh help
#
# score: outputs single-line JSON with all dimensions and ambiguous flag.
# gate:  same JSON + exits 11 if ambiguous=true, 0 otherwise.
#
# Dimensions (weights):
#   goal        (0.35) — length ≥15 + verb-like + ≥3 words
#   constraint  (0.25) — must/should/within/framework/stack/language keywords
#   success     (0.25) — test/pass/criteria/DoD/done-when keywords
#   context     (0.15) — file path / function / repo path anchors
#
# No LLM, no external services — pure bash + jq.

set -uo pipefail

# ──────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────
readonly W_GOAL=0.35
readonly W_CONSTRAINT=0.25
readonly W_SUCCESS=0.25
readonly W_CONTEXT=0.15
readonly DEFAULT_THRESHOLD=0.2

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required (brew install jq)" >&2
    exit 2
  fi
}

_usage() {
  cat >&2 <<'EOF'
Usage:
  ambiguity.sh score "<task text>" [--threshold <0..0.99>]
  ambiguity.sh gate  "<task text>" [--threshold <0..0.99>]
  ambiguity.sh help

Commands:
  score   Compute ambiguity score and print JSON.
  gate    Same as score; exit 11 if ambiguous=true, 0 otherwise.
  help    Show this help.

Dimensions (weights):
  goal        (0.35) length>=15 + verb-like word + >=3 words
  constraint  (0.25) keyword: must/should/within/by/until/stack/framework/language/...
  success     (0.25) keyword: test/pass/criteria/DoD/done when/acceptance/...
  context     (0.15) anchor count: file path / function pattern / repo path

Options:
  --threshold <float>   Override default gate threshold 0.2 (range 0..0.99).
EOF
}

# ──────────────────────────────────────────────
# Dimension calculators
# ──────────────────────────────────────────────

# goal_clarity: length>=15 (+0.4) + verb-like word (+0.4) + >=3 words (+0.2). Clamp 1.0.
_dim_goal() {
  local text="$1"
  local score=0

  # length >= 15 chars
  if (( ${#text} >= 15 )); then
    score=$(awk "BEGIN{printf \"%.6f\", $score + 0.4}")
  fi

  # verb-like word (case-insensitive, Korean + English)
  if echo "$text" | grep -qiE '(^|[[:space:]|\(|\[|"|'"'"'])(add|fix|implement|refactor|build|추가|수정|구현|리팩토링)([[:space:]|\)|]|"|'"'"'|$)'; then
    score=$(awk "BEGIN{printf \"%.6f\", $score + 0.4}")
  fi

  # word count >= 3 (split on whitespace)
  local word_count
  word_count=$(echo "$text" | wc -w | tr -d ' ')
  if (( word_count >= 3 )); then
    score=$(awk "BEGIN{printf \"%.6f\", $score + 0.2}")
  fi

  # clamp to 1.0
  awk "BEGIN{v=$score; if(v>1.0) v=1.0; printf \"%.6f\", v}"
}

# constraint_clarity: any constraint keyword → 1.0, else 0.0
_dim_constraint() {
  local text="$1"
  if echo "$text" | grep -qiE '(must|should|within|by |until|stack|framework|typescript|python|node\.?js|bash|java|ruby|golang|rust|까지|내로|스택|제약)'; then
    echo "1.000000"
  else
    echo "0.000000"
  fi
}

# success_clarity: DoD/test/pass/criteria keywords → 1.0, else 0.0
_dim_success() {
  local text="$1"
  if echo "$text" | grep -qiE '(test|pass|criteria|DoD|done when|acceptance|통과|테스트|완료조건|수용기준)'; then
    echo "1.000000"
  else
    echo "0.000000"
  fi
}

# context_clarity: 0 anchors→0, 1→0.5, 2+→1.0
_dim_context() {
  local text="$1"
  local anchors=0

  # file path: extension .ts .py .sh .md .js .json .yaml .yml .go .rb or bare /
  if echo "$text" | grep -qE '(\.[a-zA-Z]{1,4}(:[0-9]+)?|/)'; then
    if echo "$text" | grep -qE '\.(ts|py|sh|md|js|json|yaml|yml|go|rb|rs|java|txt)(:[0-9]+)?|/'; then
      anchors=$(( anchors + 1 ))
    fi
  fi

  # function name pattern: identifier() or def identifier or fn identifier
  if echo "$text" | grep -qE '([a-zA-Z_][a-zA-Z0-9_]*\(\)|def [a-zA-Z_][a-zA-Z0-9_]*|fn [a-zA-Z_][a-zA-Z0-9_]*)'; then
    anchors=$(( anchors + 1 ))
  fi

  # repo path segments: src/ tests/ skills/ lib/ pkg/ cmd/ dist/ internal/
  if echo "$text" | grep -qE '(src/|tests/|skills/|lib/|pkg/|cmd/|dist/|internal/)'; then
    anchors=$(( anchors + 1 ))
  fi

  if (( anchors == 0 )); then
    echo "0.000000"
  elif (( anchors == 1 )); then
    echo "0.500000"
  else
    echo "1.000000"
  fi
}

# ──────────────────────────────────────────────
# Core score computation
# ──────────────────────────────────────────────
_compute_score() {
  local text="$1"
  local threshold="${2:-$DEFAULT_THRESHOLD}"

  local goal constraint success context
  goal=$(_dim_goal       "$text")
  constraint=$(_dim_constraint "$text")
  success=$(_dim_success    "$text")
  context=$(_dim_context    "$text")

  # score = 1 - Σ(dim_i × weight_i)
  local score
  score=$(awk "BEGIN{
    g=$goal; c=$constraint; s=$success; cx=$context;
    wg=$W_GOAL; wc=$W_CONSTRAINT; ws=$W_SUCCESS; wcx=$W_CONTEXT;
    v = 1.0 - (g*wg + c*wc + s*ws + cx*wcx);
    if(v<0) v=0;
    if(v>1) v=1;
    printf \"%.6f\", v
  }")

  local ambiguous
  ambiguous=$(awk "BEGIN{print ($score > $threshold) ? \"true\" : \"false\"}")

  # Round to 2 decimal places for the "score" top-level field (as spec shows 0.45)
  # but keep full precision for dimensions
  local score_r2 goal_r2 constraint_r2 success_r2 context_r2
  score_r2=$(awk "BEGIN{printf \"%.2f\", $score}")
  goal_r2=$(awk "BEGIN{printf \"%.1f\", $goal}")
  constraint_r2=$(awk "BEGIN{printf \"%.1f\", $constraint}")
  success_r2=$(awk "BEGIN{printf \"%.1f\", $success}")
  context_r2=$(awk "BEGIN{printf \"%.1f\", $context}")

  jq -cn \
    --argjson score        "$score_r2" \
    --argjson goalClarity  "$goal_r2" \
    --argjson constraintClarity "$constraint_r2" \
    --argjson successCriteria "$success_r2" \
    --argjson contextClarity  "$context_r2" \
    --argjson threshold    "$threshold" \
    --argjson ambiguous    "$ambiguous" \
    '{
      score:              $score,
      goalClarity:        $goalClarity,
      constraintClarity:  $constraintClarity,
      successCriteria:    $successCriteria,
      contextClarity:     $contextClarity,
      dimensions: {
        goal:       $goalClarity,
        constraint: $constraintClarity,
        success:    $successCriteria,
        context:    $contextClarity
      },
      weights: {
        goal:       0.35,
        constraint: 0.25,
        success:    0.25,
        context:    0.15
      },
      threshold:  $threshold,
      ambiguous:  $ambiguous
    }'
}

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────
_parse_threshold() {
  # $1 = potential "--threshold", $2 = value
  # echoes the threshold or the default
  local thr="$DEFAULT_THRESHOLD"
  if [[ "${1:-}" == "--threshold" ]]; then
    local val="${2:-}"
    if [[ -z "$val" ]]; then
      echo "ERROR: --threshold requires a value" >&2; exit 2
    fi
    # validate range 0..0.99
    if ! awk "BEGIN{v=$val+0; exit (v>=0 && v<=0.99) ? 0 : 1}" 2>/dev/null; then
      echo "ERROR: --threshold must be in range 0..0.99" >&2; exit 2
    fi
    thr="$val"
  fi
  echo "$thr"
}

# ──────────────────────────────────────────────
# Subcommand dispatch
# ──────────────────────────────────────────────
_cmd="${1:-}"

case "$_cmd" in
  help|--help|-h)
    _usage
    exit 0
    ;;

  score)
    _require_jq
    _task="${2:-}"
    if [[ -z "$_task" ]]; then
      echo "ERROR: 'score' requires a task text argument" >&2; exit 2
    fi
    _thr=$(_parse_threshold "${3:-}" "${4:-}")
    _compute_score "$_task" "$_thr"
    ;;

  gate)
    _require_jq
    _task="${2:-}"
    if [[ -z "$_task" ]]; then
      echo "ERROR: 'gate' requires a task text argument" >&2; exit 2
    fi
    _thr=$(_parse_threshold "${3:-}" "${4:-}")
    _json=$(_compute_score "$_task" "$_thr")
    echo "$_json"
    _amb=$(echo "$_json" | jq -r '.ambiguous')
    if [[ "$_amb" == "true" ]]; then
      exit 11
    fi
    exit 0
    ;;

  "")
    echo "ERROR: subcommand required. Run 'ambiguity.sh help'." >&2
    exit 2
    ;;

  *)
    echo "ERROR: unknown subcommand '$_cmd'. Run 'ambiguity.sh help'." >&2
    exit 2
    ;;
esac
