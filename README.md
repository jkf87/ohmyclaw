# 🦞 ohmyclaw

> OpenClaw 용 멀티프로바이더/멀티계정 에이전트 하네스 스킬

Z.ai 코딩플랜(Lite/Pro/Max) + ChatGPT Codex OAuth + **OpenRouter** (200+ 모델) 다중 계정을 하나의 스킬로 라우팅하고, OMX 스타일 composable verbs (`/ohmyclaw exec`, `/ohmyclaw team`, `/ohmyclaw ralph`, `/ohmyclaw plan`, `/ohmyclaw review`, `/ohmyclaw debug`, `/ohmyclaw`)로 작업을 실행합니다.

[![Release](https://img.shields.io/github/v/release/jkf87/ohmyclaw)](https://github.com/jkf87/ohmyclaw/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Quick Install

### 원라인 설치

```bash
bash <(curl -sL https://raw.githubusercontent.com/jkf87/ohmyclaw/main/install.sh)
```

### 수동 설치

```bash
git clone https://github.com/jkf87/ohmyclaw.git
ln -sfn "$(pwd)/ohmyclaw/skills/ohmyclaw" ~/.openclaw/skills/ohmyclaw
```

### OpenClaw 에이전트에게 설치 시키기

아무 채널(Telegram/Discord/Web)에서 이 프롬프트를 복붙하세요:

> ohmyclaw 스킬을 설치해줘. https://github.com/jkf87/ohmyclaw 클론하고 skills/ohmyclaw 디렉토리를 ~/.openclaw/skills/ohmyclaw 에 심볼릭 링크 걸어줘. 끝나면 /ohmyclaw 실행해서 HUD 보여줘.

### 설치 확인

```
/ohmyclaw
```

## 슬래시 명령어

| 명령어 | 자연어 | 역할 |
|--------|--------|------|
| **`/ohmyclaw`** | "대시보드" "상태 보여줘" | 플랜/계정/quota/모델 대시보드 |
| `/ohmyclaw compact` | "상태 한 줄" | `🦞 PRO \| zai:1 \| codex:off \| 0%` |
| `/ohmyclaw route <task>` | "이거 어떤 모델?" | 라우팅 결정 JSON |
| `/ohmyclaw pool` | "계정 상태" | 풀 + cooldown 표 |
| `/ohmyclaw doctor` | "점검해줘" | 10항목 점검 |
| `/ohmyclaw exec <task>` | "이거 해줘" | 자율 실행 (executor.md) |
| `/ohmyclaw plan <task>` | "계획 세워줘" | 계획 수립 (planner.md) |
| `/ohmyclaw plan --consensus` | "합의해서 계획" | planner→architect→critic 합의 |
| `/ohmyclaw review` | "리뷰 좀" | 5관점 리뷰 + 갭 감지 |
| `/ohmyclaw team N <task>` | "3명이서 해" | 병렬 워커 |
| `/ohmyclaw ralph <task>` | "끝까지 해" | 끝까지 루프 (executor+verifier) |
| `/ohmyclaw debug <task>` | "버그 잡아" | 4단계 RCA |

## HUD 대시보드

```
🦞 ohmyclaw HUD  2026-04-11 22:53
─────────────────────────────────────────
Plan  PRO ($15/월)  Workers: 4
Tokens    0K / 8M  ██░░░░░░░░░░░░░░░░░░░░ 0%
Requests  0 / 3000 ██░░░░░░░░░░░░░░░░░░░░ 0%
─────────────────────────────────────────
Accounts
zai        ● zai-primary        oauth_zai plan=pro
           ○ zai-secondary      api_key plan=lite
codex      (disabled)
openrouter (disabled)  ← NEW
─────────────────────────────────────────
Models   glm-5-turbo, glm-5, glm-5.1, +OpenRouter 200+
```

## 멀티프로바이더 라우팅

### 지원 모델 (공식 벤치마크 기준)

| 모델 | SWE-Bench Pro (코딩) | GPQA Diamond (추론) | AIME 2025/26 (수학) | 확장사고 | 플랜 |
|------|---------------------|--------------------|--------------------|---------|------|
| **GLM-5 Turbo** | — | — | — | — | Lite / Pro / Max |
| **GLM-5** | — | 86.0 | 84.0 | — | Lite / Pro / Max |
| **GLM-5.1** | **58.4** (1위) | 86.2 | 95.3 | ⚡ 지원 | Pro / Max |
| **GPT-5.4** | 57.7 | **92.8** | **100** | ⚡ 지원 | ChatGPT 구독 (OAuth) |
| **OpenRouter** | 다양 | 다양 | 다양 | 모델별 | API 키 (무료+유료) |

> ⚡ **확장 사고(extended thinking)**: 복잡한 추론이 필요한 태스크에서 더 깊이 생각하는 모드.
>
> 🆕 **OpenRouter** 경유로 Claude Opus 4, DeepSeek R1, Gemini 2.5 Pro, Qwen3 235B 등 200+ 모델에 단일 API 키로 접근 가능. 무료 모델(Llama 3.3 70B, Qwen 2.5 72B 등)도 지원.
>
> **GLM-5.1** 은 SWE-Bench Pro 코딩 벤치마크 **세계 1위** (GPT-5.4, Claude Opus 4.6 을 앞섬). **GPT-5.4** 는 GPQA Diamond 추론 + AIME 수학에서 최고점. 한국어 전용 벤치마크는 현재 공식 발표 없음.
>
> 출처: [MarkTechPost](https://www.marktechpost.com/2026/04/08/z-ai-introduces-glm-5-1-an-open-weight-754b-agentic-model-that-achieves-sota-on-swe-bench-pro-and-sustains-8-hour-autonomous-execution/) · [Artificial Analysis](https://artificialanalysis.ai/models/gpt-5-4) · [BenchLM](https://benchlm.ai/models/glm-5-1)

### Z.ai 코딩플랜

| 플랜 | 가격 | 모델 | 일일 토큰 | 동시 워커 |
|------|------|------|-----------|-----------|
| **Lite** | $3/월 | GLM-5 Turbo, GLM-5 | 1.5M | 2 |
| **Pro** | $15/월 | + GLM-5.1 | 8M | 4 |
| **Max** | $30/월 | 풀 모델 + 우선 슬롯 | 25M | 7 |

가입: https://z.ai/subscribe?ic=OTYO9JPFNV

```bash
export ZAI_CODING_PLAN=pro                # lite | pro | max
export CODEX_OAUTH_ENABLED=true           # ChatGPT 구독 보유 시
export OPENROUTER_ENABLED=true            # OpenRouter 경유 외부 모델 사용
export OPENROUTER_API_KEY=sk-or-...       # openrouter.ai 에서 발급
export OPENROUTER_PREFER_FREE=true        # 무료 모델 우선 (선택)
```

### OpenRouter 연동

[OpenRouter](https://openrouter.ai) 를 경유로 200+ 외부 모델에 단일 API 키로 접근합니다. Z.ai / Codex 와 독립적으로 작동하며, codex 활성 시 codex 가 우선됩니다.

#### 지원 OpenRouter 모델

| 모델 | 용도 | 비용 | 특징 |
|------|------|------|------|
| **Claude Opus 4** | 코딩/보안 HIGH | 유료 | 확장사고, 코딩 95점 |
| **DeepSeek R1** | 추론/수학 HIGH | 유료 | 추론 96점, 수학 최강 |
| **Gemini 2.5 Pro** | 데이터 분석 HIGH | 유료 | 1M 컨텍스트, 멀티모달 |
| **Qwen3 235B** | 한국어 NLP | 유료 | 한국어 90점, 비용 효율 |
| **Qwen 2.5 72B** | 한국어 일반 | 무료 | 한국어 85점, 무료 최강 |
| **Llama 3.3 70B** | 범용 | 무료 | 131K 컨텍스트 |
| **Gemma 3 27B** | 경량 작업 | 무료 | Google Gemma 3 |
| **Mistral 7B** | 초경량 | 무료 | 단순 작업용 |

#### 설정

```bash
# 1. API 키 발급: https://openrouter.ai/keys
export OPENROUTER_API_KEY="sk-or-..."

# 2. routing.json 에서 openrouter 풀 활성화:
#    accounts.pools.openrouter.accounts[0].enabled = true

# 3. 환경변수 설정
export OPENROUTER_ENABLED=true

# (선택) 무료 모델 우선 배정
export OPENROUTER_PREFER_FREE=true
```

#### 라우팅 우선순위

1. **Z.ai matrix** (P75) — 기본 라우팅
2. **Codex overlay** (P80) — GPT-5.4 격상
3. **Claude Code CLI overlay** (P79.5) — 실험적 Claude delegation (⚠️ EXPERIMENTAL)
4. **OpenRouter overlay** (P79) — 외부 모델 오버레이 (codex 다음 우선)
5. **OpenRouter Free overlay** (P78) — 무료 모델 우선 (PREFER_FREE 시)

> codex + openrouter 동시 활성 시 codex 가 우선입니다. HIGH 복잡도 작업은 무료 모델을 건너뛰고 유료 모델로 위임합니다.

### Claude Code CLI Delegation (⚠️ EXPERIMENTAL)

> **실험적 기능 — 기본 비활성 — 언제든 제거 가능**
>
> 공식 Claude Code CLI delegation 만 사용합니다. 직접 OAuth 토큰 주입 없음.
> Anthropic 의 CLI delegation 정책이 변경되면 이 경로는 차단되거나 제거될 수 있습니다.

활성화 시 `reasoning`, `coding_arch`, `security` 카테고리의 HIGH 복잡도 작업만 Claude Code CLI 로 위임합니다.

#### 설정

```bash
# 1. claude CLI 설치 및 로그인
claude login

# 2. 환경변수 설정
export CLAUDECLI_DELEGATION_ENABLED=true

# 3. routing.json 에서 풀 활성화:
#    accounts.pools.claudecli.accounts[0].enabled = true
```

#### 비활성화

```bash
unset CLAUDECLI_DELEGATION_ENABLED
# 또는
export CLAUDECLI_DELEGATION_ENABLED=false
```

> 비활성 시 기존 ohmyclaw 라우팅(GLM-5.1 등)으로 자동 폴백됩니다.

### 추론 인식

증명, 알고리즘, 복잡도, 불변조건 같은 **추론 집약 키워드**가 감지되면 추론 점수가 가장 높은 모델로 자동 격상합니다:

| 조건 | 선택 모델 | 추론 점수 |
|------|-----------|-----------|
| 추론 집약 + ChatGPT 구독 활성 | **GPT-5.4** | 97 |
| 추론 집약 + Pro/Max 플랜 | **GLM-5.1** | 95 |
| 추론 집약 + Lite 플랜 | GLM-5 (상한) | 82 |

### 다중 계정 풀

Z.ai + ChatGPT OAuth 계정을 **제한 없이** 추가할 수 있습니다. 순환 배분(round-robin)으로 rate limit 을 분산하고, 한 계정이 제한에 걸리면 자동으로 다음 계정으로 전환됩니다 (대기 시간 60초 → 최대 600초 점진 증가). 여러 계정에 동시 발사(fan-out)도 가능합니다.

#### ChatGPT 계정 추가 방법

```bash
# 1. 계정별로 별도 디렉토리에 OAuth 로그인
codex login                              # 기본 (~/.codex)
CODEX_HOME=~/.codex-acct2 codex login    # 2번째
CODEX_HOME=~/.codex-acct3 codex login    # 3번째
CODEX_HOME=~/.codex-acct4 codex login    # 원하는 만큼

# 파일이 없다고 오류나면(예시 3번째)
mkdir -p ~/.codex-acct3 && CODEX_HOME=~/.codex-acct3 codex login


# 2. routing.json 에 계정 추가 (skills/ohmyclaw/routing.json)
#    accounts.pools.codex.accounts 배열에 항목 추가:
#    { "id": "codex-acct3", "authType": "oauth_codex", "codexHome": "~/.codex-acct3", "weight": 10, "enabled": true }

# 3. 확인
skills/ohmyclaw/pool.sh status codex
```

> **계정 수 제한 없음.** ChatGPT Plus($20/월) 또는 Pro($200/월) 구독 1개 = OAuth 토큰 1개. 구독 5개면 5계정 풀 가능. `pool.sh` 가 전부 round-robin 으로 순환합니다.

#### Z.ai 계정 추가

```bash
# 보조 API 키 발급 후 환경변수 등록
export ZAI_API_KEY_2="zai_..."

# routing.json 에서 zai-secondary 의 enabled 를 true 로 변경
# 팀 Max 계정도 동일하게 추가 가능
```

#### OpenRouter 계정 추가

OpenRouter 계정은 1개 API 키로 200+ 모델 접근이 가능하므로, 별도 다중 계정이 필요하지 않습니다. `OPENROUTER_API_KEY` 하나로 충분합니다.

#### 풀 관리 명령어

```bash
# 계정 상태
skills/ohmyclaw/pool.sh status

# round-robin 픽
skills/ohmyclaw/pool.sh next glm-5.1

# rate limit 걸렸을 때 cooldown 마킹
skills/ohmyclaw/pool.sh cooldown codex-acct3

# cooldown 해제
skills/ohmyclaw/pool.sh release codex-acct3

# 전체 상태 리셋
skills/ohmyclaw/pool.sh reset
```

## Composable Verbs (OMX 스타일)

oh-my-codex(OMX) 의 verb + prompt 패턴을 채택. 고정 파이프라인 대신 사용자가 동사를 선택하고, 각 동사가 `prompts/` 의 role prompt 를 합성합니다.

| 동사 | 합성 Prompts |
|------|-------------|
| `$ohmyclaw exec` | executor.md |
| `$ohmyclaw team N:executor` | team-orchestrator.md + N × team-executor.md |
| `$ohmyclaw ralph` | executor.md + verifier.md 루프 |
| `$ohmyclaw plan --consensus` | planner.md → architect.md → critic.md |
| `$ohmyclaw review` | reviewer.md (5관점 + 갭 감지) |
| `$ohmyclaw debug` | debugger.md (4단계 RCA) |

### 5관점 리뷰 + 갭 감지

1. **Spec compliance** — 요구사항 커버
2. **Security (OWASP)** — 비밀 키, injection, auth
3. **Quality** — 로직, 에러 핸들링, SOLID
4. **Maintainability** — 명명, 복잡도
5. **Gap detection** — assumption_injection / scope_creep / direction_drift / missing_core / over_engineering

## 트러블슈팅

### GLM-5.1 (reasoning 모델) 타임아웃

GLM-5.1 은 **확장 사고(extended thinking)** 로 응답 시간이 길어, OpenClaw 기본 타임아웃(120초)을 초과할 수 있습니다.

**증상:**
```
[agent] Profile zai:default timed out. Trying next account...
[model-fallback] decision=candidate_failed requested=zai/glm-5.1 reason=timeout next=zai/glm-5
```

**해결:** `agents.defaults.timeoutSeconds` 를 300초(5분)로 증설하세요.

OpenClaw 에이전트에게 이렇게 요청하면 됩니다:

> OpenClaw 설정에서 agents.defaults.timeoutSeconds 를 300으로 변경해줘. reasoning 모델 타임아웃 때문이야.

또는 직접 설정:
```bash
# openclaw.json 에 추가/수정
"agents": {
  "defaults": {
    "timeoutSeconds": 300
  }
}
```

> 💡 **권장값:** 300초. 복잡한 추론 태스크는 2~3분 소요될 수 있습니다.

---

## 파일 구조

```
skills/ohmyclaw/
├── SKILL.md            (820줄)  14 섹션
├── routing.json        (380줄)  모델/플랜/매트릭스/계정 단일 소스 (+OpenRouter)
├── select-model.sh     (370줄)  jq 라우터 (+OpenRouter overlay)
├── pool.sh             (305줄)  계정 풀 매니저 (+OpenRouter/ClaudeCLI 풀)
├── claude-delegate.sh  (58줄)   실험적 Claude Code CLI delegation 헬퍼
├── hud.sh              (370줄)  대시보드 (+OpenRouter 섹션)
└── prompts/            (1165줄) 10 role prompts (OMX MIT 카피 + 통합)
    ├── executor.md, planner.md, architect.md
    ├── reviewer.md (5관점), verifier.md, debugger.md, critic.md
    ├── team-orchestrator.md, team-executor.md
    └── README.md
```

레거시 bash 하네스 자산 (`scripts/`, `agents/`, `routing/`, `orchestration/`)은 하위 호환으로 유지됩니다.

## 출처

- [oh-my-codex (OMX)](https://github.com/Yeachan-Heo/oh-my-codex) — prompts XML contract, verb 패턴 (MIT)
- [OpenClaw](https://github.com/openclaw/openclaw) — 스킬 포맷, zai-provider, pi 엔진
- [pi (Mario Zechner)](https://github.com/badlogic/pi-mono) — 코어 에이전트 엔진
- oh-my-claudecode (OMC) — ralph/team/deep-interview 컨셉
- 우로보로스 하네스 — 갭 감지 5유형

## 라이선스

MIT

---

# 🦞 ohmyclaw (English)

> Multi-provider / multi-account agent harness skill for OpenClaw

Routes tasks across Z.ai Coding Plans (Lite/Pro/Max) + ChatGPT Codex OAuth + **OpenRouter** (200+ models) + **Claude Code CLI** (experimental) through a single skill, with OMX-style composable verbs (`/ohmyclaw exec`, `/ohmyclaw team`, `/ohmyclaw ralph`, `/ohmyclaw plan`, `/ohmyclaw review`, `/ohmyclaw debug`).

## Quick Install

```bash
# One-liner
bash <(curl -sL https://raw.githubusercontent.com/jkf87/ohmyclaw/main/install.sh)

# Manual
git clone https://github.com/jkf87/ohmyclaw.git
ln -sfn "$(pwd)/ohmyclaw/skills/ohmyclaw" ~/.openclaw/skills/ohmyclaw
```

## Slash Commands

| Command | Description |
|---------|-------------|
| **`/ohmyclaw`** | Plan/account/quota/model dashboard |
| `/ohmyclaw route <task>` | Routing decision JSON |
| `/ohmyclaw pool` | Account pool + cooldown status |
| `/ohmyclaw doctor` | 10-point preflight check |
| `/ohmyclaw exec <task>` | Autonomous execution |
| `/ohmyclaw plan <task>` | Task planning |
| `/ohmyclaw plan --consensus` | Planner → Architect → Critic consensus |
| `/ohmyclaw review` | 5-aspect review + gap detection |
| `/ohmyclaw team N <task>` | Parallel workers |
| `/ohmyclaw ralph <task>` | Execute-until-verified loop |
| `/ohmyclaw debug <task>` | 4-stage root cause analysis |

## Multi-Provider Routing

### Supported Models

| Model | SWE-Bench Pro (Coding) | GPQA Diamond (Reasoning) | AIME 2025/26 (Math) | Extended Thinking | Plan |
|-------|----------------------|------------------------|--------------------|-------------------|------|
| **GLM-5 Turbo** | — | — | — | — | Lite / Pro / Max |
| **GLM-5** | — | 86.0 | 84.0 | — | Lite / Pro / Max |
| **GLM-5.1** | **58.4** (#1) | 86.2 | 95.3 | ⚡ Yes | Pro / Max |
| **GPT-5.4** | 57.7 | **92.8** | **100** | ⚡ Yes | ChatGPT subscription (OAuth) |
| **OpenRouter** | Varies | Varies | Varies | Per model | API key (free + paid) |

### Z.ai Coding Plans

| Plan | Price | Models | Daily Tokens | Workers |
|------|-------|--------|-------------|---------|
| **Lite** | $3/mo | GLM-5 Turbo, GLM-5 | 1.5M | 2 |
| **Pro** | $15/mo | + GLM-5.1 | 8M | 4 |
| **Max** | $30/mo | All models + priority | 25M | 7 |

```bash
export ZAI_CODING_PLAN=pro                # lite | pro | max
export CODEX_OAUTH_ENABLED=true           # If you have a ChatGPT subscription
export OPENROUTER_ENABLED=true            # External models via OpenRouter
export OPENROUTER_API_KEY=sk-or-...       # From openrouter.ai
export OPENROUTER_PREFER_FREE=true        # Prefer free models (optional)
```

### Routing Priority

1. **Z.ai matrix** (P75) — Default routing
2. **Codex overlay** (P80) — GPT-5.4 upgrade
3. **Claude Code CLI overlay** (P79.5) — Experimental Claude delegation (⚠️ EXPERIMENTAL)
4. **OpenRouter overlay** (P79) — External model overlay
5. **OpenRouter Free overlay** (P78) — Free model preference (when PREFER_FREE)

> When Codex + OpenRouter are both active, Codex takes priority. HIGH-complexity tasks skip free models.

### Claude Code CLI Delegation (⚠️ EXPERIMENTAL)

> **Experimental — disabled by default — may be removed at any time**
>
> Uses only official Claude Code CLI delegation. No direct OAuth token ingestion.
> If Anthropic's CLI delegation policy changes, this path may be blocked or removed.

When enabled, only HIGH-complexity tasks in `reasoning`, `coding_arch`, and `security` categories are delegated to the Claude Code CLI.

#### Setup

```bash
# 1. Install and log in to claude CLI
claude login

# 2. Set environment variable
export CLAUDECLI_DELEGATION_ENABLED=true

# 3. Enable pool in routing.json:
#    accounts.pools.claudecli.accounts[0].enabled = true
```

#### Disable

```bash
unset CLAUDECLI_DELEGATION_ENABLED
# or
export CLAUDECLI_DELEGATION_ENABLED=false
```

> When disabled, falls back gracefully to existing ohmyclaw routing (GLM-5.1, etc.).

### Multi-Account Pool

Add unlimited Z.ai + ChatGPT OAuth accounts. Round-robin distributes requests; when one account hits a rate limit, it automatically switches to the next (cooldown 60s → max 600s exponential backoff). Fan-out (broadcast to all accounts) is also supported.

```bash
# Account status
skills/ohmyclaw/pool.sh status

# Round-robin pick
skills/ohmyclaw/pool.sh next glm-5.1

# Mark cooldown on rate limit
skills/ohmyclaw/pool.sh cooldown codex-acct3

# Release cooldown
skills/ohmyclaw/pool.sh release codex-acct3

# Reset all state
skills/ohmyclaw/pool.sh reset
```

## File Structure

```
skills/ohmyclaw/
├── SKILL.md            (820 lines)  14 sections
├── routing.json        (380 lines)  Models/plans/matrix/accounts single source
├── select-model.sh     (370 lines)  jq-based router
├── pool.sh             (305 lines)  Account pool manager
├── claude-delegate.sh  (58 lines)   Experimental Claude Code CLI delegation helper
├── hud.sh              (370 lines)  Dashboard
└── prompts/            (1165 lines) 10 role prompts (OMX-style)
    ├── executor.md, planner.md, architect.md
    ├── reviewer.md, verifier.md, debugger.md, critic.md
    ├── team-orchestrator.md, team-executor.md
    └── README.md
```

## License

MIT
