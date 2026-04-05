#!/usr/bin/env bash
# OpenClaw 하네스 — 브릿지 스크립트
# 에이전트 상태 추적 + 채널 알림 디스패치
# 
# P1~P4 원칙 준수:
#   P1: 화면 없이 동작 (message 툴로 채널 푸시)
#   P2: 실패 즉시 알림, 성공 배치
#   P3: 브릿지 오류 → 파이프라인에 영향 없음
#   P4: 채널/모델 자동 감지 (설정 불필요)
#
# 사용법: ./bridge.sh <액션> [인자...]
#   액션: notify, phase, complete, fail, status, reset
set -euo pipefail

# ──────────────────────────────────────────────
# 설정
# ──────────────────────────────────────────────
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${HARNESS_DIR}/state"
BRIDGE_STATE="${BRIDGE_STATE:-${STATE_DIR}/bridge-state.json}"

mkdir -p "${STATE_DIR}"

# ──────────────────────────────────────────────
# P4: 자동 감지 — 설정 파일에서 읽지 않음
# ──────────────────────────────────────────────
# 채널 정보는 OpenClaw 런타임에서 자동 감지됨
# 이 스크립트는 상태 관리만 담당
# 실제 알림 전송은 OpenClaw message 툴이 담당

# ──────────────────────────────────────────────
# 유틸리티
# ──────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

# 상태 파일이 없으면 초기화
ensure_state() {
    if [[ ! -f "${BRIDGE_STATE}" ]]; then
        echo '{}' > "${BRIDGE_STATE}"
    fi
}

# JSON에서 값 읽기 (간단한 grep 기반, jq 없이도 동작)
json_get() {
    local key="$1"
    local file="$2"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
        | head -1 | sed 's/.*: * "//' | sed 's/"$//'
}

json_get_num() {
    local key="$1"
    local file="$2"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]*" "$file" 2>/dev/null \
        | head -1 | sed 's/.*: *//'
}

