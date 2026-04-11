#!/usr/bin/env bash
# ohmyclaw skill — model router (jq-based, deterministic)
#
# Usage:
#   select-model.sh <task-text> [category] [--plan=lite|pro|max] [--codex] [--openrouter] [--prefer-free] [--openrouter-model=<id>] [--json]
#
# Examples:
#   select-model.sh "REST API 인증 미들웨어 설계" coding_arch --plan=pro
#   select-model.sh "분산 합의 알고리즘 정합성 증명" reasoning --plan=max --codex
#   select-model.sh "$(cat task.md)" auto --plan=pro --json
#   select-model.sh "architectural refactor design" coding_arch --plan=pro --openrouter
#   select-model.sh "간단한 코드 수정" coding_general --openrouter --prefer-free
#   select-model.sh "deep analysis task" auto --openrouter-model=openrouter-claude-opus-4
#
# Reads: routing.json (same directory)
# Outputs: model id (one line) OR full JSON decision (--json)
#
# Env overrides:
#   ZAI_CODING_PLAN=lite|pro|max
#   CODEX_OAUTH_ENABLED=true|false
#   OPENROUTER_ENABLED=true|false
#   OPENROUTER_PREFER_FREE=true|false      (기본: false, true 시 LOW/MEDIUM 작업에 무료 모델 우선)
#   OPENROUTER_MODEL_OVERRIDE=<model-id>   (특정 OpenRouter 모델 강제 지정, --openrouter-model 과 동일)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTING_FILE="${SCRIPT_DIR}/routing.json"

if [[ ! -f "$ROUTING_FILE" ]]; then
  echo "ERROR: routing.json not found at $ROUTING_FILE" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required (brew install jq)" >&2
  exit 2
fi

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────
TASK_TEXT="${1:-}"
CATEGORY="${2:-auto}"
PLAN="${ZAI_CODING_PLAN:-pro}"
CODEX="${CODEX_OAUTH_ENABLED:-false}"
OPENROUTER="${OPENROUTER_ENABLED:-false}"
PREFER_FREE="${OPENROUTER_PREFER_FREE:-false}"
OPENROUTER_MODEL_OVERRIDE="${OPENROUTER_MODEL_OVERRIDE:-}"
OUTPUT_JSON=false

shift 2 2>/dev/null || true
for arg in "$@"; do
  case "$arg" in
    --plan=*)              PLAN="${arg#*=}" ;;
    --codex)               CODEX=true ;;
    --no-codex)            CODEX=false ;;
    --openrouter)          OPENROUTER=true ;;
    --no-openrouter)       OPENROUTER=false ;;
    --prefer-free)         PREFER_FREE=true ;;
    --no-prefer-free)      PREFER_FREE=false ;;
    --openrouter-model=*)
      OPENROUTER_MODEL_OVERRIDE="${arg#*=}"
      if [[ -z "$OPENROUTER_MODEL_OVERRIDE" ]]; then
        echo "ERROR: --openrouter-model 값이 비어있습니다" >&2
        exit 2
      fi
      ;;
    --json)                OUTPUT_JSON=true ;;
  esac
done

# --openrouter-model 지정 시 자동으로 OpenRouter 활성화
if [[ -n "$OPENROUTER_MODEL_OVERRIDE" ]]; then
  OPENROUTER=true
fi

if [[ -z "$TASK_TEXT" ]]; then
  cat >&2 <<EOF
Usage: $0 <task-text> [category] [--plan=lite|pro|max] [--codex] [--openrouter] [--prefer-free] [--openrouter-model=<id>] [--json]
Categories: auto, coding_general, coding_arch, korean_nlp, reasoning,
            debugging, content_creation, data_analysis, security
EOF
  exit 1
fi

case "$PLAN" in lite|pro|max) ;; *) echo "ERROR: invalid plan '$PLAN'" >&2; exit 2 ;; esac

# --openrouter-model 유효성 검증: routing.json 에 openrouterId 가 있는 모델만 허용
if [[ -n "$OPENROUTER_MODEL_OVERRIDE" ]]; then
  VALID=$(jq -r --arg m "$OPENROUTER_MODEL_OVERRIDE" \
    'if .models[$m].openrouterId then "yes" else "no" end' "$ROUTING_FILE")
  if [[ "$VALID" != "yes" ]]; then
    VALID_LIST=$(jq -r '[.models | to_entries[] | select(.value.openrouterId) | .key] | join(", ")' "$ROUTING_FILE")
    echo "ERROR: unknown OpenRouter model '$OPENROUTER_MODEL_OVERRIDE'" >&2
    echo "Valid models: $VALID_LIST" >&2
    exit 2
  fi
