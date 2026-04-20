---
name: ohmyclaw
description: 'OpenClaw 용 멀티프로바이더/멀티계정 라우팅 하네스. Z.ai 코딩플랜(Lite/Pro/Max) 모델 매트릭스 + ChatGPT Codex OAuth 다중 계정 풀(round-robin/cooldown/fan-out) + 추론 인식 모델 선택 + Plan→Work→Review 오케스트레이션 + 5관점 리뷰와 갭 감지. Use when: (1) Z.ai GLM 코딩 작업, (2) 다중 ChatGPT/Z.ai 계정으로 rate limit 분산, (3) 한국어 코딩/리뷰/리팩토링, (4) Plan→Work→Review 사이클로 다단계 작업 분해, (5) 같은 태스크를 여러 계정에 fan-out. NOT for: (a) 단순 1-line 수정, (b) read-only 탐색, (c) Z.ai/Codex 가 아닌 다른 프로바이더 단독 작업.'
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

# ohmyclaw — OpenClaw Multi-Provider/Multi-Account Harness

OpenClaw 의 `@openclaw/zai-provider` (와 선택적 ChatGPT Codex OAuth) 위에 올라가는 **에이전트 하네스**입니다. 다음을 한 번에 제공합니다:

- Z.ai 코딩플랜(Lite/Pro/Max) 멀티티어 라우팅
- ChatGPT Codex OAuth 다중 계정 풀 (round-robin / cooldown / fan-out)
- 추론 인식 모델 선택 (한/영 키워드 기반)
- Plan→Work→Review 파이프라인 + 5관점 리뷰 + 갭 감지
- OMX 호환 브릿지 알림

> **철학**: bash 직역 거부. 결정론적 라우팅(`routing.json` + `select-model.sh`)과 계정 풀 (`pool.sh`) 은 코드로, 워크플로(계획/구현/리뷰/갭 수정) 는 본 스킬의 instructions 로 LLM 에이전트에게 가이드합니다.

## 1. Activation

`$ohmyclaw` 으로 호출되거나, 아래 조건이 감지되면 자동 활성화됩니다:
- 사용자가 "Z.ai" / "GLM" / "코딩플랜" / "lite/pro/max" 언급
- 한국어 비율 > 50% 인 코딩 태스크
- 다단계 작업이지만 단순 `coding-agent` 가 아닌 Plan→Work→Review 가 필요한 경우

본 스킬은 대화 시작 시 한 번 다음을 확인합니다:

```bash
# 현재 활성 플랜 확인
echo "ZAI_CODING_PLAN=${ZAI_CODING_PLAN:-pro}  CODEX_OAUTH_ENABLED=${CODEX_OAUTH_ENABLED:-false}"

# routing.json 위치 확인
ls "$(dirname $0)/routing.json" 2>/dev/null || \
  ls skills/ohmyclaw/routing.json
```

확인 안 되면 `## 12. Doctor` 섹션의 preflight 를 수행하세요.

### 슬래시 명령어 (Telegram/Discord/Web 공통)

모든 명령어는 **`/ohmyclaw`** 네임스페이스 아래에 있습니다 (다른 스킬의 `/hud` 등과 충돌 방지).

| 명령어 | 자연어 | 실행 | 출력 |
|--------|--------|------|------|
| **`/ohmyclaw`** | "ohmyclaw 상태" "사용량 보여줘" | `$SKILL/hud.sh` | 플랜/계정/quota/모델 대시보드 |
| `/ohmyclaw compact` | "상태 한 줄" | `$SKILL/hud.sh --compact` | `🦞 PRO \| zai:230K \| codex:32K \| 3%` |
| `/ohmyclaw route <task>` | "이거 어떤 모델?" | `$SKILL/select-model.sh "<task>" auto --json` | 라우팅 JSON |
| `/ohmyclaw pool` | "계정 상태" | `$SKILL/pool.sh status` | 풀 + cooldown 표 |
| `/ohmyclaw doctor` | "점검해줘" | § 12 bash snippet | 10항목 점검 |
| `/ohmyclaw exec <task>` | "이거 해줘" | § 7 → executor.md | 직접 실행 |
| `/ohmyclaw plan <task>` | "계획 세워줘" | § 7 → planner.md | 계획 수립 |
| `/ohmyclaw plan --consensus` | "합의해서 계획" | § 7 → planner→architect→critic | 합의 루프 |
| `/ohmyclaw review` | "리뷰 좀" | § 7 → reviewer.md | 5관점 + 갭 감지 |
| `/ohmyclaw team N <task>` | "3명이서 해" | § 7 → team-*.md | 병렬 워커 |
| `/ohmyclaw ralph <task>` | "끝까지 해" | § 7 → executor+verifier | 루프 |
| `/ohmyclaw debug <task>` | "버그 잡아" | § 7 → debugger.md | 4단계 RCA |

