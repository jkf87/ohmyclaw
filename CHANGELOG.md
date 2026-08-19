# Changelog

본 프로젝트는 [Keep a Changelog](https://keepachangelog.com/) 형식과 [SemVer](https://semver.org/) 를 따릅니다.


## [1.13.0] — 2026-07-14

### Added — goal-loop: Evidence-driven goal completion (LazyCodex ulw-loop architecture adapted)

LazyCodex ulw-loop 아키텍처의 핵심 컨셉(goal/evidence/criteria 상태머신)을 차용하여 OhMyClaw bash 스킬로 재구현. "같은 결과 반복 차단"이 아니라 **"목표가 완료되면 자연 종료"** 구조.

- **`goal-loop.sh`** (신규, 400 LOC) — LazyCodex ulw-loop의 goal/evidence/criteria 상태머신을 bash + jq로 재구현:
  - `init "brief"` — brief 텍스트에서 goals 파생 + success criteria 자동 시딩 (happy/edge/regression)
  - `next [--json]` — 미완료 goal의 instruction 출력 (GOAL + SUCCESS CRITERIA + STOP WHEN + EVIDENCE)
  - `evidence --goal-id --criterion-id --status pass|fail|blocked --evidence` — criterion 증거 기록
  - `checkpoint --goal-id --status complete|failed|blocked --evidence` — goal 완료 (essential criteria 전부 pass 검증)
  - `status [--json]` — plan 요약 (goals/criteria 통계 + done 여부)
  - `steer --kind --evidence --rationale` — 방향 전환 기록
  - `hook user-prompt-submit` — UserPromptSubmit steering (방향 전환 키워드 감지)
  - `is-done` — 전체 완료 판정 (exit 0=done, 1=not done)
  - State: `~/.cache/ohmyclaw/goal-loop/<session>/goals.json` + `ledger.jsonl`

- **LazyCodex ulw-loop 아키텍처 차용 핵심**:
  - goal status (pending → in_progress → complete/failed/blocked) — 동일
  - successCriteria (happy/edge/regression, essential 필드) — 동일
  - evidence 기반 criterion 판정 (pass/fail/blocked) — 동일
  - ledger.jsonl 감사 추적 (모든 상태 변화 기록) — 동일
  - essential criteria 전부 pass 못 하면 checkpoint complete 거부 — 동일
  - aggregateCompletion (전체 goal 완료 시 자동 마킹) — 동일
  - steering (UserPromptSubmit 방향 전환 감지) — 동일

- **기존 deduper와의 관계**: goal-loop = "작업이 끝났는가?" (proactive completion), deduper = "같은 결과가 반복되는가?" (reactive guard). 상호 보완.

- **테스트** — init/status/next/evidence/checkpoint/is-done/hook 전 시나리오 통과. bats 281 PASS / 0 FAIL (회귀 없음).


## [1.12.0] — 2026-07-14

### Added — result-aware loop guard 파이프라인 (routing.json → Codex)

GPT-5.6 고 effort 무한 루프(#27759)에 대한 result-aware 방어. 동일 tool+args의 **결과가 같을 때만** 루프로 판단 — 정상 test→fix→test 사이클(결과가 바뀜)은 허용.

- **routing.json `loopGuardDefault`** — `maxSame: 50`, `advisoryThreshold: 10`. 모든 모델 통일. 50회 동일 결과까지 허용(실제 작업에 영향 없음), 10회부터 advisory 주입, 50회 차단.
- **select-model.sh** — 선택된 모델의 loopGuard 설정을 `DEDUPER_MAX_SAME` env로 export. JSON 출력에 `loopGuardMaxSame` 필드 추가.
- **engine.sh** — resolve 출력에 `DEDUPER_MAX_SAME=N` prefix 추가 → Codex spawn 시 환경변수 전달.
- **deduper hook (v2)** — PostToolUse에서 결과 해시 기록 + advisory 주입, PreToolUse에서 동일 결과 N회 시 block. `DEDUPER_MAX_SAME` env로 임계값 제어.
- **모델 loopGuard 필드** — gpt-5.6-sol/terra/luna 모두 `"default"` (loopGuardDefault 사용).
- **테스트** — bats 281 PASS / 0 FAIL.

> 파이프라인: routing.json#loopGuardDefault → select-model.sh (env export) → engine.sh (env prefix) → Codex 세션 → deduper hook (env 읽어서 result-aware 차단)
> **📝 버전 정정 노트 (2026-05-24)** — 이 파일의 아래쪽 `[1.0.0]` / `[1.1.0]` 섹션은 origin 의 공식 GitHub 릴리즈 v1.0.0 (OpenClaw Multi-Provider Harness, 2026-04-10) / v1.1.0 (OpenRouter Integration, 2026-04-11) 과 **다른 작업**이며, 본 리포 자체 일련번호로 잘못 라벨된 작업입니다. 실제로는 origin v1.3.0 (gpt-5.5 frontier, 2026-05-02) 이후의 후속 작업으로, **v1.4.0 단일 릴리즈로 통합**됩니다. 정식 GitHub 태그/릴리즈는 v1.4.0 만 유효하며 잘못 라벨된 섹션 헤더는 역사 기록 차원에서 그대로 보존합니다.

## [1.11.1] — 2026-07-14

### Added — GPT-5.6 고 effort 무한 루프 방지 (tool-call-deduper + tier-aware timeout)

GPT-5.6 Sol/Terra 를 xhigh/ultra effort 로 사용 시 Codex CLI 가 반복 동일 tool call 을 bound 하지 못해(#27759) 무한 루프에 빠지고 사용량이 수분만에 소진되는(#32606) 문제에 대한 다층 방어.

- **`tool-call-deduper.mjs`** (신규, `~/.codex/scripts/`) — PreToolUse hook. (tool_name + args_hash + session_id) identity 추적, 3회까지 동일 호출 허용, 4회째 block + feedback. MCP/state 도구는 제외. `DEDUPER_MAX_REPEATS` env 로 임계값 조절. 10분 stale cleanup + 200 entry cap.
- **`hooks.json` PreToolUse 체인** — OMX hook 뒤에 deduper 를 두 번째 entry 로 추가 (timeout 5s). config.toml hook trust hash 갱신.
- **`routing.json` tier-aware timeout** — `engine.acpxFlags.timeoutSeconds` 300→600, `modelTierTimeout` (LOW=120/MEDIUM=300/HIGH=600) 추가. engine.sh 가 selected model 의 tier 를 조회해 timeout 적용.
- **`routing.json` 모델 loopRisk 메타데이터** — gpt-5.6-sol(loopRisk:high), terra(loopRisk:critical), luna(loopRisk:medium) + loopGuard 설명.
- **`config.toml`** — `agents.max_threads` 1000→8, `agents.max_turns=30` 안전망 추가.
- **engine.sh** — tier-aware timeout resolution 로직 추가.
- **테스트** — bats 281 PASS / 0 FAIL (회귀 없음).

> 근본 원인: Codex CLI #27759 (동일 tool call 반복 미차단) × #31822 (compaction 컨텍스트 손실 회귀) × #32587/#32674 (subagent 부모 effort 상속). 고 effort 일수록 모델이 "한 번 더 검증"하며 동일 tool 재호출 → Codex 가 매번 실행 → 무한 루프.

## [1.11.0] — 2026-07-14

### Added — GPT-5.6 시리즈 + OpenClaw 2026.7.1 호환

OpenClaw 2026.7.1 이 GPT-5.6(Luna/Sol/Terra) 을 신규 설치 기본 모델로 채택(#98333, #103581, #98021) 함에 따라 ohmyclaw 라우팅을 업데이트. ClawRouter(USDC 게이트웨이) 는 직접 연결(path B) 유지로 미사용.

- **모델 정의** — `routing.json#models` 에 `gpt-5.6-sol`(frontier, ultra thinking), `gpt-5.6-terra`(frontier-reasoning, ultra), `gpt-5.6-luna`(frontier-fast, max) 3종 추가. `gpt-5.5` → legacy, `gpt-5.4` → deep-legacy 로 역할 이동.
- **codexOverlay** — 코딩/아키텍처/디버깅/데이터분석 HIGH → `gpt-5.6-sol`, 보안/추론 HIGH → `gpt-5.6-terra` 로 분리(추론 집약 태스크에 terra 배정).
- **select-model.sh P82** — `reasoning_heavy + Codex` → `gpt-5.5` 에서 `gpt-5.6-terra` 로 격상(ultra extended thinking).
- **fallbackChains** — `withCodex`/`withClaudeCli` 체인에 `gpt-5.6-sol`/`gpt-5.6-terra` → `gpt-5.5`(legacy) 순으로 삽입. 기존 `gpt-5.4` deep-legacy 제거(2세대 전이라 체인 부담).
- **engine.sh** — doctor smoke loop `gpt-5.4` → `gpt-5.6-sol`. 헤더 주석 예시 `gpt-5.4` → `gpt-5.6-sol`.
- **hud.sh** — Codex 활성 시 표시 모델 `gpt-5.5, gpt-5.4` → `gpt-5.6-sol, gpt-5.6-terra, gpt-5.5`.
- **스키마** — `routing.schema.json#omxRole` enum 에 `frontier-reasoning`, `frontier-fast`, `deep-legacy` 추가.
- **문서** — SKILL.md(JSON 예시·매트릭스·오버레이 표·엔진 라우팅·provider-health 예시), prompts/README.md(역할×모델 표), prompts/reviewer.md, mcp-server.ts(예시 모델명) 전면 갱신. routing/*.yaml(standalone route-task.sh 전용) deprecation 헤더 추가.
- **테스트** — select-model.bats P82/codex-overlay 정규식 `^gpt-5\.(4|5)$` → `^gpt-5\.[4-6]` 로 5.6 변종 수용. bats **281 PASS / 0 FAIL**.
- **routing.json** 버전 1.5.0 → 1.6.0.

> **7.1 호환성**: ClawRouter(bundled plugin) 는 USDC/x402 기반 게이트웨이로, 기존 Z.ai 구독 + OpenAI OAuth 직접 연결(path B) 유지 시 불필요. `message send --presentation`, `models auth order`, `models status --json` 등 ohmyclaw 의존 CLI 는 7.1 에서 breaking change 없음 — 운영 로그(register-commands, auth-order-sync launchd) 정상 동작 확인.

## [1.10.1] — 2026-07-10

### Fixed — auth-order-sync 콜드스타트 no-op

launchd 최초 실행(부팅/게이트웨이 재시작 직후) 시 openclaw `models auth list --json` 이 간헐적으로 빈 결과를 반환하여 sync 가 provider 를 하나도 못 찾고 조용히 no-op 되던 문제 수정. 라이브 검증에서 동일 launchd 환경인데 첫 실행만 empty, 이후 실행은 정상임을 확인(env 문제 아닌 콜드스타트 transient).

- **`_provider_list` 재시도** — provider 목록이 비면 2s 쉬고 1회 재시도. 정상 케이스(목록 존재)는 재시도 없이 즉시 통과 → 기존 동작·성능 불변. `OHMYCLAW_PH_NO_RETRY=1` 로 끌 수 있음(테스트용).
- **테스트** — auth-order-sync.bats +2 (콜드스타트 재시도 복구 / no-retry 플래그). bats **281 PASS / 0 FAIL**.

## [1.10.0] — 2026-07-10

### Added — 멀티계정 auth-order health sync (openclaw 네이티브 봇 경로)

한 provider(openai)에 auth 프로파일이 2개(`openai:default`, `openai:jjoongoo@gmail.com`) 있고 openclaw 가 order override 없이 **라운드로빈**하여, 그중 하나가 만료되면 절반쯤 만료 프로파일에 걸려 "Model login expired" 경고가 반복되던 문제 해결. 봇들은 ohmyclaw 하네스를 경유하지 않고 openclaw 네이티브 라우팅을 쓰므로(모델 오버라이드 없음·ohmyclaw 스킬 미로드), select-model 게이트로는 못 막고 openclaw `models auth order` 를 직접 조정해야 함.

- **`provider-health.sh sync-auth-order [--apply]`** — 프로파일별 라이브 health(`openclaw models status --probe`)를 보고 openclaw `models auth order` 를 **동적 조정**: 전부 정상→`clear`(라운드로빈 유지=멀티계정 부하분산), 일부 만료→`set <정상만>`(만료 제외), 전부 만료→재로그인 안내. **정적 pin 이 아니라 health 기반 자동 라우팅** — 재로그인으로 회복되면 다음 싱크에서 자동 `clear` 복귀. probe 결과 없으면(오프라인) 안전 skip.
- **보조 서브커맨드** — `profiles <p>` / `probe-profiles <p>` / `agents-using <p>`.
- **launchd 자동화** — `scripts/openclaw-auth-order-sync.sh` + `scripts/com.ohmyclaw.auth-order-sync.plist.template`(10분 주기 + 로드 시 1회), register-commands 와 동일 패턴. 로그는 profileId 만 기록(토큰 비노출).
- **테스트** — auth-order-sync.bats +9 (PATH mock openclaw 로 clear/set/alert/dry-run/offline-skip/disable 결정 로직 검증). bats **279 PASS / 0 FAIL**. 라이브 openclaw dry-run 검증 완료(openai 2/2 정상→4개 agent clear 계획).
- **문서** — docs/auth-order-sync.md, SKILL.md §6-6 보강.

> 참고: v1.9.0 의 select-model 게이트/pool quarantine 은 ohmyclaw 하네스를 실제 쓰는 에이전트 경로용이고, 본 1.10.0 은 openclaw 네이티브 봇 경로(멀티 auth 프로파일 라운드로빈)용이다 — 두 경로를 각각 커버.

## [1.9.0] — 2026-07-10

### Fixed — 만료된 provider 로그인으로 반복 호출 (auth-expiry 게이트)

멀티계정 연결 시, 특정 provider(openai 등)의 **게이트웨이 OAuth 로그인이 만료**되면 openclaw 가 스스로 zai/glm 으로 폴백하며 **exit 0(성공)** 을 리턴한다. 그래서 ohmyclaw 의 exit-code 기반 cooldown 은 발동하지 않았고, 계정 풀 자격 판정에 auth-만료 개념이 없어 라운드로빈이 만료 provider 를 계속 되돌려주며 `Model login expired on the gateway for openai ...` / `Model Fallback: ... auth permanent` 경고가 무한 반복되던 문제 수정.

- **`provider-health.sh` (신규)** — openclaw `models status --json` 의 provider별 status(`ok|expiring|expired|missing|static`)를 근거로 만료/누락 provider 를 파악하는 auth-health 게이트. TTL 캐시(기본 45s), openclaw 부재 시 무해(no-op). 서브커맨드: `refresh/status/check/first-healthy/why/provider-of/quarantine/release/is-quarantined/scan-stderr`.
- **`select-model.sh` — 사전 게이트(proactive)** — 폴백 체인에서 만료 provider 의 모델을 **첫 정상 모델로 강등**(예: openai 만료 시 `gpt-5.5`→`glm-5.2`). `--json` 출력에 `.providerHealthGate` 추가. `OHMYCLAW_PROVIDER_HEALTH=false` 로 비활성.
- **`claude-delegate.sh` + SKILL.md §6-3 recipe 8b — 사후 감지(reactive)** — 엔진 stderr 의 `login expired`/`auth permanent` 시그니처를 스캔해 provider 격리(exit 0 폴백에도 안전).
- **`pool.sh` — provider 단위 격리** — `quarantine <provider|pool> [reason]` / `release-provider` 추가. 계정 cooldown(600s cap)과 달리 재로그인까지 유지. 격리된 pool 의 `next` 는 exit 3 + 재로그인 안내. `get_eligible_accounts` 가 격리 provider 를 건너뜀. 재로그인 후 라이브 status=ok 감지 시 **자동 해제**(reconcile).
- **재로그인 안내 dedup** — 만료 감지 시 `openclaw models auth login --provider <p> --force` 안내를 provider당 창(기본 1h) 1회만 발화.
- **테스트** — provider-health.bats +16, pool.bats +5(격리), select-model.bats +3(게이트) & 실기기 openclaw 의존 제거(게이트 기본 off + 격리 상태). bats **270 PASS / 0 FAIL**.
- **문서** — SKILL.md §6-6(auth-expiry 게이트) + 트러블슈팅 2행.

## [1.8.0] — 2026-06-26

### Added — 비동기 인터뷰 상태머신 (실제 버튼 클릭 동작)

동기 `interview` 는 CLI 1회성이라 버튼 클릭을 받을 수 없었다(openclaw 콜백은 비동기로 에이전트 턴에 전달 → 이미 끝난 프로세스엔 미도달 → `degraded` 폴백). 클릭이 실제로 인터뷰를 진행시키도록 **재개 가능 상태머신 + 에이전트 구동** 모드 추가.

- **`interview start <topic> --to <chatId>`** — 세션(`interview-session` state) 시작 + 첫 질문을 **`command`-액션 버튼**(`/omc_iv <value>`)으로 발화. openclaw 가 클릭을 synthetic 슬래시 명령으로 에이전트에 전달(`callback` 타입과 달리 받는 주체 존재).
- **`interview answer <value>`** — 에이전트가 버튼 클릭(`/omc_iv <value>`) 수신 후 호출. 답을 기록(`fallback:false`)·재채점·다음 질문 발화 or 종료. `--to` 는 세션에서 자동 로드.
- **`interview status` / `interview cancel`** — 진행 점검 / 중단.
- **Other**: `/omc_iv __other__` → 자유입력 안내(awaiting 유지) → 다음 텍스트를 `interview answer "<텍스트>"` 로.
- 종료 시 `interview-result`(**`mode:"async"`, `degraded:false`**) 저장 + 요약 발송. 우로보로스 조기 종료(모호성 ≤ threshold), 이미 명확한 차원 skip 동일.
- **SKILL.md §1** — 에이전트 비동기 오케스트레이션 규약(인바운드 `/omc_interview`/`/omc_iv` → cli 라우팅) 추가. 동기 `interview <topic>` 모드는 보존(프리뷰/CLI).
- **테스트** — interview-async.bats +11 (start/answer/finalize 시퀀스·조기종료·Other/free-text·status/cancel·가드·동기 회귀, `OHMYCLAW_ASK_MOCK` dry-run 결정론). bats **246 PASS / 0 FAIL**.
- **문서** — docs/ask-flow.md 비동기 상태머신 섹션.

> 최종 "클릭→다음 질문" 텔레그램 왕복(LLM 이 SKILL.md 오케스트레이션을 따르는 부분)은 라이브 게이트웨이에서 검증 필요 — 상태머신·버튼 페이로드·세션 전이는 bats 로 결정론 검증됨.

## [1.7.2] — 2026-06-26

### Fixed — 인터뷰 폴백 가시화 (조용한 가짜 성공 방지)

실 모드에서 openclaw 가 PATH 에 없거나(또는 구버전), 유효 chatId(`--to`) 없이 기본 `self` 로 보내거나, openclaw 2026.6.6 에 동기 `events wait` CLI 가 없어 버튼 응답을 못 받을 때, `interview`/`ask` 가 **조용히 `recommended` 기본값으로 폴백**하여 마치 인터뷰가 성공한 것처럼 보이던 문제 수정.

- **`cmd_ask`** — 실 모드 stderr 경고 추가: (a) openclaw CLI 부재(`which -a openclaw` 안내), (b) `message send` 실패(rc + target + chatId 힌트), (c) 버튼 응답 없음 → recommended 폴백. stdout(응답값)은 불변 → caller(`$(cmd_ask)`)·테스트 영향 없음.
- **`cmd_interview`** — 결과에 **`degraded`**(폴백이 1개라도 있으면 true) + **`fallbackCount`** + 답변별 **`fallback`** 필드 추가(폴백 여부는 `interview-<d>` state 의 `timeoutFallback` 으로 판정). degraded 시 stderr 로 "N/M 답변이 기본값(버튼 미수신)" + 올바른 실행법(`--to <chatId>` + 에이전트 컨텍스트) 안내. mock 응답은 `fallback:false`.
- **테스트** — interview.bats +2 (mock=degraded:false / 응답채널 없음=degraded:true·전 답변 fallback, openclaw 스텁으로 결정론적). bats **235 PASS / 0 FAIL**.
- **문서** — docs/ask-flow.md 인터뷰 정직성 섹션.

> 동작 자체(`/ohmyclaw interview` 흐름)는 불변 — 폴백을 **숨기지 않고 드러낼** 뿐. 실제 버튼 인터랙션은 올바른 openclaw PATH + `--to <chatId>` + 에이전트 비동기 콜백 컨텍스트에서 동작.

## [1.7.1] — 2026-06-26

### Added — Telegram 슬래시 명령 자동 복구 (launchd self-heal)

openclaw 2026.6.6 은 게이트웨이 시작 시 `deleteMyCommands`+`setMyCommands` 로 자기 명령을 재설정하여 ohmyclaw 의 `omc_*` 등록을 덮어쓴다. 이를 자동 복구하는 운영 도구 추가.

- **`scripts/telegram-register-commands.sh`** — 활성 텔레그램 봇(`~/.openclaw/openclaw.json`)마다 기존 명령 보존-병합 후 `omc_*` 를 setMyCommands. 명령 목록은 단일 소스 `cli.sh commands json`. **getMyCommands 캐시 stale 비결정성 대비 항상 merge+set**(idempotent). 토큰 비노출. env override(`OPENCLAW_JSON`/`OHMYCLAW_CLI`/`TELEGRAM_API_BASE`).
- **`scripts/com.ohmyclaw.register-commands.plist.template`** — launchd LaunchAgent 템플릿. `RunAtLoad` + `StartInterval 300`(5분) → 게이트웨이 재시작 후 ≤5분 내 자동 복구.
- **`skills/ohmyclaw/docs/telegram-slash-commands.md`** — 설치/운영/원리 문서.

> 슬래시 명령 동작(`/ohmyclaw interview`, `commands menu` 버튼, `dispatch`)은 등록과 무관하게 항상 작동. 본 도구는 `/` 자동완성 메뉴 UX 의 영속성만 담당.

## [1.7.0] — 2026-06-26

### Added — GLM-5.2 차세대 플래그십 라우팅 지원

Z.ai GLM-5.2 를 routing.json 단일 소스에 추가하고, HIGH 복잡도 coding/reasoning 의 새 1순위로 승격.

- **모델 정의** `models["glm-5.2"]` — tier HIGH, reasoningMode, anthropicAlias opus, plans [pro, max]. scores coding 97 / reasoning 96 / korean 97 (GLM-5.1 대비 후속 우위). 하드 스펙(contextWindow/maxTokens)은 공식 발표 전까지 GLM-5.1 미러링(수치 날조 방지, 라우팅 점수만 상향).
- **plan 가용성** — pro/max `allowedModels` 에 추가, lite `blockedModels` 에 추가.
- **matrix 승격** — pro/max 의 `coding_general`/`coding_arch`/`reasoning` **HIGH** 셀을 glm-5.1 → **glm-5.2**. korean_nlp/debugging/data_analysis/security 및 MEDIUM/LOW 는 glm-5.1 유지(점진 전환).
- **select-model.sh** — P81(reasoning_heavy + Pro/Max) → glm-5.2. P95 plan_block 강등 조건에 glm-5.2 추가(lite → glm-5).
- **fallbackChains** — pro/max 및 withCodex/withClaudeCli/withOpenRouter 체인에서 glm-5.2 를 glm-5.1 바로 앞에 삽입(모든 체인에서 glm-5.2 > glm-5.1).
- **테스트** — select-model.bats: 기존 4케이스(P81/HIGH/openrouter)를 glm-5.2 로 갱신 + glm-5.2 전용 4케이스(lite 차단·매니페스트·fallback·matrix HIGH) 추가. bats 233 PASS / 0 FAIL.
- **문서** — README 모델표/플랜표, SKILL.md 플랜·모델표·강등 노트 갱신.

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

## [1.17.0] — 2026-08-19

### Added — `/omc_experimental` · `/omc_star` 슬래시 명령

실험 기능 토글과 별 안내를 챗(Telegram/Discord)에서도 쓸 수 있게 `commands.json` 에 등록했습니다.

```
/omc_experimental list
/omc_experimental enable thinkingSuffix
/omc_star --status
```

### Fixed — 별 안내가 챗에서 아무것도 출력하지 않던 문제

v1.16.0 의 `cmd_star` 는 TTY 가 없으면 조용히 넘어갔습니다. 파이프·CI 출력을 오염시키지 않으려는 의도였지만, **챗 슬래시 명령에도 TTY 가 없어서 `/omc_star` 가 빈 응답이 됐습니다.**

명시 호출과 자동 호출을 분리했습니다.

| 호출 | 조건 | 출력 |
|---|---|---|
| `star` / `--force` (사용자가 직접) | 없음 — 항상 출력 | stdout |
| `--auto` (작업 성공 후 자동) | TTY + 쿨다운 + skip-env | stderr |

`--status` 를 추가해 별 안내를 띄우지 않고 상태만 확인할 수 있습니다.

### Fixed — 존재하지 않는 `ohmyclaw` 명령을 안내하던 문서

README·릴리스 노트·`experimental list` 출력이 모두 `ohmyclaw <verb>` 를 안내했으나 **그런 실행 파일은 PATH 에 없습니다** — `install.sh` 는 스킬 디렉토리만 심볼릭 링크합니다. 실제 경로(`~/.openclaw/skills/ohmyclaw/cli.sh`)와 챗 슬래시 명령으로 정정하고, 자주 쓰는 경우를 위한 alias 를 안내합니다.

### Docs

README 에 **긴 작업 재개**, **실험 기능 토글**, **끄는 스위치** 섹션을 한/영으로 추가했습니다.

### Tests

`tests/star-update.bats` 21개로 확장. 자동 경로는 의사터미널(`script`)로 실제 TTY 조건에서 검증합니다. 전체 **351 PASS / 0 FAIL**.

## [1.16.0] — 2026-08-19

### Added — 실험 기능 토글 (`ohmyclaw experimental`)

라이브 검증이 끝나지 않은 기능은 **기본 off** 로 두고, JSON 을 직접 고치지 않고 켜고 끌 수 있게 했습니다.

```bash
ohmyclaw experimental list             # 현재 상태
ohmyclaw experimental enable glm53     # 영구 활성 (routing.json 갱신)
ohmyclaw experimental disable glm53
OHMYCLAW_GLM53=true ohmyclaw route ... # 일회 override (env 가 파일보다 우선)
```

| 기능 | env | 기본 | 켜면 |
|---|---|---|---|
| `thinkingSuffix` | `OHMYCLAW_THINKING_SUFFIX` | off | HIGH 슬롯이 `model[max]` 로 실행 |
| `glm53` | `OHMYCLAW_GLM53` | off | pro/max HIGH 슬롯에 `glm-5.3` 사용 |

`enable` 시 해당 기능의 리스크를 함께 출력합니다.

### Changed — thinking level (기본 off)

effort 접미를 켜면 HIGH 슬롯이 `max` 로 돌아갑니다 — 그동안 `gpt-5.6-sol` 은 기본값 `low` 로 실행되고 있었습니다. 다만 라이브 검증을 마치지 못해 **기본은 off** 이며 `ohmyclaw experimental enable thinkingSuffix` 로 켭니다.

- **codex provider 에만 붙입니다.** `model[effort]` 는 codex-acp 가 advertise 하는 모델 ID 형태라 pi/omp(zai) 에 붙이면 모델 해석이 깨집니다. `glm-5.2[max]` 같은 잘못된 조합이 나가지 않도록 provider 로 제한했습니다.
- 레벨 직접 지정: `OHMYCLAW_THINKING=<level>`

> ⚠ 이 머신에서는 `codex-acp` 브리지가 기동 실패(exit 1)라 라이브 호출로 최종 확인하지 못했습니다. 접미가 거부되면 `fallbackChain` 의 다음 모델로 강등됩니다.

### Changed — GLM-5.3 (기본 off, 토글로 활성)

v1.15.0 의 `ZAI_GLM53_ENABLED` 게이트를 `experimental.glm53` 토글로 통합했습니다. 라우팅 표에는 정식 등재하되 **기본은 off** 이며, 꺼져 있으면 P94 게이트가 `glm-5.2` 로 강등합니다.

- `matrix` 의 pro/max × `coding_arch` / `coding_general` / `reasoning` HIGH 슬롯이 `glm-5.3`
- P81(reasoning_heavy) 이 `glm-5.2` → `glm-5.3`
- `plans: ["pro", "max"]`, lite 는 P95 로 강등
- 활성화: `ohmyclaw experimental enable glm53`
- codex frontier 가 켜져 있으면 여전히 그쪽이 우선

**강등 경로를 반드시 유지합니다.** OpenClaw 2026.7.1 zai 카탈로그에는 `glm-5.3` 이 아직 없으므로(최신 `glm-5.2`), 모든 폴백 체인에서 `glm-5.3` 바로 뒤에 `glm-5.2` 가 오도록 배치했고 이를 테스트로 고정했습니다. 카탈로그 등재 전까지는 해석 실패 시 자동 강등에 의존합니다.

### Fixed — 폴백 체인 중복 항목

`glm-5.3` 삽입 과정에서 pro/max 의 `coding`·`korean`·`reasoning` 체인에 `glm-5.3` 이 두 번 들어가 있던 것을 제거했습니다(6곳). 중복 검사도 테스트에 추가했습니다.

### Notes — 컨텍스트 1M

`glm-5.2` 는 v1.15.0 에서 실측대로 `1000000` 으로 정정했고, `glm-5.3` 도 동일하게 `1000000` 입니다. `gpt-5.6` 계열은 `1050000` 입니다.

### Tests

`tests/glm53-thinking.bats` 16개로 확장(강등 경로·중복 검사·zai 접미 금지 포함), `tests/select-model.bats` 기대값을 glm-5.3 승격에 맞춰 갱신. 전체 **339 PASS / 0 FAIL**.

## [1.15.0] — 2026-08-19

### Added — thinking level(reasoning effort) 배선

**하네스가 지금까지 effort 를 전혀 넘기지 않고 있었습니다.** `defaultThinking` 은 메타데이터일 뿐 실제로 모델에 전달되는 경로가 없었고, 그래서 각 모델의 기본값이 그대로 적용됐습니다 — **`gpt-5.6-sol` 은 기본 effort 가 `low` 라서 frontier 슬롯이 최저 사고량으로 돌고 있었습니다.**

- `routing.json` 에 `thinkingPolicy` 추가 — tier 로 결정 (`LOW: low` / `MEDIUM: medium` / `HIGH: max`).
- `engine.sh` 가 `model[effort]` 접미를 붙입니다. `OHMYCLAW_THINKING` 으로 직접 지정할 수 있습니다.
- `supportsUltra: false` 인 모델(Luna, codex 런타임)은 `ultra` 요청 시 `max` 로 자동 강등합니다.

> ⚠ **접미 문법은 `OHMYCLAW_THINKING_SUFFIX=true` 일 때만 적용됩니다(기본 off).** `model[effort]` 는 acpx 가 자체 help 에 문서화한 형태지만(`acpx codex set model 'gpt-5.2[high]'`), spawn 시 `--model` 에도 통하는지는 라이브 세션이 필요해 검증하지 못했습니다. 검증 전까지 기본 경로는 바꾸지 않습니다.

### Added — GLM-5.3 (opt-in)

Artificial Analysis 가 2026-08-18 자로 `GLM-5.3 (max)` 를 평가 등재했습니다.

**⚠ OpenClaw 2026.7.1 의 zai 카탈로그에는 아직 없습니다**(최신이 `glm-5.2`). 기본 활성화하면 모델 해석에 실패하므로 `ZAI_GLM53_ENABLED=true` 일 때만 타는 P83 오버레이로 넣었습니다. 조건은 P81 과 같습니다 — HIGH tier 또는 reasoning_heavy, lite 플랜 제외, codex frontier 가 켜져 있으면 그쪽이 우선.

하드 스펙은 카탈로그 등재 전까지 `glm-5.2` 미러링이고 `scores` 는 추정치입니다.

### Fixed — GLM-5.2 컨텍스트 윈도우 5배 오류

`204800` 으로 적혀 있었으나 실측은 **`1000000`** 입니다(`maxTokens` 도 `131100` → `131072`). openclaw 카탈로그(`provider-catalog-*.js`)에서 확인했으며 비용(`$1.4` / `$4.4`)도 함께 채웠습니다.

### Fixed — jq `//` 가 `false` 를 삼키던 버그

`.models[$m].supportsUltra // true` 는 `supportsUltra: false` 일 때 `true` 를 돌려줍니다. jq 의 `//` 는 `false` 를 빈 값으로 취급하기 때문입니다. `has()` 로 존재를 먼저 확인하도록 고쳤습니다 — 이게 없으면 Luna 의 ultra 강등이 영영 걸리지 않습니다.

### Notes — `sol-max` / `terra-max` / `luna-max` 는 모델이 아닙니다

Artificial Analysis 의 `(max)` 표기는 **reasoning effort 주석**입니다(같은 체인지로그의 `GLM-5.3 (max)`, `Gemini 3.7 Flash (low/medium/high)` 와 동일한 관례). OpenClaw 카탈로그의 실제 모델 ID 는 `gpt-5.6-sol` / `-terra` / `-luna` 셋뿐이며 `-max` 접미 ID 는 존재하지 않습니다. 따라서 모델을 추가하는 대신 위의 thinking level 배선으로 처리했습니다.

### Tests

`tests/glm53-thinking.bats` **+13**. 전체 **336 PASS / 0 FAIL**.

## [1.14.0] — 2026-08-19

### Added — sqlite 세션 스토어: 긴 작업 재개 (`session-store.sh`)

**긴 작업이 중단되면 처음부터 다시 하던 문제**를 해결합니다. 단계·태스크 단위로 sqlite 에 커밋해두고, 재개 시 **남은 일만** 다시 배정합니다.

v1.12.0 의 result-aware deduper 와는 다른 층입니다 — deduper 는 **같은 툴콜 반복(폭주)** 을 억제하고, 이건 **중단된 작업의 재개**를 다룹니다.

- **스토어** — `~/.ohmyclaw/sessions.sqlite` (`OHMYCLAW_SESSION_DB` 로 재지정). WAL + busy_timeout 으로 sqlite 가 직렬화하므로 파일락이 필요 없습니다. 8 워커 동시 쓰기 80/80, seq 충돌 0 으로 검증.
- **테이블** — `sessions`(수명주기·하트비트·재개횟수) / `checkpoints`(단계별 산출물) / `tasks`(태스크 원장).
- **재개 봉투** — `resume <sid>` 가 `remaining_task_ids` 를 포함한 JSON 을 냅니다. `done` 태스크는 재실행하지 않고, `running` 상태로 죽은 고아 태스크는 `pending` 으로 회수합니다.
- **중단 감지** — `interrupted --stale-sec 900` 으로 하트비트 끊긴 세션을 뽑습니다.
- **`spawn-agent.sh` 연동** — `OHMYCLAW_SESSION_ID` 가 있을 때만 기록하며 전부 best-effort. 스토어 장애가 spawn 을 막지 않습니다.
- **`export <sid>`** — 트라젝토리 전체를 JSON 으로. 외부 뷰어(trackio 등)로 넘길 단일 출구이며 스토어 자체는 파이썬 런타임에 의존하지 않습니다.

### Fixed — 버전 체크가 문자열 비교라 잘못 알리던 문제

v1.13.1 의 `_check_update` 가 `"$cached_latest" != "$local_v"` 로 비교하고 있어 두 가지가 틀렸습니다.

1. **로컬이 최신 릴리스보다 앞설 때**(개발 중) "업데이트 있음"을 영원히 출력 — 메인테이너가 가장 자주 겪는 케이스입니다.
2. `1.9.0` vs `1.11.0` 같은 자리수 차이를 오판.

`_semver_gt` 로 숫자 필드별 비교하도록 고쳤습니다. 프리릴리스 꼬리표(`-rc1`)는 제거 후 비교하고, 숫자가 아닌 값이 오면 알리지 않습니다.

### Added — 별(star) 안내

작업이 **성공했을 때만** 저장소 링크를 안내합니다.

- 링크만 안내합니다. 토큰을 읽거나 API 로 누르는 동작은 하지 않습니다.
- 30일 쿨다운. `ohmyclaw star --never` 로 영구 해제, `--force` 로 다시 보기.
- `OHMYCLAW_SKIP_STAR_PROMPT=1` 로도 끌 수 있습니다.
- 성공 종료(rc=0)에만 발화하므로 실패한 작업 뒤에 별을 조르지 않습니다.

### Changed — 긴 작업을 자르던 한도 상향

v1.13.1 이 acpx 타임아웃을 600s 로 올렸지만, **실제 절단 지점인 `agents/worker.md` 의 `timeout_ms: 600000`(10분) 은 그대로 남아 있었습니다.**

| 지점 | 이전 | 이후 |
|---|---|---|
| `agents/worker.md` `timeout_ms` | 600000 (10분) | **3600000 (60분)** |
| `agents/debugger.md` | 600000 | 1800000 (30분) |
| `agents/planner.md` · `reviewer.md` | 300000 (5분) | 900000 (15분) |
| `routing.json` acpx `timeoutSeconds` | 600 | 3600 |
| `pipelines.yaml` work 단계 | 600000 | 3600000 |
| 툴콜 서킷브레이커 | 50 | 400 |
| `spawn-agent.sh` 기본 `max_tokens` | 32000 고정 | 모델 실제 한도 (routing.json) |
| `agents/worker.md` `max_tokens` | 64000 | 128000 |

`max_tool_calls: 50` 은 긴 작업의 **정상 동작**을 오탐하고 있었습니다. 진짜 반복은 v1.12.0 의 result-aware deduper(maxSame=50)가 잡으므로 400 으로 올렸습니다. `consecutive_same: 5` 는 그대로 둡니다.

### Fixed — GPT-5.6 계열 메타데이터를 실측값으로 정정

v1.11.0 의 GPT-5.6 항목이 관측 근거 없는 성능 서열을 담고 있었습니다. OpenClaw 2026.7.1 설치본 카탈로그(`openai-provider-*.js`, `thinking-policy-*.js`)를 직접 읽어 정정합니다.

**Sol / Terra / Luna 는 컨텍스트(1.05M)·출력(128k)·reasoning·이미지 입력이 전부 동일합니다.** 다른 것은 비용과 기본 effort 뿐입니다.

| 모델 | 비용 in/out (1M) | 기본 effort | ultra |
|---|---|---|---|
| Sol | $5 / $30 | low | ✅ |
| Terra | $2.5 / $15 | medium | ✅ |
| Luna | $1 / $6 | medium | codex 런타임 제외 |

- `reasoningEffort: "ultra"` (Sol) → 실측 기본값은 `low` 입니다. `defaultThinking` 으로 교체하고 `supportsUltra` 를 분리했습니다.
- Terra 를 "Ultra 사고 변형 — 최난도 전용"으로 적고 reasoning HIGH 에서 Sol 보다 우선시키던 것을 되돌립니다. Terra 는 Sol 의 **상위가 아니라 절반 가격의 동급**이라, 선택은 성능이 아니라 비용 결정입니다.
- Luna 의 "추론 깊이는 얕음" 서술을 제거했습니다. 실측상 유일한 제약은 codex 런타임에서 ultra 미지원입니다.
- `security` 오버레이가 MEDIUM 에 Sol, HIGH 에 Terra 를 주어 **MEDIUM 이 더 비싼 모델을 쓰던 역전**을 바로잡았습니다.
- `contextWindow` / `maxTokens` / `costPer1k*` 를 추가해 `spawn-agent.sh` 가 출력 한도를 모델에서 읽을 수 있게 했습니다.
- 운영 관측치인 `loopRisk` / `loopGuard` 는 반박 근거가 없어 업스트림 값 그대로 보존했습니다.

### Added — 내구성 정책 (`pipelines.yaml` `durability:`)

하트비트 주기·체크포인트 시점·재개 상한(5회)·보존 기간을 한 곳에서 선언합니다. `failure_policy.worker_timeout` 이 체크포인트 재개를 가리키도록 연결했습니다.

### Tests

`tests/session-store.bats` **+29**. 전체 **310 PASS / 0 FAIL**.

## [1.13.1] — 2026-07-15

### Added — 자동 버전 체크 (GitHub Releases API)

- `cli.sh` 실행 시 GitHub Releases API 로 최신 버전 조회 (`curl --max-time 3`)
- 24시간 캐시 (`~/.ohmyclaw/update-check.cache`) — 매 실행마다 API 호출 안 함
- 구버전일 경우 stderr 에 한 줄 알림: `📦 ohmyclaw X.Y.Z available (current A.B.C) — update: git pull`
- `OHMYCLAW_SKIP_UPDATE_CHECK=1` env 로 비활성 가능
- bats 281 PASS / 0 FAIL

