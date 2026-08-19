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

# 자동 경로(--auto)는 TTY 에서만 동작한다. 의사터미널로 실행해 실제 조건을 검증한다.
# stdin 을 /dev/null 로 고정한다 — macOS script 는 stdin 이 소켓이면
# tcgetattr 로 실패한다 (bats 실행 환경에 따라 달라짐).
star_auto_tty() {
  script -q /dev/null env \
    OHMYCLAW_HOME="$OHMYCLAW_HOME" \
    OHMYCLAW_SKIP_UPDATE_CHECK=1 \
    ${OHMYCLAW_SKIP_STAR_PROMPT:+OHMYCLAW_SKIP_STAR_PROMPT="$OHMYCLAW_SKIP_STAR_PROMPT"} \
    "$SKILL_DIR/cli.sh" star --auto </dev/null 2>&1 | tr -d '\r'
}

# pty 를 못 만드는 환경(일부 CI)에서는 자동 경로 검증을 건너뛴다.
require_pty() {
  script -q /dev/null true </dev/null >/dev/null 2>&1 \
    || skip "script(1) 로 pty 를 만들 수 없는 환경"
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
  require_pty
  cli star --never
  run star_auto_tty
  [[ "$output" != *"github.com"* ]]
}

@test "star --force overrides a previous --never" {
  cli star --never
  run cli star --force
  [[ "$output" == *"github.com"* ]]
}

@test "auto star respects cooldown" {
  require_pty
  cli star --force >/dev/null
  run star_auto_tty
  [[ "$output" != *"github.com"* ]]
}

@test "auto star fires on a TTY when nothing blocks it" {
  require_pty
  run star_auto_tty
  [[ "$output" == *"github.com/jkf87/ohmyclaw"* ]]
}

@test "auto star honors OHMYCLAW_SKIP_STAR_PROMPT" {
  require_pty
  export OHMYCLAW_SKIP_STAR_PROMPT=1
  run star_auto_tty
  [[ "$output" != *"github.com"* ]]
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

# ──────────────────────────────────────────────
# 슬래시 명령 등록 (챗 경로)
# ──────────────────────────────────────────────
@test "star and experimental are registered as slash commands" {
  run jq -r '[.commands[].verb] | join(" ")' "$SKILL_DIR/commands.json"
  [[ "$output" == *"star"* ]]
  [[ "$output" == *"experimental"* ]]
}

@test "new slash command tokens follow the omc_ naming rule" {
  run jq -r '[.commands[] | select(.command | test("^omc_[a-z0-9_]{1,28}$") | not)] | length' "$SKILL_DIR/commands.json"
  [ "$output" = "0" ]
}

@test "botfather output includes the new commands" {
  run "$SKILL_DIR/cli.sh" commands botfather
  [ "$status" -eq 0 ]
  [[ "$output" == *"omc_experimental"* ]]
  [[ "$output" == *"omc_star"* ]]
}

# 챗에는 TTY 가 없다. 명시 호출은 TTY 와 무관하게 출력돼야 한다.
@test "explicit star prints without a TTY" {
  run "$SKILL_DIR/cli.sh" star
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.com/jkf87/ohmyclaw"* ]]
}

@test "explicit star ignores the cooldown" {
  "$SKILL_DIR/cli.sh" star >/dev/null
  run "$SKILL_DIR/cli.sh" star
  [[ "$output" == *"github.com"* ]]
}

@test "star --status reports state without prompting" {
  run "$SKILL_DIR/cli.sh" star --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"별 안내"* ]]
  [[ "$output" != *"github.com"* ]]
}

@test "auto star stays silent without a TTY" {
  run "$SKILL_DIR/cli.sh" version
  [[ "$output" != *"github.com"* ]]
}