> **에이전트 인식 규칙**: 사용자가 `/ohmyclaw` 로 시작하는 명령어를 입력하면 **ohmyclaw 스킬의 스크립트를 즉시 bash 로 실행**하고 결과를 보여줍니다. OMC 의 `/hud` 와 혼동 금지 — `/ohmyclaw` 는 반드시 ohmyclaw 스킬 경로(`~/.openclaw/skills/ohmyclaw/` 또는 `~/.openclaw/repos/ohmyclaw/skills/ohmyclaw/`)의 스크립트를 실행합니다.
>
> **자연어 매핑**: "ohmyclaw 사용량" → `/ohmyclaw`, "모델 뭐로?" → `/ohmyclaw route`, "계정 상태" → `/ohmyclaw pool`
>
> **주의**: `/hud` 단독은 OMC HUD 입니다. ohmyclaw 대시보드는 반드시 `/ohmyclaw` 으로 호출하세요.

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
SKILL_DIR="$(dirname $(realpath skills/ohmyclaw/SKILL.md))"

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
| Rate limit 초과 | § 6 멀티 계정 풀 사용 |

### 5-4. Experimental Claude Code CLI delegation (opt-in)

> **상태: 실험적 / 기본 비활성 / 언제든 제거 가능**
>
> 공식 Claude Code CLI 를 로컬에서 직접 실행하는 delegation 경로만 다룹니다. 제3자 도구에서의 구독 사용 정책이 바뀌면 이 경로는 막히거나 지원 중단될 수 있습니다. 따라서 ohmyclaw 에서는 **기본 라우팅으로 쓰지 않고**, 명시 opt-in 일 때만 제한적으로 노출합니다.

활성화 조건:

```bash
export CLAUDECLI_DELEGATION_ENABLED=true
# routing.json 의 accounts.pools.claudecli.accounts[0].enabled=true
claude login
```

제한:

- 기본 경로 아님, fallback 우선
- HIGH 난도의 `reasoning`, `coding_arch`, `security` 만 제한적으로 오버레이
- direct OAuth token ingestion 금지, 공식 CLI 세션만 사용
- helper: `skills/ohmyclaw/claude-delegate.sh`

예시:

```bash
SKILL=skills/ohmyclaw
MODEL=$($SKILL/select-model.sh "보안 경계 재설계" security --claudecli --json)
$SKILL/claude-delegate.sh "보안 경계 재설계" --cwd="$PROJECT"
```

---

## 6. Multi-account routing (계정 풀)

같은 모델을 **여러 계정에 분산** 해서 rate limit 을 회피하거나, 같은 태스크를 **여러 계정에 동시 발사**(fan-out) 할 수 있습니다. 본 기능은 `pool.sh` 가 담당합니다.

### 6-1. 풀 정의

`routing.json#accounts.pools` 에서 각 프로바이더 풀과 계정을 선언합니다:

```jsonc
{
  "accounts": {
    "pools": {
      "zai": {
        "providerId": "zai",
        "modelPrefixes": ["glm-"],
        "accounts": [
          { "id": "zai-primary",   "authType": "oauth_zai", "openclawProfile": "default", "plan": "pro",  "weight": 10, "enabled": true },
          { "id": "zai-secondary", "authType": "api_key",   "envKey": "ZAI_API_KEY_2",     "plan": "lite", "weight": 5,  "enabled": false },
          { "id": "zai-team-max",  "authType": "oauth_zai", "openclawProfile": "team",     "plan": "max",  "weight": 15, "enabled": false }
        ]
      },
      "codex": {
        "providerId": "openai-codex",
        "modelPrefixes": ["gpt-"],
        "optional": true,
        "accounts": [
          { "id": "codex-primary",   "authType": "oauth_codex", "codexHome": "~/.codex",       "weight": 10, "enabled": false },
          { "id": "codex-secondary", "authType": "oauth_codex", "codexHome": "~/.codex-acct2", "weight": 10, "enabled": false }
        ]
      }
    }
  }
}
```