# ──────────────────────────────────────────────
# 상태 업데이트 헬퍼 (python3 사용)
# ──────────────────────────────────────────────
update_json() {
    local key="$1" value="$2" file="$3"
    local ts
    ts=$(now_iso)
    python3 <<PYEOF
import json
with open('${file}', 'r') as f:
    data = json.load(f)
data['${key}'] = ${value}
data['last_updated'] = '${ts}'
with open('${file}', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ──────────────────────────────────────────────
# 액션: reset — 새 사이클 시작
# ──────────────────────────────────────────────
action_reset() {
    local cycle_id="${1:-cycle-$(date +%Y%m%d-%H%M%S)}"
    local mode="${2:-full}"
    
    cat > "${BRIDGE_STATE}" <<EOF
{
  "cycle_id": "${cycle_id}",
  "mode": "${mode}",
  "phase": "IDLE",
  "agents": {},
  "progress": { "completed": 0, "total": 0, "failed": 0 },
  "notifications": { "sent": 0, "failed": 0, "batched": 0 },
  "bridge_errors": [],
  "phase_history": [],
  "last_updated": "$(now_iso)"
}
EOF
    
    echo "RESET: cycle=${cycle_id} mode=${mode}"
}

# ──────────────────────────────────────────────
# 액션: phase — 파이프라인 단계 전환
# ──────────────────────────────────────────────
action_phase() {
    local phase="$1"
    local prev_phase=""
    
    ensure_state
    prev_phase=$(json_get phase "${BRIDGE_STATE}")
    
    update_json phase "\"${phase}\"" "${BRIDGE_STATE}"
    
    # 단계 히스토리 기록
    local elapsed=""
    if [[ -n "$prev_phase" ]]; then
        elapsed=" (from ${prev_phase})"
    fi
    
    echo "PHASE: ${prev_phase} → ${phase}${elapsed}"
    
    # D3: 단계 전환 알림 출력
    # 실제 OpenClaw 환경에서는 이 출력이 message 툴 호출로 변환됨
    echo "NOTIFY:phase:🔄 [harness] → ${phase} 단계 시작${elapsed}"
}

# ──────────────────────────────────────────────
# 액션: agent-start — 에이전트 시작 등록
# ──────────────────────────────────────────────
action_agent_start() {
    local agent_id="$1"
    local model="${2:-unknown}"
    
    ensure_state
    
    # agents 객체에 에이전트 추가
    local timestamp=$(now_iso)
    local epoch=$(now_epoch)
    
    # 간단 JSON 조작 (jq 없이)
    local tmp_file=$(mktemp)
    # 기존 상태의 agents 섹션에 새 에이전트 추가
    python3 -c "
import json, sys
with open('${BRIDGE_STATE}', 'r') as f:
    state = json.load(f)
state['agents']['${agent_id}'] = {
    'status': 'running',
    'model': '${model}',
    'started_at': '${timestamp}',
    'started_epoch': ${epoch},
    'completed_at': None,
    'summary': None,
    'error': None
}
state['progress']['total'] = len(state['agents'])
state['last_updated'] = '${timestamp}'
with open('${tmp_file}', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || {
        # Python3 없으면 간단 조작
        echo "WARN: python3 없음 — 상태 업데이트 생략" >&2
        return 0
    }
    
    mv "$tmp_file" "${BRIDGE_STATE}"
    
    local total=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['progress']['total'])" 2>/dev/null || echo "?")
    echo "AGENT_START: ${agent_id} (model=${model}, total=${total})"
}

# ──────────────────────────────────────────────
# 액션: complete — 에이전트 완료 (성공)
# ──────────────────────────────────────────────
action_complete() {
    local agent_id="$1"
    local summary="${2:-완료}"
    
    ensure_state
    
    local timestamp=$(now_iso)
    local epoch=$(now_epoch)
    local tmp_file=$(mktemp)
    
    python3 -c "
import json, sys
with open('${BRIDGE_STATE}', 'r') as f:
    state = json.load(f)
agent = state['agents'].setdefault('${agent_id}', {
    'status': 'running',
    'model': 'unknown',
    'started_at': '${timestamp}',
    'started_epoch': ${epoch},
    'completed_at': None,
    'summary': None,
    'error': None,
})
elapsed = ${epoch} - agent.get('started_epoch', ${epoch})
agent['status'] = 'completed'
agent['completed_at'] = '${timestamp}'
agent['elapsed_sec'] = elapsed
agent['summary'] = '''${summary}'''
state['progress']['total'] = len(state['agents'])
state['progress']['completed'] = sum(1 for a in state['agents'].values() if a['status'] == 'completed')
state['notifications']['sent'] += 1
state['last_updated'] = '${timestamp}'
with open('${tmp_file}', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || {
        echo "WARN: python3 없음" >&2
        return 0
    }
    
    mv "$tmp_file" "${BRIDGE_STATE}"
    
    # 진행률 계산
    local completed failed total elapsed model pct remaining
    completed=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['progress']['completed'])" 2>/dev/null || echo "1")
    failed=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['progress']['failed'])" 2>/dev/null || echo "0")
    total=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['progress']['total'])" 2>/dev/null || echo "1")
    elapsed=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); a=d['agents'].get('${agent_id}',{}); print(a.get('elapsed_sec','?'))" 2>/dev/null || echo "?")
    model=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); a=d['agents'].get('${agent_id}',{}); print(a.get('model','?'))" 2>/dev/null || echo "?")
    if [[ "$total" -gt 0 ]]; then
        pct=$(( completed * 100 / total ))
    else
        pct=0
    fi
    
    if [[ "$completed" -gt 0 ]] && [[ $completed -lt $total ]]; then
        remaining=$(( (total - completed) * elapsed / completed ))
        remaining="${remaining}초"
    else
        remaining="완료"
    fi
    
    # X3: 성공 배치 (호출자가 배치 타이밍 제어)
    # X4: 진행률 포함
    echo "NOTIFY:success:✅ [harness] ${completed}/${total} 완료 (${pct}%)
├── ${agent_id}: ${summary} (${model}, ${elapsed}s)
└── 예상 잔여: ~${remaining}"
}

