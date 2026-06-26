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
    interview)  cmd_interview  "$@"; exit $? ;;
    commands)   cmd_commands   "$@"; exit $? ;;
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

  # ── presentation 버튼 컴파일 (openclaw MessagePresentation) ─────────────────
  # 각 옵션 "N:label" → {label, action:{type:"callback", value:"N"}}.
  # 실제 openclaw 2026.6.6 API 는 `message send --presentation '{"blocks":[...]}'`
  # (구버전의 `--buttons {inline_keyboard}` 는 더 이상 인식되지 않음).
  local opt_tsv=""
  local spec label cb_val
  for spec in "${option_specs[@]}"; do
    cb_val="${spec%%:*}"          # 콜론 이전 → callback value
    label="${spec#*:}"            # 콜론 이후 → 버튼 레이블
    if [[ -z "$cb_val" || -z "$label" || "$cb_val" == "$spec" ]]; then
      echo "ERROR: ask: --option must be in N:label format (got: '$spec')" >&2
      exit 2
    fi
    # Telegram callback_data hard limit: 64 bytes (presentation action.value → callback_data)
    if [[ ${#cb_val} -gt 64 ]]; then
      echo "ERROR: ask: --option callback_data '$cb_val' exceeds Telegram 64-byte limit (got: ${#cb_val})" >&2
      exit 2
    fi
    opt_tsv+="${cb_val}"$'\t'"${label}"$'\n'
  done

  # --other 버튼 (마지막)
  if [[ "$add_other" -eq 1 ]]; then
    opt_tsv+="__other__"$'\t'"✏️ Other (type answer)"$'\n'
  fi

  # jq 로 buttons 배열 + presentation 빌드 (모든 이스케이프 jq 처리)
  local buttons_json presentation_json
  buttons_json=$(printf '%s' "$opt_tsv" | jq -R -s \
    '[ split("\n")[] | select(length>0) | split("\t")
       | {label: .[1], action: {type: "callback", value: .[0]}} ]')
  presentation_json=$(jq -cn --arg q "$question" --argjson btns "$buttons_json" \
    '{blocks: [ {type:"text", text:$q}, {type:"buttons", buttons:$btns} ]}')

  # ── dry-run / mock 모드 ────────────────────
  # 우선순위:
  #   1. --dry-run flag: JSON emit only, no save (테스트의 컴파일 검증)
  #   2. OHMYCLAW_ASK_MOCK=1 + OHMYCLAW_ASK_MOCK_RESPONSE=<val>: 시뮬레이션 응답 + 저장 + echo
  #   3. OHMYCLAW_ASK_MOCK=1 단독: 기존 동작 (JSON emit, no save) — 외부 verb 가 자체 응답 처리할 때
  if [[ "$dry_run" -eq 1 ]]; then
    echo "DRY_RUN_JSON: $presentation_json"
    echo "DRY_RUN_CMD: openclaw message send --channel telegram --target $to --presentation $presentation_json"
    return 0
  fi
  if [[ "${OHMYCLAW_ASK_MOCK:-0}" == "1" ]]; then
    if [[ -n "${OHMYCLAW_ASK_MOCK_RESPONSE:-}" ]]; then
      _ask_save_answer "$OHMYCLAW_ASK_MOCK_RESPONSE"
      echo "$OHMYCLAW_ASK_MOCK_RESPONSE"
      return 0
    fi
    echo "DRY_RUN_JSON: $presentation_json"
    echo "DRY_RUN_CMD: openclaw message send --channel telegram --target $to --presentation $presentation_json"
    return 0
  fi

  # ── 실 모드: presentation 전송 ────────────
  # NB: message send 의 delivery stdout 은 버린다 — cmd_ask 의 유일한 stdout 은
  # 응답값이어야 함($(cmd_ask) 로 캡처하는 interview/exec/gap-gate 오염 방지).
  # 정직성(B): 발송 실패를 조용히 삼키지 않고 stderr 로 명확히 경고한다.
  if ! command -v openclaw >/dev/null 2>&1; then
    echo "[ask] ⚠️ openclaw CLI가 PATH에 없습니다 — 버튼 미발송 (which -a openclaw / PATH 확인)." >&2
  fi
  local send_rc=0
  openclaw message send \
    --channel telegram \
    --target "$to" \
    --presentation "$presentation_json" >/dev/null || send_rc=$?
  if [[ $send_rc -ne 0 ]]; then
    echo "[ask] ⚠️ 버튼 발송 실패 (rc=$send_rc, target='$to') — openclaw 버전/PATH 또는 유효 chatId(--to <chatId>) 확인." >&2
  fi

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
      echo "[ask] ⚠️ 버튼 응답 없음(openclaw events wait 미지원/타임아웃) — recommended '$recommended' 로 폴백 (실제 선택 아님)." >&2
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
      --message "✏️ 답을 입력해주세요" >/dev/null
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
# interview — Socratic 인터뷰 (우로보로스 정합)
#
# ohmyclaw 4차원 명확성(goal/constraint/success/context)을 따라 결정론적
# Socratic 질문을 Telegram 인라인 버튼으로 발화한다. 응답을 crystallize 절로
# 누적하여 ambiguity 점수를 재계산하고, score ≤ threshold(기본 0.2)에 도달하면
# 조기 종료한다 ("질문은 모호성 ≤ 0.2 까지" — Ouroboros Socratic Clarity).
# 이미 충분히 명확한 차원은 건너뛴다. 결과는 state(interview-result)에 저장되어
# 후속 exec/plan 이 참조할 수 있다.
#
# 두 가지 모드:
#   • 동기/프리뷰: cli.sh interview [<topic>] ...  (CLI 단독; 버튼 응답 불가 → degraded 표시)
#   • 비동기 상태머신 (실 인터랙티브, openclaw 에이전트 구동):
#       cli.sh interview start <topic> --to <chatId>   # 세션 시작 + 1번 질문(command 버튼) 발화
#       cli.sh interview answer <value>                # 버튼 클릭 → 에이전트가 호출 → 기록+다음 질문
#       cli.sh interview status | cancel
#     command 버튼은 클릭 시 openclaw 가 synthetic 메시지(/omc_iv <value>)로 에이전트에 전달 →
#     SKILL.md 가 'cli.sh interview answer <value>' 로 라우팅 → 상태머신 재개. 클릭 응답은 실제값(fallback:false).
#
# Usage:
#   cli.sh interview [<topic>] [--to <chat>] [--threshold <N>]
#                    [--max-rounds <N>] [--timeout <N>] [--save-as <key>] [--dry-run]
#
# Env overrides (테스트용):
#   OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests,module"
#       → cmd_ask 호출 없이 차례대로 응답 시뮬레이션 (질문당 1개, 순서대로 소비)
#   OHMYCLAW_ASK_MOCK=1  → 비동기 모드의 presentation 발화를 dry-run (실 openclaw 미호출)
# ──────────────────────────────────────────────
cmd_interview() {
  # 비동기 상태머신 서브커맨드 (start/answer/status/cancel)
  case "${1:-}" in
    start)  shift; _interview_start  "$@"; return $? ;;
    answer) shift; _interview_answer "$@"; return $? ;;
    status) shift; _interview_status "$@"; return $? ;;
    cancel) shift; _interview_cancel "$@"; return $? ;;
  esac

  local topic="" to="self" timeout=120 threshold="0.2" dry_run=0 max_rounds=4
  local save_as="interview-result"

  # 첫 positional = topic (flag 가 아닌 경우)
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    topic="$1"; shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)         shift; to="${1:?--to requires a value}"; shift ;;
      --topic)      shift; topic="${1:?--topic requires a value}"; shift ;;
      --timeout)    shift; timeout="${1:?--timeout requires a value}"; shift ;;
      --threshold)  shift; threshold="${1:?--threshold requires a value}"; shift ;;
      --max-rounds) shift; max_rounds="${1:?--max-rounds requires a value}"; shift ;;
      --save-as)    shift; save_as="${1:?--save-as requires a value}"; shift ;;
      --dry-run)    dry_run=1; shift ;;
      *) echo "ERROR: interview: unknown argument '$1'" >&2; exit 2 ;;
    esac
  done

  local QFILE="$SCRIPT_DIR/interview.json"
  if [[ ! -f "$QFILE" ]]; then
    echo "ERROR: interview: question bank not found: $QFILE" >&2; exit 2
  fi

  local order
  order=$(jq -r '.order[]' "$QFILE")

  # ── dry-run: 각 차원 질문의 인라인 키보드만 컴파일 출력 ──
  if [[ "$dry_run" -eq 1 ]]; then
    local d
    for d in $order; do
      local q
      q=$(jq -r --arg d "$d" '.dimensions[$d].question' "$QFILE")
      local -a optargs=()
      while IFS=$'\t' read -r val label; do
        optargs+=(--option "${val}:${label}")
      done < <(jq -r --arg d "$d" '.dimensions[$d].options[] | [.value,.label] | @tsv' "$QFILE")
      echo "DRY_RUN_DIMENSION: $d"
      cmd_ask --to "$to" --question "$q" "${optargs[@]}" --other --dry-run
    done
    return 0
  fi

  # ── mock 응답 (질문당 1개, 순서대로) ──
  local -a mock_q=()
  local have_mock=0
  if [[ -n "${OHMYCLAW_INTERVIEW_MOCK_RESPONSES:-}" ]]; then
    have_mock=1
    IFS=',' read -r -a mock_q <<< "$OHMYCLAW_INTERVIEW_MOCK_RESPONSES"
  fi

  local crystallized="$topic"
  local answers_json="[]"
  local rounds=0 mock_idx=0 fallback_count=0
  local d

  for d in $order; do
    # 현재 누적 텍스트 재채점
    local score_json amb dim_clarity
    score_json=$("$SCRIPT_DIR/ambiguity.sh" score "$crystallized" --threshold "$threshold" 2>/dev/null || echo '{}')
    # NB: jq '.ambiguous // true' 는 false 를 빈값 취급하여 항상 true 가 됨 → has() 분기 사용
    amb=$(echo "$score_json" | jq -r 'if has("ambiguous") then (.ambiguous|tostring) else "true" end' 2>/dev/null || echo true)

    # 조기 종료: 더 이상 모호하지 않으면 질문 중단 (우로보로스 정합)
    if [[ "$amb" == "false" ]]; then break; fi
    if (( rounds >= max_rounds )); then break; fi

    # 이미 충분히 명확한 차원은 건너뜀
    dim_clarity=$(echo "$score_json" | jq -r --arg d "$d" '.dimensions[$d] // 0' 2>/dev/null || echo 0)
    if awk "BEGIN{exit !(($dim_clarity) >= 0.99)}"; then continue; fi

    local q recommended
    q=$(jq -r --arg d "$d" '.dimensions[$d].question' "$QFILE")
    recommended=$(jq -r --arg d "$d" '.dimensions[$d].recommended' "$QFILE")

    # ── 응답 획득 ──
    local ans="" fb="false"
    if [[ "$have_mock" -eq 1 ]]; then
      ans="${mock_q[$mock_idx]:-$recommended}"
      mock_idx=$(( mock_idx + 1 ))
    else
      local -a optargs=()
      while IFS=$'\t' read -r val label; do
        optargs+=(--option "${val}:${label}")
      done < <(jq -r --arg d "$d" '.dimensions[$d].options[] | [.value,.label] | @tsv' "$QFILE")
      local ask_rc=0
      ans=$(
        cmd_ask --to "$to" --question "$q" "${optargs[@]}" --other \
          --timeout "$timeout" --recommended "$recommended" --save-as "interview-${d}"
      ) || ask_rc=$?
      [[ $ask_rc -ne 0 ]] && ans="$recommended"
      # 폴백 판정: 실제 버튼 응답을 못 받아 recommended 로 떨어졌는가
      # (cmd_ask 가 interview-<d> state 에 timeoutFallback:true 기록). 정직성(B) 위해 표시.
      if [[ $ask_rc -ne 0 ]] || \
         [[ "$("$STATE_SH" read "interview-${d}" 2>/dev/null | jq -r '.timeoutFallback==true' 2>/dev/null || echo false)" == "true" ]]; then
        fb="true"
      fi
    fi
    [[ "$fb" == "true" ]] && fallback_count=$(( fallback_count + 1 ))

    # ── 응답값 → crystallize 절 매핑 (Other 자유응답은 원문 사용) ──
    local clause
    clause=$(jq -r --arg d "$d" --arg v "$ans" \
      '(.dimensions[$d].options[] | select(.value == $v) | .crystallize) // empty' "$QFILE")
    [[ -z "$clause" ]] && clause="${d}: ${ans}"
    crystallized="${crystallized:+$crystallized. }${clause}"

    answers_json=$(echo "$answers_json" | jq -c --arg d "$d" --arg v "$ans" --arg c "$clause" --argjson f "$fb" \
      '. + [{dimension:$d, answer:$v, clause:$c, fallback:$f}]')
    rounds=$(( rounds + 1 ))
  done

  # ── 최종 채점 + 저장 ──
  local final_json final_score final_amb
  final_json=$("$SCRIPT_DIR/ambiguity.sh" score "$crystallized" --threshold "$threshold" 2>/dev/null || echo '{}')
  final_score=$(echo "$final_json" | jq -r '.score // 1' 2>/dev/null || echo 1)
  final_amb=$(echo "$final_json"  | jq -r 'if has("ambiguous") then (.ambiguous|tostring) else "true" end' 2>/dev/null || echo true)

  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local degraded="false"; [[ "$fallback_count" -gt 0 ]] && degraded="true"
  local result_json
  result_json=$(jq -cn \
    --arg topic "$topic" \
    --arg crys  "$crystallized" \
    --argjson rounds  "$rounds" \
    --argjson score   "$final_score" \
    --argjson amb     "$final_amb" \
    --argjson degraded "$degraded" \
    --argjson fbcount "$fallback_count" \
    --argjson answers "$answers_json" \
    --arg ts "$now" \
    '{topic:$topic, crystallized:$crys, rounds:$rounds, score:$score, ambiguous:$amb, degraded:$degraded, fallbackCount:$fbcount, answers:$answers, ts:$ts, savedBy:"interview"}')
  "$STATE_SH" write "$save_as" "$result_json" 2>/dev/null || true

  # 정직성(B): 폴백이 섞이면 결과가 '진짜 인터뷰'가 아님을 명확히 알린다 (조용한 가짜 성공 방지).
  if [[ "$fallback_count" -gt 0 ]]; then
    echo "[interview] ⚠️ DEGRADED: ${fallback_count}/${rounds} 답변이 recommended 기본값입니다 (버튼 미수신 — 실제 선택 아님)." >&2
    echo "[interview]    openclaw 에이전트 컨텍스트(올바른 PATH)에서 '--to <chatId>' 로 실행해야 버튼 인터랙션이 동작합니다." >&2
  fi

  echo "$result_json"
  return 0
}

