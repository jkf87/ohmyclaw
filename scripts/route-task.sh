#!/usr/bin/env bash
# OpenClaw 하네스 — 태스크 라우팅 스크립트
# 입력: 태스크 설명 텍스트
# 출력: 최적 모델 선택 결과 (YAML)
# 사용법: ./route-task.sh "태스크 설명" [카테고리] [예산프로파일]
set -euo pipefail

# ──────────────────────────────────────────────
# 설정
# ──────────────────────────────────────────────
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

TASK_TEXT="${1:-}"
CATEGORY="${2:-auto}"
# 3번째 인자는 usage 에 남아 있으나 현재 라우팅 로직이 사용하지 않는다.
# (플랜/예산 결정은 routing/plans.yaml 의 active_plan 이 담당)
# shellcheck disable=SC2034  # CLI 호환을 위해 받기만 한다
BUDGET_PROFILE="${3:-standard}"

if [[ -z "$TASK_TEXT" ]]; then
    echo "사용법: $0 <태스크 설명> [카테고리] [예산프로파일]" >&2
    echo "카테고리: coding_general, coding_arch, korean_nlp, reasoning, debugging, content_creation, data_analysis, security" >&2
    echo "예산: minimal, standard, full" >&2
    exit 1
fi

# ──────────────────────────────────────────────
# 한국어 비율 감지
# ──────────────────────────────────────────────
detect_korean_ratio() {
    local text="$1"
    local total_chars
    local korean_chars

    # UTF-8 문자를 정확히 세기 위해 python3를 우선 사용한다.
    # python3가 없으면 기존 바이트 기반 계산으로 폴백한다.
    if command -v python3 >/dev/null 2>&1; then
        local counts
        counts=$(TEXT="$text" python3 <<'PY'
import os, re
text = os.environ.get("TEXT", "")
stripped = re.sub(r"\s+", "", text)
total = len(stripped)
korean = len(re.findall(r"[가-힣]", stripped))
print(f"{total} {korean}")
PY
)
        total_chars=$(printf '%s' "$counts" | awk '{print $1}')
        korean_chars=$(printf '%s' "$counts" | awk '{print $2}')
    else
        total_chars=$(printf '%s' "$text" | tr -d '[:space:]' | wc -c | xargs)
        korean_chars=$(printf '%s' "$text" | LC_ALL=C grep -o '[가-힣]' 2>/dev/null | wc -l | xargs || echo "0")
    fi

    if [[ "$total_chars" -eq 0 ]]; then
        echo "0.0"
        return
    fi

    # 비율 계산 (소수점 2자리)
    local ratio
    ratio=$(awk "BEGIN { printf \"%.2f\", ${korean_chars} / ${total_chars} }")
    echo "$ratio"
}

# ──────────────────────────────────────────────
# 복잡도 점수 계산 (어휘 신호 기반)
# ──────────────────────────────────────────────
calculate_complexity() {
    local text="$1"
    local score=0

    # 단어 수
    local word_count
    word_count=$(echo "$text" | wc -w | tr -d ' ')
    if [[ "$word_count" -gt 500 ]]; then
        score=$((score + 3))
    elif [[ "$word_count" -gt 200 ]]; then
        score=$((score + 2))
    elif [[ "$word_count" -gt 25 ]]; then
        score=$((score + 1))
    fi

    # 문자 수 (한국어 장문 요청 보정)
    local char_count
    char_count=$(printf '%s' "$text" | wc -c | xargs)
    if [[ "$char_count" -gt 90 ]]; then
        score=$((score + 1))
    fi

    # 아키텍처 키워드
    if echo "$text" | grep -qiE '설계|아키텍처|architecture|마이그레이션|migration|리팩토링|refactor|시스템.*설계'; then
        score=$((score + 3))
    fi

    # 고난도 추론/기획 키워드
    if echo "$text" | grep -qiE '전략|로드맵|장기|리스크|대안|트레이드오프|trade[- ]?off|의사결정|decision|비교|compare|분석하고.*설계|관점|우선순위|종합'; then
        score=$((score + 4))
    fi

    # 디버깅 키워드
    if echo "$text" | grep -qiE '에러|error|버그|bug|크래시|crash|실패|fail|exception'; then
        score=$((score + 2))
    fi

    # 장문 요청/다단 지시 보정
    if echo "$text" | grep -qE '그리고|또는|뿐만 아니라|동시에|까지|및'; then
        score=$((score + 2))
    fi

    # 단순 키워드 (감점) — 고난도 키워드가 없을 때만
    if ! echo "$text" | grep -qiE '전략|로드맵|리스크|대안|트레이드오프|의사결정|비교|설계|architecture'; then
        if echo "$text" | grep -qiE '조회|확인|포맷|변환|convert|format|check|list'; then
            score=$((score - 2))
        fi
    fi

    # 파일 경로 수
    local file_count
    file_count=$(echo "$text" | grep -oE '[a-zA-Z0-9_/.-]+\.[a-zA-Z]{1,5}' | wc -l | tr -d ' ')
    if [[ "$file_count" -gt 3 ]]; then
        score=$((score + 2))
    fi

    # 코드 블록 수
    local code_blocks
    code_blocks=$(echo "$text" | grep -c '```' || true)
    if [[ "$code_blocks" -gt 2 ]]; then
        score=$((score + 1))
    fi

    # 최소 0
    if [[ "$score" -lt 0 ]]; then
        score=0
    fi

    echo "$score"
}

