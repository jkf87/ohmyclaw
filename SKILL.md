---
name: harness
description: "OpenClaw 하네스 — Plan→Work→Review 에이전트 오케스트레이션 + 모델 라우팅 + 채널 브릿지. Claude Code 하네스 생태계 분석 기반. GLM/GPT/Claude 모델 지원. 한국어 감지→GLM 자동 라우팅. sessions_spawn으로 에이전트별 모델 별도 지정. 브릿지로 실시간 채널 알림."
---

# OpenClaw Harness

에이전트 기반 작업 오케스트레이션 스킬. Plan→Work→Review 사이클로 구조화된 작업 수행.
브릿지가 에이전트 상태를 실시간으로 추적하고 채널에 알림을 전송합니다.

## 빠른 시작

### 1. 라우팅 테스트
```bash
bash ~/.openclaw/skills/harness/scripts/route-task.sh "태스크 설명"
```

### 2. 단일 에이전트 스폰
에이전트 프롬프트를 읽어서 `sessions_spawn`에 전달:

| 에이전트 | 역할 | 권한 | 추천 모델 |
|---------|------|------|----------|
| planner | 계획 수립 (읽기 전용) | read-only | glm-5-turbo |
| worker | 코드 구현 | read+write+exec | gpt-5.4-codex |
| reviewer | 4관점 리뷰 (읽기 전용) | read-only | glm-5-turbo |
| debugger | 체계적 디버깅 | read+exec | glm-5-turbo |
| **bridge** | **상태 추적 + 채널 알림** | read+write | glm-5-turbo |

### 3. Full 사이클 (브릿지 자동 활성화)
Plan→Work→Review 전체 실행 (v2: 갭 루프 포함):

1. **Bridge** 자동 활성화 → 상태 추적 시작 (P1: 화면 없이 동작)
2. **Planner** 스폰 → 태스크 분해 → 단계 전환 알림
3. **Worker** 스폰 → 구현 → 완료/실패 알림
4. **Reviewer** 스폰 → 리뷰 + 갭 감지
   - APPROVE → COMPLETE
   - GAP_DETECTED → 갭 수정 피드백 → Worker 재실행 (최대 1회) → 재리뷰
   - 2차에서도 갭 → 에스컬레이션 (사용자 질문)

### 4. 브릿지 제어
```bash
# 상태 확인
bash ~/.openclaw/skills/harness/scripts/bridge.sh status

# 새 사이클 초기화
bash ~/.openclaw/skills/harness/scripts/bridge.sh reset "my-cycle" full

# 단계 전환 (자동 호출됨)
bash ~/.openclaw/skills/harness/scripts/bridge.sh phase WORKING
```

## 브릿지 (Bridge)

### 핵심 원칙

| 원칙 | 설명 |
|------|------|
| **P1: 화면 없이 동작** | 터미널을 보지 않아도 채널 알림으로 전체 상태 파악 |
| **P2: 실패는 즉시 알림** | 성공은 배치, 실패는 20초 내 개별 알림 |
| **P3: 브릿지 장애 격리** | 브릿지 죽어도 파이프라인 정상 동작, 지연 ≤5s |
| **P4: 자동 감지** | 채널/모델/세션 자동 감지, 설정 0개 추가 |

### 자동 감지 항목 (설정 불필요)

브릿지는 OpenClaw 런타임 컨텍스트에서 다음을 자동 감지합니다:

| 정보 | 감지 방법 | 수동 설정 |
|------|-----------|-----------|
| 채널 | 현재 메시지 컨텍스트 | ❌ 불필요 |
| 채널 ID | inbound_meta.chat_id | ❌ 불필요 |
| 모델 | session_status | ❌ 불필요 |
| Gateway URL | 내부 통신 (message 툴) | ❌ 불필요 |
| 세션 키 | 현재 세션 컨텍스트 | ❌ 불필요 |

### 알림 종류