fi

# ──────────────────────────────────────────────
# Korean ratio
# ──────────────────────────────────────────────
korean_ratio() {
  local text="$1"
  if command -v python3 >/dev/null 2>&1; then
    TEXT="$text" python3 -c '
import os, re
t = re.sub(r"\s+", "", os.environ["TEXT"])
total = len(t)
ko = len(re.findall(r"[가-힣]", t))
print(f"{ko/total if total else 0:.3f}")
'
  else
    echo "0.0"
  fi
}

KOREAN_RATIO=$(korean_ratio "$TASK_TEXT")

# ──────────────────────────────────────────────
# Reasoning-heavy detection
# ──────────────────────────────────────────────
detect_reasoning_heavy() {
  local text="$1" cat="$2" score=0
  local kws_ko kws_en
  kws_ko=$(jq -r '.reasoningDetection.keywordsKo | join("|")' "$ROUTING_FILE")
  kws_en=$(jq -r '.reasoningDetection.keywordsEn | join("|")' "$ROUTING_FILE")

  if echo "$text" | grep -qE "($kws_ko)"; then score=$((score + 2)); fi
  if echo "$text" | grep -qiE "($kws_en)"; then score=$((score + 2)); fi

  if jq -e --arg c "$cat" '.reasoningDetection.categories | index($c)' "$ROUTING_FILE" >/dev/null 2>&1; then
    score=$((score + 1))
  fi

  local min
  min=$(jq -r '.reasoningDetection.minScore' "$ROUTING_FILE")
  if [[ $score -ge $min ]]; then echo true; else echo false; fi
}

REASONING_HEAVY=$(detect_reasoning_heavy "$TASK_TEXT" "$CATEGORY")

# ──────────────────────────────────────────────
# Auto category detection (very lightweight heuristic)
# ──────────────────────────────────────────────
auto_category() {
  local t="$1"
  if echo "$t" | grep -qiE "(security|owasp|injection|csrf|jwt|보안|인증|침투)"; then echo "security"; return; fi
  if echo "$t" | grep -qiE "(architecture|migration|refactor|design|아키텍처|마이그레이션|리팩토링|설계)"; then echo "coding_arch"; return; fi
  if echo "$t" | grep -qiE "(prove|proof|algorithm|complexity|증명|알고리즘|복잡도)"; then echo "reasoning"; return; fi
  if echo "$t" | grep -qiE "(bug|error|crash|fail|디버그|에러|크래시|버그)"; then echo "debugging"; return; fi
  if echo "$t" | grep -qiE "(blog|article|글|콘텐츠|번역)"; then echo "content_creation"; return; fi
  if echo "$t" | grep -qiE "(analyze|dataset|sql|쿼리|분석)"; then echo "data_analysis"; return; fi
  if [[ "$(awk "BEGIN { print ($KOREAN_RATIO > 0.7) }")" == "1" ]]; then echo "korean_nlp"; return; fi
  echo "coding_general"
}

if [[ "$CATEGORY" == "auto" ]]; then
  CATEGORY=$(auto_category "$TASK_TEXT")
fi

