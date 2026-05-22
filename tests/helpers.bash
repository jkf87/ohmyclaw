# ohmyclaw bats — shared helpers
# 모든 .bats 파일이 `load helpers` 로 가져온다.

SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/ohmyclaw" && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# 격리된 임시 state 디렉토리를 셋업하고 정리한다.
setup_isolated_state() {
  TMP_STATE=$(mktemp -d -t ohmyclaw-bats.XXXXXX)
  export OHMYCLAW_STATE_DIR="$TMP_STATE"
  export OHMYCLAW_SESSION_ID="bats-$$-$BATS_TEST_NUMBER"
}
teardown_isolated_state() {
  [[ -n "${TMP_STATE:-}" && -d "$TMP_STATE" ]] && rm -rf "$TMP_STATE"
  unset OHMYCLAW_STATE_DIR OHMYCLAW_SESSION_ID
}

# PATH 모킹: 실행 가능한 stub 바이너리를 만든다.
# 사용: mock_bin omp pi  → PATH에 fake omp, pi 추가
mock_bin() {
  MOCK_BIN_DIR=$(mktemp -d -t ohmyclaw-bin.XXXXXX)
  local b
  for b in "$@"; do
    printf '#!/bin/sh\n: # %s mock\n' "$b" > "$MOCK_BIN_DIR/$b"
    chmod +x "$MOCK_BIN_DIR/$b"
  done
  export PATH="$MOCK_BIN_DIR:$PATH"
}
unmock_bin() {
  [[ -n "${MOCK_BIN_DIR:-}" && -d "$MOCK_BIN_DIR" ]] && rm -rf "$MOCK_BIN_DIR"
  unset MOCK_BIN_DIR
}

# select-model 단축 실행 (stdout 단일 모델 ID)
sm() { "$SKILL_DIR/select-model.sh" "$@"; }

# engine.sh 단축
eg() { "$SKILL_DIR/engine.sh" "$@"; }

# pool.sh 단축
pl() { "$SKILL_DIR/pool.sh" "$@"; }