**모델 → 풀 매핑**: prefix 기반. `glm-*` → zai 풀, `gpt-*` → codex 풀. 다른 모델은 reject.

### 6-2. pool.sh 액션

```bash
SKILL=skills/ohmyclaw
P=$SKILL/pool.sh

# round-robin pick — 모델만 주면 풀 자동 선택
$P next glm-5.1
# → zai-primary|oauth_zai|default|pro|10
#    (id|authType|authValue|plan|weight)

$P next gpt-5.4   # CODEX_OAUTH_ENABLED=true 필요
# → codex-primary|oauth_codex|/Users/me/.codex|any|10

# 풀 + 계정 상태 확인
$P status
$P status zai

# rate limit hit → cooldown 마킹 (지수 백오프, 최대 600s)
$P cooldown zai-primary

# cooldown 해제
$P release zai-primary

# state 전체 리셋
$P reset

# fan-out: 풀의 enabled 계정 전부 출력 (병렬 발사용)
$P fanout zai
```

state 파일: `${OHMYCLAW_STATE_DIR:-~/.cache/ohmyclaw}/pool-state.json`

### 6-3. select-model + pool.sh 체이닝 (가장 일반적인 패턴)

```bash
SKILL=skills/ohmyclaw

# 1. 모델 선택
MODEL=$($SKILL/select-model.sh "$TASK" auto --plan=$PLAN ${CODEX:+--codex})

# 2. 해당 모델의 계정 픽
ACCOUNT_LINE=$($SKILL/pool.sh next "$MODEL")
ACCOUNT_ID=$(echo "$ACCOUNT_LINE" | cut -d'|' -f1)
AUTH_TYPE=$(echo "$ACCOUNT_LINE" | cut -d'|' -f2)
AUTH_VALUE=$(echo "$ACCOUNT_LINE" | cut -d'|' -f3)

# 3. 인증 적용 + 실행
case "$AUTH_TYPE" in
  oauth_zai)
    # OpenClaw profile 사용
    openclaw-profile activate "$AUTH_VALUE"
    bash pty:true command:"pi --provider zai --model $MODEL '$TASK'"
    ;;
  oauth_codex)
    # CODEX_HOME 분리
    CODEX_HOME="$AUTH_VALUE" bash pty:true command:"codex exec --model=$MODEL '$TASK'"
    ;;
  api_key)
    # 환경변수 주입
    export ZAI_API_KEY="${!AUTH_VALUE}"
    bash pty:true command:"pi --provider zai --model $MODEL '$TASK'"
    ;;
esac

# 4. 실패 시 cooldown 마킹 + 다음 계정으로 재시도
if [[ $? -ne 0 ]]; then
  $SKILL/pool.sh cooldown "$ACCOUNT_ID"
  ACCOUNT_LINE=$($SKILL/pool.sh next "$MODEL")
  # ... 재시도
fi
```

### 6-4. Round-robin / Cooldown 동작

- **Round-robin**: 풀의 enabled 계정을 인덱스 modulo 회전. state 에 `roundRobinIndex` 저장.
- **Cooldown**: 실패 시 `consecutiveFailures` 증가, 백오프 = `min(base × multiplier^(failures-1), maxCooldown)`. 기본: 60s → 120s → 240s → 480s → 600s (cap).
- **자동 해제**: cooldown 만료 시 자동으로 다시 후보. 명시 해제는 `release`.
- **빈 풀**: 모든 enabled 계정이 cooldown 이거나 enabled=false 면 `next` 가 에러.

### 6-5. Fan-out 패턴 (대량 분산)

같은 태스크를 여러 계정에 동시 발사:

