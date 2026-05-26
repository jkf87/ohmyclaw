#!/usr/bin/env bash
# ohmyclaw skill — unified standalone dispatcher
#
# Usage:
#   cli.sh <verb> [args...]
#
# Verbs:
#   doctor                                전체 점검 (engine + state + hooks)
#   route <task> [category] [--plan=...]  모델 라우팅 (select-model.sh)
#   pool <action> [args...]               계정 풀 액션 (pool.sh)
#   engine <action> [args...]             ACP 엔진 액션 (engine.sh)
#   state <action> [args...]              세션 state 액션 (state.sh)
#   hooks <action> [args...]              훅 액션 (hooks.sh)
#   cancel [--force]                      라이프사이클 정리
#   ask --to <chat> --question <Q> \
#       --option N:label [...]            Telegram 인라인 버튼 질문 전송 + 응답 대기
#   exec <task> [--to <chat>] \
#        [--category <cat>] \
#        [--plan <plan>] \
#        [--threshold <N>] \
#        [--dry-run]                      Ambiguity-gated task execution + model routing
#   plan-gate [--to <chat>] \
#             [--timeout N] \
#             [--dry-run]                 Planner ambiguity gate: parse stdin JSON, dispatch ask
#   gap-gate [--to <chat>] \
#            [--timeout N] \
#            [--dry-run]                  GAP_DETECTED 후속 결정 게이트: reviewer JSON → ask dispatch
#   version                               버전 출력
#   help | --help | -h                    사용법
#
# 라이프사이클:
#   - 각 verb 진입: pre-<verb> 훅 발화 + skill-active state 작성
#   - 정상/실패 종료: trap 으로 post-<verb> 훅 발화 + skill-active 청소
#   - pre 훅 exit 7 시 verb abort

set -uo pipefail   # set -e 는 verb 별 종료코드를 통제하기 위해 적용 안 함

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SH="$SCRIPT_DIR/hooks.sh"
STATE_SH="$SCRIPT_DIR/state.sh"

OHMYCLAW_HOME="${OHMYCLAW_HOME:-$HOME/.ohmyclaw}"
export OHMYCLAW_HOME

# ──────────────────────────────────────────────
# 라이프사이클 헬퍼
# ──────────────────────────────────────────────
_VERB=""
_LIFECYCLE_DONE=0

_lifecycle_exit() {
  # 첫 줄에서 즉시 $? 캡쳐 — 이후 어떤 평가도 $? 를 덮어쓸 수 있으므로.
  local rc=$?
  # 멱등성 보장 (trap 이 EXIT + INT + TERM 셋에 동시 매핑돼도 한 번만 실행)
  [[ $_LIFECYCLE_DONE -eq 1 ]] && return 0
  _LIFECYCLE_DONE=1
  if [[ -n "$_VERB" ]]; then
    # post 훅 (실패 비차단)
    "$HOOKS_SH" fire post "$_VERB" 2>/dev/null || true
    # skill-active 청소 (실패 무시)
    "$STATE_SH" clear skill-active 2>/dev/null || true
  fi
  exit "$rc"
}

_skill_active_write() {
  local verb="$1"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  "$STATE_SH" write skill-active "{\"active\":true,\"action\":\"$verb\",\"pid\":$$,\"started_at\":\"$now\"}" 2>/dev/null || true
}

# ──────────────────────────────────────────────
# Verb 실행 래퍼 — pre 훅 + skill-active + 본체 + (trap 이 post + cleanup)
# ──────────────────────────────────────────────
_run_verb() {
  local verb="$1"; shift
  _VERB="$verb"
  trap _lifecycle_exit EXIT INT TERM

  # ── prefetch: 최근 ask 응답을 env 로 노출 (pre 훅 + verb 본체 둘 다에서 접근 가능) ──
  local _last_answer_json _last_answer_value=""
  _last_answer_json=$("$STATE_SH" recent last-ask-answer 3600 2>/dev/null || true)
  if [[ -n "$_last_answer_json" ]]; then
    _last_answer_value=$(echo "$_last_answer_json" | jq -r '.value // ""' 2>/dev/null || true)
  fi
  export OHMYCLAW_LAST_ANSWER="$_last_answer_value"

  # pre 훅 — 원본 종료코드 캡쳐 (`! cmd` 패턴은 $? 가 0 으로 덮여서 못 씀)
  local prh_rc=0
  "$HOOKS_SH" fire pre "$verb" "$@" || prh_rc=$?
  if [[ $prh_rc -eq 7 ]]; then
    echo "[cli] pre-${verb} 훅이 action 을 거부 (exit 7) — abort" >&2
    exit 7
  fi

  _skill_active_write "$verb"

  # 본체 디스패치
  case "$verb" in
    doctor)  cmd_doctor  "$@"; exit $? ;;
    route)   "$SCRIPT_DIR/select-model.sh" "$@"; exit $? ;;
    pool)    "$SCRIPT_DIR/pool.sh"         "$@"; exit $? ;;
    engine)  "$SCRIPT_DIR/engine.sh"       "$@"; exit $? ;;
    state)   "$STATE_SH"                   "$@"; exit $? ;;
    hooks)   "$HOOKS_SH"                   "$@"; exit $? ;;
    cancel)     cmd_cancel     "$@"; exit $? ;;
    ask)        cmd_ask        "$@"; exit $? ;;
    exec)       cmd_exec       "$@"; exit $? ;;
    plan-gate)  cmd_plan_gate  "$@"; exit $? ;;
    gap-gate)   cmd_gap_gate   "$@"; exit $? ;;
    version)    cmd_version    "$@"; exit $? ;;
    *)
      echo "ERROR: unknown verb '$verb'. try: cli.sh help" >&2
      exit 2
      ;;
  esac
}

