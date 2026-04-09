#!/usr/bin/env bash
# OpenClaw 하네스 — 계정 풀 스모크 테스트
# 실제 API 호출 없이 round-robin / cooldown / fan-out / OAuth 라우팅 검증
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
POOL="${HARNESS_DIR}/scripts/account-pool.sh"
SPAWN="${HARNESS_DIR}/scripts/spawn-agent.sh"

PASS=0; FAIL=0
check_pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
check_fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  계정 풀 스모크 테스트 (OAuth 우선)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 격리된 테스트 환경 구성 ──
TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT

# 가짜 CODEX_HOME 디렉토리 (auth.json 만 있으면 사용 가능 판정됨)
mkdir -p "${TEST_DIR}/codex-1" "${TEST_DIR}/codex-2"
echo '{"OPENAI_API_KEY":null}' > "${TEST_DIR}/codex-1/auth.json"
echo '{"OPENAI_API_KEY":null}' > "${TEST_DIR}/codex-2/auth.json"

# 테스트용 accounts.yaml (실 ~/.codex 경로 대신 임시 디렉토리 사용)
TEST_ACCOUNTS="${TEST_DIR}/accounts.yaml"
cat > "${TEST_ACCOUNTS}" <<EOF
version: "1.1"
pool_defaults:
  strategy: round_robin
  cooldown_seconds: 60
  max_cooldown_seconds: 600
  backoff_multiplier: 2
pools:
  codex:
    strategy: round_robin
    accounts:
      - id: codex-primary
        auth_type: oauth_codex
        codex_home: ${TEST_DIR}/codex-1
        weight: 10
        enabled: true
      - id: codex-secondary
        auth_type: oauth_codex
        codex_home: ${TEST_DIR}/codex-2
        weight: 10
        enabled: true
  zai:
    strategy: round_robin
    accounts:
      - id: zai-primary
        auth_type: api_key
        env_key: ZAI_API_KEY
        weight: 10
        enabled: true
      - id: zai-secondary
        auth_type: api_key
        env_key: ZAI_API_KEY_2
        weight: 5
        enabled: true
EOF

export ACCOUNTS_FILE="${TEST_ACCOUNTS}"
export POOL_STATE="${TEST_DIR}/pool-state.json"
export ZAI_API_KEY="test-zai-1"
export ZAI_API_KEY_2="test-zai-2"

# [1] 초기화
echo "[1/10] 초기화"
if bash "${POOL}" reset 2>&1 | grep -q "초기화"; then
    check_pass "전체 풀 초기화"
else
    check_fail "전체 풀 초기화"
fi

# [2] 풀 요약
echo ""
echo "[2/10] 풀 요약 조회"
output=$(bash "${POOL}" status 2>&1)
if echo "$output" | grep -q "codex" && echo "$output" | grep -q "zai"; then
    check_pass "codex + zai 풀 감지"
else
    check_fail "풀 감지 실패"
fi

# [3] codex 풀 OAuth 라운드 로빈
echo ""
echo "[3/10] OAuth 라운드 로빈 (codex 풀, 4회 순환)"
seen_p=0; seen_s=0
for i in 1 2 3 4; do
    out=$(bash "${POOL}" next codex 2>/dev/null || true)
    acct=$(echo "$out" | grep 'account_id:' | sed 's/.*: //' | xargs)
    [[ "$acct" == "codex-primary" ]]   && seen_p=1
    [[ "$acct" == "codex-secondary" ]] && seen_s=1
done
if [[ "$seen_p" -eq 1 ]] && [[ "$seen_s" -eq 1 ]]; then
    check_pass "codex-primary, codex-secondary 모두 선택됨"
else
    check_fail "라운드 로빈 미작동 (p=${seen_p}, s=${seen_s})"
fi

# [4] codex 풀 status에 oauth_codex 정보가 노출되는지
echo ""
echo "[4/10] OAuth 메타데이터 노출 (status)"
status_out=$(bash "${POOL}" status codex 2>&1 || true)
if echo "$status_out" | grep -q "auth_type: oauth_codex" \
   && echo "$status_out" | grep -q "auth_value: ${TEST_DIR}/codex-1" \
   && echo "$status_out" | grep -q "status: ready"; then
    check_pass "auth_type/auth_value/ready 상태 노출"
