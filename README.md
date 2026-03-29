# OpenClaw Harness

> Plan→Work→Review 에이전트 오케스트레이션 + 갭(Gap) 감지 루프

에이전트 기반 작업을 구조화된 사이클로 실행합니다. Claude Code 하네스 생태계 분석을 기반으로 설계되었고, 정구봉의 "우로보로스 하네스" 핵심 아이디어(드리프트 방지, 갭 감지, 스펙 진화)를 채택했습니다.

## 특징

- **🔄 Plan→Work→Review 사이클** — Planner가 태스크를 분해하고 Worker가 병렬 구현, Reviewer가 검증
- **⚡ 갭(Gap) 감지 루프** — AI가 원래 의도에서 벗어난 것을 자동 감지하고 1회 수정 재실행
- **📡 브릿지 알림** — 에이전트 상태를 실시간으로 텔레그램/디스코드 등 채널에 푸시
- **🧭 모델 라우팅** — 태스크 복잡도에 따라 적절한 모델 자동 선택 (GLM/GPT/Claude)
- **🇰🇷 한국어 최적화** — 한국어 감지 시 GLM 자동 라우팅

## 아키텍처

```
사용자 요청
    │
    ▼
┌─────────┐
│ Planner │ ── 태스크 분해 + Ambiguity Score
└────┬────┘
     │
     ▼
┌─────────┐     ┌─────────┐
│ Worker-1│ ... │ Worker-N│ ── 병렬 구현 (sessions_spawn)
└────┬────┘     └────┬────┘
     │               │
     ▼               ▼
┌─────────────────────┐
│     Reviewer        │ ── 5관점 리뷰 + 갭 감지
│  (read-only)        │
└──────────┬──────────┘
           │
     ┌─────┴─────┐
     │ APPROVE?  │
     └─────┬─────┘
      예 │     │ 아니오 (GAP_DETECTED)
         │     │
    COMPLETE  갭 피드백 → Worker 재실행 (최대 1회)
                   │
              ┌────┴────┐
              │ 여전히 갭? │
              └────┬────┘
             예 │     │ 아니오
                │     │
           에스컬레이션  COMPLETE
          (사용자 질문)
```

## 에이전트

| 에이전트 | 역할 | 권한 | 추천 모델 |
|---------|------|------|----------|
| **planner** | 계획 수립 | read-only | glm-5-turbo |
| **worker** | 코드 구현 | read+write+exec | gpt-5.4-codex |
| **reviewer** | 5관점 리뷰 + 갭 감지 | read-only | glm-5-turbo |
| **debugger** | 체계적 디버깅 | read+exec | glm-5-turbo |

## Reviewer 5관점

1. **완료 기준 검증** — DoD 항목별 체크, 테스트/빌드 통과 여부
2. **보안 검토** — OWASP Top 10, 하드코딩 시크릿, 인젝션 패턴
3. **성능/품질** — N+1 쿼리, 불필요 API 호출, 에러 핸들링
4. **유지보수성** — 명명 규칙, 추상화 수준, 순환 복잡도
5. **🆕 갭(Gap) 감지** — 의도 보존, 가정 주입, 스코프 이탈, 방향성

## 갭(Gap) 유형

| 유형 | 설명 | 예시 |
|------|------|------|
| `assumption_injection` | 사용자가 말하지 않은 가정 추가 | "JWT 인증 자의 추가" |
| `scope_creep` | 요청하지 않은 기능/복잡도 | "TODO 앱에 알림 시스템 추가" |
| `direction_drift` | 전체 방향이 의도와 다름 | "단순 API → 풀스택 프레임워크" |
| `missing_core` | 핵심 기능 누락 | "검색 기능 구현 누락" |
| `over_engineering` | 과도한 추상화/일반화 | "단순 CRUD에 DI 컨테이너" |

## 브릿지(Bridge) 알림

에이전트 상태를 채널(텔레그램 등)에 실시간 푸시합니다.

