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

## 참고

- [Q00/ouroboros](https://github.com/Q00/ouroboros) — Ambiguity Score 4차원 가중 영감 (단, ohmyclaw 의 갭 5유형은 자체 분류)
- [OpenClaw Telegram inline keyboards](https://docs.openclaw.ai/channels/telegram) — buttons 2D 배열 + callback_data 메커니즘
- [prompts/reviewer.md](../prompts/reviewer.md) — 우로보로스 5관점 + 갭 감지 (본 릴리즈에서 변경 없음)