# ──────────────────────────────────────────────
# Complexity score (lexical signals)
# ──────────────────────────────────────────────
complexity_score() {
  local t="$1" s=0 wc fp arch_n sec_n reason_n
  # 한국어는 wc -w 가 부정확 — 단어 수 + (한국어 글자 / 3) 으로 보정
  wc=$(echo "$t" | wc -w | tr -d ' ')
  local ko_chars
  if command -v python3 >/dev/null 2>&1; then
    ko_chars=$(TEXT="$t" python3 -c '
import os, re
print(len(re.findall(r"[가-힣]", os.environ["TEXT"])))
')
  else
    ko_chars=0
  fi
  wc=$((wc + ko_chars / 3))

  if [[ $wc -ge 50  ]]; then s=$((s + 1)); fi
  if [[ $wc -ge 100 ]]; then s=$((s + 2)); fi
  if [[ $wc -ge 200 ]]; then s=$((s + 3)); fi

  fp=$(echo "$t" | grep -oE '[a-zA-Z0-9_/.-]+\.(ts|js|py|sh|md|yaml|json|tsx|rs|go)' | wc -l | tr -d ' ')
  if [[ $fp -ge 1 ]]; then s=$((s + 1)); fi
  if [[ $fp -ge 3 ]]; then s=$((s + 2)); fi

  # 키워드 매치 수 (grep -o 로 개별 매치 카운트)
  arch_n=$(echo "$t" | grep -oiE "(architect|migration|refactor|아키텍처|마이그레이션|리팩토링|시스템 설계|다중 서비스)" | wc -l | tr -d ' ')
  if [[ $arch_n -ge 1 ]]; then s=$((s + 5)); fi
  if [[ $arch_n -ge 3 ]]; then s=$((s + 2)); fi

  sec_n=$(echo "$t" | grep -oiE "(owasp|injection|csrf|jwt|oauth|침투|보안|인증|토큰)" | wc -l | tr -d ' ')
  if [[ $sec_n -ge 1 ]]; then s=$((s + 3)); fi
  if [[ $sec_n -ge 3 ]]; then s=$((s + 2)); fi

  reason_n=$(echo "$t" | grep -oiE "(prove|proof|invariant|complexity|big-?o|algorithm|증명|알고리즘|복잡도|불변|race condition|consensus)" | wc -l | tr -d ' ')
  if [[ $reason_n -ge 1 ]]; then s=$((s + 3)); fi
  if [[ $reason_n -ge 2 ]]; then s=$((s + 2)); fi

  # 단순 키워드 강하 차감
  if echo "$t" | grep -qiE "(simple|trivial|quick|간단|빠른|단순|타입만|주석만)"; then s=$((s - 3)); fi

  if [[ $s -lt 0 ]]; then s=0; fi
  echo $s
}

SCORE=$(complexity_score "$TASK_TEXT")

if [[ $SCORE -ge 10 ]]; then TIER=HIGH
elif [[ $SCORE -ge 5 ]]; then TIER=MEDIUM
else TIER=LOW
fi

# ──────────────────────────────────────────────
# Resolve model (priority order — first match wins)
# ──────────────────────────────────────────────
PICKED=""
REASON=""

# P99: explicit openrouter model override — 모든 자동 라우팅 우선
if [[ -z "$PICKED" && -n "$OPENROUTER_MODEL_OVERRIDE" ]]; then
  PICKED="$OPENROUTER_MODEL_OVERRIDE"
  REASON="openrouter_model_override (P99)"
fi

# P82: reasoning_heavy + Codex → gpt-5.4
if [[ -z "$PICKED" && "$CODEX" == "true" && "$REASONING_HEAVY" == "true" ]]; then
  PICKED="gpt-5.4"
  REASON="reasoning_heavy + codex (P82, extended thinking)"
fi

# P81: reasoning_heavy + Pro/Max → glm-5.1
if [[ -z "$PICKED" && "$REASONING_HEAVY" == "true" && "$PLAN" != "lite" ]]; then
  PICKED="glm-5.1"
  REASON="reasoning_heavy + ${PLAN} (P81)"
fi

# P81b: reasoning_heavy + Lite → glm-5
if [[ -z "$PICKED" && "$REASONING_HEAVY" == "true" && "$PLAN" == "lite" ]]; then
  PICKED="glm-5"
  REASON="reasoning_heavy + lite cap (P81b)"
fi

# P80: codex overlay
if [[ -z "$PICKED" && "$CODEX" == "true" ]]; then
  OVERLAY=$(jq -r --arg c "$CATEGORY" --arg t "$TIER" \
    '.codexOverlay.overrides[$c][$t] // empty' "$ROUTING_FILE")
  if [[ -n "$OVERLAY" ]]; then
    PICKED="$OVERLAY"
    REASON="codex_overlay ${CATEGORY}/${TIER} (P80)"
  fi
fi

# P78: openrouter prefer_free overlay (LOW/MEDIUM만 적용, HIGH는 P79로 위임)
if [[ -z "$PICKED" && "$OPENROUTER" == "true" && "$PREFER_FREE" == "true" ]]; then
  OVERLAY=$(jq -r --arg c "$CATEGORY" --arg t "$TIER" \
    '.openrouterFreeOverlay.overrides[$c][$t] // empty' "$ROUTING_FILE")
  if [[ -n "$OVERLAY" ]]; then
    PICKED="$OVERLAY"
    REASON="openrouter_free_overlay ${CATEGORY}/${TIER} (P78)"
  fi
fi

# P79: openrouter overlay
if [[ -z "$PICKED" && "$OPENROUTER" == "true" ]]; then
  OVERLAY=$(jq -r --arg c "$CATEGORY" --arg t "$TIER" \
    '.openrouterOverlay.overrides[$c][$t] // empty' "$ROUTING_FILE")
  if [[ -n "$OVERLAY" ]]; then
    PICKED="$OVERLAY"
    REASON="openrouter_overlay ${CATEGORY}/${TIER} (P79)"
  fi
fi

# P75/P50/P0: plan matrix
if [[ -z "$PICKED" ]]; then
  PICKED=$(jq -r --arg p "$PLAN" --arg c "$CATEGORY" --arg t "$TIER" \
    '.matrix[$p][$c][$t] // .matrix[$p].coding_general[$t]' "$ROUTING_FILE")
  REASON="matrix[${PLAN}][${CATEGORY}][${TIER}]"
fi

# P95 plan_block: lite 에서 glm-5.1 등장 시 강등
if [[ "$PLAN" == "lite" && "$PICKED" == "glm-5.1" ]]; then
  PICKED="glm-5"
  REASON="${REASON} → cap_for_lite"
fi

# ──────────────────────────────────────────────
# Fallback chain
# ──────────────────────────────────────────────
if [[ -n "$OPENROUTER_MODEL_OVERRIDE" || "$OPENROUTER" == "true" ]]; then
  # --openrouter-model 지정 시 codex 활성화 여부와 무관하게 withOpenRouter fallback 사용
  case "$CATEGORY" in
    coding_*|debugging) FB_KEY="coding" ;;
    korean_nlp|content_creation) FB_KEY="korean" ;;
    reasoning)          FB_KEY="reasoning" ;;
    security)           FB_KEY="security" ;;
    data_analysis)      FB_KEY="data" ;;
    *)                  FB_KEY="coding" ;;
  esac
  CHAIN=$(jq -r --arg k "$FB_KEY" '.fallbackChains.withOpenRouter[$k] // .fallbackChains.withOpenRouter.coding | join(",")' "$ROUTING_FILE")
