#!/usr/bin/env bash
# ohmyclaw skill — experimental Claude Code CLI delegation helper (multi-account)
#
# Usage:
#   claude-delegate.sh "task text" [--cwd=/path] [--config-dir=PATH] [--from-pool] [--print-command]
#
# Multi-account modes (우선순위):
#   1) 명시 디렉토리:   --config-dir=~/.claude-acct2     (P100)
#   2) 풀 round-robin:  --from-pool                       (P90, pool.sh 가 자동 픽 + 실패 시 cooldown)
#   3) 환경변수 상속:   CLAUDE_CONFIG_DIR=~/.claude-acct2 (P80)
#   4) 기본:            ~/.claude                          (P0)
#
# Requirements:
#   - CLAUDECLI_DELEGATION_ENABLED=true
#   - `claude` available on PATH
#   - 사용할 계정 디렉토리에서 한 번 `claude login` 완료
#       예: CLAUDE_CONFIG_DIR=~/.claude-acct2 claude login
#   - --from-pool 사용 시: routing.json 의 claudecli 풀에 enabled=true 한 계정 ≥ 1
#
# Notes:
#   - 공식 CLI delegation 전용. 직접 OAuth token ingestion 금지.
#   - macOS 에서는 CLAUDE_CONFIG_DIR 가 keychain 대신 해당 디렉토리의
#     .credentials.json 을 우선 사용 (anthropics/claude-code 공식 동작).
#   - 실험적, opt-in, graceful failure 설계.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK="${1:-}"
CWD="${PWD}"
CONFIG_DIR=""
FROM_POOL=false
PRINT_ONLY=false
PICKED_ACCOUNT_ID=""

shift 1 2>/dev/null || true
for arg in "$@"; do
  case "$arg" in
    --cwd=*)         CWD="${arg#*=}" ;;
    --config-dir=*)  CONFIG_DIR="${arg#*=}" ;;
    --from-pool)     FROM_POOL=true ;;
    --print-command) PRINT_ONLY=true ;;
    *) echo "ERROR: unknown arg $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "$TASK" ]]; then
  echo "Usage: $0 \"task text\" [--cwd=/path] [--config-dir=PATH] [--from-pool] [--print-command]" >&2
  exit 2
fi

if [[ "${CLAUDECLI_DELEGATION_ENABLED:-false}" != "true" ]]; then
  echo "ERROR: ClaudeCLI delegation disabled. Set CLAUDECLI_DELEGATION_ENABLED=true to opt in." >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude CLI not found on PATH" >&2
  exit 1
fi

# ──────────────────────────────────────────────
# 계정 디렉토리 결정
# ──────────────────────────────────────────────
if [[ -z "$CONFIG_DIR" && "$FROM_POOL" == "true" ]]; then
  if [[ ! -x "$SCRIPT_DIR/pool.sh" ]]; then
    echo "ERROR: pool.sh not executable at $SCRIPT_DIR/pool.sh" >&2
    exit 1
  fi
  POOL_LINE=$("$SCRIPT_DIR/pool.sh" next claude-code-experimental 2>&1) || {
    echo "ERROR: pool.sh next 실패 — claudecli 풀에 enabled=true 한 계정이 있는지 확인" >&2
    echo "$POOL_LINE" >&2
    exit 1
  }
  PICKED_ACCOUNT_ID=$(echo "$POOL_LINE" | cut -d'|' -f1)
  POOL_AUTH_TYPE=$(echo "$POOL_LINE" | cut -d'|' -f2)
  POOL_AUTH_VALUE=$(echo "$POOL_LINE" | cut -d'|' -f3)

  if [[ "$POOL_AUTH_TYPE" != "oauth_claude_cli" ]]; then
    echo "ERROR: pool returned unexpected authType=$POOL_AUTH_TYPE (expected oauth_claude_cli)" >&2
    exit 1
  fi
  CONFIG_DIR="$POOL_AUTH_VALUE"
fi

if [[ -z "$CONFIG_DIR" && -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  CONFIG_DIR="$CLAUDE_CONFIG_DIR"
fi

# tilde 확장 (--config-dir=~/... 처럼 = 뒤의 tilde 는 shell 이 expand 안 함)
case "$CONFIG_DIR" in
  '~/'*) CONFIG_DIR="${HOME}/${CONFIG_DIR#'~/'}" ;;
  '~')   CONFIG_DIR="${HOME}" ;;
esac

CMD=(claude --print "$TASK")

if [[ "$PRINT_ONLY" == "true" ]]; then
  printf 'cd %q && ' "$CWD"
  [[ -n "$CONFIG_DIR" ]] && printf 'CLAUDE_CONFIG_DIR=%q ' "$CONFIG_DIR"
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

# ──────────────────────────────────────────────
# 실행 + 실패 시 pool cooldown 마킹 (--from-pool 일 때만)
# ──────────────────────────────────────────────
set +e
(
  cd "$CWD"
  if [[ -n "$CONFIG_DIR" ]]; then
    CLAUDE_CONFIG_DIR="$CONFIG_DIR" "${CMD[@]}"
  else
    "${CMD[@]}"
  fi
)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 && -n "$PICKED_ACCOUNT_ID" ]]; then
  echo "claude-delegate: exit=$EXIT_CODE → pool cooldown for $PICKED_ACCOUNT_ID" >&2
  "$SCRIPT_DIR/pool.sh" cooldown "$PICKED_ACCOUNT_ID" >/dev/null 2>&1 || true
fi

exit $EXIT_CODE
