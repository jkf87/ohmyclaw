---
name: zai-coding-plan
description: 'Z.ai Coding Plan (Lite/Pro/Max) 멀티티어 라우팅 + Plan→Work→Review 오케스트레이션 + 갭 감지 + 추론 인식 모델 선택. Use when: (1) Z.ai GLM 모델로 코딩 작업, (2) 한국어 코딩/리뷰/리팩토링, (3) 복잡 태스크를 Plan→Work→Review 사이클로 분해, (4) 사용자가 lite/pro/max 플랜 보유 시 또는 ChatGPT 구독 OAuth 병행 시. NOT for: (a) 단순 1-line 수정, (b) Z.ai/Codex 가 아닌 다른 프로바이더 단독 작업, (c) read-only 코드 탐색.'
metadata:
  openclaw:
    emoji: 🦞
    requires:
      anyBins: ["jq"]
    install:
      - id: brew-jq
        kind: brew
        package: jq
        bins: ["jq"]
        label: "Install jq (routing engine prerequisite)"
---

# Z.ai Coding Plan Skill

OpenClaw 의 `@openclaw/zai-provider` 위에 올라가는 **에이전트 하네스**입니다. Plan→Work→Review 파이프라인, 멀티티어 라우팅, 갭 감지, 추론 인식 모델 선택을 한 번에 제공합니다.

> **철학**: bash 직역 거부. 결정론적 라우팅은 `routing.json` + `select-model.sh` 가 담당하고, 워크플로(계획/구현/리뷰/갭 수정) 는 본 스킬의 instructions 가 LLM 에이전트에게 가이드합니다.

## 1. Activation

`$zai-coding-plan` 으로 호출되거나, 아래 조건이 감지되면 자동 활성화됩니다:
- 사용자가 "Z.ai" / "GLM" / "코딩플랜" / "lite/pro/max" 언급
- 한국어 비율 > 50% 인 코딩 태스크
- 다단계 작업이지만 단순 `coding-agent` 가 아닌 Plan→Work→Review 가 필요한 경우

본 스킬은 대화 시작 시 한 번 다음을 확인합니다:

```bash
# 현재 활성 플랜 확인
echo "ZAI_CODING_PLAN=${ZAI_CODING_PLAN:-pro}  CODEX_OAUTH_ENABLED=${CODEX_OAUTH_ENABLED:-false}"

# routing.json 위치 확인
ls "$(dirname $0)/routing.json" 2>/dev/null || \
  ls skills/zai-coding-plan/routing.json
```

확인 안 되면 `## 11. Doctor` 섹션의 preflight 를 수행하세요.

---

## 2. Plan tiers

| 플랜 | 가격 | 모델 | 일일 토큰 | 동시 워커 | full 파이프라인 |
|------|------|------|-----------|-----------|------------------|
| **Lite** | $3/월 | GLM-5 Turbo, GLM-5 | 1.5M | 2 | ⚠️ 제한 |
| **Pro**  | $15/월 | + GLM-5.1 | 8M | 4 | ✅ |
| **Max**  | $30/월 | 풀 모델 + 우선 슬롯 | 25M | 7 | ✅ |

가입: https://z.ai/subscribe?ic=OTYO9JPFNV

활성 플랜 변경:

```bash
# 환경변수 (세션 한정)
export ZAI_CODING_PLAN=pro

# 영구 (~/.zshrc 또는 .envrc)
echo 'export ZAI_CODING_PLAN=pro' >> ~/.zshrc

# Codex OAuth 병행 활성화 (ChatGPT Plus/Pro 보유 시)
export CODEX_OAUTH_ENABLED=true
```

> **Lite 플랜 사용자**: GLM-5.1 미포함입니다. `routing.json` 의 `plan_block` 규칙이 자동으로 `glm-5.1 → glm-5` 로 강등합니다.

---

## 3. Routing core

본 스킬의 결정론적 라우터는 `select-model.sh` 입니다. 모델/플랜/매트릭스/추론 키워드는 **`routing.json` 단일 소스**에서 읽습니다.

### 3-1. 단일 태스크 라우팅

