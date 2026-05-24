# ohmyclaw 아키텍처 — 자체 Runtime + ACP 외부 경계

> v1.4.0 부터 ohmyclaw 는 OpenClaw 스킬 안에 살되 OMC/Ouroboros/OMX 수준의 자체 runtime(state·hooks·MCP·lifecycle) 을 보유한다. 외부 호스트(Claude Code/Codex/raw acpx) 지원은 ACP 경계로 한다.

## 레이어 다이어그램

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Host (OpenClaw 스킬 모드 / Claude Code MCP / acpx 직접)                  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  cli.sh  (verb dispatcher + lifecycle)                              │  │
│  │     ├─ pre-<verb> 훅                                                 │  │
│  │     ├─ skill-active-state.json (trap EXIT/INT/TERM)                  │  │
│  │     ├─ verb dispatch → select-model | pool | engine | state | hooks │  │
│  │     └─ post-<verb> 훅 + cleanup                                      │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌── 자체 Runtime ──────────────────────────────────────────────────────┐  │
│  │  state.sh    세션 격리 state (read/write/clear/list-active)          │  │
│  │              경로: ${OHMYCLAW_HOME}/state/sessions/<id>/<key>.json   │  │
│  │              flock + atomic mv 동시성 안전                            │  │
│  │                                                                     │  │
│  │  hooks.sh    pre/post 훅 디스패처 (사용자 확장 진입점)                  │  │
│  │              경로: ${OHMYCLAW_HOME}/hooks/{pre,post}-<verb>.sh        │  │
│  │              pre 실패 → exit 7 (action abort)                        │  │
│  │              post 실패 → 경고만 (비차단)                               │  │
│  │                                                                     │  │
│  │  mcp-server  (TypeScript / Node 22 / @modelcontextprotocol/sdk)      │  │
│  │              stdio JSON-RPC 2.0, 도구 5개                            │  │
│  │              ohmyclaw_route/pool_status/engine_resolve/doctor/version│  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌── 결정론 코어 ──────────────────────────────────────────────────────┐  │
│  │  routing.json     단일 소스 (models/plans/matrix/engine/accounts)    │  │
│  │  select-model.sh  jq 라우터 (P0-P100 우선순위 규칙)                   │  │
│  │  pool.sh          계정 풀 (round-robin/cooldown/fan-out + 동시성)    │  │
│  │  engine.sh        ACP 엔진 리졸버 (omp 우선, pi/codex/claude 폴백)    │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼ ACP (acpx --agent "omp acp" / --model …)
       ┌──────────────────┬──────────────────┬──────────────────┐
       │   omp 엔진       │   pi 엔진        │  codex / claude   │
       │ (1순위 우대)      │   (폴백)         │   (폴백)          │
       └──────────────────┴──────────────────┴──────────────────┘
```

## 소유권 분할

| 레이어 | 책임 |
|--------|------|
| **OpenClaw / Claude Code / acpx** | 호스팅, 사용자 입력, 채널 라우팅, 글로벌 보안 정책 |
| **ohmyclaw cli.sh** | verb 진입, lifecycle, 훅 발화 |
| **ohmyclaw 자체 runtime** | 세션 격리 state, 사용자 훅 진입점, MCP 도구 노출 |
| **ohmyclaw 결정론 코어** | 모델 라우팅(P0-P100), 계정 풀, ACP 엔진 결정 |
| **외부 엔진 (omp/pi/codex/claude)** | hashline 편집, LSP, DAP, 네이티브 도구, 세부 role 라우팅 |

## 데이터 경로

### state 격리
```
${OHMYCLAW_HOME:-~/.ohmyclaw}/
├── state/
│   ├── <key>.json                    # 글로벌 (OHMYCLAW_SESSION_ID 없을 때)
│   └── sessions/
│       ├── alpha/<key>.json          # 세션 alpha
│       └── beta/<key>.json           # 세션 beta
└── hooks/
    ├── pre-exec.sh                    # 사용자 확장 진입점
    ├── post-exec.sh
    ├── pre-route.sh
    └── ...
