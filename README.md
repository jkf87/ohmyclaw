# 🦞 ohmyclaw

> OpenClaw 용 멀티프로바이더/멀티계정 에이전트 하네스 스킬

Z.ai 코딩플랜(Lite/Pro/Max) + ChatGPT Codex OAuth 다중 계정을 하나의 스킬로 라우팅하고, OMX 스타일 composable verbs (`/ohmyclaw exec`, `/ohmyclaw team`, `/ohmyclaw ralph`, `/ohmyclaw plan`, `/ohmyclaw review`, `/ohmyclaw debug`, `/ohmyclaw`)로 작업을 실행합니다.

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
🦞 ohmyclaw HUD  2026-04-10 13:59
─────────────────────────────────────────
Plan  PRO ($15/월)  Workers: 4
Tokens    0K / 8M  ██░░░░░░░░░░░░░░░░░░░░ 0%
Requests  0 / 3000 ██░░░░░░░░░░░░░░░░░░░░ 0%
─────────────────────────────────────────
Accounts
zai     ● zai-primary        oauth_zai plan=pro
        ○ zai-secondary      api_key plan=lite
codex   (disabled)
─────────────────────────────────────────
Models   glm-5-turbo, glm-5, glm-5.1
```

## 멀티프로바이더 라우팅

### 지원 모델

| 모델 | 코딩 | 추론 | 한국어 | 플랜 |
|------|------|------|--------|------|
| **GLM-5 Turbo** | 70 | 60 | 95 | lite/pro/max |
| **GLM-5** | 88 | 82 | 95 | lite/pro/max |
| **GLM-5.1** ⚡ | 95 | 95 | 96 | pro/max |
| **GPT-5.4** ⚡ | 97 | 97 | 72 | Codex OAuth |

⚡ = extended thinking (reasoning_mode)

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
```

### 추론 인식

추론 집약 태스크(증명/알고리즘/복잡도/불변조건) 감지 시 reasoning_score 최상위 모델로 자동 격상:

| 조건 | 모델 |
|------|------|
| reasoning_heavy + Codex | **GPT-5.4** (97) |
| reasoning_heavy + Pro/Max | **GLM-5.1** (95) |
| reasoning_heavy + Lite | GLM-5 (82, 상한) |

### 다중 계정 풀

Z.ai 3계정 + Codex OAuth 2계정 round-robin. 지수 백오프 cooldown (60s → 600s cap). Fan-out 패턴 지원.

```bash
# 계정 상태
skills/ohmyclaw/pool.sh status

# round-robin 픽
skills/ohmyclaw/pool.sh next glm-5.1

# cooldown 마킹 (rate limit hit)
skills/ohmyclaw/pool.sh cooldown zai-primary
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

## 파일 구조

```
skills/ohmyclaw/
├── SKILL.md            (820줄)  14 섹션
├── routing.json        (246줄)  모델/플랜/매트릭스/계정 단일 소스
├── select-model.sh     (277줄)  jq 라우터
├── pool.sh             (290줄)  계정 풀 매니저
├── hud.sh              (256줄)  대시보드
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