```bash
SKILL_DIR="$(dirname $(realpath skills/zai-coding-plan/SKILL.md))"

# 가장 단순한 호출 (auto 카테고리, 환경변수 사용)
"$SKILL_DIR/select-model.sh" "REST API 인증 미들웨어 설계" auto

# 명시적 카테고리 + 플랜
"$SKILL_DIR/select-model.sh" "분산 합의 알고리즘 정합성 증명" reasoning --plan=max

# Codex OAuth 활성 + JSON 출력
"$SKILL_DIR/select-model.sh" "전체 인증 시스템 마이그레이션 설계" coding_arch --plan=pro --codex --json
```

JSON 출력 예시:

```json
{
  "model": "gpt-5.4",
  "category": "reasoning",
  "complexity": { "score": 8, "tier": "MEDIUM" },
  "koreanRatio": 1.0,
  "reasoningHeavy": true,
  "activePlan": "pro",
  "codexOauthEnabled": true,
  "reason": "reasoning_heavy + codex (P82, extended thinking)",
  "fallbackChain": ["gpt-5.4", "glm-5.1", "glm-5", "glm-5-turbo"]
}
```

### 3-2. 라우팅 매트릭스 (Pro 기준)

| 카테고리 | LOW | MEDIUM | HIGH |
|----------|-----|--------|------|
| 코딩 (일반) | glm-5-turbo | glm-5 | glm-5.1 |
| 코딩 (아키텍처) | glm-5 | glm-5.1 | glm-5.1 |
| 한국어 NLP | glm-5-turbo | glm-5 | glm-5.1 |
| 추론 | glm-5-turbo | glm-5 | glm-5.1 |
| 디버깅 | glm-5-turbo | glm-5 | glm-5.1 |
| 보안 | glm-5 | glm-5.1 | glm-5.1 |
| 콘텐츠 생성 | glm-5-turbo | glm-5 | glm-5.1 |
| 데이터 분석 | glm-5-turbo | glm-5 | glm-5.1 |

- **Lite**: HIGH 슬롯 전부 `glm-5` 로 강등 (GLM-5.1 미포함)
- **Max**: MEDIUM 코딩/리뷰도 적극적으로 `glm-5.1` 사용
- **+Codex**: 코딩(아키/일반 HIGH), 디버깅(HIGH), 보안(MEDIUM/HIGH), 추론(HIGH), 데이터분석(HIGH) → `gpt-5.4`

전체 매트릭스: `routing.json#matrix.<plan>` 참조.

### 3-3. 우선순위 규칙 (first-match)

1. **P100** — 사용자 명시 오버라이드 (`--plan=` / `--codex`)
2. **P95** — 활성 플랜 미허용 모델 자동 강등
3. **P90** — 한국어 비율 >70% + NLP/콘텐츠 → GLM 시리즈 우선
4. **P82** — 🧠 reasoning_heavy + Codex 활성 → **gpt-5.4** (extended thinking)
5. **P81** — 🧠 reasoning_heavy + Pro/Max → **glm-5.1**
6. **P81b** — 🧠 reasoning_heavy + Lite → glm-5 (상한)
7. **P80** — Codex 활성 + 고난도 아키/보안/추론/분석 → gpt-5.4
8. **P75** — Pro/Max + HIGH 복잡도 → glm-5.1
9. **P70** — Lite + HIGH → glm-5 (상한)
10. **P50** — LOW → glm-5-turbo
11. **P0** — 기본 → glm-5

---

## 4. Reasoning-aware routing

본 스킬의 핵심 차별화. **복잡도 점수가 LOW 라도** 추론 신호가 감지되면 reasoning_score 최상위 모델로 격상합니다 (짧지만 어려운 증명/알고리즘 태스크 대응).

### 4-1. 감지 키워드

- **한국어**: 증명, 알고리즘, 복잡도, 수학, 최적화, 정합성, 상태 머신, 동형, 불변조건, race condition, 분산 합의, 정렬 증명, lock-free, Byzantine
- **영문**: prove, proof, invariant, complexity, big-O, algorithm, optimization, theorem, derive, tradeoff, distributed consensus, lock-free, byzantine
- **카테고리 힌트**: `reasoning`, `coding_arch`, `data_analysis`, `security`

