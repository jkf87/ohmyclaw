#!/usr/bin/env bash
# OpenClaw 하네스 — 설치 상태 진단 스크립트
# 의존성, 설정 파일, 디렉토리 구조 검증
# 사용법: ./doctor.sh
set -euo pipefail

# ──────────────────────────────────────────────
# 설정
# ──────────────────────────────────────────────
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

PASS=0
WARN=0
FAIL=0

# ──────────────────────────────────────────────
# 출력 헬퍼
# ──────────────────────────────────────────────
check_pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
check_warn() { echo "  ⚠ $1"; WARN=$((WARN + 1)); }
check_fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# ──────────────────────────────────────────────
# 1. 핵심 파일 검사
# ──────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenClaw 하네스 진단"
echo "  하네스 디렉토리: ${HARNESS_DIR}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "[1/7] 핵심 파일 검사"

required_files=(
    "SKILL.md:스킬 정의"
    "CATALOG.md:에이전트 카탈로그"
    "agents/planner.md:계획 에이전트"
    "agents/worker.md:구현 에이전트"
    "agents/reviewer.md:리뷰 에이전트"
    "agents/debugger.md:디버그 에이전트"
    "agents/bridge.md:브릿지 에이전트 정의"
    "routing/models.yaml:모델 카탈로그"
    "routing/routing-rules.yaml:라우팅 규칙"
    "routing/budget-profiles.yaml:예산 프로파일"
    "orchestration/pipelines.yaml:파이프라인 정의"
    "orchestration/message-protocol.md:메시지 프로토콜"
    "routing/accounts.yaml:계정 풀 설정"
)

for entry in "${required_files[@]}"; do
    file="${entry%%:*}"
    label="${entry#*:}"
    if [[ -f "${HARNESS_DIR}/${file}" ]]; then
        check_pass "${label} (${file})"
    else
        check_fail "${label} (${file}) — 파일 누락!"
    fi
done

# ──────────────────────────────────────────────
# 2. 스크립트 실행 권한 검사
# ──────────────────────────────────────────────
echo ""
echo "[2/7] 스크립트 실행 권한 검사"

scripts=(
    "scripts/route-task.sh"
    "scripts/orchestrate.sh"
    "scripts/spawn-agent.sh"
    "scripts/install.sh"
    "scripts/catalog-gen.sh"
    "scripts/doctor.sh"
    "scripts/account-pool.sh"
    "scripts/account-pool-demo.sh"
)

for script in "${scripts[@]}"; do
    if [[ -f "${HARNESS_DIR}/${script}" ]]; then
        if [[ -x "${HARNESS_DIR}/${script}" ]]; then
            check_pass "${script} (실행 가능)"
        else
            check_warn "${script} — 실행 권한 없음 (chmod +x 필요)"
        fi
    else
        check_fail "${script} — 파일 누락!"
    fi
done

# ──────────────────────────────────────────────
# 3. YAML 유효성 검사 (기본)
# ──────────────────────────────────────────────
echo ""
echo "[3/7] YAML 구문 검사"

yaml_files=(
    "routing/models.yaml"
    "routing/routing-rules.yaml"
    "routing/budget-profiles.yaml"
    "routing/accounts.yaml"
    "orchestration/pipelines.yaml"
)

for yaml_file in "${yaml_files[@]}"; do
    full_path="${HARNESS_DIR}/${yaml_file}"
    if [[ ! -f "$full_path" ]]; then
        check_fail "${yaml_file} — 파일 없음"
        continue
    fi

    # 기본 YAML 구문 검사 (탭 문자, 잘못된 들여쓰기)
    if grep -qP '\t' "$full_path" 2>/dev/null; then
        check_warn "${yaml_file} — 탭 문자 발견 (공백 사용 권장)"
    else
        check_pass "${yaml_file} (구문 기본 검사 통과)"
    fi
done

# ──────────────────────────────────────────────
# 4. 환경 변수 검사
# ──────────────────────────────────────────────
echo ""
echo "[4/7] 인증 자격 검사"

# Z.ai (API 키 — OAuth 미지원)
if [[ -n "${ZAI_API_KEY:-}" ]]; then
    check_pass "Z.ai API 키 (ZAI_API_KEY 설정됨)"
else
    check_warn "Z.ai API 키 (ZAI_API_KEY 미설정) — z.ai 콘솔에서 발급"
fi

# Codex OAuth (~/.codex/auth.json)
if [[ -f "${HOME}/.codex/auth.json" ]]; then
    check_pass "Codex OAuth (~/.codex/auth.json 존재)"
else
    check_warn "Codex OAuth 미로그인 — codex login 실행 필요"
fi

# 추가 Codex OAuth 계정 (선택)
if [[ -f "${HOME}/.codex-acct2/auth.json" ]]; then
    check_pass "Codex OAuth 보조 계정 (~/.codex-acct2/auth.json)"
else
    check_warn "Codex OAuth 보조 계정 없음 — 'CODEX_HOME=~/.codex-acct2 codex login' 으로 추가 가능"
fi

# ──────────────────────────────────────────────
# 5. OpenClaw 연동 검사
# ──────────────────────────────────────────────
echo ""
echo "[5/7] OpenClaw 연동 검사"

if command -v openclaw &>/dev/null; then
    check_pass "openclaw CLI 설치됨"
else
    check_warn "openclaw CLI 미설치 — 시뮬레이션 모드로 동작"
fi

if [[ -d "${HOME}/.openclaw" ]]; then
    check_pass "~/.openclaw/ 디렉토리 존재"
else
    check_warn "~/.openclaw/ 디렉토리 없음 — OpenClaw 미설치 가능성"
fi