```bash
# zai 풀의 모든 enabled 계정에 동시 발사 (3 워커 병렬)
SKILL/pool.sh fanout zai | while IFS='|' read -r id authType authValue plan weight; do
  bash pty:true workdir:~/project background:true command:"
    case '$authType' in
      oauth_zai) openclaw-profile activate '$authValue' ;;
    esac
    pi --provider zai --model glm-5.1 '$TASK'
  "
done

# 모든 응답 수집 후 reviewer 가 합치거나 best 선택
process action:list
```

> **fan-out 권장 시점**: 같은 태스크를 다른 계정으로 한 번씩 돌려서 결과를 비교하고 싶을 때 (consensus / cross-validation), 또는 한 계정 quota 가 부족할 때 분할.

### 6-6. 새 계정 등록 절차

**Z.ai 보조 키 추가**:
```bash
export ZAI_API_KEY_2="zai_..."
# routing.json 에서 zai-secondary 의 enabled 를 true 로 변경
```

**ChatGPT 두 번째 계정**:
```bash
# 1. 별도 디렉토리로 로그인
CODEX_HOME=~/.codex-acct2 codex login
ls ~/.codex-acct2/auth.json   # 확인

# 2. routing.json 에서 codex-secondary 의 enabled 를 true 로 변경

# 3. 검증
CODEX_OAUTH_ENABLED=true skills/ohmyclaw/pool.sh status codex
```

### 6-7. 전략 선택

| 전략 | 언제 | pool.sh 액션 |
|------|------|--------------|
| `round_robin` (기본) | rate limit 분산, 계정별 부하 균등화 | `next <model>` |
| `fan_out` | consensus, cross-validation, 대량 분할 | `fanout <providerId>` |
| `cooldown only` | 단일 계정 + 실패 추적만 필요 | `next` + `cooldown` |

---

## 7. Composable execution verbs (OMX-style)

기존 Plan→Work→Review 고정 파이프라인 대신, OMX (oh-my-codex) 의 **composable verb** 패턴을 채택합니다. 사용자가 동사를 선택하고, 각 동사가 `prompts/` 의 role prompt 를 합성합니다.

> **왜 고정 파이프라인을 버렸나**: OMX 의 교훈 — "사용자가 verb 를 고르는 게 더 유연하다". Plan 없이 바로 exec, review 만 따로, team 으로 병렬 — 동사별로 다른 prompt 를 조합하면 됨.

### 7-1. 동사 × Prompt 매핑

| 동사 | 사용법 | 합성 Prompt | 모델 카테고리 |
|------|--------|-------------|---------------|
| `$ohmyclaw exec` | `$ohmyclaw exec "REST API 인증 미들웨어"` | `executor.md` 단일 | auto |
| `$ohmyclaw team N:role` | `$ohmyclaw team 3:executor "타입 3개 동시 추가"` | `team-orchestrator.md` + N × `team-executor.md` | reasoning / auto |
| `$ohmyclaw ralph` | `$ohmyclaw ralph "E2E 테스트 통과까지"` | `executor.md` + `verifier.md` 루프 | auto + reasoning |
| `$ohmyclaw plan` | `$ohmyclaw plan "API gateway 마이그레이션"` | `planner.md` 단일 | reasoning |
| `$ohmyclaw plan --consensus` | `$ohmyclaw plan --consensus "마이그레이션"` | `planner.md` → `architect.md` → `critic.md` 합의 | reasoning + coding_arch |
| `$ohmyclaw deep-interview` | `$ohmyclaw deep-interview "기능 정의 명확화"` | `planner.md` (ambiguity gating 부분만) | reasoning |
| `$ohmyclaw review` | `$ohmyclaw review src/` | `reviewer.md` (5관점 + 갭 감지) | reasoning |
| `$ohmyclaw debug` | `$ohmyclaw debug "TypeError at user.ts:42"` | `debugger.md` (4단계 RCA, 3회 circuit breaker) | debugging |
| `$ohmyclaw verify` | `$ohmyclaw verify "빌드+테스트 통과"` | `verifier.md` (PASS / FAIL / PARTIAL) | reasoning |

자세한 합성 규칙과 모델/계정 선택 패턴: `prompts/README.md` 참조.

### 7-2. Spawn 패턴 (모든 동사 공통)

ohmyclaw 는 기본적으로 **에이전트가 직접 실행** 합니다 (sub-agent spawn 없이). 라우터로 모델을 결정하고, 직접 코드를 읽고 쓰면서 해당 prompt 의 instructions 를 따릅니다.