# ──────────────────────────────────────────────
# interview — 비동기 상태머신 헬퍼 (openclaw 에이전트 구동, command 버튼 클릭으로 재개)
#   세션 state: interview-session {topic,to,threshold,order,answers,crystallized,askedDims,awaiting,status,ts}
#   결과 state: interview-result (mode:"async", degraded:false — 클릭 응답은 실제값)
# ──────────────────────────────────────────────
_interview_send_presentation() {
  local to="$1" pj="$2"
  if [[ "${OHMYCLAW_ASK_MOCK:-0}" == "1" ]]; then
    echo "DRY_RUN_JSON: $pj"
    echo "DRY_RUN_CMD: openclaw message send --channel telegram --target $to --presentation $pj"
    return 0
  fi
  if ! command -v openclaw >/dev/null 2>&1; then
    echo "[interview] ⚠️ openclaw CLI가 PATH에 없습니다 — 질문 미발송 (which -a openclaw / PATH 확인)." >&2
    return 1
  fi
  local rc=0
  openclaw message send --channel telegram --target "$to" --presentation "$pj" >/dev/null || rc=$?
  [[ $rc -ne 0 ]] && echo "[interview] ⚠️ 질문 발송 실패 (rc=$rc, target='$to') — openclaw 버전/PATH 또는 유효 chatId 확인." >&2
  return $rc
}