elif [[ "$CODEX" == "true" ]]; then
  case "$CATEGORY" in
    coding_*|debugging) FB_KEY="coding" ;;
    security)           FB_KEY="security" ;;
    reasoning)          FB_KEY="reasoning" ;;
    *)                  FB_KEY="coding" ;;
  esac
  CHAIN=$(jq -r --arg k "$FB_KEY" '.fallbackChains.withCodex[$k] // .fallbackChains.withCodex.coding | join(",")' "$ROUTING_FILE")
else
  case "$CATEGORY" in
    korean_nlp|content_creation) FB_KEY="korean" ;;
    reasoning)                   FB_KEY="reasoning" ;;
    *)                           FB_KEY="coding" ;;
  esac
  CHAIN=$(jq -r --arg p "$PLAN" --arg k "$FB_KEY" '.fallbackChains[$p][$k] | join(",")' "$ROUTING_FILE")
fi
# Prepend picked, dedupe
FALLBACK="${PICKED},${CHAIN}"
FALLBACK=$(echo "$FALLBACK" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')

# ──────────────────────────────────────────────
# Output
# ──────────────────────────────────────────────
if [[ "$OUTPUT_JSON" == "true" ]]; then
  jq -n \
    --arg model "$PICKED" \
    --arg category "$CATEGORY" \
    --arg tier "$TIER" \
    --arg score "$SCORE" \
    --arg ko "$KOREAN_RATIO" \
    --arg rh "$REASONING_HEAVY" \
    --arg plan "$PLAN" \
    --arg codex "$CODEX" \
    --arg openrouter "$OPENROUTER" \
    --arg prefer_free "$PREFER_FREE" \
    --arg or_model_override "$OPENROUTER_MODEL_OVERRIDE" \
    --arg reason "$REASON" \
    --arg fallback "$FALLBACK" \
    '{
      model: $model,
      category: $category,
      complexity: { score: ($score|tonumber), tier: $tier },
      koreanRatio: ($ko|tonumber),
      reasoningHeavy: ($rh == "true"),
      activePlan: $plan,
      codexOauthEnabled: ($codex == "true"),
      openrouterEnabled: ($openrouter == "true"),
      openrouterPreferFree: ($prefer_free == "true"),
      openrouterModelOverride: (if $or_model_override == "" then null else $or_model_override end),
      reason: $reason,
      fallbackChain: ($fallback | split(","))
    }'
else
  echo "$PICKED"
fi