# ──────────────────────────────────────────────
# doctor — 전체 점검 (engine + state + hooks)
# ──────────────────────────────────────────────
cmd_doctor() {
  local rc=0
  echo "═══ ohmyclaw skill doctor ═══"
  echo ""

  # 1) engine doctor (기존)
  echo "── engine ──"
  "$SCRIPT_DIR/engine.sh" doctor || rc=1
  echo ""

  # 2) state smoke
  echo "── state ──"
  local probe="probe-$$"
  if "$STATE_SH" write "$probe" '{"smoke":true}' >/dev/null 2>&1 \
     && [[ "$("$STATE_SH" read "$probe")" == '{"smoke":true}' ]] \
     && "$STATE_SH" clear "$probe" >/dev/null 2>&1; then
    echo "✓ state.sh write/read/clear OK ($OHMYCLAW_HOME)"
  else
    echo "✗ state.sh smoke 실패"; rc=1
  fi
  echo ""

  # 3) hooks 점검
  echo "── hooks ──"
  "$HOOKS_SH" list
  echo ""

  echo "═══ doctor rc=$rc ═══"
  return $rc
}

# ──────────────────────────────────────────────
# version — VERSION 파일 또는 routing.json
# ──────────────────────────────────────────────
cmd_version() {
  local v
  if [[ -f "$SCRIPT_DIR/../../VERSION" ]]; then
    v=$(cat "$SCRIPT_DIR/../../VERSION")
  else
    v=$(jq -r '.version // "unknown"' "$SCRIPT_DIR/routing.json" 2>/dev/null || echo unknown)
  fi
  echo "ohmyclaw $v"
}

# ──────────────────────────────────────────────
# cancel — skill-active + pool sweep + 세션 state 청소 + (force 시 전체)
# ──────────────────────────────────────────────
cmd_cancel() {
  local force=""
  [[ "${1:-}" == "--force" ]] && force="--force"

  echo "[cli] cancel 시작 (session=${OHMYCLAW_SESSION_ID:-<global>}, force=${force:-no})"

  # 1) cancel-signal (우로보로스 ESCALATED 정합)
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  "$STATE_SH" write cancel-signal "{\"active\":true,\"mode\":\"cli\",\"source\":\"cli.sh cancel\",\"ts\":\"$now\"}" 2>/dev/null || true

  # 2) pool sweep (dead PID 슬롯 회수)
  "$SCRIPT_DIR/pool.sh" sweep 2>/dev/null || true

  # 3) skill-active 청소
  "$STATE_SH" clear skill-active 2>/dev/null || true
  # 3b) last-ask-answer 청소 + prefetch env 비움 (cancel hygiene)
  "$STATE_SH" clear last-ask-answer 2>/dev/null || true
  unset OHMYCLAW_LAST_ANSWER 2>/dev/null || true

  # 4) 세션 state reset (force 면 전체)
  if [[ -n "$force" ]]; then
    "$STATE_SH" reset --all 2>/dev/null || true
  else
    "$STATE_SH" reset 2>/dev/null || true
  fi

  echo "[cli] cancel 완료"
}

