#!/usr/bin/env bash
# ohmyclaw goal-loop.sh — LazyCodex ulw-loop 파쿠리 (goal/evidence/criteria 기반 completion)
#
# 핵심: "목표가 완료되면 자연 종료" — 같은 결과 반복 차단이 아님.
# goal → successCriteria(happy/edge/regression) → evidence 기록 → 전체 pass = 완료.
#
# State: ${OHMYCLAW_STATE_DIR:-~/.cache/ohmyclaw}/goal-loop/<session>/
#   goals.json   — plan (goals + criteria)
#   ledger.jsonl — audit trail
#
# Usage:
#   goal-loop.sh init "brief text"                    — plan 생성 (goals 파생)
#   goal-loop.sh status [--json]                       — 현재 상태
#   goal-loop.sh next [--json]                         — 다음 미완료 goal의 instruction 출력
#   goal-loop.sh evidence --goal-id G1 --criterion-id C001 --status pass --evidence "..." 
#   goal-loop.sh checkpoint --goal-id G1 --status complete --evidence "..."
#   goal-loop.sh steer --kind add_subgoal --evidence "..." --rationale "..."
#   goal-loop.sh is-done                              — exit 0=done, 1=not done
#   goal-loop.sh hook user-prompt-submit              — UserPromptSubmit steering
set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
STATE_BASE="${OHMYCLAW_STATE_DIR:-${HOME}/.cache/ohmyclaw}/goal-loop"
SESSION_ID="${OHMYCLAW_SESSION_ID:-default}"
LOOP_DIR="${STATE_BASE}/${SESSION_ID}"
GOALS_FILE="${LOOP_DIR}/goals.json"
LEDGER_FILE="${LOOP_DIR}/ledger.jsonl"

iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ensure_dir() { mkdir -p "$LOOP_DIR"; }
ledger_append() {
  ensure_dir
  echo "$1" >> "$LEDGER_FILE"
}

