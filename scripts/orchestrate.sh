#!/usr/bin/env bash
# OpenClaw 하네스 — 오케스트레이터 진입 스크립트
# Plan→Work→Review 전체 사이클 실행
# 사용법: ./orchestrate.sh <모드> <태스크설명...>
#   모드: solo, parallel, full, auto
set -euo pipefail

# ──────────────────────────────────────────────
# 설정
# ──────────────────────────────────────────────
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT_DIR="${HARNESS_DIR}/scripts"
STATE_DIR="${HARNESS_DIR}/state"

MODE="${1:-auto}"
shift || true
TASK_DESC="${*:-}"

if [[ -z "$TASK_DESC" ]]; then
    echo "사용법: $0 <모드> <태스크설명>" >&2
    echo "모드: solo, parallel, full, auto" >&2
    echo "" >&2
    echo "예시:" >&2
    echo "  $0 auto 'Todo 앱 만들어줘'" >&2
    echo "  $0 solo '버그 하나 고쳐줘'" >&2
    echo "  $0 parallel '인증 구현, 프로필 구현'" >&2
    echo "  $0 full '전체 백엔드 리팩토링'" >&2
    exit 1
fi

# 상태 디렉토리 생성
mkdir -p "${STATE_DIR}"

# ──────────────────────────────────────────────
# 사이클 ID 생성
# ──────────────────────────────────────────────
CYCLE_ID="cycle-$(date +%Y%m%d-%H%M%S)"
STATE_FILE="${STATE_DIR}/${CYCLE_ID}.yaml"

# ──────────────────────────────────────────────
# 로깅
# ──────────────────────────────────────────────
log() {
    local level="$1"
    shift
    echo "[$(date +%H:%M:%S)] [${level}] $*"
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ──────────────────────────────────────────────
# 모드 자동 선택
# ──────────────────────────────────────────────
auto_detect_mode() {
    local text="$1"

    # 쉼표로 구분된 태스크 수 카운트
    local task_count
    task_count=$(echo "$text" | tr ',' '\n' | grep -c '[^ ]' || echo "1")

    # 라우팅으로 복잡도 확인
    local routing_result
    routing_result=$("${SCRIPT_DIR}/route-task.sh" "$text" "auto" "standard" 2>/dev/null || echo "")
    local complexity_tier
    complexity_tier=$(echo "$routing_result" | grep "complexity_tier:" | sed 's/.*complexity_tier:[[:space:]]*//' || echo "MEDIUM")

    if [[ "$task_count" -eq 1 ]] && [[ "$complexity_tier" != "HIGH" ]]; then
        echo "solo"
    elif [[ "$task_count" -le 3 ]]; then
        echo "parallel"
    else
        echo "full"
    fi
}

# ──────────────────────────────────────────────
# 상태 파일 초기화
# ──────────────────────────────────────────────
init_state() {
    cat > "${STATE_FILE}" <<EOF
cycle:
  id: "${CYCLE_ID}"
  started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mode: "${MODE}"
  phase: IDLE
  task_description: "${TASK_DESC}"
  plan:
    session_id: null
    status: pending
  workers: []
  review:
    session_id: null
    verdict: null
    attempt: 0
  fix_loop:
    count: 0
    max: 3
EOF
}

update_phase() {
    local phase="$1"
    if command -v sed &>/dev/null; then
        sed -i.bak "s/phase:.*/phase: ${phase}/" "${STATE_FILE}" 2>/dev/null || true
        rm -f "${STATE_FILE}.bak"
    fi
    log_info "단계 전환: ${phase}"
}

# ──────────────────────────────────────────────
# Solo 모드: 직접 구현
# ──────────────────────────────────────────────
run_solo() {
    log_info "━━━ Solo 모드 ━━━"
    log_info "태스크: ${TASK_DESC}"

    update_phase "WORKING"

    # 라우팅으로 모델 결정
    local routing_result
    routing_result=$("${SCRIPT_DIR}/route-task.sh" "$TASK_DESC" "auto" "standard" 2>/dev/null || echo "")
    local model
    model=$(echo "$routing_result" | grep "model:" | head -1 | sed 's/.*model:[[:space:]]*//' || echo "gpt-5.4-codex")

    log_info "선택된 모델: ${model}"

    # Worker spawn
    "${SCRIPT_DIR}/spawn-agent.sh" "worker" "$TASK_DESC" "$model"

    update_phase "COMPLETE"
    log_info "Solo 모드 완료"
}

# ──────────────────────────────────────────────
# Parallel 모드: 독립 태스크 병렬 실행
# ──────────────────────────────────────────────
run_parallel() {
    log_info "━━━ Parallel 모드 ━━━"

    update_phase "WORKING"

    # 쉼표로 태스크 분리
    IFS=',' read -ra TASKS <<< "$TASK_DESC"

    local pids=()
    local task_idx=0

    for task in "${TASKS[@]}"; do
        task=$(echo "$task" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "$task" ]]; then
            continue
        fi

        task_idx=$((task_idx + 1))
        log_info "Worker-${task_idx} 시작: ${task}"

        # 라우팅으로 모델 결정
        local model
        model=$("${SCRIPT_DIR}/route-task.sh" "$task" "auto" "standard" 2>/dev/null \
            | grep "model:" | head -1 | sed 's/.*model:[[:space:]]*//' || echo "gpt-5.4-codex")

        # 병렬 spawn (백그라운드)
        "${SCRIPT_DIR}/spawn-agent.sh" "worker" "$task" "$model" &
        pids+=($!)
    done

    # 모든 Worker 완료 대기
    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=$((failed + 1))
        fi
    done

    if [[ "$failed" -gt 0 ]]; then
        log_warn "${failed}개 Worker 실패"
        update_phase "ESCALATED"
    else
        # 리뷰 단계
        update_phase "REVIEWING"
        log_info "리뷰 시작..."
        "${SCRIPT_DIR}/spawn-agent.sh" "reviewer" "병렬 구현 결과 리뷰: ${TASK_DESC}"
        update_phase "COMPLETE"
    fi

    log_info "Parallel 모드 완료"
}