# ──────────────────────────────────────────────
# ask — Telegram 인라인 버튼 질문 전송 + 응답 대기
#
# Usage:
#   cli.sh ask --to <chat> --question <Q>
#              --option N:label [--option N:label]...
#              [--other] [--timeout N] [--recommended <val>] [--dry-run]
#
# Env overrides:
#   OHMYCLAW_ASK_MOCK=1   --dry-run 과 동일 (테스트용)
# ──────────────────────────────────────────────
cmd_ask() {
  local to="" question="" timeout=120 recommended="" dry_run=0 add_other=0
  local save_as="last-ask-answer"
  local -a option_specs=()

  # ── 인수 파싱 ──────────────────────────────
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        shift; to="${1:?--to requires a value}"; shift ;;
      --question)
        shift; question="${1:?--question requires a value}"; shift ;;
      --option)
        shift; option_specs+=("${1:?--option requires N:label}"); shift ;;
      --other)
        add_other=1; shift ;;
      --timeout)
        shift; timeout="${1:?--timeout requires a value}"; shift ;;
      --recommended)
        shift; recommended="${1:?--recommended requires a value}"; shift ;;
      --save-as)
        shift; save_as="${1:?--save-as requires a value}"; shift ;;
      --dry-run)
        dry_run=1; shift ;;
      *)
        echo "ERROR: ask: unknown argument '$1'" >&2
        exit 2 ;;
    esac
  done

  # ── 응답 저장 헬퍼 (state.sh write last-ask-answer) ──
  _ask_save_answer() {
    local value="$1"
    local timeout_flag="${2:-false}"
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local payload
    local v_esc; v_esc=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [[ "$timeout_flag" == "true" ]]; then
      payload="{\"value\":\"$v_esc\",\"ts\":\"$now\",\"savedBy\":\"ask\",\"timeoutFallback\":true}"
    else
      payload="{\"value\":\"$v_esc\",\"ts\":\"$now\",\"savedBy\":\"ask\"}"
    fi
    "$STATE_SH" write "$save_as" "$payload" 2>/dev/null || true
  }

  # ── 필수 인수 검증 ─────────────────────────
  if [[ -z "$to" ]]; then
    echo "ERROR: ask: --to is required" >&2; exit 2
  fi
  if [[ -z "$question" ]]; then
    echo "ERROR: ask: --question is required" >&2; exit 2
  fi
  if [[ ${#option_specs[@]} -eq 0 ]]; then
    echo "ERROR: ask: at least one --option is required" >&2; exit 2
  fi

  # ── timeout 범위 검증 (5..600) ─────────────
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -lt 5 ]] || [[ "$timeout" -gt 600 ]]; then
    echo "ERROR: ask: --timeout must be an integer between 5 and 600 (got: $timeout)" >&2
    exit 2
  fi

  # ── 인라인 키보드 JSON 컴파일 ─────────────
  # 각 옵션은 "N:label" 형식. callback_data 는 콜론 앞 N 부분.
  # 결과: {"inline_keyboard":[[{"text":"label","callback_data":"N"}], ...]}
  local rows=""
  local spec label cb_val
  for spec in "${option_specs[@]}"; do
    cb_val="${spec%%:*}"          # 콜론 이전
    label="${spec#*:}"            # 콜론 이후
    if [[ -z "$cb_val" || -z "$label" || "$cb_val" == "$spec" ]]; then
      echo "ERROR: ask: --option must be in N:label format (got: '$spec')" >&2
      exit 2
    fi
    # Telegram callback_data hard limit: 64 bytes
    if [[ ${#cb_val} -gt 64 ]]; then
      echo "ERROR: ask: --option callback_data '$cb_val' exceeds Telegram 64-byte limit (got: ${#cb_val})" >&2
      exit 2
    fi
    local row
    row=$(printf '[{"text":"%s","callback_data":"%s"}]' \
      "$(printf '%s' "$label"   | sed 's/\\/\\\\/g; s/"/\\"/g')" \
      "$(printf '%s' "$cb_val" | sed 's/\\/\\\\/g; s/"/\\"/g')")
    rows="${rows:+$rows,}$row"
  done

  # --other 추가 행
  if [[ "$add_other" -eq 1 ]]; then
    local other_row='[{"text":"✏️ Other (type answer)","callback_data":"__other__"}]'
    rows="${rows:+$rows,}$other_row"
  fi

  local keyboard_json="{\"inline_keyboard\":[$rows]}"

  # ── dry-run / mock 모드 ────────────────────
  # 우선순위:
  #   1. --dry-run flag: JSON emit only, no save (테스트의 컴파일 검증)
  #   2. OHMYCLAW_ASK_MOCK=1 + OHMYCLAW_ASK_MOCK_RESPONSE=<val>: 시뮬레이션 응답 + 저장 + echo
  #   3. OHMYCLAW_ASK_MOCK=1 단독: 기존 동작 (JSON emit, no save) — 외부 verb 가 자체 응답 처리할 때
  if [[ "$dry_run" -eq 1 ]]; then
    echo "DRY_RUN_JSON: $keyboard_json"
    echo "DRY_RUN_CMD: openclaw message send --channel telegram --target $to --message $question --buttons $keyboard_json"
    return 0
  fi
  if [[ "${OHMYCLAW_ASK_MOCK:-0}" == "1" ]]; then
    if [[ -n "${OHMYCLAW_ASK_MOCK_RESPONSE:-}" ]]; then
      _ask_save_answer "$OHMYCLAW_ASK_MOCK_RESPONSE"
      echo "$OHMYCLAW_ASK_MOCK_RESPONSE"
      return 0
    fi
    echo "DRY_RUN_JSON: $keyboard_json"
    echo "DRY_RUN_CMD: openclaw message send --channel telegram --target $to --message $question --buttons $keyboard_json"
    return 0
  fi

  # ── 실 모드: 메시지 전송 ──────────────────
  openclaw message send \
    --channel telegram \
    --target "$to" \
    --message "$question" \
    --buttons "$keyboard_json"

  # ── 응답 폴링 ─────────────────────────────
  # openclaw CLI 가 있으면 CLI 폴링, 없으면 종료 124
  local answer=""
  local poll_rc=0

  if command -v openclaw >/dev/null 2>&1 && openclaw events wait --help >/dev/null 2>&1; then
    answer=$(openclaw events wait --timeout "$timeout" 2>/dev/null) || poll_rc=$?
  else
    poll_rc=124
  fi

  # ── timeout 처리 ──────────────────────────
  if [[ "$poll_rc" -ne 0 ]]; then
    if [[ -n "$recommended" ]]; then
      echo "$recommended"
      local fb_dir="$OHMYCLAW_HOME/state"
      mkdir -p "$fb_dir"
      local fb_file="$fb_dir/timeout-fallback.json"
      local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      printf '{"question":"%s","recommended":"%s","ts":"%s"}\n' \
        "$(printf '%s' "$question"    | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        "$(printf '%s' "$recommended" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        "$now" > "$fb_file"
      _ask_save_answer "$recommended" true
      return 0
    fi
    return 124
  fi

  # ── callback_data 파싱 ────────────────────
  local cb_data=""
  if [[ "$answer" == "callback_data: "* ]]; then
    cb_data="${answer#callback_data: }"
  else
    cb_data="$answer"
  fi

  # ── __other__ 처리 ────────────────────────
  if [[ "$cb_data" == "__other__" ]]; then
    openclaw message send \
      --channel telegram \
      --target "$to" \
      --message "✏️ 답을 입력해주세요"
    local other_answer=""
    other_answer=$(openclaw events wait --timeout "$timeout" 2>/dev/null) || true
    _ask_save_answer "$other_answer"
    echo "$other_answer"
    return 0
  fi

  _ask_save_answer "$cb_data"
  echo "$cb_data"
  return 0
}

# ──────────────────────────────────────────────
# exec — Ambiguity-gated task execution + model routing
#
# Usage:
#   cli.sh exec <task> [--to <chat>] [--category <cat>] [--plan <plan>]
#               [--threshold <N>] [--dry-run]
#
# Env overrides:
#   OHMYCLAW_SKIP_AMBIGUITY=true   → skip gate entirely
#   OHMYCLAW_EXEC_MOCK_RESPONSE=<val> → skip ask call; use this as simulated response
# ──────────────────────────────────────────────
cmd_exec() {
  local task="" to="" category="auto" plan="pro" threshold="0.2" dry_run=0

  # ── 인수 파싱 ────────────────────────────────
  # 첫 번째 positional arg 이 task (flag 가 아닌 경우)
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    task="$1"; shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        shift; to="${1:?--to requires a value}"; shift ;;
      --category)
        shift; category="${1:?--category requires a value}"; shift ;;
      --plan)
        shift; plan="${1:?--plan requires a value}"; shift ;;
      --threshold)
        shift
        local _thr="${1:?--threshold requires a value}"; shift
        # 숫자 + 범위 검증 (0..0.99)
        if ! awk "BEGIN{v=\"$_thr\"+0; exit (v>=0 && v<=0.99) ? 0 : 1}" 2>/dev/null; then
          echo "ERROR: exec: --threshold must be a number in range 0..0.99 (got: '$_thr')" >&2
          exit 2
        fi
        threshold="$_thr"
        ;;
      --dry-run)
        dry_run=1; shift ;;
      *)
        echo "ERROR: exec: unknown argument '$1'" >&2
        exit 2 ;;
    esac
  done

  # ── task 필수 검증 ───────────────────────────
  if [[ -z "$task" ]]; then
    echo "Usage: cli.sh exec <task> [--to <chat>] [--category <cat>] [--plan <plan>] [--threshold <N>] [--dry-run]" >&2
    exit 2
  fi

  # ── dry-run 스텁 ─────────────────────────────
  if [[ "$dry_run" -eq 1 ]]; then
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -cn \
      --arg task   "$task" \
      --arg cat    "$category" \
      --arg plan   "$plan" \
      --arg thr    "$threshold" \
      --arg ts     "$now" \
      '{task:$task,model:"<dry-run>",intent_id:"last-exec-intent",ambiguous:false,
        _dry_run:true,category:$cat,plan:$plan,threshold:($thr|tonumber),ts:$ts}'
    return 0
  fi

  # ── 1. Ambiguity Gate ────────────────────────
  local ambiguous=false
  local resolved_task="$task"
  local interpretation="none"

  if [[ "${OHMYCLAW_SKIP_AMBIGUITY:-}" == "true" ]]; then
    # 게이트 완전 건너뜀 — ambiguous=false 유지
    ambiguous=false
  else
    local gate_rc=0
    "$SCRIPT_DIR/ambiguity.sh" gate "$task" --threshold "$threshold" >/dev/null 2>&1 \
      || gate_rc=$?

    if [[ $gate_rc -eq 11 ]]; then
      ambiguous=true
    fi
  fi

  # ── 2. Clarification via ask (gate=11 일 때) ─
  if [[ "$ambiguous" == "true" ]]; then
    local opt1="1:${task} 를 그대로 진행 (현재 해석 유지)"
    local opt2="2:${task} 를 단계별로 분해, 1단계만 먼저 실행"
    local opt3="3:일단 read-only 탐색만 수행 (변경 없음)"

    local ask_response=""

    if [[ -n "${OHMYCLAW_EXEC_MOCK_RESPONSE:-}" ]]; then
      # Mock 모드: ask 호출 없이 env 값을 직접 사용
      ask_response="$OHMYCLAW_EXEC_MOCK_RESPONSE"
    else
      # 실 모드: cli.sh ask 호출
      local ask_rc=0
      ask_response=$(
        cmd_ask \
          --to "${to:-self}" \
          --question "더 구체화가 필요합니다: $task" \
          --option "$opt1" \
          --option "$opt2" \
          --option "$opt3" \
          --other \
          --timeout 120
      ) || ask_rc=$?

      if [[ $ask_rc -ne 0 ]]; then
        # timeout without --recommended → exit 124
        exit 124
      fi
    fi

    # ── 응답 매핑 ──────────────────────────────
    case "$ask_response" in
      1)
        resolved_task="$task"
        interpretation="1"
        ;;
      2)
        resolved_task="[단계 1/N] $task"
        interpretation="2"
        ;;
      3)
        resolved_task="[read-only 탐색] $task"
        interpretation="3"
        ;;
      *)
        # 자유 텍스트
        resolved_task="$ask_response"
        interpretation="other"
        ;;
    esac
  fi

  # ── 3. Save intent ───────────────────────────
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local intent_json
  intent_json=$(jq -cn \
    --arg task    "$resolved_task" \
    --arg orig    "$task" \
    --arg interp  "$interpretation" \
    --arg ts      "$now" \
    --argjson amb "$ambiguous" \
    '{"task":$task,"original":$orig,"interpretation":$interp,"ts":$ts,"ambiguous":$amb}')
  "$STATE_SH" write "last-exec-intent" "$intent_json" 2>/dev/null || true

  # ── 4. Route — モデル選択 ────────────────────
  local model
  model=$("$SCRIPT_DIR/select-model.sh" "$resolved_task" "$category" "--plan=$plan")

  # ── 5. Output ────────────────────────────────
  jq -cn \
    --arg task    "$resolved_task" \
    --arg model   "$model" \
    --argjson amb "$ambiguous" \
    '{"task":$task,"model":$model,"intent_id":"last-exec-intent","ambiguous":$amb}'
}