# ──────────────────────────────────────────────
# 액션: fail — 에이전트 실패 (D2: 즉시 알림)
# ──────────────────────────────────────────────
action_fail() {
    local agent_id="$1"
    local error="${2:-알 수 없는 오류}"
    local error_log="${3:-}"
    
    ensure_state
    
    local timestamp=$(now_iso)
    local epoch=$(now_epoch)
    local tmp_file=$(mktemp)
    
    python3 -c "
import json, sys
with open('${BRIDGE_STATE}', 'r') as f:
    state = json.load(f)
agent = state['agents'].setdefault('${agent_id}', {
    'status': 'running',
    'model': 'unknown',
    'started_at': '${timestamp}',
    'started_epoch': ${epoch},
    'completed_at': None,
    'summary': None,
    'error': None,
})
elapsed = ${epoch} - agent.get('started_epoch', ${epoch})
agent['status'] = 'failed'
agent['completed_at'] = '${timestamp}'
agent['elapsed_sec'] = elapsed
agent['error'] = '''${error}'''
state['progress']['total'] = len(state['agents'])
state['progress']['failed'] = sum(1 for a in state['agents'].values() if a['status'] == 'failed')
state['progress']['completed'] = sum(1 for a in state['agents'].values() if a['status'] in ('completed', 'failed'))
state['notifications']['sent'] += 1
state['last_updated'] = '${timestamp}'
with open('${tmp_file}', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || {
        echo "WARN: python3 없음" >&2
        return 0
    }
    
    mv "$tmp_file" "${BRIDGE_STATE}"
    
    local completed failed total
    completed=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(sum(1 for a in d['agents'].values() if a['status'] in ('completed','failed')))" 2>/dev/null || echo "1")
    failed=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['progress']['failed'])" 2>/dev/null || echo "1")
    total=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['progress']['total'])" 2>/dev/null || echo "1")
    
    # D2: 실패 즉시 개별 알림 (배치 없음)
    echo "NOTIFY:fail:❌ [harness] ${agent_id} 실패
├── 태스크: $(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['agents']['${agent_id}'].get('summary','?'))" 2>/dev/null || echo "?")
├── 에러: ${error}
└── 상태: ${completed}/${total} 완료 (${failed} 실패) — 나머지 진행 중"
}

# ──────────────────────────────────────────────
# 액션: gap-detected — 갭 감지 알림 (우로보로스 루프 트리거)
# ──────────────────────────────────────────────
action_gap_detected() {
    local agent_id="$1"
    local gap_type="${2:-unknown}"
    local description="${3:-갭 감지됨}"
    local correction="${4:-수정 필요}"
    
    ensure_state
    
    local timestamp=$(now_iso)
    local tmp_file=$(mktemp)
    
    python3 -c "
import json
with open('${BRIDGE_STATE}', 'r') as f:
    state = json.load(f)
if '${agent_id}' in state['agents']:
    agent = state['agents']['${agent_id}']
    agent['status'] = 'gap_detected'
    agent['gap_type'] = '${gap_type}'
    agent['gap_description'] = '''${description}'''
    agent['correction'] = '''${correction}'''
    agent['completed_at'] = '${timestamp}'
    state['progress']['completed'] = sum(1 for a in state['agents'].values() if a['status'] in ('completed', 'failed', 'gap_detected'))
    state['last_updated'] = '${timestamp}'
# 갭 루프 카운터
if 'gap_loop' not in state:
    state['gap_loop'] = {'count': 0, 'max': 1, 'agents': []}
state['last_updated'] = '${timestamp}'
with open('${tmp_file}', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
    
    if [[ -f "$tmp_file" ]]; then
        mv "$tmp_file" "${BRIDGE_STATE}"
    fi
    
    local completed total loop_count
    completed=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['progress']['completed'])" 2>/dev/null || echo "1")
    total=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d['progress']['total'])" 2>/dev/null || echo "1")
    loop_count=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d.get('gap_loop',{}).get('count',0))" 2>/dev/null || echo "0")
    
    echo "NOTIFY:gap:⚡ [harness] ${agent_id} 갭 감지 (${gap_type})
