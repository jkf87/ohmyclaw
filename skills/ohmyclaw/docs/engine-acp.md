# 엔진 레이어 (ACP 경계) — oh-my-pi(omp) 이식 설계

> ohmyclaw 가 모델·계정·키를 선택하고, 실제 코딩 에이전트 실행은 **ACP(Agent Client Protocol)** 로 위임한다. 1순위 엔진은 [oh-my-pi(omp)](https://github.com/can1357/oh-my-pi).

## 1. 결정: no-fork ACP 경계

omp 는 TypeScript + Rust(N-API) ~27k LoC 의 코딩 에이전트 엔진(hashline 편집, LSP-연동 쓰기, DAP, 네이티브 grep/shell, 영속 Python)이다. ohmyclaw 는 bash + jq + 마크다운 프롬프트로 된 **OpenClaw 스킬**이다.

**로버스트한 통합 = 하드포크/벤더링 금지.** omp 엔진 코드를 ohmyclaw 리포에 복사하면 27k LoC 업스트림 추적 부담이 생긴다. 대신 `acpx`(ACP 클라이언트)의 escape hatch 로 `omp acp` 를 spawn 한다 → 업스트림 유지보수 부담 0, ohmyclaw 는 스킬로 유지.

```
┌─ OpenClaw (라우팅·채널·정책·백그라운드 태스크) ───────────────┐
│  [ohmyclaw 스킬]                                              │
│    select-model.sh  → 모델 ID                                 │
│    pool.sh          → 계정/키 (round-robin/cooldown/fan-out)  │
│    engine.sh        → ENGINE|CMD_TEMPLATE                      │
│         │ acpx (ACP client)                                   │
│         ▼                                                     │
│    [omp acp]  ←1순위   /  pi · codex · claude  ←폴백          │
│      hashline·LSP·DAP·native·Python                           │
└──────────────────────────────────────────────────────────────┘
```

## 2. 모델 선택 소유권 분할

| 레이어 | 소유 | 근거 |
|--------|------|------|
| **ohmyclaw** | 모델 ID, 계정/키, 풀 쿼터, role→권한정책 | 멀티계정 라운드로빈·cooldown·한국어/Z.ai 라우팅은 ohmyclaw 의 차별점 |
| **omp (엔진)** | 엔진 툴(lsp/ast/hashline), 세부 role 라우팅(smol subagent), 세션 권한(`session/request_permission`) | 엔진 내부 동작은 omp 가 소유 |

ohmyclaw 가 고른 모델은 acpx `--model` 로 omp 세션에 주입(ACP `session/set_model`). **외부 명시 모델이 omp 내부 라우팅보다 우선**하여 충돌을 방지한다.

## 3. acpx 실측 매핑 (v0.5.0)

`acpx --help` 기준 실제 인터페이스:

- 글로벌 옵션(**subcommand 앞**): `--agent <cmd>`(raw ACP escape hatch), `--model <id>`, `--cwd <dir>`, `--approve-all` / `--approve-reads` / `--deny-all`, `--format text|json|quiet`, `--timeout <s>`, `--max-turns <n>`, `--ttl <s>`.
- 내장 어댑터 subcommand: `pi`, `codex`, `claude`, `gemini`, `openclaw`, `cursor`, `copilot`, `droid`, `qwen`, `kimi`, `opencode`, …
- `acpx config` 로 `~/.acpx/config.json` 의 커스텀 `agents` 등록.

| 형태 | 명령 |
|------|------|
| omp (escape hatch) | `acpx --agent "omp acp" --model <m> --cwd <dir> <perm> --format text --timeout 300 <task>` |
| pi/codex/claude (내장) | `acpx --model <m> --cwd <dir> <perm> --format text --timeout 300 <sub> <task>` |
| omp (커스텀 등록 후) | `acpx omp --model <m> <task>` |

커스텀 등록 스니펫(`engine.sh acp-config` 출력)을 `~/.acpx/config.json` 에 병합:

```json
{ "agents": { "omp": { "command": "omp", "args": ["acp"] } } }
```

## 4. engine.sh 계약

```
engine.sh resolve <model> [authType] [role]   → "<engine>|<command-template>"
engine.sh acp-config                          → ~/.acpx/config.json omp 스니펫
engine.sh doctor                              → 점검 리포트 (exit 0=정상)
```

- 엔진 후보: `routing.json#engine.providerEngines[provider]`(없으면 `engine.preferred`). `glm-*`→zai, `gpt-*`→codex, `openrouter-*`→openrouter.
- 가용성: omp 는 `omp` 바이너리 필요, 내장 어댑터는 `acpx` 존재로 충족. acpx 부재 시 직접 CLI 폴백.
- role→권한: `routing.json#engine.permissions` (reviewer/planner/verifier/critic/architect → `--approve-reads`; executor/worker/debugger/team-executor → `--approve-all`).
- `{{CWD}}` / `{{TASK}}` 플레이스홀더는 호출측이 치환. **반드시 `printf %q` 로 셸 안전 인용**할 것 (사용자 task 에 따옴표/세미콜론이 있으면 인젝션 위험):
  ```bash
  CMD=${CMD_TMPL//\{\{CWD\}\}/$(printf %q "$PROJECT")}
  CMD=${CMD//\{\{TASK\}\}/$(printf %q "$TASK")}
  bash command:"$CMD"
  ```
- env: `OHMYCLAW_ENGINE` 강제, `OHMYCLAW_ENGINE_FALLBACK=false` 시 폴백 비활성.

## 5. 폴백 체인

```
provider=zai:        omp → pi    → (acpx 부재) pi 직접 CLI
provider=codex:      omp → codex → (acpx 부재) codex exec --full-auto
provider=openrouter: omp → codex → (acpx 부재) codex exec --full-auto
```

- omp 미설치(현 호스트 상태)에서도 `acpx pi`/`acpx codex` 로 정상 동작.
- acpx 미설치 시 `omp -p` / `codex exec` / `claude --print` 직접 실행으로 강등.

## 6. 우로보로스 보존 (불변)

`prompts/reviewer.md` 는 **이미 omp 엔진 툴 `lsp_diagnostics` / `ast_grep_search` 를 호출**하도록 작성돼 있다. 엔진을 omp 로 바꾸면 이 툴이 실제로 채워져 5관점 리뷰가 더 정확해진다.

- reviewer 는 read-only role → engine.sh 가 `--approve-reads` 권한으로 spawn (쓰기 차단 = omp `session/request_permission` 정합).
- 갭 5유형(assumption_injection / scope_creep / direction_drift / missing_core / over_engineering)과 `GAP_DETECTED → fix 1회 → 재리뷰 → ESCALATED` 제어흐름은 **프롬프트/오케스트레이션 계약**이므로 엔진 교체와 무관하게 그대로 유지된다.

## 7. omp 미설치 대응

omp 가 호스트에 없어도 본 설계는 동작한다(폴백). omp 를 1순위로 쓰려면:

```bash
curl -fsSL https://omp.sh/install | sh         # 또는
bun install -g @oh-my-pi/pi-coding-agent
omp --version
# (선택) 커스텀 에이전트 등록
skills/ohmyclaw/engine.sh acp-config >> ~/.acpx/config.json   # 수동 병합
```

provider auth(Z.ai/OpenAI OAuth)는 게이트웨이 호스트에 존재해야 한다(omp `discoverAuthStorage`).

## 8. 참고

- oh-my-pi: https://github.com/can1357/oh-my-pi
- acpx (ACP client): `npm i -g @openclaw/acpx`
- OpenClaw ACP agents: https://docs.openclaw.ai/tools/acp-agents
- Agent Client Protocol: https://github.com/zed-industries/agent-client-protocol
