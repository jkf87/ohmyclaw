#!/usr/bin/env bash
# OpenClaw 하네스 — 설치 상태 진단 스크립트
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
PASS=0
WARN=0
FAIL=0

check_pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
check_warn() { echo "  ⚠ $1"; WARN=$((WARN + 1)); }
check_fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenClaw 하네스 진단"
echo "  하네스 디렉토리: ${HARNESS_DIR}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

required_files=(
    "SKILL.md"
    "CATALOG.md"
    "agents/planner.md"
    "agents/worker.md"
    "agents/reviewer.md"
    "agents/debugger.md"
    "agents/bridge.md"
    "routing/models.yaml"
    "routing/routing-rules.yaml"
    "routing/budget-profiles.yaml"
    "orchestration/pipelines.yaml"
    "orchestration/message-protocol.md"
)

for file in "${required_files[@]}"; do
    if [[ -f "${HARNESS_DIR}/${file}" ]]; then
        check_pass "${file}"
    else
        check_fail "${file} — 파일 누락!"
    fi
done

echo ""
echo "[OpenClaw]"
if command -v openclaw &>/dev/null; then
    check_pass "openclaw CLI 설치됨"
else
    check_warn "openclaw CLI 미설치 — 시뮬레이션 모드로 동작"
fi

if [[ -L "${HOME}/.openclaw/skills/harness" ]] || [[ -d "${HOME}/.openclaw/skills/harness" ]]; then
    check_pass "하네스 설치됨 (~/.openclaw/skills/harness)"
else
    check_warn "하네스 미설치 — install.sh 실행 필요"
fi

if [[ -L "${HOME}/.openclaw/harness" ]] || [[ -d "${HOME}/.openclaw/harness" ]]; then
    check_warn "legacy 설치 경로 감지 (~/.openclaw/harness)"
fi

echo ""
echo "[Bridge]"
if [[ -f "${HARNESS_DIR}/scripts/bridge.sh" ]]; then
    check_pass "bridge 스크립트 존재"
else
    check_fail "bridge 스크립트 누락"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ 통과: ${PASS}"
echo "  ⚠ 경고: ${WARN}"
echo "  ✗ 실패: ${FAIL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
