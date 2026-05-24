# ohmyclaw MCP 통합 가이드

v1.4.0 부터 ohmyclaw 는 stdio JSON-RPC 2.0 MCP 서버를 제공한다. Claude Code / OpenClaw / Codex / 임의 MCP 호스트에서 ohmyclaw 도구를 1급 시민으로 호출할 수 있다.

## 빌드

```bash
cd <repo>
npm install
npm run build:mcp          # → skills/ohmyclaw/dist/mcp-server.js
```

타입체크만:
```bash
npm run build:mcp:check
```

요구: Node ≥ 22.

## 노출 도구 5종

| 도구 | 매핑 | 인자 |
|------|------|------|
| `ohmyclaw_route` | `select-model.sh --json` | `task`(required), `category?`, `plan?`, `codex?` |
| `ohmyclaw_pool_status` | `pool.sh status [provider]` | `provider?` |
| `ohmyclaw_engine_resolve` | `engine.sh resolve` | `model`(required), `authType?`, `role?` |
| `ohmyclaw_doctor` | `engine.sh doctor` | — |
| `ohmyclaw_version` | VERSION 파일 또는 routing.json | — |

스키마는 zod 로 정의되어 JSON Schema 로 자동 export 된다.

## Claude Code 등록

`~/.claude/mcp.json` 또는 프로젝트 `.claude/mcp.json`:

```jsonc
{
  "mcpServers": {
    "ohmyclaw": {
      "command": "node",
      "args": ["/absolute/path/to/repo/skills/ohmyclaw/dist/mcp-server.js"],
      "env": {
        "OHMYCLAW_HOME": "${HOME}/.ohmyclaw",
        "OHMYCLAW_STATE_DIR": "${HOME}/.cache/ohmyclaw",
        "ZAI_CODING_PLAN": "pro",
        "CODEX_OAUTH_ENABLED": "false"
      }
    }
  }
}
```

Claude Code 재시작 후 `/mcp` 로 ohmyclaw 가 떠있는지 확인. 채팅에서:
```
ohmyclaw_route task="GraphQL 마이그레이션 설계" category="coding_arch" plan="pro"
```

## OpenClaw 등록

OpenClaw 가 MCP 클라이언트로 동작하는 경우 (예: `openclaw mcp add`):

```bash
openclaw mcp add ohmyclaw \
  --command node \
  --args /absolute/path/skills/ohmyclaw/dist/mcp-server.js \
  --env OHMYCLAW_HOME=$HOME/.ohmyclaw \
  --env ZAI_CODING_PLAN=pro
```

또는 OpenClaw 설정 JSON 에 직접 추가하는 방식은 OpenClaw 의 MCP 매니페스트 포맷을 따른다.

## Codex (acpx) 경유

`acpx` 자체가 MCP 호스트는 아니지만, ohmyclaw MCP 도구의 출력을 codex 세션에서 활용하려면 두 방식이 있다:

1. **직접 호출**: codex 세션 안에서 `bash` 도구로 `node skills/ohmyclaw/dist/mcp-server.js` 와 stdio JSON-RPC 를 주고받기.
2. **얇은 래퍼 함수**: `cli.sh route/engine` 을 codex 세션의 verb 로 노출 (이미 cli.sh 가 standalone 으로 동작).

권장은 (2) — `cli.sh` 가 단일 진입점이라 더 단순.

## 직접 stdio 테스트

```bash
node skills/ohmyclaw/dist/mcp-server.js <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ohmyclaw_route","arguments":{"task":"add null check","category":"coding_general","plan":"pro"}}}
JSON
```

예상 출력 (NDJSON):
```
{"result":{"protocolVersion":"2024-11-05",...},"jsonrpc":"2.0","id":1}
{"result":{"tools":[{...5개}]},"jsonrpc":"2.0","id":2}
{"result":{"content":[{"type":"text","text":"{\"model\":\"glm-5\",...}"}]},"jsonrpc":"2.0","id":3}
```

## 환경변수

MCP 서버는 부모 프로세스의 env 를 그대로 상속한다. 다음을 설정하면 도구가 그대로 반영:

| 변수 | 용도 |
|------|------|
| `OHMYCLAW_HOME` | `~/.ohmyclaw` (state + hooks 루트) |
| `OHMYCLAW_STATE_DIR` | `~/.cache/ohmyclaw` (pool-state) |
| `OHMYCLAW_SESSION_ID` | 세션 격리 활성화 |
| `ZAI_CODING_PLAN` | `lite\|pro\|max` |
| `CODEX_OAUTH_ENABLED` | `true\|false` |
| `OPENROUTER_ENABLED` | `true\|false` |
| `OPENROUTER_API_KEY` | OpenRouter API 키 |
| `OHMYCLAW_ENGINE` | 엔진 강제 (omp/pi/codex/claude) |

## 트러블슈팅

| 증상 | 해결 |
|------|------|
| `mcp-server.js: command not found` | `npm run build:mcp` 먼저 |
| `Cannot find module @modelcontextprotocol/sdk` | `npm install` (Node ≥ 22) |
| tools/call 가 isError 응답 | 자세한 메시지는 `content[0].text` 참조. 보통 child process(`select-model.sh` 등) 실패 — 직접 CLI 로 재현 시도 |
| Claude Code 가 서버 인식 못함 | `~/.claude/mcp.json` 경로가 절대경로인지 확인. Claude Code 재시작 |

## 보안 고려

- 본 서버는 read/eval 도구만 노출하며 파일 쓰기/실행 명령은 없음.
- child process 는 `execFile` 사용 — 셸 인터프리테이션 없음(인젝션 안전).
- 환경변수에 API 키가 있는 경우 MCP 호스트에서 격리/redact 권장.
