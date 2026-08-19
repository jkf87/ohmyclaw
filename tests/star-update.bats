#!/usr/bin/env bats
# cli.sh — 별(star) 안내 + semver 기반 업데이트 알림

load helpers

cli() { "$SKILL_DIR/cli.sh" "$@"; }

setup() {
  TMP_HOME=$(mktemp -d -t omc-star.XXXXXX)
  export OHMYCLAW_HOME="$TMP_HOME"
  export OHMYCLAW_SKIP_UPDATE_CHECK=1
  unset OHMYCLAW_SKIP_STAR_PROMPT || true
}
teardown() {
  [[ -n "${TMP_HOME:-}" && -d "$TMP_HOME" ]] && rm -rf "$TMP_HOME"
  unset OHMYCLAW_HOME OHMYCLAW_SKIP_UPDATE_CHECK OHMYCLAW_SKIP_STAR_PROMPT
}

# 캐시 파일에 latest 를 심어 네트워크 없이 알림 경로만 검증한다.
seed_update_cache() {
  mkdir -p "$TMP_HOME"
  printf '%s\n%s\n' "$(date +%s)" "$1" > "$TMP_HOME/update-check.cache"
}

# ──────────────────────────────────────────────
# 별 안내
# ──────────────────────────────────────────────
@test "star --force prints repo link" {
  run cli star --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com/jkf87/ohmyclaw"* ]]
}

@test "star --never suppresses subsequent auto prompts" {
  cli star --never
  run cli star
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "star --force overrides a previous --never" {
  cli star --never
  run cli star --force
  [[ "$output" == *"github.com"* ]]
}

@test "star respects cooldown" {
  cli star --force >/dev/null
  run cli star
  [ -z "$output" ]
}

@test "star honors OHMYCLAW_SKIP_STAR_PROMPT" {
  export OHMYCLAW_SKIP_STAR_PROMPT=1
  run cli star
  [ -z "$output" ]
}

@test "star rejects unknown flag" {
  run cli star --bogus
  [ "$status" -ne 0 ]
}

# 기계가 읽는 출력에 홍보 문구가 섞이면 안 된다.
# bats 의 run 은 TTY 가 아니므로 자동 경로는 조용해야 한다.
@test "verb output stays clean when not a TTY" {
  run cli version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^ohmyclaw\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# ──────────────────────────────────────────────
# semver 업데이트 알림
# ──────────────────────────────────────────────
@test "update notice fires when release is newer" {
  unset OHMYCLAW_SKIP_UPDATE_CHECK
  seed_update_cache "99.0.0"
  run cli version
  [[ "$output" == *"99.0.0 available"* ]]
}

@test "no notice when local is ahead of release" {
  unset OHMYCLAW_SKIP_UPDATE_CHECK
  seed_update_cache "0.0.1"
  run cli version
  [[ "$output" != *"available"* ]]
}

@test "no notice when versions are equal" {
  unset OHMYCLAW_SKIP_UPDATE_CHECK
  seed_update_cache "$(cat "$REPO_ROOT/VERSION")"
  run cli version
  [[ "$output" != *"available"* ]]
}

# 문자열 비교였다면 1.9.0 을 1.13.x 보다 크다고 오판했다.
@test "semver compare handles multi-digit minor versions" {
  unset OHMYCLAW_SKIP_UPDATE_CHECK
  seed_update_cache "1.9.0"
  run cli version
  [[ "$output" != *"available"* ]]
}

@test "no notice when release value is malformed" {
  unset OHMYCLAW_SKIP_UPDATE_CHECK
  seed_update_cache "not-a-version"
  run cli version
  [[ "$output" != *"available"* ]]
}

@test "OHMYCLAW_SKIP_UPDATE_CHECK disables the notice" {
  seed_update_cache "99.0.0"
  run cli version
  [[ "$output" != *"available"* ]]
}