# ──── init: brief에서 goals 파생 ────
cmd_init() {
  local brief="${1:-}"
  [[ -z "$brief" ]] && { echo "ERROR: brief required" >&2; exit 2; }
  ensure_dir

  if [[ -f "$GOALS_FILE" ]] && ! cmd_is_done 2>/dev/null; then
    echo "ERROR: existing plan found. Use 'goal-loop.sh reset' first." >&2
    exit 2
  fi

  local now; now=$(iso)

  # brief를 줄 단위로 파싱해서 goals 파생
  local goals_json="[]"
  local idx=0
  while IFS= read -r line; do
    local cleaned
    cleaned=$(echo "$line" | sed 's/^\s*[-*+]\s*//' | sed 's/^\s*[0-9]\+[.)]\s*//' | tr -s ' ' | xargs)
    [[ -z "$cleaned" ]] && continue
    [[ ${#cleaned} -gt 1200 ]] && continue

    local gid
    gid="G$(printf '%03d' $((idx+1)))"
    local goal_json
    goal_json=$(jq -n \
      --arg id "$gid" \
      --arg title "${cleaned:0:72}" \
      --arg obj "$cleaned" \
      --arg now "$now" \
      '{
        id: $id,
        title: $title,
        objective: $obj,
        status: "pending",
        attempt: 0,
        createdAt: $now,
        updatedAt: $now,
        successCriteria: [
          {id:"C001", scenario:("happy path: "+($obj|.[0:60])), userModel:"happy", expectedEvidence:"관찰 가능한 happy-path 증명", essential:true, capturedEvidence:null, status:"pending"},
          {id:"C002", scenario:"edge case", userModel:"edge", expectedEvidence:"경계값/예외 입력 증명", essential:true, capturedEvidence:null, status:"pending"},
          {id:"C003", scenario:"regression", userModel:"regression", expectedEvidence:"인접 기능 회귀 없음 증명", essential:false, capturedEvidence:null, status:"pending"}
        ]
      }')
    goals_json=$(echo "$goals_json" | jq --argjson g "$goal_json" '. + [$g]')
    idx=$((idx+1))
  done <<< "$brief"

  # brief에 불릿이 없으면 단일 goal
  if [[ "$idx" -eq 0 ]]; then
    local goal_json
    goal_json=$(jq -n \
      --arg now "$now" \
      --arg obj "$brief" \
      '{
        id:"G001",
        title:($obj|.[0:72]),
        objective:$obj,
        status:"pending",
        attempt:0,
        createdAt:$now,
        updatedAt:$now,
        successCriteria: [
          {id:"C001", scenario:"happy path", userModel:"happy", expectedEvidence:"관찰 가능한 happy-path 증명", essential:true, capturedEvidence:null, status:"pending"},
          {id:"C002", scenario:"edge case", userModel:"edge", expectedEvidence:"경계값/예외 입력 증명", essential:true, capturedEvidence:null, status:"pending"}
        ]
      }')
    goals_json=$(echo "$goals_json" | jq --argjson g "$goal_json" '. + [$g]')
  fi

  local plan
  plan=$(jq -n \
    --arg now "$now" \
    --argjson goals "$goals_json" \
    --arg session "$SESSION_ID" \
    '{version:1, createdAt:$now, updatedAt:$now, session:$session, goals:$goals}')

  echo "$plan" > "$GOALS_FILE"
  ledger_append "$(jq -c --arg now "$now" --argjson plan "$plan" '{at:$now, kind:"plan_created", plan:$plan}')"

  local count; count=$(echo "$goals_json" | jq 'length')
  echo "goal-loop plan created: ${count} goal(s)"
  echo "goals: ${GOALS_FILE}"
  echo "ledger: ${LEDGER_FILE}"
}

# ──── is-done: 모든 goal이 complete인가 ────
cmd_is_done() {
  [[ ! -f "$GOALS_FILE" ]] && return 1
  local blocking
  blocking=$(jq '[.goals[] | select(.status != "complete" and .steeringStatus != "superseded")] | length' "$GOALS_FILE" 2>/dev/null || echo 1)
  [[ "$blocking" -eq 0 ]]
}

# ──── status ────
cmd_status() {
  local json="${1:-false}"
  [[ ! -f "$GOALS_FILE" ]] && { echo "No plan found. Run 'goal-loop.sh init' first." >&2; exit 2; }

  local summary
  summary=$(jq -c '{
    total: (.goals|length),
    pending: ([.goals[]|select(.status=="pending")]|length),
    in_progress: ([.goals[]|select(.status=="in_progress")]|length),
    complete: ([.goals[]|select(.status=="complete")]|length),
    failed: ([.goals[]|select(.status=="failed")]|length),
    blocked: ([.goals[]|select(.status=="blocked")]|length),
    criteria: {
      total: ([.goals[].successCriteria[]]|length),
      pass: ([.goals[].successCriteria[]|select(.status=="pass")]|length),
      pending: ([.goals[].successCriteria[]|select(.status=="pending")]|length),
      fail: ([.goals[].successCriteria[]|select(.status=="fail")]|length)
    },
    done: ([.goals[]|select(.status!="complete" and .steeringStatus!="superseded")]|length == 0)
  }' "$GOALS_FILE")

  if [[ "$json" == "true" ]]; then
    SUMMARY="$summary" jq -c '. + {summary:(env.SUMMARY|fromjson)}' "$GOALS_FILE"
  else
    echo "goal-loop status"
    echo "$summary" | jq -r '"goals: \(.total) (pending:\(.pending) in_progress:\(.in_progress) complete:\(.complete) failed:\(.failed) blocked:\(.blocked))\ncriteria: \(.criteria.total) (pass:\(.criteria.pass) pending:\(.criteria.pending) fail:\(.criteria.fail))\ndone: \(.done)"'
  fi
}

# ──── next: 다음 미완료 goal instruction ────
cmd_next() {
  local json="${1:-false}"
  [[ ! -f "$GOALS_FILE" ]] && { echo "No plan found." >&2; exit 2; }

  if cmd_is_done; then
    if [[ "$json" == "true" ]]; then
      echo '{"done":true}'
    else
      echo "goal-loop: all goals complete"
    fi
    return 0
  fi

  # 첫 번째 미완료 goal 찾기
  local goal
  goal=$(jq -c '[.goals[] | select(.status != "complete" and .steeringStatus != "superseded")] | .[0]' "$GOALS_FILE")

  [[ "$goal" == "null" ]] && { echo '{"done":true}'; return 0; }

  local gid title obj
  gid=$(echo "$goal" | jq -r '.id')
  title=$(echo "$goal" | jq -r '.title')
  obj=$(echo "$goal" | jq -r '.objective')

  # goal을 in_progress로 마킹
  local now; now=$(iso)
  local prev_status; prev_status=$(echo "$goal" | jq -r '.status')
  jq --arg id "$gid" --arg now "$now" '
    .updatedAt = $now |
    .goals |= map(if .id == $id then .status = "in_progress" | .startedAt = ($now) | .attempt += 1 else . end)
  ' "$GOALS_FILE" > "${GOALS_FILE}.tmp" && mv "${GOALS_FILE}.tmp" "$GOALS_FILE"

  ledger_append "$(jq -c --arg now "$now" --arg gid "$gid" --arg prev "$prev_status" '{at:$now, kind:"goal_started", goalId:$gid, status:"in_progress", before:{status:$prev}}')"

  local unresolved
  unresolved=$(echo "$goal" | jq -r '[.successCriteria[] | select(.status != "pass") | "  - \(.id): \(.scenario) (\(.userModel))"] | join("\n")')

  if [[ "$json" == "true" ]]; then
    jq -c --arg gid "$gid" --arg instruction "GOAL: $obj\n\nSUCCESS CRITERIA:\n$unresolved\n\nSTOP WHEN: 모든 essential criterion이 pass.\nEVIDENCE: 각 criterion에 대해 관찰 가능한 증명을 제공." \
      '{goalId:$gid, instruction:$instruction, goal:.}' "$GOALS_FILE" | head -1
  else
    echo "═══ GOAL: $gid ─ $title ═══"
    echo ""
    echo "$obj"
    echo ""
    echo "SUCCESS CRITERIA:"
    echo "$unresolved"
    echo ""
    echo "STOP WHEN: 모든 essential criterion이 pass."
    echo "EVIDENCE: 각 criterion에 대해 관찰 가능한 증명을 제공."
  fi
}

# ──── evidence: criterion 상태 기록 ────
cmd_evidence() {
  local goal_id="" criterion_id="" status_val="" evidence="" notes=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal-id) goal_id="$2"; shift 2 ;;
      --criterion-id) criterion_id="$2"; shift 2 ;;
      --status) status_val="$2"; shift 2 ;;
      --evidence) evidence="$2"; shift 2 ;;
      --notes) notes="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -z "$goal_id" || -z "$criterion_id" || -z "$status_val" ]] && { echo "ERROR: --goal-id, --criterion-id, --status required" >&2; exit 2; }
  [[ ! "$status_val" =~ ^(pass|fail|blocked)$ ]] && { echo "ERROR: status must be pass|fail|blocked" >&2; exit 2; }

  local now; now=$(iso)
  local prev_status
  prev_status=$(jq -r --arg gid "$goal_id" --arg cid "$criterion_id" '.goals[] | select(.id==$gid) | .successCriteria[] | select(.id==$cid) | .status' "$GOALS_FILE")

  jq --arg gid "$goal_id" --arg cid "$criterion_id" --arg st "$status_val" --arg ev "$evidence" --arg now "$now" --arg notes "$notes" '
    .updatedAt = $now |
    .goals |= map(
      if .id == $gid then
        .updatedAt = $now |
        .successCriteria |= map(
          if .id == $cid then
            .status = $st | .capturedEvidence = $ev | .capturedAt = $now
            | (if $notes != "" then .notes = $notes else . end)
          else . end
        )
      else . end
    )
  ' "$GOALS_FILE" > "${GOALS_FILE}.tmp" && mv "${GOALS_FILE}.tmp" "$GOALS_FILE"

  local kind
  case "$status_val" in
    pass) kind="evidence_captured" ;;
    fail) kind="criterion_failed" ;;
    blocked) kind="criterion_blocked" ;;
  esac

  ledger_append "$(jq -c --arg now "$now" --arg kind "$kind" --arg gid "$goal_id" --arg cid "$criterion_id" --arg st "$status_val" --arg ev "$evidence" --arg prev "$prev_status" '{at:$now, kind:$kind, goalId:$gid, criterionId:$cid, criterionStatus:$st, evidence:$ev, before:{status:$prev}}')"

  echo "evidence recorded: $goal_id/$criterion_id = $status_val"
}

