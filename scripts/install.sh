#!/usr/bin/env bash
# OpenClaw 하네스 — 설치 스크립트
# harness/ 디렉토리를 ~/.openclaw/skills/harness/에 복사 또는 심볼릭 링크
# 사용법: ./install.sh [--link | --copy]
set -euo pipefail

# ──────────────────────────────────────────────
# 설정
# ──────────────────────────────────────────────
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="${HOME}/.openclaw/skills/harness"
INSTALL_MODE="${1:---link}"  # --link (기본) 또는 --copy

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenClaw 하네스 설치"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  소스: ${SOURCE_DIR}"
echo "  대상: ${TARGET_DIR}"
echo "  모드: ${INSTALL_MODE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ──────────────────────────────────────────────
# 사전 검사
# ──────────────────────────────────────────────

# ~/.openclaw/skills 디렉토리 존재 확인
if [[ ! -d "${HOME}/.openclaw/skills" ]]; then
    echo "[경고] ~/.openclaw/skills 디렉토리가 없습니다."
    echo "  OpenClaw이 설치되어 있는지 확인하세요."
    read -rp "  디렉토리를 생성하시겠습니까? (y/N) " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mkdir -p "${HOME}/.openclaw/skills"
        echo "  ~/.openclaw/skills 생성됨"
    else
        echo "  설치를 취소합니다."
        exit 1
    fi
fi

# 기존 하네스 백업
if [[ -e "$TARGET_DIR" ]]; then
    BACKUP_DIR="${TARGET_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
    echo "[정보] 기존 하네스를 백업합니다: ${BACKUP_DIR}"
    mv "$TARGET_DIR" "$BACKUP_DIR"
fi

# ──────────────────────────────────────────────
# 설치
# ──────────────────────────────────────────────
case "$INSTALL_MODE" in
    --link)
        echo "[설치] 심볼릭 링크 생성..."
        ln -s "$SOURCE_DIR" "$TARGET_DIR"
        echo "  ${TARGET_DIR} → ${SOURCE_DIR}"
        ;;
    --copy)
        echo "[설치] 파일 복사..."
        cp -r "$SOURCE_DIR" "$TARGET_DIR"
        echo "  ${SOURCE_DIR} → ${TARGET_DIR}"
        ;;
    *)
        echo "에러: 알 수 없는 모드: ${INSTALL_MODE}" >&2
        echo "사용법: $0 [--link | --copy]" >&2
        exit 1
        ;;
esac

# ──────────────────────────────────────────────
# 스크립트 실행 권한 설정
# ──────────────────────────────────────────────
echo "[설정] 스크립트 실행 권한 부여..."
chmod +x "${TARGET_DIR}/scripts/"*.sh 2>/dev/null || true

# ──────────────────────────────────────────────
# 필요 디렉토리 생성
# ──────────────────────────────────────────────
echo "[설정] 런타임 디렉토리 생성..."
mkdir -p "${TARGET_DIR}/state"
mkdir -p "${TARGET_DIR}/logs/daily"
mkdir -p "${TARGET_DIR}/agents/custom"

# ──────────────────────────────────────────────
# CATALOG.md 자동 생성
# ──────────────────────────────────────────────
if [[ -x "${TARGET_DIR}/scripts/catalog-gen.sh" ]]; then
    echo "[설정] CATALOG.md 생성..."
    "${TARGET_DIR}/scripts/catalog-gen.sh" || true
fi

# ──────────────────────────────────────────────
# 설치 검증
# ──────────────────────────────────────────────
echo ""
echo "[검증] 설치 상태 확인..."

check_file() {
    local path="$1"
    local label="$2"
    if [[ -f "$path" ]]; then
        echo "  ✓ ${label}"
    else
        echo "  ✗ ${label} (누락!)"
    fi
}

check_file "${TARGET_DIR}/SKILL.md" "SKILL.md (스킬 정의)"
check_file "${TARGET_DIR}/CATALOG.md" "CATALOG.md (카탈로그)"
check_file "${TARGET_DIR}/agents/planner.md" "agents/planner.md"
check_file "${TARGET_DIR}/agents/worker.md" "agents/worker.md"
check_file "${TARGET_DIR}/agents/reviewer.md" "agents/reviewer.md"
check_file "${TARGET_DIR}/agents/debugger.md" "agents/debugger.md"
check_file "${TARGET_DIR}/agents/bridge.md" "agents/bridge.md"
check_file "${TARGET_DIR}/routing/models.yaml" "routing/models.yaml"
check_file "${TARGET_DIR}/routing/routing-rules.yaml" "routing/routing-rules.yaml"
check_file "${TARGET_DIR}/routing/budget-profiles.yaml" "routing/budget-profiles.yaml"
check_file "${TARGET_DIR}/orchestration/pipelines.yaml" "orchestration/pipelines.yaml"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  설치 완료!"
echo "  진단 실행: ${TARGET_DIR}/scripts/doctor.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