#### 직접 실행 (기본 — 권장)

```bash
SKILL=skills/ohmyclaw

# 1. 모델 결정 (어떤 모델이 적절한지 판단용 — 에이전트 자체가 실행)
MODEL=$($SKILL/select-model.sh "$TASK" <category> --plan=$PLAN ${CODEX:+--codex})
echo "추천 모델: $MODEL"

# 2. 에이전트가 직접 prompts/<role>.md 를 읽고 따릅니다
# → Read prompts/executor.md 또는 prompts/reviewer.md 등
# → 해당 prompt 의 <execution_loop> 대로 진행
```

에이전트가 직접 실행하므로 **ACP agent spawn 이 필요 없습니다**.

#### Sub-agent spawn (병렬 작업 시 — codex/claude/pi CLI 사용)

team 이나 ralph 처럼 병렬 또는 background 실행이 필요할 때만 CLI 를 spawn 합니다:

```bash
SKILL=skills/ohmyclaw
MODEL=$($SKILL/select-model.sh "$TASK" auto --plan=$PLAN ${CODEX:+--codex})

# Codex 로 spawn (PTY 필수)
bash pty:true workdir:"$PROJECT" background:true command:"codex exec --full-auto '$TASK'"

# Claude Code 로 spawn (PTY 불필요, 실험 경로는 helper 사용 권장)
bash workdir:"$PROJECT" background:true command:"skills/ohmyclaw/claude-delegate.sh '$TASK' --cwd='$PROJECT'"

# Pi 로 spawn (PTY 필수)
bash pty:true workdir:"$PROJECT" background:true command:"pi '$TASK'"
```

어떤 CLI 를 쓸지는 **모델에 따라 결정**:
- `glm-*` 모델 → `pi` (Z.ai provider 활성) 또는 `codex` (OpenAI compatible endpoint)
- `gpt-5.4` 모델 → `codex` (Codex CLI + ChatGPT OAuth)

#### 계정 풀 연동 (선택)

```bash
# 모델에 맞는 계정 선택 (round-robin)
ACCT=$($SKILL/pool.sh next "$MODEL")
ID=$(echo "$ACCT" | cut -d'|' -f1)
AUTH_TYPE=$(echo "$ACCT" | cut -d'|' -f2)
AUTH_VAL=$(echo "$ACCT" | cut -d'|' -f3)

# 인증 적용
case "$AUTH_TYPE" in
  oauth_zai)   openclaw-profile activate "$AUTH_VAL" ;;
  oauth_codex) export CODEX_HOME="$AUTH_VAL" ;;
  api_key)     export ZAI_API_KEY="${!AUTH_VAL}" ;;
esac

# 실패 시 cooldown + 다음 계정
[[ $? -ne 0 ]] && $SKILL/pool.sh cooldown "$ID"
```

### 7-3. `$ohmyclaw ralph` — 끝까지 루프

```
  ┌──────────────┐
  │  executor    │ ← prompts/executor.md
  │  (구현)      │
  └──────┬───────┘
         ↓
  ┌──────────────┐
  │  verifier    │ ← prompts/verifier.md
  │  (검증)      │
  └──────┬───────┘
     ┌───┴───┐
     │PASS?  │
     └───┬───┘
      예 │     │ 아니오
         ↓     ↓
     COMPLETE   다시 executor (max N 회)
                lite=2 / pro=3 / max=4
```

- `fixLoopMaxIterations`: `routing.json#plans` 참조
- N 회 소진 → ESCALATED → `openclaw system event ... --mode now`

### 7-4. `$ohmyclaw plan --consensus` — 합의 루프

```
  planner → architect → critic
      ↑_________________________↓ (REJECT → planner 재시도, max 3 라운드)
```

- `planner.md` 가 초안 작성 → `.omx/plans/<name>.md` 저장
- `architect.md` 가 read-only 분석 + 트레이드오프 표
- `critic.md` 가 OKAY / REJECT 판정
- `--interactive` 플래그 시 사용자 승인 게이트 추가

### 7-5. `$ohmyclaw team` — 병렬 워커