# ──────────────────────────────────────────────
# plan-gate — Planner ambiguity gate
#
# Usage:
#   cli.sh plan-gate [--to <chat>] [--timeout N] [--dry-run]
#
# Reads planner output from stdin.
# If the line contains ask_required:true → dispatches cli.sh ask → emits
#   {"ask_fired":true,"response":"<r>","next":"architect"}
# Otherwise (no JSON / ask_required false/absent) → pass-through:
#   {"ask_fired":false,"next":"architect"}
# The original stdin text (non-JSON or non-ask_required) goes to stderr.
#
# Env overrides:
#   OHMYCLAW_PLAN_MOCK_RESPONSE=<val>  dry-run simulated response (else "(no response)")
#   OHMYCLAW_ASK_MOCK=1               makes the inner ask call a dry-run too
# ──────────────────────────────────────────────
cmd_plan_gate() {
  local to="" timeout=120 dry_run=0

  # ── 인수 파싱 ──────────────────────────────
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        shift; to="${1:?--to requires a value}"; shift ;;
      --timeout)
        shift; timeout="${1:?--timeout requires a value}"; shift ;;
      --dry-run)
        dry_run=1; shift ;;
      *)
        echo "ERROR: plan-gate: unknown argument '$1'" >&2
        exit 2 ;;
    esac
  done

  # ── timeout 범위 검증 (5..600) ─────────────
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -lt 5 ]] || [[ "$timeout" -gt 600 ]]; then
    echo "ERROR: plan-gate: --timeout must be an integer between 5 and 600 (got: $timeout)" >&2
    exit 2
  fi

  # ── stdin 읽기 ────────────────────────────
  local stdin_text
  stdin_text=$(cat)

  # ── ask_required 검출 (jq 로 파싱) ───────
  local ask_required="false"
  local parse_ok=0
  ask_required=$(printf '%s' "$stdin_text" | jq -re '.ask_required // false' 2>/dev/null) \
    || parse_ok=1

  # parse_ok!=0 → 유효한 JSON 아님 → pass-through
  if [[ $parse_ok -ne 0 ]] || [[ "$ask_required" != "true" ]]; then
    # pass-through: original text → stderr, result → stdout
    printf '%s\n' "$stdin_text" >&2
    printf '{"ask_fired":false,"next":"architect"}\n'
    return 0
  fi

  # ── ask_required=true 경로 ────────────────
  # --to 없으면 exit 2
  if [[ -z "$to" ]]; then
    echo "ERROR: plan-gate: --to is required when ask_required is true" >&2
    exit 2
  fi

  # 필드 추출
  local question recommended
  question=$(printf '%s' "$stdin_text" | jq -r '.question // ""')
  recommended=$(printf '%s' "$stdin_text" | jq -r '.recommended // ""')

  # options 배열 길이 검증 (≥2)
  local opt_count
  opt_count=$(printf '%s' "$stdin_text" | jq '.options | length')
  if [[ "$opt_count" -lt 2 ]]; then
    echo "ERROR: plan-gate: options array must have at least 2 entries (got: $opt_count)" >&2
    exit 2
  fi

  # options → --option value:label args 컴파일
  local -a ask_args=()
  ask_args+=(--to "$to")
  ask_args+=(--question "$question")

  local i label value
  for (( i=0; i<opt_count; i++ )); do
    label=$(printf '%s' "$stdin_text" | jq -r ".options[$i].label")
    value=$(printf '%s' "$stdin_text" | jq -r ".options[$i].value")
    ask_args+=(--option "${value}:${label}")
  done

  ask_args+=(--other)
  ask_args+=(--timeout "$timeout")
  [[ -n "$recommended" ]] && ask_args+=(--recommended "$recommended")

  # ── dry-run モード ────────────────────────
  if [[ "$dry_run" -eq 1 ]]; then
    local mock_response
    mock_response="${OHMYCLAW_PLAN_MOCK_RESPONSE:-(no response)}"
    jq -cn \
      --arg resp "$mock_response" \
      '{"ask_fired":true,"response":$resp,"next":"architect"}'
    return 0
  fi

  # ── 실 모드: cmd_ask 호출 ────────────────
  local ask_response=""
  local ask_rc=0

  if [[ -n "${OHMYCLAW_PLAN_MOCK_RESPONSE:-}" ]]; then
    # PLAN_MOCK 모드: ask 를 건너뛰고 env 값 사용
    ask_response="$OHMYCLAW_PLAN_MOCK_RESPONSE"
  else
    ask_response=$(bash "$SCRIPT_DIR/cli.sh" ask "${ask_args[@]}") || ask_rc=$?
    if [[ $ask_rc -ne 0 ]]; then
      echo "ERROR: plan-gate: ask exited $ask_rc" >&2
      exit "$ask_rc"
    fi
  fi

  jq -cn \
    --arg resp "$ask_response" \
    '{"ask_fired":true,"response":$resp,"next":"architect"}'
}