# ──── checkpoint: goal 완료/실패/차단 ────
cmd_checkpoint() {
  local goal_id="" status_val="" evidence=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal-id) goal_id="$2"; shift 2 ;;
      --status) status_val="$2"; shift 2 ;;
      --evidence) evidence="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -z "$goal_id" || -z "$status_val" ]] && { echo "ERROR: --goal-id, --status required" >&2; exit 2; }
  [[ ! "$status_val" =~ ^(complete|failed|blocked)$ ]] && { echo "ERROR: status must be complete|failed|blocked" >&2; exit 2; }

  # complete 시 essential criteria 검증
  if [[ "$status_val" == "complete" ]]; then
    local essential_fail
    essential_fail=$(jq -r --arg gid "$goal_id" '
      [.goals[] | select(.id==$gid) | .successCriteria[] | select(.essential == true and .status != "pass")] | length
    ' "$GOALS_FILE")
    if [[ "$essential_fail" -gt 0 ]]; then
      echo "ERROR: $essential_fail essential criteria not passed. Use 'evidence' to record pass evidence first." >&2
      exit 3
    fi
  fi

  local now; now=$(iso)
  jq --arg gid "$goal_id" --arg st "$status_val" --arg ev "$evidence" --arg now "$now" '
    .updatedAt = $now |
    .goals |= map(if .id == $gid then .status = $st | .evidence = $ev | .updatedAt = $now |
      (if $st == "complete" then .completedAt = $now elif $st == "failed" then .failedAt = $now else . end)
    else . end)
  ' "$GOALS_FILE" > "${GOALS_FILE}.tmp" && mv "${GOALS_FILE}.tmp" "$GOALS_FILE"

  local kind
  case "$status_val" in
    complete) kind="goal_completed" ;;
    failed) kind="goal_failed" ;;
    blocked) kind="goal_blocked" ;;
  esac

  ledger_append "$(jq -c --arg now "$now" --arg kind "$kind" --arg gid "$goal_id" --arg st "$status_val" --arg ev "$evidence" '{at:$now, kind:$kind, goalId:$gid, status:$st, evidence:$ev}')"

  # 전체 완료 확인
  if cmd_is_done; then
    jq --arg now "$now" '.aggregateCompletion = {status:"complete", completedAt:$now, evidence:"all goals resolved"}' "$GOALS_FILE" > "${GOALS_FILE}.tmp" && mv "${GOALS_FILE}.tmp" "$GOALS_FILE"
    ledger_append "$(jq -c --arg now "$now" '{at:$now, kind:"aggregate_completed", evidence:"all goals resolved"}')"
    echo "goal-loop: ALL GOALS COMPLETE"
  else
    echo "checkpoint: $goal_id = $status_val"
  fi
}