```

### pool 상태 (별도, 후방호환)
```
${OHMYCLAW_STATE_DIR:-~/.cache/ohmyclaw}/
├── pool-state.json                   # roundRobinIndex, cooldown, lastUsed
└── pids/<session>/slot-*             # worker semaphore (maxWorkers)
```

## 라이프사이클

```
  cli.sh <verb> <args>
    │
    ├─→ hooks.sh fire pre <verb>     # 사용자 훅 (exit 7 → abort)
    ├─→ state.sh write skill-active  # {active:true, action, pid, started_at}
    │
    │   trap EXIT|INT|TERM → _lifecycle_exit
    │     ├─ hooks.sh fire post <verb>
    │     └─ state.sh clear skill-active
    │
    └─→ verb 본체:
         doctor   → engine.sh doctor + state smoke + hooks list
         route    → select-model.sh "$@"
         pool     → pool.sh "$@"
         engine   → engine.sh "$@"
         state    → state.sh "$@"
         hooks    → hooks.sh "$@"
         cancel   → cancel-signal + pool sweep + state reset
         version  → VERSION 또는 routing.json#version
```

## MCP 통합

`skills/ohmyclaw/src/mcp-server.ts` 는 `@modelcontextprotocol/sdk` 의 `McpServer` 위에 5개 도구를 노출한다. Claude Code 의 `~/.claude/mcp.json` 또는 OpenClaw 의 MCP 설정에 본 서버를 등록하면 채팅에서 직접 호출 가능:

```jsonc
{
  "mcpServers": {
    "ohmyclaw": {
      "command": "node",
      "args": ["<repo>/skills/ohmyclaw/dist/mcp-server.js"],
      "env": {
        "OHMYCLAW_HOME": "${HOME}/.ohmyclaw",
        "ZAI_CODING_PLAN": "pro"
      }
    }
  }
}
```

자세한 설정은 [mcp-integration.md](./mcp-integration.md) 참조.

## 동시성 모델

- **state.sh / pool.sh**: 각자 별도 락 파일. Linux 는 `flock`, macOS 는 portable `mkdir`-lock. `with_state_lock` 함수 패턴.
  - **macOS mkdir-lock 캐비엇**: 락 보유자가 `SIGKILL`(또는 `kill -9`)로 즉사하면 `rmdir` 가 실행되지 않아 락 디렉토리가 stale 로 남고, 다음 호출자가 `OHMYCLAW_LOCK_TIMEOUT_MS`(기본 10s) 만큼 대기 후 에러. 복구는 stale `.lockdir` 디렉토리 수동 삭제 또는 `make clean`. SIGTERM / 정상 종료에서는 trap/EXIT 으로 정리됨. `flock` 경로(Linux)는 커널이 fd 회수 시 자동 해제하므로 영향 없음.
- **worker semaphore**: `pool.sh acquire-worker` 가 `${OHMYCLAW_STATE_DIR}/pids/<session>/slot-*` 파일로 maxWorkers 강제. `sweep` 으로 dead PID 회수.
- **MCP server**: 동시 요청은 SDK 가 직렬 처리. 외부 명령은 `execFile` 으로 격리.

## 우로보로스 보존 (불변 계약)

본 격상은 `prompts/reviewer.md` 의 5관점 갭 감지 + `GAP_DETECTED → fix 1회 → ESCALATED` 흐름을 **건드리지 않는다**. cancel-signal 발신 시 OMX/Ouroboros 가 기대하는 시그널과 정합한다.

## 참고

- [oh-my-pi (omp)](https://github.com/can1357/oh-my-pi) — 1순위 엔진 (ACP 경계로 통합)
- [Ouroboros (Q00/ouroboros)](https://github.com/Q00/ouroboros) — Ambiguity Score 명확성 게이트 영감
- [oh-my-claudecode (OMC)](https://github.com/Yeachan-Heo/oh-my-claudecode) — session-scoped state, ralph/team 컨셉
- [oh-my-codex (OMX)](https://github.com/Yeachan-Heo/oh-my-codex) — verb 패턴, role 분리
- [@modelcontextprotocol/sdk](https://github.com/modelcontextprotocol/typescript-sdk) — MCP TypeScript SDK