# ──────────────────────────────────────────────
# 복잡도 티어 결정
# ──────────────────────────────────────────────
get_complexity_tier() {
    local score="$1"
    if [[ "$score" -le 4 ]]; then
        echo "LOW"
    elif [[ "$score" -le 9 ]]; then
        echo "MEDIUM"
    else
        echo "HIGH"
    fi
}

# ──────────────────────────────────────────────
# 카테고리 자동 감지
# ──────────────────────────────────────────────
detect_category() {
    local text="$1"

    # 디버깅 (가장 명확한 키워드 우선)
    if echo "$text" | grep -qiE '디버그|debug|버그|bug|에러|error|fix|고쳐|오류'; then
        echo "debugging"
        return
    fi

    # 아키텍처 (보안보다 먼저 — "인증 서비스 설계"는 coding_arch)
    if echo "$text" | grep -qiE '아키텍처|architecture|설계|design|시스템.*구조|마이그레이션|migration'; then
        echo "coding_arch"
        return
    fi

    # 보안 (인증 단독 키워드는 제외 — 아키텍처에서 잡히도록)
    if echo "$text" | grep -qiE '보안|security|취약점|vulnerability|XSS|injection|OWASP|취약'; then
        echo "security"
        return
    fi

    # 데이터 분석
    if echo "$text" | grep -qiE '데이터.*분석|data.*analysis|통계|statistics|시각화|visualization|차트|chart'; then
        echo "data_analysis"
        return
    fi

    # 한국어 NLP/콘텐츠
    local korean_ratio
    korean_ratio=$(detect_korean_ratio "$text")
    if awk "BEGIN { exit !($korean_ratio > 0.7) }"; then
        if echo "$text" | grep -qiE '코드|code|구현|implement|함수|function|클래스|class|만들어|앱|app|서버|server|API|빌드|build'; then
            echo "coding_general"
        else
            echo "korean_nlp"
        fi
        return
    fi

    # 콘텐츠 생성
    if echo "$text" | grep -qiE '문서|document|작성|write|번역|translate|요약|summary|콘텐츠|content'; then
        echo "content_creation"
        return
    fi

    # 기본: 코딩
    echo "coding_general"
}

# ──────────────────────────────────────────────
# 모델 결정
# ──────────────────────────────────────────────
# 활성 플랜 / Codex OAuth 토글 (env > plans.yaml > 기본값)
detect_active_plan() {
    if [[ -n "${ZAI_CODING_PLAN:-}" ]]; then
        echo "$ZAI_CODING_PLAN"
        return
    fi
    local plans_file
    plans_file="$(cd "$(dirname "$0")/.." && pwd)/routing/plans.yaml"
    if [[ -f "$plans_file" ]]; then
        awk '/^active_plan:/ { print $2; exit }' "$plans_file" 2>/dev/null || echo "pro"
    else
        echo "pro"
    fi
}

detect_codex_enabled() {
    if [[ "${CODEX_OAUTH_ENABLED:-}" == "true" ]]; then
        echo "true"
        return
    fi
    local plans_file
    plans_file="$(cd "$(dirname "$0")/.." && pwd)/routing/plans.yaml"
    if [[ -f "$plans_file" ]]; then
        awk '/^codex_oauth_enabled:/ { print $2; exit }' "$plans_file" 2>/dev/null || echo "false"
    else
        echo "false"
    fi
}

# Lite 플랜 모델 강등
cap_for_lite() {
    case "$1" in
        glm-5.1) echo "glm-5" ;;
        *)       echo "$1" ;;
    esac
}