### 4-2. 점수 계산

- 한국어 키워드 매치: +2
- 영문 키워드 매치: +2
- 카테고리 힌트: +1
- **합산 ≥ 2 → reasoning_heavy = true**

### 4-3. 격상 분기

| 조건 | 선택 모델 | reasoning_score |
|------|-----------|-----------------|
| reasoning_heavy + Codex 활성 | **gpt-5.4** | 97 |
| reasoning_heavy + Pro/Max | **glm-5.1** | 95 |
| reasoning_heavy + Lite | glm-5 (상한) | 82 |

전체 정의: `routing.json#reasoningDetection`

---

## 5. Codex OAuth overlay (선택)

ChatGPT Plus($20/월) 또는 Pro($200/월) 구독 보유 시, OpenAI Codex CLI OAuth 로 **gpt-5.4** 를 추가 비용 없이 병행할 수 있습니다.

### 5-1. 셋업 (한 번만)

```bash
# 1) Codex CLI 설치
brew install codex                  # macOS
# 또는: npm install -g @openai/codex

# 2) OAuth 로그인 (브라우저 흐름)
codex login
# → ChatGPT 계정으로 로그인 → "Authorize Codex CLI" 클릭
# → ~/.codex/auth.json 생성 확인
codex whoami

# 3) (선택) 두 번째 계정으로 rate limit 분산
CODEX_HOME=~/.codex-acct2 codex login

# 4) 본 스킬에 알리기
export CODEX_OAUTH_ENABLED=true
```

### 5-2. 오버레이 동작

`CODEX_OAUTH_ENABLED=true` 일 때 아래 슬롯이 `gpt-5.4` 로 자동 오버레이됩니다:

| 카테고리 | 복잡도 | Z.ai 단독 | + Codex |
|----------|--------|-----------|---------|
| coding_arch | MEDIUM/HIGH | glm-5.1 | **gpt-5.4** |
| coding_general | HIGH | glm-5.1 | **gpt-5.4** |
| debugging | HIGH | glm-5.1 | **gpt-5.4** |
| security | MEDIUM/HIGH | glm-5.1 | **gpt-5.4** |
| **reasoning** | HIGH | glm-5.1 | **gpt-5.4** 🧠 |
| **data_analysis** | HIGH | glm-5.1 | **gpt-5.4** 🧠 |

🧠 = extended thinking (gpt-5.4 reasoning_score 97 > glm-5.1 의 95)

> **rate limit 보호**: Codex 동시 워커는 최대 3개로 제한 (`routing.json#concurrency`)

### 5-3. 트러블슈팅

| 증상 | 해결 |
|------|------|
| `codex: command not found` | `brew install codex` 또는 `npm i -g @openai/codex` |
| 401 Unauthorized 간헐 | `codex login` 재실행 (refresh token 30일) |
| `No subscription found` | Free 계정. Plus/Pro 결제 후 재시도 |
| Rate limit 초과 | 두 번째 `CODEX_HOME` 추가 |

---

## 6. Plan→Work→Review pipeline

본 스킬의 **워크플로 코어**. 단순 코딩이 아닌 다단계 작업은 반드시 이 사이클로 처리합니다.

### 6-1. 모드 선택

| 모드 | 조건 | 파이프라인 | 동시 워커 |
|------|------|-----------|-----------|
| `solo` | 태스크 1개 + LOW/MEDIUM | Work | 0 |
| `parallel` | 독립 태스크 2-3개 | Work(병렬) → Review | 2-3 |
| `full` | 태스크 4개+ 또는 의존성 또는 HIGH | Plan → Work(병렬) → Review | 활성 플랜 한도 |

```
IDLE → PLANNING → WORKING → REVIEWING → COMPLETE
                          ↓             ↓
                       ESCALATED    FIXING → REVIEWING (max N회)
```

`fixLoopMaxIterations`: lite=2, pro=3, max=4 (`routing.json#plans`)

### 6-2. Stage 1 — Planning (full 모드)

