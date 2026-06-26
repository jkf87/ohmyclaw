# Interactive Ask Flow — 4 Anchors (v1.5.0+)

ohmyclaw v1.5.0 부터 모호한 결정 지점에서 사용자에게 **구조화 선택지 질문(1/2/3 + Other 텔레그램 인라인 키보드)** 을 발동할 수 있다. 4 앵커 중 1-3 은 자동 트리거되며, prompts/reviewer.md 본문은 변경되지 않는다(우로보로스 정합).

## 아키텍처 다이어그램

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 사용자 입력 (cli.sh <verb>)                                              │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │  cli.sh                                                          │    │
│  │                                                                  │    │
│  │   _run_verb()                                                    │    │
│  │     ├─ prefetch: OHMYCLAW_LAST_ANSWER (state.sh recent, TTL 3600) │    │
│  │     ├─ pre-<verb> hook                                            │    │
│  │     │                                                            │    │
│  │     ├─ cmd_exec  ──┐                                              │    │
│  │     │              ├─ Anchor 3: ambiguity.sh gate                 │    │
│  │     │              │   score>0.2 → cli.sh ask (3 옵션 + Other)    │    │
│  │     │              └─ state.sh write last-exec-intent              │    │
│  │     │                                                            │    │
│  │     ├─ cmd_plan_gate ──┐                                          │    │
│  │     │                  ├─ Anchor 1: planner output ask_required?  │    │
│  │     │                  │   true → cli.sh ask                      │    │
│  │     │                  └─ 응답에 따라 architect/critic 진행         │    │
│  │     │                                                            │    │
│  │     ├─ cmd_gap_gate ──┐                                           │    │
│  │     │                 ├─ Anchor 2: reviewer GAP_DETECTED?         │    │
│  │     │                 │   true → cli.sh ask (apply/ignore/other)  │    │
│  │     │                 └─ action: fix-loop/force-approve/escalated │    │
│  │     │                                                            │    │
│  │     ├─ cmd_ask ──────┐                                            │    │
│  │     │                ├─ openclaw message send --buttons '<JSON>'  │    │
│  │     │                ├─ events_wait → callback_data: <val>        │    │
│  │     │                ├─ __other__ → free-text 수신                  │    │
│  │     │                └─ state.sh write last-ask-answer            │    │
│  │     │                                                            │    │
│  │     └─ post-<verb> hook + skill-active cleanup (trap)             │    │
│  └──────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
              │
              ▼
   ┌───────────────────────────────────────┐
   │ OpenClaw Telegram bridge               │
   │   ┌─ inline_keyboard JSON 렌더링        │
   │   └─ user click → callback_data: <val> │
   └───────────────────────────────────────┘
```

## 4 Anchors

| # | 앵커 | 트리거 | 발동 위치 | 옵션 출처 |
|---|------|--------|-----------|-----------|
| 1 | **Planner gate** | planner LLM 출력에 `"ask_required":true` | `cli.sh plan-gate` | planner 가 제안한 해석들 |
| 2 | **GAP_DETECTED** | reviewer verdict == `GAP_DETECTED` | `cli.sh gap-gate` (오케스트레이터 단) | apply-fix / ignore-gap / Other |
| 3 | **Vague exec** | `ambiguity.sh gate` exit 11 (score>0.2) | `cli.sh exec` 자동 | 3 generic 해석 + Other |
| 4 | **Destructive op** | 위험 동작(rm -rf, git push -f, db drop) | OpenClaw `permissions_*` API (기존) | allow-once / allow-always / deny |

> Anchor 4 는 OpenClaw가 이미 처리. ohmyclaw 신규 추가는 1-3.

## Ambiguity Score 공식

Ouroboros 의 4차원 가중 명확성 점수에서 영감:

```
Ambiguity = 1 - Σ(clarity_i × weight_i)

clarity_i ∈ [0, 1]:
  • goal        — 길이 ≥ 15자 (0.4) + 동사 (0.4) + 명사구 (0.2)
  • constraint  — must/should/stack/within/까지/내로/제약 (1.0/0.0)
  • success     — test/pass/criteria/DoD/통과/완료조건 (1.0/0.0)
  • context     — file path / function() / repo path (anchor 0:0, 1:0.5, 2+:1.0)

weights: goal 0.35, constraint 0.25, success 0.25, context 0.15

threshold (기본 0.2): score > threshold → "ambiguous", ask 발동
```

LLM 호출 없는 결정론 휴리스틱 — 매 verb 진입에 부담 없이 동작.

## 사용 예시

### 직접 호출 (Anchor 별 invoke)

```bash
# Anchor 3: 모호한 task → 자동 ask
cli.sh exec "이거 해줘" --to $CHAT_ID
# → ambiguity score>0.2 → 3 옵션 + Other 발동
# 사용자 선택 후 last-exec-intent 에 저장 + route → 모델 결정

