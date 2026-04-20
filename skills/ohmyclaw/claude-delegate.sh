#!/usr/bin/env bash
# ohmyclaw skill — experimental Claude Code CLI delegation helper
#
# Usage:
#   claude-delegate.sh "task text" [--cwd=/path] [--print-command]
#
# Requirements:
#   - CLAUDECLI_DELEGATION_ENABLED=true
#   - `claude` available on PATH
#   - Claude Code CLI already logged in on this machine
#
# Notes:
#   - Official CLI delegation only. No direct OAuth token ingestion.
#   - Experimental, opt-in, and designed for graceful failure.

set -euo pipefail

TASK="${1:-}"
CWD="${PWD}"
PRINT_ONLY=false

shift 1 2>/dev/null || true
for arg in "$@"; do
  case "$arg" in
    --cwd=*) CWD="${arg#*=}" ;;
    --print-command) PRINT_ONLY=true ;;
    *) echo "ERROR: unknown arg $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "$TASK" ]]; then
  echo "Usage: $0 \"task text\" [--cwd=/path] [--print-command]" >&2
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

CMD=(claude --print "$TASK")

if [[ "$PRINT_ONLY" == "true" ]]; then
  printf 'cd %q && ' "$CWD"
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

(
  cd "$CWD"
  "${CMD[@]}"
)