├── 원인: ${description}
├── 수정 방향: ${correction}
├── 루프: ${loop_count}/1
└── 상태: ${completed}/${total}"
}

# ──────────────────────────────────────────────
# 액션: gap-fix-start — 갭 수정 재실행 등록
# ──────────────────────────────────────────────
action_gap_fix_start() {
    local agent_id="$1"
    local model="${2:-unknown}"
    
    ensure_state
    
    local timestamp=$(now_iso)
    local epoch=$(now_epoch)
    local tmp_file=$(mktemp)
    
    python3 -c "
import json
with open('${BRIDGE_STATE}', 'r') as f:
    state = json.load(f)
if 'gap_loop' not in state:
    state['gap_loop'] = {'count': 0, 'max': 1, 'agents': []}
state['gap_loop']['count'] += 1
state['gap_loop']['agents'].append('${agent_id}')

fix_id = '${agent_id}-fix-' + str(state['gap_loop']['count'])
state['agents'][fix_id] = {
    'status': 'running',
    'model': '${model}',
    'started_at': '${timestamp}',
    'started_epoch': ${epoch},
    'parent': '${agent_id}',
    'type': 'gap_fix',
    'completed_at': None,
    'summary': None,
    'error': None
}
state['progress']['total'] = len(state['agents'])
state['last_updated'] = '${timestamp}'
with open('${tmp_file}', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
    
    if [[ -f "$tmp_file" ]]; then
        mv "$tmp_file" "${BRIDGE_STATE}"
    fi
    
    local loop_count
    loop_count=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(d.get('gap_loop',{}).get('count',0))" 2>/dev/null || echo "1")
    
    echo "GAP_FIX_START: ${agent_id} 수정 재실행 (${loop_count}/1)"
    echo "NOTIFY:gap-fix:🔄 [harness] ${agent_id} 갭 수정 시작 (루프 ${loop_count}/1)"
}

# ──────────────────────────────────────────────
# 액션: batch-complete — 성공 배치 알림 (X3)
# ──────────────────────────────────────────────
action_batch() {
    ensure_state
    
    local tmp_file=$(mktemp)
    python3 -c "
import json
with open('${BRIDGE_STATE}', 'r') as f:
    state = json.load(f)

completed_agents = []
for aid, agent in state['agents'].items():
    if agent['status'] == 'completed':
        elapsed = agent.get('elapsed_sec', '?')
        completed_agents.append(f\"├── {aid}: {agent.get('summary','?')} ({agent.get('model','?')}, {elapsed}s)\")

completed = state['progress']['completed']
total = state['progress']['total']
failed = state['progress']['failed']
pct = (completed * 100 // total) if total > 0 else 0

lines = [f\"✅ [harness] {completed}/{total} 완료 ({pct}%)\"]
for line in completed_agents:
    lines.append(line)
if failed > 0:
    lines.append(f\"├── ⚠ {failed}개 실패\")
lines.append(f\"└── 예상 잔여: ~계산 중\")

print('\\n'.join(lines))

# 배치 카운트 증가
state['notifications']['batched'] += 1
with open('${tmp_file}', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
    
    if [[ -f "$tmp_file" ]]; then
        mv "$tmp_file" "${BRIDGE_STATE}"
    fi
}

# ──────────────────────────────────────────────
# 액션: status — 현재 상태 출력
# ──────────────────────────────────────────────
action_status() {
    ensure_state
    
    if [[ ! -s "${BRIDGE_STATE}" ]] || [[ "$(cat "${BRIDGE_STATE}")" == "{}" ]]; then
        echo "상태 없음 — bridge reset <cycle_id>로 초기화하세요"
        return 0
    fi
    
    python3 -c "
import json
with open('${BRIDGE_STATE}', 'r') as f:
    state = json.load(f)

print(f\"사이클: {state.get('cycle_id', '?')}\")
print(f\"모드: {state.get('mode', '?')}\")
print(f\"단계: {state.get('phase', '?')}\")
print(f\"진행: {state['progress']['completed']}/{state['progress']['total']} 완료 ({state['progress']['failed']} 실패)\")
print(f\"알림: {state['notifications']['sent']} 전송, {state['notifications']['batched']} 배치, {state['notifications']['failed']} 실패\")
print()
print('에이전트:')
for aid, agent in state.get('agents', {}).items():
    status_icon = '✅' if agent['status'] == 'completed' else '❌' if agent['status'] == 'failed' else '🔄'
    elapsed = agent.get('elapsed_sec', '?')
    print(f\"  {status_icon} {aid}: {agent['status']} ({agent.get('model','?')}, {elapsed}s) {agent.get('summary','')}\")
if state.get('bridge_errors'):
    print(f\"\\n브릿지 에러: {len(state['bridge_errors'])}개\")
    for err in state['bridge_errors'][-3:]:
        print(f\"  - {err}\")
" 2>/dev/null || {
        cat "${BRIDGE_STATE}"
    }
}

# ──────────────────────────────────────────────
# 액션: bridge-error — 브릿지 자체 장애 기록 (D5)
# ──────────────────────────────────────────────
action_bridge_error() {
    local error="$1"
    
    ensure_state
    
    local tmp_file=$(mktemp)
    python3 -c "
import json
with open('${BRIDGE_STATE}', 'r') as f:
    state = json.load(f)
state['bridge_errors'].append({'error': '''${error}''', 'timestamp': '$(now_iso)'})
state['notifications']['failed'] += 1
state['last_updated'] = '$(now_iso)'
with open('${tmp_file}', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null
    
    if [[ -f "$tmp_file" ]]; then
        mv "$tmp_file" "${BRIDGE_STATE}"
    fi
    
    local error_count
    error_count=$(python3 -c "import json; d=json.load(open('${BRIDGE_STATE}')); print(len(d.get('bridge_errors',[])))" 2>/dev/null || echo "1")
    
    # D5: 3회 연속 실패 시 장애 알림
    if [[ "$error_count" -ge 3 ]]; then
        echo "NOTIFY:bridge-error:⚠️ [harness] 브릿지 알림 전송 실패 (${error_count}회)
├── 원인: ${error}
└── 파이프라인은 정상 동작 중"
    else
        echo "BRIDGE_ERROR: ${error} (재시도 ${error_count}/3)"
    fi
}

# ──────────────────────────────────────────────
# 메인
# ──────────────────────────────────────────────
ACTION="${1:-}"
shift || true

case "$ACTION" in
    reset)          action_reset "$@" ;;
    phase)          action_phase "$@" ;;
    agent-start)    action_agent_start "$@" ;;
    complete)       action_complete "$@" ;;
    fail)           action_fail "$@" ;;
    batch)          action_batch "$@" ;;
    gap-detected)   action_gap_detected "$@" ;;
    gap-fix-start)  action_gap_fix_start "$@" ;;
    status)         action_status "$@" ;;
    bridge-error)   action_bridge_error "$@" ;;
    *)
        echo "사용법: $0 <액션> [인자...]" >&2
        echo "액션:" >&2
        echo "  reset <cycle_id> [mode]  새 사이클 시작" >&2
        echo "  phase <단계명>            단계 전환 (IDLE/PLANNING/WORKING/REVIEWING/COMPLETE)" >&2
        echo "  agent-start <id> [model] 에이전트 시작 등록" >&2
        echo "  complete <id> [요약]     에이전트 완료 (성공)" >&2
        echo "  fail <id> <에러> [로그]  에이전트 실패 (즉시 알림)" >&2
        echo "  batch                    성공 배치 알림" >&2
        echo "  gap-detected <id> <type> <desc> <correction>  갭 감지 (우로보로스 루프 트리거)" >&2
        echo "  gap-fix-start <id> [model]  갭 수정 재실행 등록" >&2
        echo "  status                   현재 상태 출력" >&2
        echo "  bridge-error <에러>      브릿지 자체 장애 기록" >&2
        exit 1
        ;;
esac