# Anchor 1: planner 출력 파이프
cli.sh plan "API 마이그레이션" | cli.sh plan-gate --to $CHAT_ID
# → planner가 ask_required 출력하면 자동 발동, 응답 후 architect 단계

# Anchor 2: reviewer 출력 파이프  
echo "$REVIEWER_VERDICT_JSON" | cli.sh gap-gate --to $CHAT_ID
# → GAP_DETECTED 면 자동 발동, action 으로 다음 단계 결정
```

### 명시 호출 (커스텀 질문)

```bash
cli.sh ask \
  --to $CHAT_ID \
  --question "어떤 DB 쓸까?" \
  --option 1:"PostgreSQL (관계형)" \
  --option 2:"MongoDB (문서)" \
  --option 3:"Redis (KV)" \
  --other \
  --timeout 120 \
  --recommended 1 \
  --save-as db-choice
```

응답은 `last-ask-answer`(또는 `--save-as` 키) 에 자동 저장:
```json
{"value":"2","ts":"2026-05-26T...","savedBy":"ask"}
```

후속 verb 는 prefetch 로 자동 접근:
```bash
cli.sh route "MongoDB schema 설계"   # OHMYCLAW_LAST_ANSWER="2" env 자동 export
```

## 옵트아웃 / 환경변수

| 환경변수 | 효과 |
|---------|------|
| `OHMYCLAW_SKIP_AMBIGUITY=true` | `cli.sh exec` 의 Anchor 3 자동 발동 비활성 |
| `OHMYCLAW_ASK_MOCK=1` | ask 가 실제 openclaw 호출 안 함 (DRY_RUN_JSON 출력) |
| `OHMYCLAW_ASK_MOCK_RESPONSE=<val>` | ask 응답 시뮬레이션 (테스트용) |
| `OHMYCLAW_EXEC_MOCK_RESPONSE=<val>` | exec 의 inner ask 응답 우회 |
| `OHMYCLAW_PLAN_MOCK_RESPONSE=<val>` | plan-gate 의 inner ask 응답 우회 |
| `OHMYCLAW_GAP_MOCK_RESPONSE=<val>` | gap-gate 의 inner ask 응답 우회 |

## 우로보로스 정합

- `prompts/reviewer.md` 본문 100% 보존 — Stage 5 갭 5유형 + GAP_DETECTED→fix 1회→ESCALATED 흐름 불변
- gap-gate 는 **오케스트레이터 레벨**에서만 동작 (SKILL.md §7-6-1)
- 사용자 응답에 따른 분기:
  - `apply-fix` → 기존 fix loop 1회 후 재리뷰
  - `force-approve` → verdict 를 APPROVE 로 처리 (사용자 명시 override)
  - `escalated` / Other → 기존 ESCALATED 흐름 (사용자 자유 답변)

## 테스트 커버리지

| 슈트 | 케이스 수 | 검증 영역 |
|------|----------|-----------|
| `ask.bats` | 23 | JSON 컴파일 / dry-run / save-as / prefetch / timeout |
| `ambiguity.bats` | 18 | 4차원 가중 점수 / gate / threshold override |
| `plan-gate.bats` | 13 | ask_required 파싱 / 옵션 컴파일 / pass-through |
| `gap-gate.bats` | 10 | GAP_DETECTED 분기 / reviewer.md 불변 검증 |
| `cli.bats` (exec) | 7 | ambiguity 게이트 / SKIP_AMBIGUITY / mock 응답 |
| `state.bats` (recent) | 6 | TTL stale / 누락 / 잘못된 ttl |
| **합계** | **77 신규** | 기존 121 회귀 0건 + 198 전체 PASS |

## Socratic Interview (v1.6.0)

`cli.sh interview [topic]` 는 Q00/ouroboros 의 Socratic 인터뷰("질문은 모호성 ≤ 0.2 까지")를 ohmyclaw 4차원 명확성 위에 이식한 것이다.

```
topic ──▶ ambiguity.sh score ──▶ ambiguous?  ──no──▶ 종료(이미 명확)
                  ▲                    │yes
                  │                    ▼
        crystallized 누적      가장 약한(미충족) 차원의 Socratic 질문
                  │              (interview.json: goal/constraint/success/context)
                  │                    │
                  │              cmd_ask → presentation 버튼 (1/2/3 + ✏️ Other)
                  │                    │
                  └──── 응답 → crystallize 절 누적 ◀──┘
                                       │
                  score ≤ threshold(0.2) 도달 → interview-result state 저장