**역할**: 태스크 분해 + 의존성 파악 + Ambiguity Score 계산

**모델 선택**: `select-model.sh` 를 reasoning 카테고리로 호출

```bash
PLANNER_MODEL=$(./skills/zai-coding-plan/select-model.sh \
  "$USER_REQUEST" reasoning --plan=$PLAN ${CODEX:+--codex})
```

**산출물**: `plan_v1.yaml` (태스크 트리, DoD, parallel_group, execution_order)

**HITL 게이트**: 계획 승인 필수. ralplan 패턴 적용 (모호함이 있으면 deep-interview 로 우회).

### 6-3. Stage 2 — Working (병렬)

**역할**: Plan 의 task 를 sessions_spawn 으로 병렬 실행

**모델 선택**: 각 task 별로 카테고리 추론 → `select-model.sh`

**스폰 패턴** (OpenClaw bash + sessions_spawn):

```bash
# 단일 worker 스폰 (PTY + workdir + background)
WORKER_MODEL=$(./skills/zai-coding-plan/select-model.sh \
  "$TASK_DESC" "$TASK_CATEGORY" --plan=$PLAN ${CODEX:+--codex})

bash pty:true workdir:"$PROJECT_DIR" background:true command:"
  zai-runner --model='$WORKER_MODEL' --task-id='$TASK_ID' \
    --task='$(jq -nr --arg t \"$TASK_DESC\" '\$t')' \
    --dod='$(jq -nr --arg d \"$TASK_DOD\" '\$d')' \
    --notify-on-finish
"
# → sessionId 반환, process action:list 로 추적
```

> **중요**: 워커는 자기 task 의 DoD 만 신경쓰고, 다른 워커의 작업 내용을 보지 않습니다 (context isolation). 이게 OMC 의 `$team` 패턴과 동일합니다.

### 6-4. Stage 3 — Reviewing (5관점)

**역할**: read-only 로 diff + plan + DoD 검증

**모델 선택**: 항상 reasoning 카테고리 (가장 비싼 모델 사용)

```bash
REVIEWER_MODEL=$(./skills/zai-coding-plan/select-model.sh \
  "review diff and detect gaps" reasoning --plan=$PLAN ${CODEX:+--codex})
# → Pro/Max: glm-5.1, +Codex: gpt-5.4
```

**5관점**:
1. **완료 기준 검증** — DoD 항목별 체크, 테스트/빌드 통과
2. **보안 검토** — OWASP Top 10, 하드코딩 시크릿, 인젝션
3. **성능/품질** — N+1 쿼리, 불필요 API 호출, 에러 핸들링
4. **유지보수성** — 명명, 추상화 수준, 순환 복잡도
5. **🆕 갭 감지** — 다음 섹션 참조

**Verdict**: `APPROVE` | `REQUEST_CHANGES` | `GAP_DETECTED`

### 6-5. Fix loop

`REQUEST_CHANGES` 또는 `GAP_DETECTED` 시 worker 재실행. 최대 횟수는 플랜별로 다릅니다.

소진 시 → `ESCALATED` → 사용자에게 질문 (`openclaw system event ... --mode now`).

---

## 7. Gap detection (5 gap types)

본 스킬의 또 다른 핵심 차별화. 우로보로스 하네스의 "드리프트 방지" 개념.

### 7-1. 갭 유형

| 유형 | 설명 | 예시 |
|------|------|------|
| `assumption_injection` | 사용자가 말하지 않은 가정 추가 | "JWT 인증 임의 추가" |
| `scope_creep` | 요청하지 않은 기능/복잡도 | "TODO 앱에 알림 시스템 추가" |
| `direction_drift` | 전체 방향이 의도와 다름 | "단순 API → 풀스택 프레임워크" |
| `missing_core` | 핵심 기능 누락 | "검색 기능 구현 누락" |
| `over_engineering` | 과도한 추상화/일반화 | "단순 CRUD 에 DI 컨테이너" |

### 7-2. 감지 체크리스트 (Reviewer 가 수행)