```
# 단계 전환 (D3)
🔄 [harness] → Work 단계 시작 (Plan 완료, 45초)

# 성공 배치 (X3, X4)
✅ [harness] 2/3 완료 (67%)
├── worker-1: API 구현 (gpt-5.4-codex, 120s)
├── worker-2: 테스트 작성 (glm-5-turbo, 45s)
└── 예상 잔여: ~60초

# 실패 즉시 (D2)
❌ [harness] worker-3 실패
├── 태스크: DB 마이그레이션
├── 에러: connection refused (마지막 5줄)
└── 상태: 2/3 완료 — 나머지 진행 중

# 브릿지 장애 (D5)
⚠️ [harness] 브릿지 알림 전송 실패 (3회 재시도 후)
├── 원인: 채널 연결 불가
└── 파이프라인은 정상 동작 중

# 갭 감지 (우로보로스 루프)
⚡ [harness] worker-2 갭 감지 (scope_creep)
├── 원인: TODO 앱에 알림 시스템 자의 추가
├── 수정 방향: 알림 기능 제거, 단순 CRUD로 축소
├── 루프: 0/1
└── 상태: 1/3

# 갭 수정 시작
🔄 [harness] worker-2 갭 수정 시작 (루프 1/1)
```

### 브릿지 스크립트 API

```bash
BRIDGE=~/.openclaw/skills/harness/scripts/bridge.sh

# 사이클 관리
$BRIDGE reset <cycle_id> [mode]     # 새 사이클 시작
$BRIDGE status                       # 현재 상태 출력

# 단계 전환
$BRIDGE phase <phase>                # IDLE/PLANNING/WORKING/REVIEWING/COMPLETE

# 에이전트 추적
$BRIDGE agent-start <id> [model]     # 에이전트 시작 등록
$BRIDGE complete <id> [요약]         # 성공 완료 (배치 대상)
$BRIDGE fail <id> <에러> [로그]      # 실패 (즉시 알림)
$BRIDGE batch                        # 성공 배치 알림 전송

# 장애 관리
$BRIDGE bridge-error <에러>          # 브릿지 장애 기록 (3회→에스컬레이션)
```

## 모델 라우팅

복잡도 × 카테고리 2D 매트릭스:

| 카테고리 | LOW (0-4) | MEDIUM (5-9) | HIGH (10+) |
|---------|-----------|-------------|------------|
| 코딩 일반 | glm-5-turbo | gpt-5.4-codex | gpt-5.4-codex |
| 아키텍처 | gpt-5.4-codex | gpt-5.4-codex | gpt-5.4-codex |
| 한국어 NLP | glm-5-turbo | glm-5 | glm-5 |
| 디버깅 | glm-5-turbo | gpt-5.4-codex | gpt-5.4-codex |
| 보안 | gpt-5.4-codex | gpt-5.4-codex | gpt-5.4-codex |
| 콘텐츠 | glm-5-turbo | glm-5 | glm-5 |

한국어 비율 > 70% → GLM 계열 자동 우선

**B1/B2: 모델 제약 없음** — GLM, GPT, Claude 모두 동일한 브릿지 기능 사용.

## 에이전트 스폰 방법

에이전트 정의 파일을 읽어서 `sessions_spawn` 호출:

```
sessions_spawn(
  label: "harness-planner",
  model: "zai/glm-5-turbo",
  mode: "run",
  task: "태스크 설명 + 에이전트 지침 포함"
)
```

에이전트별 다른 모델 지정 가능 (이게 핵심).

## 파일 구조

```
~/.openclaw/skills/harness/
├── SKILL.md                    # 이 파일
├── agents/                     # 에이전트 정의
│   ├── planner.md
│   ├── worker.md
│   ├── reviewer.md
│   ├── debugger.md
│   └── bridge.md               # 브릿지 에이전트 (v2.0)
├── scripts/                    # 실행 스크립트
│   ├── route-task.sh           # 모델 라우팅
│   ├── orchestrate.sh          # 오케스트레이터
│   ├── spawn-agent.sh          # 에이전트 생성 헬퍼
│   ├── bridge.sh               # 브릿지 상태 추적 + 알림 (v2.0)
│   ├── install.sh
│   ├── catalog-gen.sh
│   └── doctor.sh               # 진단 (브릿지 검증 포함)
├── state/                      # 런타임 상태 (gitignore)
│   └── bridge-state.json       # 브릿지 상태
├── routing/                    # 라우팅 설정
│   ├── models.yaml
│   ├── routing-rules.yaml
│   └── budget-profiles.yaml
├── orchestration/              # 오케스트레이션 설정
│   ├── pipelines.yaml
│   └── message-protocol.md
└── examples/
```

## 평가 루브릭

브릿지 기능은 95% 합격선 루브릭으로 평가됩니다:
- 평가 철학: `harness-bridge-eval/EVALUATION_PHILOSOPHY.md`
- 실행 루브릭: `harness-bridge-eval/EVALUATION_RUBRIC.md`
- 20개 평가 항목 (D1-D5, S1-S5+S2b+S4b, X1-X4, B1-B4)