else
    check_fail "OAuth 메타데이터 누락"
fi

# [5] 쿨다운 + 페일오버 (codex 풀)
echo ""
echo "[5/10] 쿨다운 + 페일오버 (codex 풀)"
bash "${POOL}" reset >/dev/null
bash "${POOL}" cooldown codex codex-primary rate_limit >/dev/null 2>&1
acct=$(bash "${POOL}" next codex 2>/dev/null | grep 'account_id:' | sed 's/.*: //' | xargs)
if [[ "$acct" == "codex-secondary" ]]; then
    check_pass "쿨다운 후 codex-secondary 페일오버"
else
    check_fail "페일오버 실패 (got: ${acct:-empty})"
fi

# [6] no_auth 감지: auth.json 삭제 시 사용 불가
echo ""
echo "[6/10] OAuth no_auth 감지 (auth.json 삭제)"
rm -f "${TEST_DIR}/codex-2/auth.json"
bash "${POOL}" reset >/dev/null
status_out=$(bash "${POOL}" status codex 2>&1 || true)
if echo "$status_out" | grep -A4 "codex-secondary" | grep -q "status: no_auth"; then
    check_pass "auth.json 없음 → no_auth"
else
    check_fail "no_auth 미감지"
fi
# 복구
echo '{"OPENAI_API_KEY":null}' > "${TEST_DIR}/codex-2/auth.json"

# [7] 쿨다운 해제
echo ""
echo "[7/10] 쿨다운 해제"
bash "${POOL}" cooldown codex codex-primary rate_limit >/dev/null 2>&1
bash "${POOL}" release codex codex-primary 2>/dev/null
if bash "${POOL}" status codex 2>/dev/null | grep -A4 "codex-primary" | grep -q "status: ready"; then
    check_pass "codex-primary → ready 복구"
else
    check_fail "쿨다운 해제 실패"
fi

# [8] spawn-agent 통합: codex 모델 → codex 풀
echo ""
echo "[8/10] spawn-agent 통합 — gpt 모델 → codex 풀 라우팅"
bash "${POOL}" reset >/dev/null
out=$(bash "${SPAWN}" worker "test" gpt-5.3-codex 2>/dev/null || true)
if echo "$out" | grep -q "pool: codex" \
   && echo "$out" | grep -q "auth_type: oauth_codex" \
   && echo "$out" | grep -qE "auth_value: ${TEST_DIR}/codex-[12]"; then
    check_pass "gpt-5.3-codex → codex 풀 OAuth 선택"
else
    check_fail "codex OAuth 라우팅 실패"
    echo "$out" | sed 's/^/    /'
fi

# [9] spawn-agent 통합: glm 모델 → zai 풀 (api_key 경로)
echo ""
echo "[9/10] spawn-agent 통합 — glm 모델 → zai 풀 라우팅 (api_key)"
out=$(bash "${SPAWN}" worker "test" glm-5 2>/dev/null || true)
if echo "$out" | grep -q "pool: zai" \
   && echo "$out" | grep -q "auth_type: api_key"; then
    check_pass "glm-5 → zai 풀 api_key 선택"
else
    check_fail "zai api_key 라우팅 실패"
fi

# [10] spawn-agent 통합: codex 4회 호출 라운드 로빈
echo ""
echo "[10/10] spawn-agent 통합 — codex 4회 호출 라운드 로빈"
bash "${POOL}" reset >/dev/null
seen_p=0; seen_s=0
for i in 1 2 3 4; do
    out=$(bash "${SPAWN}" worker "test" gpt-5.3-codex 2>/dev/null || true)
    echo "$out" | grep -q "account_id: codex-primary"   && seen_p=1
    echo "$out" | grep -q "account_id: codex-secondary" && seen_s=1
done
if [[ "$seen_p" -eq 1 ]] && [[ "$seen_s" -eq 1 ]]; then
    check_pass "4회 spawn 호출에 두 OAuth 계정 모두 사용됨"
else
    check_fail "spawn 라운드 로빈 미작동 (p=${seen_p}, s=${seen_s})"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  결과: ✓ ${PASS} 통과 / ✗ ${FAIL} 실패"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