# ──────────────────────────────────────────────
# gap-gate — GAP_DETECTED 후속 결정 게이트
#
# Usage:
#   cli.sh gap-gate [--to <chat>] [--timeout N] [--dry-run]
#
# Reads reviewer verdict JSON from stdin. Expected shape:
#   {"verdict":"GAP_DETECTED","gapType":"...","gapReason":"...","fixDirection":"...","fixIteration":0}
#
# Logic:
#   - Non-JSON or missing verdict → emit {"action":"none","verdict":"unknown"}, exit 0
#   - verdict != GAP_DETECTED    → emit {"action":"none","verdict":"<v>"}, exit 0
#   - verdict == GAP_DETECTED    → compose 2 options + Other, invoke cli.sh ask
#     - apply-fix  → {"action":"fix-loop","verdict":"GAP_DETECTED","direction":"...","fixIteration":<next>}
#     - ignore-gap → {"action":"force-approve","verdict":"APPROVE","note":"user-overrode-gap"}
#     - free text  → {"action":"escalated","verdict":"ESCALATED","userInput":"<text>"}
#
# Env overrides:
#   OHMYCLAW_ASK_MOCK=1                    → inner ask dry-run
#   OHMYCLAW_GAP_MOCK_RESPONSE=<val>       → bypass inner ask entirely (테스트용)
# ──────────────────────────────────────────────
cmd_gap_gate() {
  local to="" timeout=120 dry_run=0

  # ── 인수 파싱 ──────────────────────────────
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        shift; to="${1:?--to requires a value}"; shift ;;
      --timeout)
        shift; timeout="${1:?--timeout requires a value}"; shift ;;
      --dry-run)
        dry_run=1; shift ;;
      *)
        echo "ERROR: gap-gate: unknown argument '$1'" >&2
        exit 2 ;;
    esac
  done

  # ── timeout 범위 검증 (5..600) ─────────────
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -lt 5 ]] || [[ "$timeout" -gt 600 ]]; then
    echo "ERROR: gap-gate: --timeout must be an integer between 5 and 600 (got: $timeout)" >&2
    exit 2
  fi

  # ── stdin 읽기 ────────────────────────────
  local stdin_text
  stdin_text=$(cat)

  # ── verdict 파싱 ─────────────────────────
  local verdict=""
  local parse_ok=0
  verdict=$(printf '%s' "$stdin_text" | jq -re '.verdict' 2>/dev/null) || parse_ok=1

  # Non-JSON 또는 verdict 필드 없음 → pass-through
  if [[ $parse_ok -ne 0 ]] || [[ -z "$verdict" ]]; then
    printf '%s\n' "$stdin_text" >&2
    printf '{"action":"none","verdict":"unknown"}\n'
    return 0
  fi

  # verdict != GAP_DETECTED → pass-through
  if [[ "$verdict" != "GAP_DETECTED" ]]; then
    jq -cn --arg v "$verdict" '{"action":"none","verdict":$v}'
    return 0
  fi

  # ── verdict == GAP_DETECTED ───────────────
  # --to 없으면 exit 2
  if [[ -z "$to" ]]; then
    echo "ERROR: gap-gate: --to is required when verdict is GAP_DETECTED" >&2
    exit 2
  fi

  # 필드 추출
  local gap_type gap_reason fix_direction fix_iteration
  gap_type=$(printf '%s' "$stdin_text"    | jq -r '.gapType // ""')
  gap_reason=$(printf '%s' "$stdin_text"  | jq -r '.gapReason // ""')
  fix_direction=$(printf '%s' "$stdin_text" | jq -r '.fixDirection // ""')
  fix_iteration=$(printf '%s' "$stdin_text" | jq -r '.fixIteration // 0')

  # ── dry-run モード ────────────────────────
  if [[ "$dry_run" -eq 1 ]]; then
    local mock_response
    mock_response="${OHMYCLAW_GAP_MOCK_RESPONSE:-apply-fix}"
    _gap_gate_map_response "$mock_response" "$fix_direction" "$fix_iteration"
    return 0
  fi

  # ── 실 모드 or OHMYCLAW_GAP_MOCK_RESPONSE ─
  local gap_response=""

  if [[ -n "${OHMYCLAW_GAP_MOCK_RESPONSE:-}" ]]; then
    # Mock 모드: ask 호출 없이 env 값을 직접 사용
    gap_response="$OHMYCLAW_GAP_MOCK_RESPONSE"
  else
    # 실 모드: cli.sh ask 호출
    local opt1_label="수정 방향 적용: ${fix_direction}"
    local opt2_label="갭 무시하고 진행 (APPROVE 강제)"
    local ask_rc=0
    gap_response=$(
      bash "$SCRIPT_DIR/cli.sh" ask \
        --to "$to" \
        --question "[${gap_type}] ${gap_reason}" \
        --option "apply-fix:${opt1_label}" \
        --option "ignore-gap:${opt2_label}" \
        --other \
        --timeout "$timeout"
    ) || ask_rc=$?

    if [[ $ask_rc -ne 0 ]]; then
      echo "ERROR: gap-gate: ask exited $ask_rc" >&2
      exit "$ask_rc"
    fi
  fi

  _gap_gate_map_response "$gap_response" "$fix_direction" "$fix_iteration"
}

