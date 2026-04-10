#!/usr/bin/env bash
# ohmyclaw — quick installer
# Usage: bash <(curl -sL https://raw.githubusercontent.com/jkf87/ohmyclaw/main/install.sh)
set -euo pipefail

REPO="https://github.com/jkf87/ohmyclaw.git"
INSTALL_DIR="${OHMYCLAW_INSTALL_DIR:-$HOME/.openclaw/repos/ohmyclaw}"
SKILL_LINK="${HOME}/.openclaw/skills/ohmyclaw"

echo "🦞 ohmyclaw installer"
echo ""

# 1. 의존성
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠ jq 가 필요합니다."
  if command -v brew >/dev/null 2>&1; then
    echo "  → brew install jq"
    read -p "  설치할까요? (y/n) " ans
    [[ "$ans" == "y" ]] && brew install jq || { echo "jq 설치 후 다시 실행하세요."; exit 1; }
  else
    echo "  → https://jqlang.github.io/jq/download/"
    exit 1
  fi
fi

# 2. 클론 or 업데이트
mkdir -p "$(dirname "$INSTALL_DIR")"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "📦 기존 설치 발견 → git pull"
  cd "$INSTALL_DIR" && git pull --rebase --quiet
else
  echo "📦 클론 중..."
  git clone --depth 1 "$REPO" "$INSTALL_DIR"
fi

# 3. 심볼릭 링크
mkdir -p "$(dirname "$SKILL_LINK")"
ln -sfn "$INSTALL_DIR/skills/ohmyclaw" "$SKILL_LINK"

# 4. 실행 권한
chmod +x "$INSTALL_DIR/skills/ohmyclaw/select-model.sh" \
         "$INSTALL_DIR/skills/ohmyclaw/pool.sh" \
         "$INSTALL_DIR/skills/ohmyclaw/hud.sh" 2>/dev/null || true

# 5. 검증
echo ""
echo "✅ 설치 완료"
echo "   위치: $INSTALL_DIR"
echo "   링크: $SKILL_LINK → $INSTALL_DIR/skills/ohmyclaw"
echo ""

# smoke test
if "$SKILL_LINK/select-model.sh" "smoke" auto --plan=pro >/dev/null 2>&1; then
  echo "✅ 라우터 smoke test 통과"
else
  echo "⚠ 라우터 smoke test 실패 — jq 설치 확인"
fi

echo ""
echo "🦞 사용법: 아무 OpenClaw 에이전트에서"
echo "   /ohmyclaw"
echo ""
echo "   또는 에이전트에게:"
echo "   \"ohmyclaw 사용량 보여줘\""