```
[ ] 원래 사용자 요청 1문장으로 요약 가능한가?
[ ] 워커가 추가한 기능 중 요청에 없는 것이 있는가? (scope_creep)
[ ] 인증/저장소/네트워크 같은 외부 의존성이 임의로 추가됐는가? (assumption_injection)
[ ] 전체 디렉토리/패키지 구조가 원래 의도보다 무거워졌는가? (direction_drift)
[ ] 원래 요청의 핵심 기능 중 빠진 것이 있는가? (missing_core)
[ ] 인터페이스/추상화가 1번만 쓰이는데도 일반화돼 있는가? (over_engineering)
```

### 7-3. Gap 발견 시 워크플로

1. **bridge notification 발신** (`## 9` 참조)
2. **수정 방향 작성** — "X 를 제거하고 Y 만 남기세요" 형식
3. **새 워커 스폰** — 원래 task + gap 피드백 동봉
4. **재리뷰** (최대 1회 추가 fix loop)
5. **2차 갭** → `ESCALATED` → 사용자 질문

```bash
# 갭 감지 시 bridge 발신 예시
openclaw system event \
  --text "[gap_detected] worker-2 ${GAP_TYPE}: ${GAP_REASON}" \
  --mode now
```

---

## 8. Borrowed from OMC (워크플로 패턴)

본 스킬은 OMC 의 검증된 워크플로 어휘를 흡수합니다. **개념을 빌려오되 구현은 본 스킬의 sessions_spawn + select-model.sh 로 통일** 합니다 (직역 거부).

### 8-1. `$ralph` — persistent loop until done

큰 태스크에서 `solo`/`parallel` 사이클이 한 번에 안 끝날 때:

```
1. 첫 사이클 실행
2. doctor.sh 로 검증 + reviewer 가 verdict 발행
3. APPROVE 가 아니면 fix loop (최대 N회, plan 별 다름)
4. 모든 task COMPLETE 까지 1-3 반복
5. 종료 조건 도달 시 openclaw system event ... --mode now
```

### 8-2. `$deep-interview` — Socratic ambiguity gating

Plan 단계 직전에 사용자 요청이 모호하면 (Ambiguity Score > 임계치) 자동 활성화. 모호한 부분만 골라서 사용자에게 1-2개 질문. **무한 질문 금지** — 최대 3턴 안에 결정.

### 8-3. `$team` — N coordinated parallel agents

`parallel`/`full` 모드의 workers spawning 이 본 패턴입니다. 차이점:
- 본 스킬: 모델 선택을 `select-model.sh` 가 결정 (각 task 별 다른 모델 가능)
- 활성 플랜의 `concurrency.maxWorkers` 자동 적용
- 워커 간 context isolation (다른 워커의 작업물 못 봄)

### 8-4. `$ultraqa` — QA cycling

Reviewer 의 fix loop 가 본 패턴. 차이점:
- 5관점 + 갭 감지가 정형화됨
- 플랜별 `fixLoopMaxIterations` 자동 적용
- 소진 시 `ESCALATED` 로 안전하게 종료

### 8-5. `$ralplan` — consensus planning gate

Plan 단계의 HITL 게이트. 사용자가 "그냥 진행" 이라고 하면 한 번 더 위험 요소를 짚고 진행 (특히 destructive ops).

### 8-6. `ai-slop-cleaner` 원칙

워커가 **사용자가 요청하지 않은 backwards-compat shim, 미사용 helper, 가정에 의한 fallback** 을 추가하지 못하도록 reviewer 의 5관점 #4 (유지보수성) + 갭 감지 #5 (over_engineering) 가 필터링.

---

## 9. Bridge notifications (OMX 호환)

본 스킬은 OMX (oh-my-codex) 의 OpenClaw 통합 contract 를 따라 lifecycle 이벤트를 발신합니다.

### 9-1. 활성 게이트

```bash
export OMX_OPENCLAW=1                       # 필수
export OMX_OPENCLAW_COMMAND=1               # command gateway 사용 시
export HOOKS_TOKEN="<bearer-token>"
export OMX_OPENCLAW_COMMAND_TIMEOUT_MS=120000
```

### 9-2. 상태 → 훅 매핑