```bash
# 상태 확인
bash scripts/bridge.sh status

# 새 사이클
bash scripts/bridge.sh reset "my-cycle" full

# 단계 전환
bash scripts/bridge.sh phase WORKING

# 갭 감지
bash scripts/bridge.sh gap-detected worker-1 scope_creep "알림 자의 추가" "알림 제거"

# 갭 수정 시작
bash scripts/bridge.sh gap-fix-start worker-1 gpt-5.4-codex
```

### 알림 예시

```
🔄 [harness] → WORKING 단계 시작
✅ [harness] 3/5 완료 (60%)
├── worker-1: API 구현 (glm-5-turbo, 120s)
├── worker-2: 테스트 작성 (glm-5-turbo, 45s)
└── 예상 잔여: ~60s

⚡ [harness] worker-2 갭 감지 (scope_creep)
├── 원인: TODO 앱에 알림 시스템 자의 추가
├── 수정 방향: 알림 기능 제거, 단순 CRUD로 축소
├── 루프: 0/1
└── 상태: 3/5
```

## 모델 라우팅

태스크의 **복잡도 × 카테고리** 2D 매트릭스로 자동 모델 선택. Claude/Gemini 제외, GLM/GPT만 사용.

### 지원 모델

| 모델 | 티어 | 비용 (in/out per 1k) | 컨텍스트 | 강점 |
|------|------|---------------------|----------|------|
| **GLM-5 Turbo** | LOW | $0.0003 / $0.0006 | 128K | 한국어 네이티브, 저비용, 빠른 응답 |
| **GPT-5.4 Codex** | MEDIUM | $0.003 / $0.015 | 200K | 코드 생성, 디버깅, 아키텍처 |
| **GLM-5** | MEDIUM | $0.002 / $0.008 | 128K | 한국어 NLP, 콘텐츠, 균형잡힌 추론 |

### 라우팅 매트릭스

| 카테고리 | LOW | MEDIUM | HIGH |
|---------|-----|--------|------|
| 코딩 (일반) | GLM-5-Turbo | GPT-5.4-Codex | GPT-5.4-Codex |
| 코딩 (아키텍처) | GPT-5.4-Codex | GPT-5.4-Codex | GPT-5.4-Codex |
| 한국어 NLP | GLM-5-Turbo | GLM-5 | GLM-5 |
| 추론 | GLM-5-Turbo | GPT-5.4-Codex | GPT-5.4-Codex |
| 보안 | GPT-5.4-Codex | GPT-5.4-Codex | GPT-5.4-Codex |
| 콘텐츠 생성 | GLM-5-Turbo | GLM-5 | GLM-5 |

### 우선순위 규칙 (first-match)

1. **P100** — 사용자 명시 오버라이드
2. **P90** — 한국어 비율 >70% + NLP/콘텐츠 → GLM-5
3. **P85** — 한국어 비율 >50% + NLP/콘텐츠 → GLM-5-Turbo
4. **P80** — 고복잡도 아키텍처 → GPT-5.4-Codex
5. **P70** — 보안 태스크 → GPT-5.4-Codex
6. **P60** — 중간 이상 코딩/디버깅 → GPT-5.4-Codex
7. **P50** — 저복잡도 → GLM-5-Turbo (비용 효율)
8. **P0** — 기본 → GPT-5.4-Codex

### 복잡도 측정 신호

**어휘 신호:** 단어 수, 코드 블록 수, 파일 경로 수, 아키텍처 키워드("설계", "마이그레이션", "리팩토링")

**구조 신호:** 서브태스크 수, 크로스 파일 참조, 테스트 필요 여부, 시스템 전체 영향

**컨텍스트 신호:** 이전 실패 횟수, 대화 턴 수, 계획 단계 수

### 폴백 체인