# ── 응답 매핑 헬퍼 ───────────────────────────
_gap_gate_map_response() {
  local response="$1"
  local direction="$2"
  local fix_iter="$3"
  local next_iter=$(( fix_iter + 1 ))

  case "$response" in
    apply-fix)
      jq -cn \
        --arg dir  "$direction" \
        --argjson ni "$next_iter" \
        '{"action":"fix-loop","verdict":"GAP_DETECTED","direction":$dir,"fixIteration":$ni}'
      ;;
    ignore-gap)
      printf '{"action":"force-approve","verdict":"APPROVE","note":"user-overrode-gap"}\n'
      ;;
    *)
      # Free text → escalated
      jq -cn \
        --arg ui "$response" \
        '{"action":"escalated","verdict":"ESCALATED","userInput":$ui}'
      ;;
  esac
}

# ──────────────────────────────────────────────
# help
# ──────────────────────────────────────────────
cmd_help() {
  cat <<'USAGE'
ohmyclaw cli — unified skill dispatcher

Usage:
  cli.sh <verb> [args...]

Verbs:
  doctor                          종합 점검 (engine + state + hooks)
  route <task> [cat] [--plan=]    모델 라우팅 → select-model.sh
  pool <action> [args]            계정 풀 (next/status/cooldown/release/sweep/...)
  engine <action> [args]          ACP 엔진 (resolve/acp-config/doctor)
  state <action> [args]           세션 state (write/read/clear/list-active/...)
  hooks <action> [args]           훅 (fire/list)
  cancel [--force]                라이프사이클 정리 + (force 시 전체)
  ask --to <chat> --question <Q>  Telegram 인라인 버튼 질문 전송 + 응답 대기
      --option N:label [...]
      [--other] [--timeout N]
      [--recommended <val>]
      [--dry-run]
  exec <task>                     Ambiguity-gated 실행 + 모델 라우팅
      [--to <chat>]
      [--category <cat>]
      [--plan <plan>]
      [--threshold <N>]
      [--dry-run]
  plan-gate                       Planner 모호성 게이트 (stdin JSON → ask dispatch)
      [--to <chat>]
      [--timeout N]
      [--dry-run]
  gap-gate                        GAP_DETECTED 후속 결정 게이트 (reviewer JSON → ask dispatch)
      [--to <chat>]
      [--timeout N]
      [--dry-run]
  version                         버전 출력
  help                            본 사용법

Lifecycle:
  각 verb 진입 시 pre-<verb> 훅 + skill-active state 작성.
  종료 시 post-<verb> 훅 + skill-active 청소 (trap EXIT/INT/TERM).
  pre 훅 exit 7 → verb abort.

Env:
  OHMYCLAW_HOME          ~/.ohmyclaw (state + hooks 루트)
  OHMYCLAW_SESSION_ID    세션 격리 활성화
  OHMYCLAW_STATE_DIR     ~/.cache/ohmyclaw (pool-state, legacy)
  OHMYCLAW_ASK_MOCK            1 → ask dry-run mode (테스트용)
  OHMYCLAW_SKIP_AMBIGUITY      true → exec ambiguity gate 건너뜀
  OHMYCLAW_EXEC_MOCK_RESPONSE  exec ask 응답 시뮬레이션 (테스트용)
  OHMYCLAW_PLAN_MOCK_RESPONSE  plan-gate dry-run 시뮬레이션 응답 (테스트용)
  OHMYCLAW_GAP_MOCK_RESPONSE   gap-gate ask 응답 시뮬레이션 (테스트용; apply-fix|ignore-gap|<text>)
  ZAI_CODING_PLAN              lite|pro|max
  CODEX_OAUTH_ENABLED          true|false
USAGE
}

# ──────────────────────────────────────────────
# 디스패치
# ──────────────────────────────────────────────
VERB="${1:-help}"; shift || true

case "$VERB" in
  help|-h|--help) cmd_help ;;
  doctor|route|pool|engine|state|hooks|cancel|ask|exec|plan-gate|gap-gate|version)
    _run_verb "$VERB" "$@"
    ;;
  *)
    echo "ERROR: unknown verb '$VERB'. try: cli.sh help" >&2
    exit 2
    ;;
esac