| 상태 전이 | OMX 훅 |
|-----------|--------|
| `IDLE → PLANNING` | `session-start` |
| `WORKING → ESCALATED` | `ask-user-question` |
| `→ COMPLETE` | `session-end` |
| `사용자 취소 / kill` | `stop` |
| `agent idle > 60s` | `session-idle` |

### 9-3. 발신 예시

```bash
# session-start (Plan 단계 진입)
openclaw system event \
  --text "[session-start|exec] project=${PROJECT} cycle=${CYCLE_ID}\n요약: ${SUMMARY}\n우선순위: ${TOP_TASKS}\n주의사항: ${RISKS}" \
  --mode now

# ask-user-question (ESCALATED)
openclaw system event \
  --text "[ask-user-question|exec] session=${SESSION_ID} question=${Q}\n핵심질문: ${CORE_Q}\n영향: ${IMPACT}\n권장응답: ${RECOMMENDED}" \
  --mode now

# session-end (COMPLETE)
openclaw system event \
  --text "[session-end|exec] reason=success\n성과: ${OUTCOME}\n검증: ${VERIFICATION}\n다음: ${NEXT_ACTIONS}" \
  --mode now
```

### 9-4. 한국어 우선 instruction

OMX 의 `Korean-first` 패턴을 따릅니다. 모든 hook instruction 은 한국어로 발신하고, 구조화된 필드를 사용합니다 (요약/우선순위/주의사항/성과/검증/다음).

---

## 10. Examples

### 10-1. 단순 1회성 라우팅

```bash
# 사용자: "이 함수에 한국어 주석 추가해줘"
SKILL=skills/zai-coding-plan
MODEL=$($SKILL/select-model.sh "이 함수에 한국어 주석 추가해줘" auto --plan=pro)
# → glm-5-turbo (LOW + 한국어)

# 그냥 직접 실행
bash workdir:~/project command:"
  zai-runner --model=$MODEL --task='이 함수에 한국어 주석 추가해줘'
"
```

### 10-2. parallel 모드 (3개 독립 task)

```bash
# 사용자: "API 라우트 3개에 각각 인증 미들웨어 추가"
SKILL=skills/zai-coding-plan
PLAN=pro

for i in 1 2 3; do
  TASK="api/route$i.ts 에 인증 미들웨어 추가"
  MODEL=$($SKILL/select-model.sh "$TASK" coding_general --plan=$PLAN)
  bash pty:true workdir:~/project background:true command:"
    zai-runner --model=$MODEL --task-id=T$i --task='$TASK' \
      --dod='기존 테스트 통과 + 새 인증 테스트 1개 추가'
  "
done

# 모니터링
process action:list
process action:log sessionId:XXX

# 모두 끝나면 reviewer 스폰
REVIEWER_MODEL=$($SKILL/select-model.sh "review 3 routes" reasoning --plan=$PLAN)
bash workdir:~/project command:"
  zai-runner --model=$REVIEWER_MODEL --review --tasks=T1,T2,T3
"
```

### 10-3. full 모드 (Plan→Work→Review)

```bash
# 사용자: "TODO 앱에 검색 + 필터 + 영속화 추가"
SKILL=skills/zai-coding-plan
PLAN=pro
CYCLE_ID=cycle-$(date +%Y%m%d-%H%M%S)

# 1. session-start 알림
openclaw system event --text "[session-start] cycle=$CYCLE_ID 요약: TODO 검색/필터/영속화" --mode now

# 2. Planner 스폰
PLANNER=$($SKILL/select-model.sh "decompose: TODO 검색 필터 영속화" reasoning --plan=$PLAN)
bash workdir:~/project command:"zai-runner --model=$PLANNER --plan-only" > /tmp/plan_v1.yaml

# 3. ralplan 게이트 — 사용자 승인 (질문 후 진행)
cat /tmp/plan_v1.yaml
read -p "이 plan 으로 진행할까요? (y/n) " ans
[[ "$ans" != "y" ]] && exit 1

# 4. Workers 병렬 스폰 (plan 의 task 별)
yq '.tasks[] | [.id, .content, .category, .dod] | @tsv' /tmp/plan_v1.yaml | \
while IFS=$'\t' read tid content cat dod; do
  m=$($SKILL/select-model.sh "$content" "$cat" --plan=$PLAN)
  bash pty:true workdir:~/project background:true command:"
    zai-runner --model=$m --task-id=$tid --task='$content' --dod='$dod'
  "
done

# 5. 워커 완료 대기 → Reviewer (5관점 + 갭 감지)
process action:list  # 전부 ✓ 될 때까지
REVIEWER=$($SKILL/select-model.sh "5-perspective review + gap" reasoning --plan=$PLAN)
bash workdir:~/project command:"zai-runner --model=$REVIEWER --review --gap-check"

# 6. APPROVE 면 session-end, GAP_DETECTED 면 fix loop
```