# ──────────────────────────────────────────────
# Full 모드: Plan → Work → Review 전체 사이클
# ──────────────────────────────────────────────
run_full() {
    log_info "━━━ Full Cycle 모드 ━━━"

    # ① Plan 단계
    update_phase "PLANNING"
    log_info "[1/3] Plan 단계 시작..."
    "${SCRIPT_DIR}/spawn-agent.sh" "planner" "$TASK_DESC"

    # TODO: plan_v1 결과를 파싱하여 태스크 목록 추출
    # 현재는 전체 태스크를 단일 Worker에 전달

    # ② Work 단계
    update_phase "WORKING"
    log_info "[2/3] Work 단계 시작..."

    # 라우팅으로 모델 결정
    local model
    model=$("${SCRIPT_DIR}/route-task.sh" "$TASK_DESC" "auto" "standard" 2>/dev/null \
        | grep "model:" | head -1 | sed 's/.*model:[[:space:]]*//' || echo "gpt-5.4-codex")

    "${SCRIPT_DIR}/spawn-agent.sh" "worker" "$TASK_DESC" "$model"

    # ③ Review 단계 + 갭(Gap) 루프
    update_phase "REVIEWING"
    log_info "[3/3] Review 단계 시작..."
    "${SCRIPT_DIR}/spawn-agent.sh" "reviewer" "구현 결과 리뷰: ${TASK_DESC}"

    # TODO: review_verdict 판정에 따라 gap 루프 실행
    # verdict가 GAP_DETECTED인 경우:
    #   1. gap_report의 correction을 Worker에 피드백으로 제공
    #   2. Worker 재실행 (최대 1회 — bridge.sh gap-fix-start 사용)
    #   3. 재리뷰
    #   4. 여전히 갭이면 에스컬레이션 (사용자에게 질문)
    log_info "갭 루프: 최대 1회 수정 재실행 지원"

    update_phase "COMPLETE"
    log_info "Full Cycle 모드 완료"
}

# ──────────────────────────────────────────────
# 메인 실행
# ──────────────────────────────────────────────
main() {
    # 모드 자동 선택
    if [[ "$MODE" == "auto" ]]; then
        MODE=$(auto_detect_mode "$TASK_DESC")
        log_info "자동 감지 모드: ${MODE}"
    fi

    # 상태 초기화
    init_state

    log_info "사이클 시작: ${CYCLE_ID}"
    log_info "모드: ${MODE}"
    log_info "태스크: ${TASK_DESC}"
    echo ""

    # 모드별 실행
    case "$MODE" in
        solo)     run_solo ;;
        parallel) run_parallel ;;
        full)     run_full ;;
        *)
            log_error "알 수 없는 모드: ${MODE}"
            exit 1
            ;;
    esac

    echo ""
    log_info "상태 파일: ${STATE_FILE}"
    log_info "사이클 ${CYCLE_ID} 종료"
}

main