# 질문 1개를 command-action 버튼으로 발화: 각 옵션 → /omc_iv <value>, Other → /omc_iv __other__
_interview_send_question() {
  local d="$1" to="$2"
  local QFILE="$SCRIPT_DIR/interview.json"
  local q; q=$(jq -r --arg d "$d" '.dimensions[$d].question' "$QFILE")
  local pj
  pj=$(jq -c --arg d "$d" --arg q "$q" '
    { blocks: [
        {type:"text", text:$q},
        {type:"buttons", buttons:
          ( (.dimensions[$d].options | map({label:.label, action:{type:"command", command:("/omc_iv " + .value)}}))
            + [ {label:"✏️ Other (type answer)", action:{type:"command", command:"/omc_iv __other__"}} ] )
        }
    ] }' "$QFILE")
  _interview_send_presentation "$to" "$pj"
}

# 다음 질문 결정(우로보로스: 모호성 ≤ threshold 면 종료, 이미 명확/이미 물은 차원 skip) → 발화 or 종료
_interview_advance() {
  local session; session=$("$STATE_SH" read interview-session 2>/dev/null)
  [[ -z "$session" ]] && { echo "ERROR: 활성 인터뷰 세션 없음" >&2; exit 2; }
  local crystallized threshold to
  crystallized=$(echo "$session" | jq -r '.crystallized')
  threshold=$(echo "$session" | jq -r '.threshold')
  to=$(echo "$session" | jq -r '.to')

  local score_json amb
  score_json=$("$SCRIPT_DIR/ambiguity.sh" score "$crystallized" --threshold "$threshold" 2>/dev/null || echo '{}')
  amb=$(echo "$score_json" | jq -r 'if has("ambiguous") then (.ambiguous|tostring) else "true" end' 2>/dev/null || echo true)
  if [[ "$amb" == "false" ]]; then _interview_finalize; return $?; fi

  local next_dim="" d asked clarity
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    asked=$(echo "$session" | jq -r --arg d "$d" '(.askedDims | index($d)) != null')
    [[ "$asked" == "true" ]] && continue
    clarity=$(echo "$score_json" | jq -r --arg d "$d" '.dimensions[$d] // 0')
    if awk "BEGIN{exit !(($clarity) >= 0.99)}"; then continue; fi
    next_dim="$d"; break
  done < <(echo "$session" | jq -r '.order[]')

  if [[ -z "$next_dim" ]]; then _interview_finalize; return $?; fi

  session=$(echo "$session" | jq -c --arg d "$next_dim" '.awaiting=$d | .askedDims += [$d]')
  "$STATE_SH" write interview-session "$session" 2>/dev/null || true
  _interview_send_question "$next_dim" "$to"
  jq -cn --arg d "$next_dim" --arg to "$to" '{status:"awaiting", dimension:$d, to:$to}'
}

# 최종화: interview-result(mode:async, degraded:false) 저장 + 세션 청소 + 요약 발송
_interview_finalize() {
  local session; session=$("$STATE_SH" read interview-session 2>/dev/null)
  [[ -z "$session" ]] && { echo "ERROR: 활성 인터뷰 세션 없음" >&2; exit 2; }
  local crystallized threshold to topic answers
  crystallized=$(echo "$session" | jq -r '.crystallized')
  threshold=$(echo "$session" | jq -r '.threshold')
  to=$(echo "$session" | jq -r '.to')
  topic=$(echo "$session" | jq -r '.topic')
  answers=$(echo "$session" | jq -c '.answers')

  local final_json final_score final_amb rounds
  final_json=$("$SCRIPT_DIR/ambiguity.sh" score "$crystallized" --threshold "$threshold" 2>/dev/null || echo '{}')
  final_score=$(echo "$final_json" | jq -r '.score // 1')
  final_amb=$(echo "$final_json" | jq -r 'if has("ambiguous") then (.ambiguous|tostring) else "true" end')
  rounds=$(echo "$answers" | jq 'length')

  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local result_json
  result_json=$(jq -cn --arg topic "$topic" --arg crys "$crystallized" \
    --argjson rounds "$rounds" --argjson score "$final_score" --argjson amb "$final_amb" \
    --argjson answers "$answers" --arg ts "$now" \
    '{topic:$topic, crystallized:$crys, rounds:$rounds, score:$score, ambiguous:$amb, degraded:false, fallbackCount:0, answers:$answers, ts:$ts, savedBy:"interview", mode:"async"}')
  "$STATE_SH" write interview-result "$result_json" 2>/dev/null || true
  "$STATE_SH" clear interview-session 2>/dev/null || true

  local summary; summary=$(printf '✅ 인터뷰 완료 — %s 라운드 / 모호성 %s\n%s' "$rounds" "$final_score" "$crystallized")
  _interview_send_presentation "$to" "$(jq -cn --arg t "$summary" '{blocks:[{type:"text", text:$t}]}')" || true
  echo "$result_json"
}

# start <topic> --to <chatId> [--threshold N]
_interview_start() {
  local topic="" to="" threshold="0.2"
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then topic="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)        shift; to="${1:?--to requires a value}"; shift ;;
      --topic)     shift; topic="${1:?--topic requires a value}"; shift ;;
      --threshold) shift; threshold="${1:?--threshold requires a value}"; shift ;;
      *) echo "ERROR: interview start: unknown argument '$1'" >&2; exit 2 ;;
    esac
  done
  [[ -z "$to" ]] && { echo "ERROR: interview start: --to <chatId> 필수 (실 인터랙션 대상)" >&2; exit 2; }
  local QFILE="$SCRIPT_DIR/interview.json"
  [[ -f "$QFILE" ]] || { echo "ERROR: question bank not found: $QFILE" >&2; exit 2; }

  local order now session
  order=$(jq -c '.order' "$QFILE")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  session=$(jq -cn --arg t "$topic" --arg to "$to" --argjson thr "$threshold" --argjson order "$order" --arg ts "$now" \
    '{topic:$t, to:$to, threshold:$thr, order:$order, answers:[], crystallized:$t, askedDims:[], awaiting:null, status:"active", ts:$ts}')
  "$STATE_SH" write interview-session "$session" 2>/dev/null || true
  _interview_advance
}