### 10-4. 추론 집약 + Codex

```bash
# 사용자: "분산 락의 정합성 증명과 race condition 케이스 분석"
SKILL=skills/zai-coding-plan
$SKILL/select-model.sh "분산 락의 정합성 증명과 race condition 케이스 분석" \
  reasoning --plan=pro --codex --json
# → model: gpt-5.4 (P82, extended thinking)
```

---

## 11. Doctor / preflight

스킬 시작 시 자동 또는 수동 점검:

```bash
SKILL=skills/zai-coding-plan
echo "=== zai-coding-plan doctor ==="

# 1) jq
command -v jq >/dev/null && echo "✓ jq" || { echo "✗ jq missing"; exit 1; }

# 2) routing.json
test -f "$SKILL/routing.json" && \
  jq empty "$SKILL/routing.json" && echo "✓ routing.json valid" || echo "✗ routing.json invalid"

# 3) select-model.sh 실행 가능
test -x "$SKILL/select-model.sh" && echo "✓ select-model.sh executable" || echo "✗ chmod +x needed"

# 4) 활성 플랜 sanity
PLAN="${ZAI_CODING_PLAN:-pro}"
case "$PLAN" in lite|pro|max) echo "✓ plan=$PLAN" ;; *) echo "✗ invalid ZAI_CODING_PLAN" ;; esac

# 5) Z.ai provider 인증 확인 (env 또는 openclaw config)
[[ -n "${ZAI_API_KEY:-}" ]] && echo "✓ ZAI_API_KEY set" || \
  echo "⚠ ZAI_API_KEY not in env (openclaw config may have it)"

# 6) Codex OAuth (선택)
if [[ "${CODEX_OAUTH_ENABLED:-false}" == "true" ]]; then
  test -f ~/.codex/auth.json && echo "✓ codex auth.json" || echo "✗ codex login needed"
fi

# 7) 라우터 smoke test
$SKILL/select-model.sh "smoke test" coding_general --plan=$PLAN >/dev/null && \
  echo "✓ router smoke test" || echo "✗ router failed"
```

기대 출력: `✓ * 7개`. 실패 시 해당 항목 해결 후 재시도.

---

## 12. Rules / safety

1. **모델 선택은 항상 `select-model.sh` 통과** — 직접 모델 ID 하드코딩 금지. 플랜 변경 시 자동 강등이 깨집니다.
2. **Plan 단계 HITL 게이트는 절대 생략 금지** — full 모드에서 사용자 승인 없이 워커 스폰 금지. ralplan 패턴 강제.
3. **워커 간 context isolation 유지** — 한 워커가 다른 워커의 작업물을 읽지 않도록. `team` 패턴.
4. **갭 감지 시 fix loop 1회 후 무조건 ESCALATED** — 무한 fix 방지. 사용자 결정 우선.
5. **Codex OAuth 없으면 명시 안 함** — `CODEX_OAUTH_ENABLED=false` (기본) 일 때 gpt-5.4 추천 금지.
6. **Lite 플랜에서 glm-5.1 강제 금지** — `select-model.sh` 의 `cap_for_lite` 가 자동 강등하지만, 사용자가 `--plan=lite` 명시 시 절대 우회 금지.
7. **bridge notification 은 best-effort** — 발신 실패가 파이프라인을 차단하지 않도록 `|| true` 패턴.
8. **모든 Korean-first instruction 은 한국어로 발신** — OMX 호환성.
9. **민감 정보는 로그에 안 찍음** — API 키/토큰은 항상 env 참조, instruction 텍스트에 평문 포함 금지.
10. **destructive ops 는 ralplan 게이트 후 진행** — `git push --force`, `rm -rf`, `db drop` 등은 사용자 명시 승인 필수.