| 용도 | 1순위 | 2순위 | 3순위 |
|------|-------|-------|-------|
| 코딩 | GPT-5.4-Codex | GLM-5 | GLM-5-Turbo |
| 한국어 | GLM-5 | GLM-5-Turbo | GPT-5.4-Codex |
| 추론 | GPT-5.4-Codex | GLM-5 | GLM-5-Turbo |

## 예산 프로파일

| 프로파일 | 일일 토큰 | 태스크당 | 비용 한도 | 용도 |
|---------|----------|---------|----------|------|
| `minimal` | 500K | 30K | $1/일 | 개인/학습 |
| `standard` | 2M | 100K | $10/일 | 팀/프로덕션 |
| `full` | 무제한 | 500K | 무제한 | 엔터프라이즈 |

**예산 초과 정책:** 80% 경고 → 95% GLM-5-Turbo 강제 다운그레이드 → 100% 신규 태스크 차단

## 파이프라인 모드

| 모드 | 조건 | 파이프라인 | 최대 Worker |
|------|------|-----------|-------------|
| `solo` | 태스크 1개 + 중간 이하 복잡도 | Work | 0 |
| `parallel` | 독립 태스크 2~3개 | Work(병렬) → Review | 3 |
| `full` | 태스크 4개+ or 의존성 있음 or 고복잡도 | Plan → Work(병렬) → Review | 5 |

**동시 실행:** GPT-5.4-Codex 최대 3개, GLM-5-Turbo 최대 7개 (비용/부하 분산)

### 상태 머신

```
IDLE → PLANNING → WORKING → REVIEWING → COMPLETE
                        ↓           ↓
                    ESCALATED    FIXING → REVIEWING (최대 3회)
```

## 메시지 프로토콜

에이전트 간 통신은 `sessions_send` + YAML 봉투 포맷:

```yaml
message:
  type: task_assign
  from: orchestrator
  to: worker-1
  timestamp: "2026-03-26T14:30:00Z"
  correlation_id: "cycle-001"
  payload:
    task:
      id: T1
      content: "태스크 설명"
      dod: "검증 가능한 완료 기준"
    related_files:
      - path: src/auth/middleware.ts
        reason: "수정 대상"
```

**메시지 유형:** `plan_request`, `plan`, `task_assign`, `work_result`, `review_request`, `review_verdict`, `fix_request`, `escalation`, `status_update`

## 파일 구조

```
harness/
├── agents/                    # 에이전트 정의
│   ├── planner.md             #   계획 수립 (read-only)
│   ├── worker.md              #   코드 구현 (read+write+exec)
│   ├── reviewer.md            #   5관점 리뷰 + 갭 감지 (read-only)
│   ├── debugger.md            #   체계적 디버깅 (read+exec)
│   └── bridge.md              #   브릿지 참조
├── scripts/
│   ├── bridge.sh              #   브릿지 상태 추적 + 알림
│   ├── orchestrate.sh         #   오케스트레이터 진입
│   ├── route-task.sh          #   라우팅 엔진
│   ├── spawn-agent.sh         #   에이전트 스폰 래퍼
│   └── doctor.sh              #   진단 스크립트
├── routing/
│   ├── models.yaml            #   모델 카탈로그 + 비용
│   ├── routing-rules.yaml     #   라우팅 규칙 엔진
│   └── budget-profiles.yaml   #   예산 프로파일
├── orchestration/
│   ├── pipelines.yaml         #   파이프라인 정의
│   └── message-protocol.md    #   메시지 프로토콜
├── examples/                  #   예시 산출물
└── state/                     #   런타임 상태 (git-ignored)
```

## 설치

```bash
# ClawHub에서 설치 (로그인 필요)
clawhub install openclaw-harness

# 또는 수동으로 심볼릭 링크
ln -s /path/to/openclaw-harness ~/.openclaw/skills/harness
```

## 영감

- OpenAI Codex Community Meetup 발표 시리즈 (우로보로스 하네스, OMX)
- Claude Code 하네스 생태계 분석

## 라이선스

MIT