if [[ -L "${HOME}/.openclaw/harness" ]] || [[ -d "${HOME}/.openclaw/harness" ]]; then
    check_pass "하네스 설치됨 (~/.openclaw/harness/)"
else
    check_warn "하네스 미설치 — install.sh 실행 필요"
fi

# ──────────────────────────────────────────────
# 6. 브릿지 검사 (S2)
# ──────────────────────────────────────────────
echo ""
echo "[6/7] 브릿지 검사"

BRIDGE_SCRIPT="${HARNESS_DIR}/scripts/bridge.sh"
BRIDGE_AGENT="${HARNESS_DIR}/agents/bridge.md"
BRIDGE_STATE_DIR="${HARNESS_DIR}/state"

if [[ -f "${BRIDGE_SCRIPT}" ]]; then
    if [[ -x "${BRIDGE_SCRIPT}" ]]; then
        check_pass "브릿지 스크립트 (scripts/bridge.sh)"
    else
        check_warn "브릿지 스크립트 — 실행 권한 없음"
    fi
else
    check_fail "브릿지 스크립트 (scripts/bridge.sh) — 파일 누락!"
fi

if [[ -f "${BRIDGE_AGENT}" ]]; then
    check_pass "브릿지 에이전트 정의 (agents/bridge.md)"
else
    check_fail "브릿지 에이전트 정의 (agents/bridge.md) — 파일 누락!"
fi

# P4: 설정 일원화 (S2) — 별도 브릿지 config가 없어야 함
BRIDGE_CONFIG_FILES=$(find "${HARNESS_DIR}" -maxdepth 1 \( -name "bridge-config.*" -o -name "bridge.yaml" -o -name "bridge.json" -o -name "bridge.env" \) 2>/dev/null | wc -l | tr -d ' ')
if [[ "${BRIDGE_CONFIG_FILES}" -eq 0 ]]; then
    check_pass "브릿지 설정 일원화 (별도 config 없음)"
else
    check_fail "브릿지 설정 분리 발견 (${BRIDGE_CONFIG_FILES}개) — P4 위배"
fi

# python3 의존성 (bridge.sh가 사용)
if command -v python3 &>/dev/null; then
    check_pass "python3 설치됨 (브릿지 상태 관리용)"
else
    check_warn "python3 미설치 — 브릿지 상태 관리 제한됨"
fi

# 브릿지 기능 테스트
if [[ -x "${BRIDGE_SCRIPT}" ]] && command -v python3 &>/dev/null; then
    TEST_DIR=$(mktemp -d)
    TEST_STATE="${TEST_DIR}/bridge-state.json"
    
    # 상태 초기화 테스트
    HARNESS_DIR="${HARNESS_DIR}" BRIDGE_STATE="${TEST_STATE}" "${BRIDGE_SCRIPT}" reset "doctor-test" solo > /dev/null 2>&1
    
    if [[ -f "${TEST_STATE}" ]] && grep -q "doctor-test" "${TEST_STATE}" 2>/dev/null; then
        check_pass "브릿지 상태 초기화 동작"
    else
        check_warn "브릿지 상태 초기화 불가"
    fi
    
    rm -rf "${TEST_DIR}"
fi

# ──────────────────────────────────────────────
# 7. 계정 풀 검사
# ──────────────────────────────────────────────
echo ""
echo "[7/7] 계정 풀 검사"

POOL_SCRIPT="${HARNESS_DIR}/scripts/account-pool.sh"
ACCOUNTS_YAML="${HARNESS_DIR}/routing/accounts.yaml"

if [[ -f "${ACCOUNTS_YAML}" ]] && [[ -x "${POOL_SCRIPT}" ]] && command -v python3 &>/dev/null; then
    POOL_TEST_DIR=$(mktemp -d)
    POOL_TEST_STATE="${POOL_TEST_DIR}/pool-state.json"
    POOL_OUTPUT=$(HARNESS_DIR="${HARNESS_DIR}" POOL_STATE="${POOL_TEST_STATE}" \
        "${POOL_SCRIPT}" status 2>&1 || true)
    if echo "${POOL_OUTPUT}" | grep -q "account_pool_summary:"; then
        check_pass "계정 풀 status 동작"
    else
        check_warn "계정 풀 status 응답 이상"
    fi

    POOL_NAMES=$(echo "${POOL_OUTPUT}" | grep -E '^\s*- pool:' | wc -l | tr -d ' ')
    if [[ "${POOL_NAMES}" -gt 0 ]]; then
        check_pass "계정 풀 정의 ${POOL_NAMES}개 감지"
    else
        check_warn "계정 풀 정의 없음 — routing/accounts.yaml 확인"
    fi
    rm -rf "${POOL_TEST_DIR}"
else
    [[ ! -f "${ACCOUNTS_YAML}" ]] && check_fail "routing/accounts.yaml 누락"
    [[ ! -x "${POOL_SCRIPT}" ]] && check_warn "scripts/account-pool.sh 실행 권한 없음"
    command -v python3 &>/dev/null || check_warn "python3 미설치 — 계정 풀 동작 불가"
fi

# ──────────────────────────────────────────────
# 결과 요약
# ──────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  진단 결과"
echo "  ✓ 통과: ${PASS}"
echo "  ⚠ 경고: ${WARN}"
echo "  ✗ 실패: ${FAIL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "  ✗ 실패 항목이 있습니다. 위 내용을 확인하세요."
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    echo ""
    echo "  ⚠ 경고 항목이 있지만 기본 동작에는 문제없습니다."
    exit 0
else
    echo ""
    echo "  모든 검사 통과! 하네스가 정상 상태입니다."
    exit 0
fi
