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

## 설치

```bash
# ClawHub에서 설치 (로그인 필요)
clawhub install openclaw-harness

# 또는 수동으로 심볼릭 링크
ln -s /path/to/openclaw-harness ~/.openclaw/skills/harness
```

## 영감

- [정구봉 — AI가 밤새 코딩하는 시대 (우로보로스 하네스)](https://www.youtube.com/watch?v=tjEVBcPT-RA)
- [하네스 엔지니어링 완전정복 (PDF)](https://github.com/Amir-Arvan/Harness_Engineering_Complete_Guide)
- [허예찬 — OMX: 코덱스를 마개조 하다](https://www.youtube.com/watch?v=XwFoegzihyE)

## 라이선스

MIT
