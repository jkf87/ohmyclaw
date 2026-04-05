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
ROUTING_DIR="${HARNESS_DIR}/routing"
MODELS_FILE="${ROUTING_DIR}/models.yaml"
RULES_FILE="${ROUTING_DIR}/routing-rules.yaml"
BUDGET_FILE="${ROUTING_DIR}/budget-profiles.yaml"

TASK_TEXT="${1:-}"
CATEGORY="${2:-auto}"
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
resolve_model() {
    local category="$1"
    local tier="$2"
    local korean_ratio="$3"

    # 한국어 비율 높고 NLP/콘텐츠 태스크 → GLM 계열
    if awk "BEGIN { exit !($korean_ratio > 0.7) }"; then
        case "$category" in
            korean_nlp|content_creation)
                if [[ "$tier" == "HIGH" ]]; then
                    echo "glm-5.1"
                else
                    echo "glm-5"
                fi
                return
                ;;
        esac
    fi

    if awk "BEGIN { exit !($korean_ratio > 0.5) }"; then
        case "$category" in
            korean_nlp|content_creation)
                if [[ "$tier" == "LOW" ]]; then
                    echo "glm-5-turbo"
                else
                    echo "glm-5"
                fi
                return
                ;;
        esac
    fi

    # 카테고리 × 복잡도 매트릭스
    case "${category}_${tier}" in
        coding_general_LOW)     echo "glm-5-turbo" ;;
        coding_general_MEDIUM)  echo "gpt-5.3-codex" ;;
        coding_general_HIGH)    echo "gpt-5.3-codex" ;;

        coding_arch_LOW)        echo "gpt-5.3-codex" ;;
        coding_arch_MEDIUM)     echo "gpt-5.3-codex" ;;
        coding_arch_HIGH)       echo "gpt-5.3-codex" ;;

        korean_nlp_LOW)         echo "glm-5-turbo" ;;
        korean_nlp_MEDIUM)      echo "glm-5" ;;
        korean_nlp_HIGH)        echo "glm-5.1" ;;

        reasoning_LOW)          echo "glm-5-turbo" ;;
        reasoning_MEDIUM)       echo "gpt-5.3-codex" ;;
        reasoning_HIGH)         echo "glm-5.1" ;;

        debugging_LOW)          echo "glm-5-turbo" ;;
        debugging_MEDIUM)       echo "gpt-5.3-codex" ;;
        debugging_HIGH)         echo "gpt-5.3-codex" ;;

        reasoning_LOW)          echo "glm-5-turbo" ;;
        reasoning_MEDIUM)       echo "gpt-5.3-codex" ;;
        reasoning_HIGH)         echo "glm-5.1" ;;

        content_creation_LOW)   echo "glm-5-turbo" ;;
        content_creation_MEDIUM) echo "glm-5" ;;
        content_creation_HIGH)  echo "glm-5.1" ;;

        data_analysis_LOW)      echo "glm-5-turbo" ;;
        data_analysis_MEDIUM)   echo "gpt-5.3-codex" ;;
        data_analysis_HIGH)     echo "gpt-5.3-codex" ;;

        security_LOW)           echo "gpt-5.3-codex" ;;
        security_MEDIUM)        echo "gpt-5.3-codex" ;;
        security_HIGH)          echo "gpt-5.3-codex" ;;

        *)                      echo "gpt-5.3-codex" ;;
    esac
}

# ──────────────────────────────────────────────
# 폴백 체인 결정
# ──────────────────────────────────────────────
get_fallback_chain() {
    local category="$1"
    local primary="$2"
    local raw_chain=""

    case "$category" in
        coding_general|coding_arch|debugging|security|data_analysis|reasoning)
            raw_chain="${primary},glm-5.1,glm-5,glm-5-turbo"
            ;;
        korean_nlp|content_creation)
            raw_chain="${primary},glm-5,glm-5-turbo,gpt-5.3-codex"
            ;;
        *)
            raw_chain="${primary},glm-5.1,glm-5,glm-5-turbo"
            ;;
    esac

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

    # 4. 모델 결정
    local model
    model=$(resolve_model "$category" "$complexity_tier" "$korean_ratio")

    # 5. 폴백 체인
    local fallback_chain
    fallback_chain=$(get_fallback_chain "$category" "$model")

    # 6. 결과 출력 (YAML)
    cat <<EOF
routing_decision:
  model: ${model}
  category: ${category}
  complexity_score: ${complexity_score}
  complexity_tier: ${complexity_tier}
  korean_ratio: ${korean_ratio}
  budget_profile: ${BUDGET_PROFILE}
  fallback_chain: [$(echo "$fallback_chain" | sed 's/,/, /g')]
  reason: "카테고리=${category}, 복잡도=${complexity_tier}(${complexity_score}점), 한국어=${korean_ratio}"
EOF
}

main