# 추론 집약(reasoning-heavy) 태스크 감지
# 반환: "true" | "false"
detect_reasoning_heavy() {
    local text="$1"
    local category="$2"
    local score=0

    # 한국어 추론 키워드
    if echo "$text" | grep -qE "(증명|알고리즘|복잡도|수학|최적화|정합성|상태 머신|불변조건|race condition|분산 합의|정렬 증명)"; then
        score=$((score + 2))
    fi
    # 영문 추론 키워드
    if echo "$text" | grep -qiE "(prove|proof|invariant|complexity|big-?o|algorithm|optimization|theorem|derive|tradeoff|race condition|distributed consensus)"; then
        score=$((score + 2))
    fi
    # 카테고리 힌트 (reasoning/coding_arch/data_analysis/security)
    case "$category" in
        reasoning|coding_arch|data_analysis|security) score=$((score + 1)) ;;
    esac

    if [[ $score -ge 2 ]]; then echo "true"; else echo "false"; fi
}

resolve_model() {
    local category="$1"
    local tier="$2"
    local korean_ratio="$3"
    local reasoning_heavy="${4:-false}"
    local plan codex_enabled
    plan="$(detect_active_plan)"
    codex_enabled="$(detect_codex_enabled)"

    local picked=""

    # ── P82: 추론 집약 + Codex 활성 → extended thinking ──
    # 추론 집약은 복잡도 점수와 무관하게 모델을 격상한다 (짧지만 어려운 증명/알고리즘 태스크 대응)
    if [[ -z "$picked" ]] && [[ "$codex_enabled" == "true" ]] && [[ "$reasoning_heavy" == "true" ]]; then
        picked="gpt-5.4"
    fi

    # ── P81: 추론 집약 + Pro/Max → glm-5.1 ──
    if [[ -z "$picked" ]] && [[ "$reasoning_heavy" == "true" ]] && [[ "$plan" != "lite" ]]; then
        picked="glm-5.1"
    fi

    # ── P81b: 추론 집약 + Lite → glm-5 (상한) ──
    if [[ -z "$picked" ]] && [[ "$reasoning_heavy" == "true" ]] && [[ "$plan" == "lite" ]]; then
        picked="glm-5"
    fi

    # ── Codex OAuth 오버레이 (활성화 시) ──
    if [[ -z "$picked" ]] && [[ "$codex_enabled" == "true" ]]; then
        case "${category}_${tier}" in
            coding_arch_HIGH|coding_arch_MEDIUM) picked="gpt-5.4" ;;
            coding_general_HIGH)                 picked="gpt-5.4" ;;
            debugging_HIGH)                      picked="gpt-5.4" ;;
            security_HIGH|security_MEDIUM)       picked="gpt-5.4" ;;
            reasoning_HIGH)                      picked="gpt-5.4" ;;
            data_analysis_HIGH)                  picked="gpt-5.4" ;;
        esac
    fi

    # ── 한국어 우선 (NLP/콘텐츠) ──
    if [[ -z "$picked" ]] && awk "BEGIN { exit !($korean_ratio > 0.7) }"; then
        case "$category" in
            korean_nlp|content_creation)
                if [[ "$tier" == "HIGH" ]]; then picked="glm-5.1"; else picked="glm-5"; fi
                ;;
        esac
    fi

    if [[ -z "$picked" ]] && awk "BEGIN { exit !($korean_ratio > 0.5) }"; then
        case "$category" in
            korean_nlp|content_creation)
                if [[ "$tier" == "LOW" ]]; then picked="glm-5-turbo"; else picked="glm-5"; fi
                ;;
        esac
    fi

    # ── 플랜별 매트릭스 ──
    if [[ -z "$picked" ]]; then
        case "$plan" in
            lite)
                case "${category}_${tier}" in
                    *_LOW)              picked="glm-5-turbo" ;;
                    coding_arch_*)      picked="glm-5" ;;
                    security_*)         picked="glm-5" ;;
                    *_MEDIUM|*_HIGH)    picked="glm-5" ;;
                    *)                  picked="glm-5" ;;
                esac
                ;;
            max)
                case "${category}_${tier}" in
                    *_LOW)
                        case "$category" in
                            coding_arch|security|reasoning|data_analysis) picked="glm-5" ;;
                            *) picked="glm-5-turbo" ;;
                        esac
                        ;;
                    coding_general_MEDIUM|coding_general_HIGH) picked="glm-5.1" ;;
                    coding_arch_*)      picked="glm-5.1" ;;
                    security_*)         picked="glm-5.1" ;;
                    reasoning_MEDIUM|reasoning_HIGH) picked="glm-5.1" ;;
                    debugging_MEDIUM|debugging_HIGH) picked="glm-5.1" ;;
                    data_analysis_*)    picked="glm-5.1" ;;
                    *_HIGH)             picked="glm-5.1" ;;
                    *_MEDIUM)           picked="glm-5" ;;
                    *)                  picked="glm-5" ;;
                esac
                ;;
            pro|*)
                case "${category}_${tier}" in
                    *_LOW)
                        case "$category" in
                            coding_arch|security) picked="glm-5" ;;
                            *) picked="glm-5-turbo" ;;
                        esac
                        ;;
                    coding_arch_MEDIUM|coding_arch_HIGH) picked="glm-5.1" ;;
                    security_MEDIUM|security_HIGH)       picked="glm-5.1" ;;
                    *_HIGH)              picked="glm-5.1" ;;
                    *_MEDIUM)            picked="glm-5" ;;
                    *)                   picked="glm-5" ;;
                esac
                ;;
        esac
    fi

    # ── Lite 플랜 강등 (glm-5.1 → glm-5) ──
    if [[ "$plan" == "lite" ]]; then
        picked="$(cap_for_lite "$picked")"
    fi

    [[ -z "$picked" ]] && picked="glm-5"
    echo "$picked"
}