# answer <value>  (에이전트가 버튼 클릭 synthetic 명령 /omc_iv <value> 수신 후 호출; --to 는 세션에서 읽음)
_interview_answer() {
  local value=""
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then value="$1"; shift; fi
  while [[ $# -gt 0 ]]; do case "$1" in --to) shift; shift ;; *) shift ;; esac; done
  [[ -z "$value" ]] && { echo "ERROR: interview answer: <value> 필요" >&2; exit 2; }

  local session; session=$("$STATE_SH" read interview-session 2>/dev/null)
  [[ -z "$session" ]] && { echo "ERROR: 활성 인터뷰 세션 없음 (먼저 'interview start')" >&2; exit 2; }
  local d to; d=$(echo "$session" | jq -r '.awaiting // empty'); to=$(echo "$session" | jq -r '.to')
  [[ -z "$d" ]] && { echo "ERROR: 현재 대기 중인 질문이 없습니다" >&2; exit 2; }

  # Other → 자유 입력 요청. awaiting 유지 → 다음 'interview answer <텍스트>' 가 free-text 로 처리됨.
  if [[ "$value" == "__other__" ]]; then
    _interview_send_presentation "$to" "$(jq -cn '{blocks:[{type:"text", text:"✏️ 답을 입력해 주세요 (자유 서술)"}]}')"
    jq -cn --arg d "$d" '{status:"awaiting-freetext", dimension:$d}'
    return 0
  fi

  local QFILE="$SCRIPT_DIR/interview.json"
  local clause
  clause=$(jq -r --arg d "$d" --arg v "$value" '(.dimensions[$d].options[]|select(.value==$v)|.crystallize)//empty' "$QFILE")
  [[ -z "$clause" ]] && clause="${d}: ${value}"
  session=$(echo "$session" | jq -c --arg d "$d" --arg v "$value" --arg c "$clause" \
    '.answers += [{dimension:$d, answer:$v, clause:$c, fallback:false}]
     | .crystallized = (if (.crystallized|length)>0 then (.crystallized + ". " + $c) else $c end)
     | .awaiting = null')
  "$STATE_SH" write interview-session "$session" 2>/dev/null || true
  _interview_advance
}

_interview_status() {
  local session; session=$("$STATE_SH" read interview-session 2>/dev/null)
  if [[ -z "$session" ]]; then echo '{"status":"none"}'; return 0; fi
  echo "$session" | jq -c '{status:.status, awaiting:.awaiting, asked:.askedDims, answers:(.answers|length), crystallized:.crystallized}'
}

_interview_cancel() {
  "$STATE_SH" clear interview-session 2>/dev/null || true
  echo '{"status":"cancelled"}'
}

# ──────────────────────────────────────────────
# commands — Telegram 슬래시 명령어 매니페스트 (register/dispatch/menu)
#
# Usage:
#   cli.sh commands list                       # 사람용 표
#   cli.sh commands json                        # setMyCommands API 페이로드
#   cli.sh commands botfather                   # @BotFather 붙여넣기 형식
#   cli.sh commands register [--to <scope>]     # openclaw commands set (없으면 페이로드 출력)
#   cli.sh commands dispatch "<인바운드 /명령>" [--to <chat>]   # /명령 → verb 라우팅 실행
#   cli.sh commands menu [--to <chat>] [--dry-run]             # 명령 팔레트를 버튼으로 발화
#
# Env overrides (테스트용):
#   OHMYCLAW_COMMANDS_MOCK=1   → register/dispatch/menu 가 실제 호출 없이 페이로드/라우팅 emit
# ──────────────────────────────────────────────
cmd_commands() {
  local sub="${1:-list}"; shift || true
  local CFILE="$SCRIPT_DIR/commands.json"
  if [[ ! -f "$CFILE" ]]; then
    echo "ERROR: commands: manifest not found: $CFILE" >&2; exit 2
  fi

  case "$sub" in
    list)
      jq -r '.commands[] | "/\(.command)\t\(.description)\t→ cli.sh \(.verb) \(.args)"' "$CFILE"
      ;;

    json)
      jq -c '[.commands[] | {command:.command, description:.description}]' "$CFILE"
      ;;

    botfather)
      jq -r '.commands[] | "\(.command) - \(.description)"' "$CFILE"
      ;;

    register)
      local to=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --to) shift; to="${1:-}"; shift ;;
          *) shift ;;
        esac
      done
      local payload
      payload=$(jq -c '[.commands[] | {command:.command, description:.description}]' "$CFILE")
      # openclaw 2026.6.6 에는 슬래시 명령 등록(Telegram setMyCommands) CLI 가 없다.
      # → setMyCommands JSON 페이로드 + 적용 방법을 출력 (Bot API 또는 @BotFather).
      echo "SET_MY_COMMANDS_JSON: $payload"
      echo "# Telegram Bot API setMyCommands 로 등록:"
      echo "#   curl -s \"https://api.telegram.org/bot<TOKEN>/setMyCommands\" \\"
      echo "#     -H 'Content-Type: application/json' \\"
      echo "#     -d '{\"commands\": ${payload}}'"
      echo "# 또는 @BotFather 에 'cli.sh commands botfather' 출력을 붙여넣기."
      [[ -n "$to" ]] && echo "# scope: $to"
      return 0
      ;;

    dispatch)
      local to="" raw=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --to) shift; to="${1:-}"; shift ;;
          *)    raw="$1"; shift ;;
        esac
      done
      if [[ -z "$raw" ]]; then
        echo "ERROR: commands dispatch: 인바운드 메시지 문자열이 필요합니다" >&2; exit 2
      fi
      local msg="${raw#/}"                 # 선행 슬래시 제거
      local first rest
      first="${msg%%[[:space:]]*}"         # 첫 토큰
      first="${first%%@*}"                 # @botname 제거
      if [[ "$msg" == *[[:space:]]* ]]; then rest="${msg#*[[:space:]]}"; else rest=""; fi

      local verb="" cand_rest="$rest"
      verb=$(jq -r --arg c "$first" \
        '(.commands[] | select(.command == $c or ((.aliases // []) | index($c))) | .verb) // empty' \
        "$CFILE" | head -1)

      # 2토큰 alias ("ohmyclaw interview ...") 처리
      if [[ -z "$verb" && -n "$rest" ]]; then
        local second two
        second="${rest%%[[:space:]]*}"
        two="${first} ${second}"
        verb=$(jq -r --arg c "$two" \
          '(.commands[] | select((.aliases // []) | index($c)) | .verb) // empty' \
          "$CFILE" | head -1)
        if [[ -n "$verb" ]]; then
          if [[ "$rest" == *[[:space:]]* ]]; then cand_rest="${rest#*[[:space:]]}"; else cand_rest=""; fi
        fi
      fi

      if [[ -z "$verb" ]]; then
        echo "ERROR: commands dispatch: 알 수 없는 명령 '/$first'" >&2; exit 2
      fi

      # menu 의사-verb
      if [[ "$verb" == "__menu__" ]]; then
        if [[ "${OHMYCLAW_COMMANDS_MOCK:-0}" == "1" ]]; then
          jq -cn --arg v menu --arg a "" --arg to "$to" '{resolved:$v, args:$a, to:$to}'
          return 0
        fi
        cmd_commands menu --to "$to"
        return $?
      fi

      if [[ "${OHMYCLAW_COMMANDS_MOCK:-0}" == "1" ]]; then
        jq -cn --arg v "$verb" --arg a "$cand_rest" --arg to "$to" '{resolved:$v, args:$a, to:$to}'
        return 0
      fi

      # 실행: 잔여 문자열을 단일 positional 로 전달 (+ --to). 별도 cli.sh 프로세스로 깨끗한 라이프사이클.
      if [[ -n "$cand_rest" && -n "$to" ]]; then
        "$SCRIPT_DIR/cli.sh" "$verb" "$cand_rest" --to "$to"
      elif [[ -n "$cand_rest" ]]; then
        "$SCRIPT_DIR/cli.sh" "$verb" "$cand_rest"
      elif [[ -n "$to" ]]; then
        "$SCRIPT_DIR/cli.sh" "$verb" --to "$to"
      else
        "$SCRIPT_DIR/cli.sh" "$verb"
      fi
      return $?
      ;;

    menu)
      local to="self" mdry=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --to) shift; to="${1:-self}"; shift ;;
          --dry-run) mdry=1; shift ;;
          *) shift ;;
        esac
      done
      # 슬래시 명령어를 버튼으로: action.type="command" → 클릭 시 채널 네이티브
      # 슬래시 명령 경로로 실행 (등록된 omc_* 명령이 발동). 우로보로스 정합 팔레트.
      local presentation_json
      presentation_json=$(jq -c '
        { title: "🦞 ohmyclaw 명령 팔레트",
          blocks: [
            {type:"text", text:"실행할 슬래시 명령을 선택하세요"},
            {type:"buttons",
             buttons: [ .commands[] | select(.verb != "__menu__")
               | {label: ("/" + .command), action: {type:"command", command: ("/" + .command)}} ]}
          ] }' "$CFILE")
      if [[ "$mdry" -eq 1 || "${OHMYCLAW_COMMANDS_MOCK:-0}" == "1" ]] || ! command -v openclaw >/dev/null 2>&1; then
        echo "DRY_RUN_JSON: $presentation_json"
        echo "DRY_RUN_CMD: openclaw message send --channel telegram --target $to --presentation $presentation_json"
        return 0
      fi
      openclaw message send --channel telegram --target "$to" --presentation "$presentation_json"
      ;;

    *)
      echo "ERROR: commands: 알 수 없는 하위명령 '$sub' (list|json|botfather|register|dispatch|menu)" >&2
      exit 2 ;;
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
  interview [<topic>]             Socratic 인터뷰 — 4차원 명확성 버튼 질문 (우로보로스 정합)
      [--to <chat>]
      [--threshold <N>]
      [--max-rounds <N>]
      [--timeout <N>]
      [--save-as <key>]
      [--dry-run]
  commands <sub>                  Telegram 슬래시 명령어 (list/json/botfather/register/dispatch/menu)
      list | json | botfather
      register [--to <scope>]
      dispatch "<인바운드 /명령>" [--to <chat>]
      menu [--to <chat>] [--dry-run]
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
  OHMYCLAW_INTERVIEW_MOCK_RESPONSES  쉼표구분 응답 큐 → interview 가 ask 없이 순서대로 소비 (테스트용)
  OHMYCLAW_COMMANDS_MOCK       1 → commands register/dispatch/menu dry-run (테스트용)
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
  doctor|route|pool|engine|state|hooks|cancel|ask|exec|interview|commands|plan-gate|gap-gate|version)
    _run_verb "$VERB" "$@"
    ;;
  *)
    echo "ERROR: unknown verb '$VERB'. try: cli.sh help" >&2
    exit 2
    ;;
esac