# ──── steer: 방향 전환 ────
cmd_steer() {
  local kind="" evidence="" rationale=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="$2"; shift 2 ;;
      --evidence) evidence="$2"; shift 2 ;;
      --rationale) rationale="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local now; now=$(iso)
  ledger_append "$(jq -c --arg now "$now" --arg kind "$kind" --arg ev "$evidence" --arg rat "$rationale" '{at:$now, kind:"steering_accepted", mutationKind:$kind, evidence:$ev, rationale:$rat}')"
  echo "steering recorded: $kind"
}

# ──── hook: UserPromptSubmit steering ────
cmd_hook() {
  local event="${1:-}"
  case "$event" in
    user-prompt-submit)
      # stdin에서 payload 읽기
      local payload
      payload=$(cat 2>/dev/null || echo "")
      [[ -z "$payload" ]] && exit 0

      local prompt
      prompt=$(echo "$payload" | jq -r '.prompt // empty' 2>/dev/null || echo "")
      [[ -z "$prompt" ]] && exit 0

      # plan이 없으면 skip
      [[ ! -f "$GOALS_FILE" ]] && exit 0

      # steering 감지: "그만해", "다른 방법", "이건 빼", 방향 전환 키워드
      if echo "$prompt" | grep -qiE "그만|다른 방법|이건 ?빼|skip|다른 접근|restart|reset|방향 ?전환|change direction"; then
        local now; now=$(iso)
        local output
        output=$(jq -c --arg now "$now" --arg p "$prompt" '{
          hookEventName: "UserPromptSubmit",
          systemMessage: ("[goal-loop] 방향 전환 감지. 현재 plan 상태를 확인하고 필요시 steering 적용: " + ($p|.[0:80]))
        }')
        echo "$output"
      fi
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
}

# ──── reset ────
cmd_reset() {
  rm -rf "$LOOP_DIR"
  echo "goal-loop reset: ${LOOP_DIR}"
}

# ──── dispatch ────
case "${1:-help}" in
  init)     shift; cmd_init "$*" ;;
  status)   shift; _j="false"; [[ "${1:-}" == "--json" ]] && _j="true"; cmd_status "$_j" ;;
  next)     shift; _j="false"; [[ "${1:-}" == "--json" ]] && _j="true"; cmd_next "$_j" ;;
  evidence) shift; cmd_evidence "$@" ;;
  checkpoint) shift; cmd_checkpoint "$@" ;;
  steer)    shift; cmd_steer "$@" ;;
  hook)     shift; cmd_hook "$@" ;;
  is-done)  cmd_is_done ;;
  reset)    cmd_reset ;;
  help|*)
    echo "Usage: goal-loop.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init \"brief\"                    — plan 생성"
    echo "  status [--json]                  — 현재 상태"
    echo "  next [--json]                    — 다음 goal instruction"
    echo "  evidence --goal-id G1 --criterion-id C001 --status pass --evidence \"...\""
    echo "  checkpoint --goal-id G1 --status complete --evidence \"...\""
    echo "  steer --kind add_subgoal --evidence \"...\" --rationale \"...\""
    echo "  is-done                          — exit 0=done, 1=not done"
    echo "  hook user-prompt-submit          — steering hook"
    echo "  reset                            — plan 삭제"
    ;;
esac