```

- 질문 뱅크: `interview.json` (LLM 호출 없는 결정론). 각 옵션의 crystallize 절은 `ambiguity.sh` 차원 키워드(구현/제약/스택/통과/완료조건/`src/` 등)를 자연스럽게 포함하여 응답 누적 시 점수가 결정론적으로 개선된다.
- 조기 종료: 매 라운드 재채점하여 `ambiguous=false` 이면 즉시 중단(우로보로스 정합). 이미 명확한 차원은 건너뛴다.
- 결과: `state.sh write interview-result`(또는 `--save-as <key>`). 후속 `exec`/`plan` 이 prefetch.
- **정직성 (v1.7.2)**: 실 모드에서 버튼 응답을 못 받으면(openclaw 부재/버전불일치/`events wait` 미지원/유효 chatId 누락) 각 질문은 `recommended` 로 폴백한다. 이때 결과에 `degraded:true` + `fallbackCount` + 답변별 `fallback:true` 를 기록하고 stderr 로 명확히 경고한다 — "조용한 가짜 성공"을 방지. 폴백이 없는 정상 인터뷰는 `degraded:false`. 실제 버튼 인터랙션은 올바른 openclaw PATH + `--to <chatId>` + 에이전트 컨텍스트(비동기 콜백)에서만 동작.
- 테스트 모드: `OHMYCLAW_INTERVIEW_MOCK_RESPONSES="feature,no-break,tests,module"` (질문당 1개, 순서대로 소비; mock 응답은 `fallback:false`).

## Telegram 슬래시 명령어 (v1.6.0)

`cli.sh commands` — 매니페스트(`commands.json`) 기반 슬래시 명령어 관리.

| 하위명령 | 동작 |
|---------|------|
| `list` | 명령 ↔ verb 매핑 표 |
| `json` | Telegram setMyCommands API 페이로드 |
| `botfather` | @BotFather 붙여넣기 형식 (`cmd - desc`) |
| `register [--to]` | setMyCommands JSON + 적용 가이드 출력 (openclaw 전용 CLI 없음) |
| `dispatch "<인바운드 /명령>" [--to]` | `/omc_exec ...`·`/exec ...`·`/ohmyclaw exec ...`·`@botname` → verb 라우팅 |
| `menu [--to]` | 명령 팔레트를 **버튼**으로 발화 (`action.type="command"` → 네이티브 슬래시 실행) |

`omc_` 네임스페이스로 `/hud` 등과 충돌 방지 + 친근한 alias 인식. 테스트 모드: `OHMYCLAW_COMMANDS_MOCK=1`.

## openclaw Presentation API (v1.6.0 BREAKING fix)

v1.6.0 부터 모든 버튼은 실제 openclaw 2026.6.6 의 **`message send --presentation`** (`MessagePresentation`) 으로 발화한다. v1.5.0 의 `--buttons {inline_keyboard}` 는 현재 openclaw 가 인식하지 않으므로("OpenClaw does not recognize option --buttons") 실제 런타임에서 전송 실패 상태였다.

```jsonc
// ask/interview 선택지 (callback)
{ "blocks": [
  { "type": "text", "text": "<질문>" },
  { "type": "buttons", "buttons": [
    { "label": "PostgreSQL", "action": { "type": "callback", "value": "1" } },
    { "label": "✏️ Other (type answer)", "action": { "type": "callback", "value": "__other__" } }
  ] }
] }

// commands menu (네이티브 슬래시 실행)
{ "blocks": [ { "type": "buttons", "buttons": [
  { "label": "/omc_interview", "action": { "type": "command", "command": "/omc_interview" } }
] } ] }
```

> **응답 폴링 한계**: openclaw 2026.6.6 에는 동기 `events wait` CLI 가 없다. 버튼 콜백은 비동기로 에이전트 턴에 재진입되는 것이 정석이며, `cmd_ask` 의 CLI 폴링은 부재 시 `--recommended`/timeout 으로 graceful degrade 한다.

## 참고

- [Q00/ouroboros](https://github.com/Q00/ouroboros) — Socratic 인터뷰 + Ambiguity Score 4차원 가중 영감 (단, ohmyclaw 의 갭 5유형은 자체 분류)
- [OpenClaw MessagePresentation](https://docs.openclaw.ai/cli) — `message send --presentation` (text/context/divider/buttons/selects 블록 + callback/command action)
- [prompts/reviewer.md](../prompts/reviewer.md) — 우로보로스 5관점 + 갭 감지 (본 릴리즈에서 변경 없음)
