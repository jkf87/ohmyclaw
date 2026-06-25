# Changelog

본 프로젝트는 [Keep a Changelog](https://keepachangelog.com/) 형식과 [SemVer](https://semver.org/) 를 따릅니다.

> **📝 버전 정정 노트 (2026-05-24)** — 이 파일의 아래쪽 `[1.0.0]` / `[1.1.0]` 섹션은 origin 의 공식 GitHub 릴리즈 v1.0.0 (OpenClaw Multi-Provider Harness, 2026-04-10) / v1.1.0 (OpenRouter Integration, 2026-04-11) 과 **다른 작업**이며, 본 리포 자체 일련번호로 잘못 라벨된 작업입니다. 실제로는 origin v1.3.0 (gpt-5.5 frontier, 2026-05-02) 이후의 후속 작업으로, **v1.4.0 단일 릴리즈로 통합**됩니다. 정식 GitHub 태그/릴리즈는 v1.4.0 만 유효하며 잘못 라벨된 섹션 헤더는 역사 기록 차원에서 그대로 보존합니다.

## [1.6.0] — 2026-06-26

### Added — Socratic Interview + Telegram 슬래시 명령어 (우로보로스 정합)

Q00/ouroboros 의 Socratic 인터뷰("질문은 모호성 ≤ 0.2 까지")를 ohmyclaw 4차원 명확성 위에 이식하고, 텔레그램 슬래시 명령어를 버튼으로 노출한다. 모든 버튼은 **실제 openclaw 2026.6.6 `MessagePresentation` API** 로 발화한다.

- **US-101 cli.sh `interview` verb** — 4차원(goal/constraint/success/context) Socratic 인터뷰. 각 질문을 인라인 버튼으로 발화(`cmd_ask` 재사용), 응답을 crystallize 절로 누적 → `ambiguity.sh` 재채점 → score ≤ threshold(기본 0.2) 도달 시 **조기 종료**. 이미 명확한 차원은 건너뜀. 결과를 `state.sh write interview-result`(또는 `--save-as`)에 저장 → 후속 exec/plan 이 prefetch. 질문 뱅크는 `interview.json`(LLM 호출 없는 결정론). `--to/--threshold/--max-rounds/--timeout/--save-as/--dry-run`. `OHMYCLAW_INTERVIEW_MOCK_RESPONSES` 테스트 모드. 13 interview.bats.
- **US-102 cli.sh `commands` verb** — Telegram 슬래시 명령어 매니페스트(`commands.json`). `list`(표) / `json`(setMyCommands 페이로드) / `botfather`(@BotFather 형식) / `register`(적용 가이드 출력) / `dispatch`(인바운드 `/명령` → verb 라우팅) / `menu`(명령 팔레트를 버튼으로). `omc_` 네임스페이스로 `/hud` 등 충돌 방지 + 친근한 alias(`/interview`, `/ohmyclaw interview`) + `@botname`/2토큰 인식. `OHMYCLAW_COMMANDS_MOCK` 테스트 모드. 17 commands.bats.
- **US-103 슬래시 명령어를 버튼으로** — `commands menu` 가 `action.type="command"` 버튼을 발화 → 클릭 시 채널 네이티브 슬래시 명령 경로로 실행. 인터뷰/ask 선택지는 `action.type="callback"` value.

### Changed — openclaw 버튼 API 정합 (BREAKING fix)

- **`cmd_ask` 버튼 전송을 `--buttons {inline_keyboard}` → `--presentation {blocks[buttons]}` 로 마이그레이션.** 실제 openclaw 2026.6.6 은 `--buttons` 플래그를 인식하지 않으며("OpenClaw does not recognize option --buttons"), 버튼은 `message send --presentation` 의 `MessagePresentationButtonsBlock` 으로 전달한다. v1.5.0 의 ask/exec/plan-gate/gap-gate 버튼은 mock 테스트만 통과했을 뿐 실제 런타임에서는 전송 실패 상태였음 — 본 릴리즈에서 실제 동작하도록 수정. 발화 payload 는 실 openclaw CLI `--dry-run` 으로 수락 검증.
- ask 응답값은 `action.value`(callback)로 전달되며 Telegram 64-byte callback_data 한계 검증 유지. 질문은 `MessagePresentationTextBlock` 으로 렌더.
- `ask.bats` 23케이스를 presentation 스키마로 갱신(`inline_keyboard`/`callback_data` → `type:buttons`/`action.value`). 회귀 0건.
- `SKILL.md` / `README.md` 슬래시 명령어 섹션에 `/ohmyclaw interview` + `commands` 추가. `docs/ask-flow.md` 에 인터뷰·presentation·슬래시 명령 섹션 추가.

### Notes

- **응답 폴링 한계**: openclaw 2026.6.6 에는 동기 `events wait` CLI 가 없다(기존 가정). 버튼 콜백은 비동기로 에이전트 턴에 재진입되는 것이 정석이며, `cmd_ask` 의 CLI 폴링은 부재 시 `--recommended`/timeout 으로 graceful degrade. 슬래시 명령 등록(setMyCommands)도 전용 CLI 가 없어 `commands register` 가 Bot API/@BotFather 적용 페이로드를 출력한다.
- **테스트**: bats 229 PASS (기존 198 회귀 0건 + interview 13 + commands 17 + ask 마이그레이션). `make syntax` + `make schema`(ajv) clean.

## [1.5.0] — 2026-05-26

### Added — Interactive Ask Flow (4 anchors, 우로보로스 정합)

origin v1.4.0 이후 누적된 사용자 질문 발동 메커니즘. 사용자가 1/2/3 + Other 텔레그램 인라인 키보드 버튼으로 결정 지점에서 답할 수 있게 한다. 결과적으로 Hermes/Ouroboros 스타일 "ambiguity gate" 와 정합.

- **US-001 bridge-event 스키마 v1.1.0** — `payload.options[{label,value}]`, `payload.allowOther`, `payload.timeoutSec`, `payload.recommended` 필드 추가. `ask-user-question` 타입에 대해 `options.length≥2` 조건부 강제. 기존 페이로드(summary only) 후방호환.
- **US-002 cli.sh `ask` verb** — Telegram inline keyboard 발화 + 응답 폴링. `--to/--question/--option N:label/--other/--timeout/--recommended/--save-as/--dry-run` 옵션. `OHMYCLAW_ASK_MOCK=1` + `OHMYCLAW_ASK_MOCK_RESPONSE` 테스트 모드. callback_data 응답 + `__other__` free-text 분기 + timeout fallback. 18 ask.bats(US-002) → 23(+US-007).
- **US-003 ambiguity.sh** — Ouroboros 4차원 가중 Ambiguity Score (`goal 0.35 + constraint 0.25 + success 0.25 + context 0.15`). `score` 액션은 JSON 출력, `gate` 액션은 score>0.2 시 exit 11. 휴리스틱 측정(LLM 호출 없음): 글자수/anchor/제약 키워드/DoD 키워드. 18 ambiguity.bats PASS.
- **US-004 cli.sh `exec` verb (Anchor 3)** — task 진입 시 ambiguity gate. score>0.2 시 자동 ask 발동(3 generic 해석 옵션 + Other). `OHMYCLAW_SKIP_AMBIGUITY=true` 옵트아웃. 응답 → `state.sh write last-exec-intent`. 7 cli.bats 추가.
- **US-005 cli.sh `plan-gate` verb (Anchor 1)** — `prompts/planner.md` 출력 계약 확장: planner LLM 이 다중해석 시 `ask_required:true + options[]` JSON 출력. plan-gate 가 stdin JSON 파싱 → ask 자동 발동 → `{"ask_fired":bool, ...}` 응답. 13 plan-gate.bats PASS.
- **US-006 cli.sh `gap-gate` verb (Anchor 2)** — reviewer.md `GAP_DETECTED` verdict JSON 을 stdin 으로 받아 3가지 옵션 ask 발동(apply-fix / ignore-gap / Other). 응답에 따라 `action: fix-loop|force-approve|escalated` 매핑. SKILL.md §7-6-1 orchestrator 가이드 추가. **prompts/reviewer.md 본문 UNCHANGED — 우로보로스 불변 제약 준수**. 10 gap-gate.bats PASS.
- **US-007 state.sh `recent` action + ask `--save-as` + cli prefetch** — TTL 기반 stale 무시 (mtime ≤ ttl 이내만 출력). ask 가 응답을 자동으로 state 에 저장(기본 `last-ask-answer`, `--save-as <key>` 커스텀). `_run_verb` 가 모든 verb 진입 시 `OHMYCLAW_LAST_ANSWER` env export (TTL 3600s). 후속 verb / 사용자 hook 이 prefetch 활용. 6 state.bats + 5 ask.bats 추가.
- **US-008 통합 테스트** — bats 198 PASS (목표 145+ 큰 폭 초과). 기존 v1.4.0 121 케이스 회귀 0건. shellcheck `-S warning` clean. `make ci` ✅ all gates. 슈트별: state(27) + ambiguity(18) + ask(23) + cli(25) + e2e(7) + engine(20) + gap-gate(10) + hooks(11) + mcp(6) + plan-gate(13) + pool(17) + select-model(21) = 198.

### Changed

- `prompts/planner.md` — "Ambiguity output contract" 섹션 추가 (LLM 출력 약속). 본문 흐름 무변경.
- `SKILL.md` — 신규 §7-6-1 (gap-gate orchestrator) + 별도 §Interactive Ask Flow 섹션.

### Fixed

- **engine.bats fragility** — `OHMYCLAW_ENGINE_FALLBACK=false errors when forced engine absent` 케이스가 호스트에 omp(`~/.bun/bin/omp`)가 실재할 때 비결정적. PATH 스크럽으로 deterministic 화. CI 는 영향 없었으나 로컬 개발자 환경에서 회귀.

### Constraint — 우로보로스 불변 검증

`prompts/reviewer.md` 본문은 본 릴리즈에서 한 글자도 변경되지 않음. GAP_DETECTED → ask 매핑은 *오케스트레이터 레벨*(SKILL.md §7-6-1)에서만 동작. Stage 5 갭 5유형 + fix1 → ESCALATED 흐름 100% 보존.

[1.5.0]: https://github.com/jkf87/ohmyclaw/compare/v1.4.0...v1.5.0

## [1.4.0] — 2026-05-24

origin v1.3.0 (gpt-5.5 frontier routing) 이후의 누적 작업을 정식 릴리즈로 통합. 본 릴리즈는 잘못 라벨됐던 1.0.0/1.1.0/1.2.0 세 commit (engine ACP 이식 + robustness P1-P7 + 범용 하네스 격상) 의 합본입니다.

### Added — 범용 하네스 격상 (자체 Runtime, 8 user stories)

- **US-001 state.sh** — 자체 세션 격리 state helper (OMC `state_*` 인터페이스 모방).
  - 액션: `read/write/clear/list-active/get-status/path/reset`.
  - 경로: `${OHMYCLAW_HOME:-~/.ohmyclaw}/state/sessions/<id>/<key>.json` (글로벌 fallback 지원).
  - `flock` + atomic `mv` 동시성 안전 (macOS portable mkdir-lock 폴백).
  - 21 bats 케이스 PASS (격리/잠금/CRUD/`reset --all`/잘못된 key 거부/10 병렬 race).

- **US-002 hooks.sh** — pre/post 훅 디스패처.
  - `${OHMYCLAW_HOME}/hooks/{pre,post}-<verb>.sh` 자동 발화.
  - 훅에 env export: `OHMYCLAW_ACTION/PHASE/SESSION/HOME/ARGS/ARGS_JSON`.
  - 정책: pre 실패 → exit 7 (action abort), post 실패 → 경고만 (비차단).
  - 11 bats 케이스 PASS.

- **US-003 cli.sh** — verb 통합 디스패처 + skill-active 라이프사이클.
  - verb: `doctor/route/pool/engine/state/hooks/cancel/version/help`.
  - 각 verb 진입 시 pre 훅 + skill-active state 작성, 종료 시(trap EXIT/INT/TERM) post 훅 + cleanup.
  - 18 bats 케이스 PASS (각 verb proxy + lifecycle + pre exit 7 abort).
  - 버그픽스: `[[ ]] && return` 후 `$?` 캡쳐 오류 → trap 첫 줄로 이동.

- **US-004 mcp-server.ts** — MCP 서버 (Node 22 / TypeScript / `@modelcontextprotocol/sdk` 1.29).
  - 아키텍처: `McpServer` + `registerTool` 신 API + zod 스키마.
  - 도구 5종: `ohmyclaw_route / ohmyclaw_pool_status / ohmyclaw_engine_resolve / ohmyclaw_doctor / ohmyclaw_version`.
  - `tsc --noEmit` strict 통과, `dist/mcp-server.js` 산출 (7565B).
  - 6 mcp.bats 케이스 PASS (initialize 핸드셰이크, tools/list 5개, 2종 tools/call, isError, schema 검증).

- **US-005 cancel** — orphan cleanup + 우로보로스 정합.
  - `cli.sh cancel [--force]` 으로 노출. skill-active 청소 + pool sweep (dead PID 슬롯) + 세션 state reset + cancel-signal 발신.
  - `--force` 시 전체 세션 일괄.
  - 4 cli.bats 케이스 PASS (skill-active 청소 / cancel-signal / dead PID sweep / `--force` 전체 청소).

- **US-006 통합 테스트** — bats 114 케이스 PASS, 기존 58 회귀 무손상.
  - state.bats(21) + hooks.bats(11) + cli.bats(18) + mcp.bats(6) + engine.bats(20) + pool.bats(17) + select-model.bats(21) = **114** (목표 96+ 초과).
  - 모든 .sh shellcheck `-S warning` clean.
  - `make ci` ✅ all gates passed.

- **US-007 문서** — 아키텍처 + MCP 통합 + 비교표.
  - `skills/ohmyclaw/docs/architecture.md` (신규): 레이어 다이어그램, 소유권 분할, 라이프사이클, 우로보로스 보존.
  - `skills/ohmyclaw/docs/mcp-integration.md` (신규): Claude Code / OpenClaw / Codex MCP 등록 가이드, 도구 매핑, 환경변수, 트러블슈팅.
  - `SKILL.md` 신규 §"자체 Runtime" 섹션 + 다른 하네스 비교표.
  - `README.md` "범용 하네스" 섹션 + Ouroboros/OMC/OMX 비교표.

- **US-008 semver + CI 통합** — v1.4.0 출시.
  - `VERSION` 1.3.0 → 1.4.0; `routing.json#version` 1.4.0.
  - `package.json` + `tsconfig.json` 추가 — `@modelcontextprotocol/sdk` + zod 의존성, `npm run build:mcp / build:mcp:check / mcp` 스크립트.
  - `Makefile` `build-mcp` 타깃 추가, `ci` 타깃이 MCP 빌드 포함.
  - `.github/workflows/ci.yml`: Node 셋업 후 `npm install` + `npm run build:mcp`, 그 뒤 114 bats 슈트.

### Changed

- `SKILL.md` 슬래시 명령은 `cli.sh <verb>` 와 1:1 매핑됨을 명시.
- `README.md` 의 출처 섹션에 `oh-my-pi` / `acpx` / `Ouroboros` 정정 라인 유지.

### 제약 — 우로보로스 프롬프트 불변

`prompts/reviewer.md` 의 Stage 5 갭 5유형 + `GAP_DETECTED → fix 1회 → ESCALATED` 흐름은 변경 없음. `cancel-signal-state.json` 발신만 추가 통합.

[1.4.0]: https://github.com/jkf87/ohmyclaw/compare/v1.3.0...v1.4.0

## [1.1.0] — 2026-05-23  (⚠️ 가짜 라벨 — v1.4.0 에 통합됨)

### Added — 로버스트성 (P1–P7)
- **bats 테스트 슈트** (`tests/`, 58+ 케이스): select-model 라우팅 매트릭스·우선순위 규칙·plan cap·reasoning 인식·Codex/OpenRouter overlay 회귀 + engine.sh resolve(omp 우선/폴백, role→permission, 강제/no-fallback, acp-config, doctor) + pool.sh next/cooldown/release + worker semaphore + 동시성 race 시나리오.
- **JSON Schema**: `skills/ohmyclaw/schemas/routing.schema.json`, `skills/ohmyclaw/schemas/bridge-event.schema.json`. `engine.sh doctor` 와 CI 에서 `ajv-cli` 로 검증.
- **CI**: `.github/workflows/ci.yml` — ubuntu+macos 매트릭스, `bash -n` + shellcheck + ajv 스키마 검증 + bats 슈트.
- **Makefile**: `test`/`lint`/`schema`/`doctor`/`syntax`/`ci` 타깃.
- **Worker semaphore** (P5): `pool.sh acquire-worker` / `release-worker` / `sweep`. `ZAI_CODING_PLAN` 에 따른 `maxWorkers` 강제(만석 시 exit 11), `${OHMYCLAW_STATE_DIR}/pids/<session>/` 슬롯 파일에 PID 추적, dead PID 자동 회수.

### Changed — 동시성·정확성·문서
- **pool.sh 동시성 안전** (P2/F1): 모든 write 액션을 `with_state_lock` 으로 직렬화. Linux 는 `flock`, macOS 는 portable mkdir-lock 폴백. read-modify-write 사이클 race 종료.
- **bridge 이벤트 구조화** (P6/F7): SKILL.md §9 free-form `--text` 예제를 `bridge-event.schema.json` 기반 JSON 페이로드 패턴으로 교체. `payload.summary` 로 하위호환 텍스트 유지.
- **출처 정정**: README/SKILL.md 의 "우로보로스 → 갭 5유형" 인용을 사실 기반으로 수정. 실제 [Q00/ouroboros](https://github.com/Q00/ouroboros) 의 매커니즘은 "Ambiguity Score(4차원 가중, ≤0.2 게이트)" 이며, 갭 5유형(`assumption_injection / scope_creep / direction_drift / missing_core / over_engineering`)은 ohmyclaw 자체 분류임을 명시.

### Fixed
- routing.json 의 키 오타가 런타임까지 미발각되던 문제 — ajv 스키마 검증(F3)으로 사전 차단.
- 병렬 워커 fan-out 시 `pool-state.json` 의 `roundRobinIndex` 가 한쪽 writer 에게 lost-update 되던 race (F1).
- `concurrency.maxWorkers` 가 hud 표시용일 뿐 실제 spawn 한도가 강제되지 않던 결함 (F2).
- 비정상 종료 시 `${STATE_DIR}/pids/<session>/` 의 고아 슬롯이 누적되던 문제 — `pool.sh sweep` 으로 dead PID 회수 (F5).

## [1.0.0] — 2026-05-23  (⚠️ 가짜 라벨 — v1.4.0 에 통합됨; 첫 omp ACP 엔진 이식 작업)
- **Engine layer (omp via ACP)**: `engine.sh` 신규 — `acpx` 의 `--agent "omp acp"` escape hatch 로 oh-my-pi(omp) 를 1순위 엔진으로 spawn, omp 미설치 시 acpx 내장 어댑터(pi/codex/claude)로 graceful fallback.
- routing.json 최상위 `engine` 블록 + ohmyclaw=모델·계정·키 / omp=엔진툴·세부 role 소유권 분할.
- 우로보로스 reviewer.md 는 변경 없이 omp 툴(`lsp_diagnostics`/`ast_grep_search`)을 그대로 활용.
- SKILL.md `Engine layer` 섹션, §6-3/§7-2 spawn 을 engine.sh 경유로 교체, §10 가상 `zai-runner` 제거.
- SKILL.md 예제의 셸 인용/인젝션 결함 수정 (`printf %q` 안전 인용 17곳).

[1.1.0]: https://github.com/jkf87/ohmyclaw/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/jkf87/ohmyclaw/releases/tag/v1.0.0