---

## 13. Reference

### 13-1. 모델 카탈로그

| 모델 | 티어 | 컨텍스트 | 코딩 | 추론 | 한국어 | 플랜 |
|------|------|----------|------|------|--------|------|
| **GLM-5 Turbo** | LOW | 128K | 70 | 60 | 95 | lite/pro/max |
| **GLM-5** | MEDIUM | 128K | 88 | 82 | 95 | lite/pro/max |
| **GLM-5.1** ⚡ | HIGH | 204.8K | 95 | 95 | 96 | pro/max |
| **GPT-5.4** ⚡ *(선택)* | HIGH | 256K | 97 | 97 | 72 | OAuth |

⚡ = extended thinking (reasoning_mode: true)

### 13-2. 파일 구조

```
skills/zai-coding-plan/
├── SKILL.md          # 본 파일 — 워크플로 instructions
├── routing.json      # 결정론적 라우팅 데이터 (모델/플랜/매트릭스/키워드)
└── select-model.sh   # jq 기반 라우터 (routing.json 읽음)
```

### 13-3. 환경변수

| 변수 | 기본값 | 용도 |
|------|--------|------|
| `ZAI_CODING_PLAN` | `pro` | 활성 플랜 (lite\|pro\|max) |
| `CODEX_OAUTH_ENABLED` | `false` | Codex OAuth 오버레이 활성 |
| `ZAI_API_KEY` | (openclaw config) | Z.AI API 키 |
| `OMX_OPENCLAW` | (none) | bridge notifications 활성 |
| `HOOKS_TOKEN` | (none) | bridge bearer token |

### 13-4. 외부 참조

- Z.ai 가입: https://z.ai/subscribe?ic=OTYO9JPFNV
- OpenClaw plugin SDK: `openclaw/plugin-sdk/*`
- 기존 zai provider: `extensions/zai/openclaw.plugin.json`
- pi 코어: https://github.com/badlogic/pi-mono
- 본 하네스 원본 (bash): https://github.com/jkf87/openclaw-harness
- 영감: oh-my-codex (OMX) workflow patterns, OMC ralph/team/deep-interview

---

## 14. Learnings (Apr 2026)

- **결정론과 워크플로의 분리**: 모델 선택 같은 결정론적 로직은 코드(`select-model.sh` + `routing.json`)에, 협상 가능한 워크플로는 instructions(`SKILL.md`)에. LLM 이 매번 매트릭스를 재해석하면 드리프트 발생.
- **추론 신호는 복잡도와 독립**: "분산 합의 정합성 증명" 은 짧은 문장(LOW 복잡도)이지만 reasoning_score 최상위 모델이 필요. 키워드 기반 휴리스틱이 LOW 격상 트리거 역할.
- **Lite 플랜은 적극적 강등**: 자동 `cap_for_lite` 가 없으면 사용자가 코딩플랜 quota 초과 위험. P95 plan_block 규칙 필수.
- **Codex OAuth 는 오버레이지 대체가 아님**: gpt-5.4 가 reasoning_score 97 로 우위지만 한국어 점수는 72. 한국어 NLP/콘텐츠는 그대로 GLM 시리즈 유지.
- **갭 감지 1회 + ESCALATED**: 무한 fix 시도는 사용자 입장에서 더 큰 비용. 1회 fix 후 명확히 사용자 결정 요청.
- **bridge notification 은 fire-and-forget**: 발신 실패가 파이프라인을 차단하면 안 됨. OMX 의 `|| true` 패턴 채택.
- **bash 직역 거부**: 원본 harness 의 `route-task.sh` 를 직역하지 않고, `select-model.sh` + `routing.json` 으로 데이터/로직 분리. 같은 결과지만 LLM 이 reasoning 을 routing.json 으로 위임 가능.