- `team-orchestrator.md` 1 인스턴스가 리더
- `team-executor.md` × N 인스턴스가 워커
- 워커 간 **context isolation** (다른 워커 작업물 못 봄)
- 동시 워커 수: 활성 플랜의 `concurrency.maxWorkers` 자동 적용 (lite=2, pro=4, max=7)

### 7-6. `$ohmyclaw review` — 5관점 + 갭 감지

`reviewer.md` 가 단일 패스로 5 stage 를 수행합니다:

1. **Spec compliance** — 요구사항 커버 여부
2. **Security (OWASP)** — 비밀 키, injection, auth
3. **Quality** — 로직 결함, 에러 핸들링, SOLID
4. **Maintainability** — 명명, 복잡도, 테스트 가능성
5. **Gap detection** — assumption_injection / scope_creep / direction_drift / missing_core / over_engineering

Verdict: `APPROVE` / `REQUEST_CHANGES` / `GAP_DETECTED`

**갭 발견 시**:
```bash
openclaw system event \
  --text "[gap_detected] ${GAP_TYPE}: ${GAP_REASON}" --mode now
```
→ 1회 fix loop 후에도 남아있으면 ESCALATED.

---

## 8. Provenance (OMC + OMX 어디서 왔나)

본 스킬의 prompts 와 동사 어휘는 두 소스에서 영감을 받았습니다:

| 출처 | 가져온 것 | 어떻게 적응 |
|------|-----------|-------------|
| **OMX** (oh-my-codex, MIT) | prompts/ XML contract 포맷, verb 패턴 ($ralph/$team/$plan), role 분리 (executor/verifier/architect/critic) | 카피 + `## ohmyclaw integration` 블록, 모델/계정 선택 통합 |
| **OMC** (oh-my-claudecode) | ralph loop, deep-interview gating, team isolation, ultraqa cycling, ai-slop-cleaner 원칙 | 동사 이름 공유, reviewer.md Stage 5 갭 감지 |
| **우로보로스 하네스** | 갭 유형 5종 (assumption_injection, scope_creep, direction_drift, missing_core, over_engineering) | reviewer.md Stage 5 로 통합 |

> 원본 참조: https://github.com/Yeachan-Heo/oh-my-codex (MIT)

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
SKILL=skills/ohmyclaw
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
SKILL=skills/ohmyclaw
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
SKILL=skills/ohmyclaw
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
SKILL=skills/ohmyclaw
$SKILL/select-model.sh "분산 락의 정합성 증명과 race condition 케이스 분석" \
  reasoning --plan=pro --codex --json
# → model: gpt-5.4 (P82, extended thinking)
```

---

## 11. Doctor / preflight

스킬 시작 시 자동 또는 수동 점검:

```bash
SKILL=skills/ohmyclaw
echo "=== ohmyclaw doctor ==="

# 1) jq
command -v jq >/dev/null && echo "✓ jq" || { echo "✗ jq missing"; exit 1; }

# 2) routing.json
test -f "$SKILL/routing.json" && \
  jq empty "$SKILL/routing.json" && echo "✓ routing.json valid" || echo "✗ routing.json invalid"

# 3) select-model.sh 실행 가능
test -x "$SKILL/select-model.sh" && echo "✓ select-model.sh executable" || echo "✗ chmod +x needed"

# 4) pool.sh 실행 가능
test -x "$SKILL/pool.sh" && echo "✓ pool.sh executable" || echo "✗ chmod +x needed"

# 5) 활성 플랜 sanity
PLAN="${ZAI_CODING_PLAN:-pro}"
case "$PLAN" in lite|pro|max) echo "✓ plan=$PLAN" ;; *) echo "✗ invalid ZAI_CODING_PLAN" ;; esac

# 6) Z.ai provider 인증 확인 (env 또는 openclaw config)
[[ -n "${ZAI_API_KEY:-}" ]] && echo "✓ ZAI_API_KEY set" || \
  echo "⚠ ZAI_API_KEY not in env (openclaw config may have it)"

# 7) Codex OAuth (선택)
if [[ "${CODEX_OAUTH_ENABLED:-false}" == "true" ]]; then
  test -f ~/.codex/auth.json && echo "✓ codex auth.json" || echo "✗ codex login needed"
  test -f ~/.codex-acct2/auth.json && echo "✓ codex-acct2 auth.json" || echo "ℹ codex-acct2 (선택)"