# ──────────────────────────────────────────────
# 폴백 체인 결정
# ──────────────────────────────────────────────
get_fallback_chain() {
    local category="$1"
    local primary="$2"
    local plan codex_enabled
    plan="$(detect_active_plan)"
    codex_enabled="$(detect_codex_enabled)"
    local raw_chain=""

    if [[ "$plan" == "lite" ]]; then
        # Lite: glm-5.1 사용 불가
        raw_chain="${primary},glm-5,glm-5-turbo"
    elif [[ "$codex_enabled" == "true" ]]; then
        case "$category" in
            coding_arch|coding_general|debugging|security)
                raw_chain="${primary},gpt-5.4,glm-5.1,glm-5,glm-5-turbo"
                ;;
            *)
                raw_chain="${primary},glm-5.1,glm-5,glm-5-turbo"
                ;;
        esac
    else
        case "$category" in
            coding_general|coding_arch|debugging|security|data_analysis|reasoning)
                raw_chain="${primary},glm-5.1,glm-5,glm-5-turbo"
                ;;
            korean_nlp|content_creation)
                raw_chain="${primary},glm-5.1,glm-5,glm-5-turbo"
                ;;
            *)
                raw_chain="${primary},glm-5.1,glm-5,glm-5-turbo"
                ;;
        esac
    fi

    local item
    local deduped=""
    IFS=',' read -r -a items <<< "$raw_chain"
    for item in "${items[@]}"; do
        if [[ ",$deduped," != *",${item},"* ]]; then
            deduped="${deduped:+${deduped},}${item}"
        fi
    done

    echo "$deduped"
}

# ──────────────────────────────────────────────
# 메인 실행
# ──────────────────────────────────────────────
main() {
    # 1. 한국어 비율 감지
    local korean_ratio
    korean_ratio=$(detect_korean_ratio "$TASK_TEXT")

    # 2. 카테고리 감지 (auto 모드)
    local category="$CATEGORY"
    if [[ "$category" == "auto" ]]; then
        category=$(detect_category "$TASK_TEXT")
    fi

    # 3. 복잡도 계산
    local complexity_score
    complexity_score=$(calculate_complexity "$TASK_TEXT")

    local complexity_tier
    complexity_tier=$(get_complexity_tier "$complexity_score")

    # 4. 추론 집약 감지
    local reasoning_heavy
    reasoning_heavy=$(detect_reasoning_heavy "$TASK_TEXT" "$category")

    # 5. 모델 결정
    local model
    model=$(resolve_model "$category" "$complexity_tier" "$korean_ratio" "$reasoning_heavy")

    # 6. 폴백 체인
    local fallback_chain
    fallback_chain=$(get_fallback_chain "$category" "$model")

    # 7. 결과 출력 (YAML)
    cat <<EOF
routing_decision:
  model: ${model}
  category: ${category}
  complexity_score: ${complexity_score}
  complexity_tier: ${complexity_tier}
  korean_ratio: ${korean_ratio}
  reasoning_heavy: ${reasoning_heavy}
  active_plan: $(detect_active_plan)
  codex_oauth_enabled: $(detect_codex_enabled)
  fallback_chain: [$(echo "$fallback_chain" | sed 's/,/, /g')]
  reason: "카테고리=${category}, 복잡도=${complexity_tier}(${complexity_score}점), 한국어=${korean_ratio}, 추론집약=${reasoning_heavy}"
EOF
}

main
