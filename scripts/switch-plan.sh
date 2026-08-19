#!/usr/bin/env bash
# OpenClaw 하네스 — Z.ai 코딩플랜 전환 스크립트
# Usage:
#   bash scripts/switch-plan.sh lite
#   bash scripts/switch-plan.sh pro
#   bash scripts/switch-plan.sh max
#   bash scripts/switch-plan.sh pro --with-codex
set -euo pipefail

PLAN="${1:-}"
WITH_CODEX="false"
if [[ "${2:-}" == "--with-codex" ]]; then
  WITH_CODEX="true"
fi

case "$PLAN" in
  lite|pro|max) ;;
  *)
    echo "Usage: $0 <lite|pro|max> [--with-codex]" >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLANS_FILE="$ROOT/routing/plans.yaml"

if [[ ! -f "$PLANS_FILE" ]]; then
  echo "ERROR: $PLANS_FILE 가 없습니다." >&2
  exit 1
fi

# active_plan 갱신
# 명령 출력이 아니라 실행할 명령 이름을 담는다 (BSD/GNU sed 분기)
# shellcheck disable=SC2209
if command -v gsed >/dev/null 2>&1; then
  SED=gsed
else
  SED=sed
fi

$SED -i.bak \
  -e "s/^active_plan:.*/active_plan: $PLAN/" \
  -e "s/^codex_oauth_enabled:.*/codex_oauth_enabled: $WITH_CODEX/" \
  "$PLANS_FILE"

rm -f "${PLANS_FILE}.bak"

echo "✅ 활성 플랜: $PLAN"
echo "✅ Codex OAuth 병행: $WITH_CODEX"
echo ""
echo "다음 단계:"
echo "  1) bash scripts/doctor.sh"
echo "  2) (필요 시) ~/.claude/settings.json 모델 매핑 갱신"
if [[ "$PLAN" == "lite" ]]; then
  echo "  ⚠️  Lite 플랜: ANTHROPIC_DEFAULT_OPUS_MODEL 을 'glm-5' 로 설정하세요 (GLM-5.1 미포함)"
fi
if [[ "$WITH_CODEX" == "true" ]]; then
  echo "  3) routing/accounts.yaml 의 pools.codex.accounts[*].enabled 를 true 로 설정"
  echo "     (사전에 \`codex login\` 완료 필요)"
fi