fi

# 8) 라우터 smoke test
$SKILL/select-model.sh "smoke test" coding_general --plan=$PLAN >/dev/null && \
  echo "✓ router smoke test" || echo "✗ router failed"

# 9) 풀 enabled 계정 확인
$SKILL/pool.sh status zai 2>&1 | grep -q "enabled=true" && echo "✓ zai pool has enabled account" || \
  echo "⚠ zai pool 모든 계정 enabled=false (routing.json 확인)"

# 10) 풀 round-robin smoke test
$SKILL/pool.sh next glm-5 >/dev/null 2>&1 && echo "✓ pool round-robin smoke test" || \
  echo "✗ pool.sh next 실패"
```

기대 출력: `✓ * 8–10개`. 실패 시 해당 항목 해결 후 재시도.

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

| 모델 | 티어 | 컨텍스트 | 코딩 | 추론 | 한국어 | 플랜 / 풀 |
|------|------|----------|------|------|--------|----------|
| **GLM-5 Turbo** | LOW | 128K | 70 | 60 | 95 | zai · lite/pro/max |
| **GLM-5** | MEDIUM | 128K | 88 | 82 | 95 | zai · lite/pro/max |
| **GLM-5.1** ⚡ | HIGH | 204.8K | 95 | 95 | 96 | zai · pro/max |
| **GPT-5.4** ⚡ *(선택)* | HIGH | 256K | 97 | 97 | **97** | codex · OAuth pool |

⚡ = extended thinking (reasoning_mode: true)

### 13-2. 파일 구조

```
skills/ohmyclaw/
├── SKILL.md          # 본 파일 — 워크플로 instructions (15 섹션)
├── routing.json      # 결정론적 단일 소스
│                     #   ├── models       — 4 모델 메타
│                     #   ├── plans        — lite/pro/max quota/concurrency
│                     #   ├── matrix       — 3 플랜 × 8 카테고리 × 3 티어
│                     #   ├── codexOverlay — gpt-5.4 활성 슬롯
│                     #   ├── reasoningDetection — 한/영 키워드
│                     #   ├── koreanDetection
│                     #   ├── accounts     — pools (zai + codex) + poolDefaults
│                     #   └── fallbackChains
├── select-model.sh   # jq 기반 라우터 — routing.json 읽음, 모델 ID 출력
└── pool.sh           # jq 기반 계정 풀 — round-robin/cooldown/fan-out
                      #   액션: next/fanout/cooldown/release/status/reset
```

### 13-3. 환경변수

| 변수 | 기본값 | 용도 |
|------|--------|------|
| `ZAI_CODING_PLAN` | `pro` | 활성 Z.ai 플랜 (lite\|pro\|max) |
| `CODEX_OAUTH_ENABLED` | `false` | Codex OAuth 풀 사용 게이트 |
| `ZAI_API_KEY` | (openclaw config) | Z.AI 메인 API 키 |
| `ZAI_API_KEY_2` | (none) | Z.AI 보조 API 키 (zai-secondary 계정용) |
| `CODEX_HOME` | `~/.codex` | Codex OAuth 토큰 디렉토리 (계정별 분리 시 사용) |
| `OHMYCLAW_STATE_DIR` | `~/.cache/ohmyclaw` | pool.sh state 디렉토리 |
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
- **Codex OAuth 는 오버레이지 대체가 아님**: gpt-5.4 는 코딩 97, 추론 97, 한국어 97 로 전 영역 최상위. Codex OAuth 활성 시 한국어 태스크도 GPT-5.4 로 처리 가능.
- **갭 감지 1회 + ESCALATED**: 무한 fix 시도는 사용자 입장에서 더 큰 비용. 1회 fix 후 명확히 사용자 결정 요청.
- **bridge notification 은 fire-and-forget**: 발신 실패가 파이프라인을 차단하면 안 됨. OMX 의 `|| true` 패턴 채택.
- **bash 직역 거부**: 원본 harness 의 `route-task.sh` 를 직역하지 않고, `select-model.sh` + `routing.json` 으로 데이터/로직 분리. 같은 결과지만 LLM 이 reasoning 을 routing.json 으로 위임 가능.
