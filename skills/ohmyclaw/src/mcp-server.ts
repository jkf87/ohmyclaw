#!/usr/bin/env node
/**
 * ohmyclaw MCP server — stdio JSON-RPC 2.0 (McpServer + registerTool API)
 *
 * 도구 5개:
 *   ohmyclaw_route(task, category?, plan?, codex?)   → 모델 라우팅 (select-model.sh --json)
 *   ohmyclaw_pool_status(provider?)                  → 풀 상태 (pool.sh status)
 *   ohmyclaw_engine_resolve(model, authType?, role?) → ACP 엔진 명령 (engine.sh resolve)
 *   ohmyclaw_doctor()                                → 종합 점검 (engine.sh doctor)
 *   ohmyclaw_version()                               → 버전
 *
 * 등록: Claude Code / OpenClaw mcp 설정에:
 *   { "command": "node", "args": ["<repo>/skills/ohmyclaw/dist/mcp-server.js"] }
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { readFileSync, existsSync } from "node:fs";

const execFileP = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
// src/mcp-server.ts(ts-node) 또는 dist/mcp-server.js 어디서 실행하든 skills/ohmyclaw 로 해석
const SKILL_DIR = resolve(__dirname, "..");

const SELECT_MODEL = resolve(SKILL_DIR, "select-model.sh");
const POOL_SH = resolve(SKILL_DIR, "pool.sh");
const ENGINE_SH = resolve(SKILL_DIR, "engine.sh");
const ROUTING_JSON = resolve(SKILL_DIR, "routing.json");

/** 안전 실행 — 텍스트 stdout 반환 (stderr 는 throw). 4MB 버퍼. */
async function run(cmd: string, args: string[]): Promise<string> {
  try {
    const { stdout } = await execFileP(cmd, args, {
      env: process.env,
      maxBuffer: 1024 * 1024 * 4,
    });
    return stdout.trim();
  } catch (e: unknown) {
    const err = e as { stderr?: string; message?: string; code?: number };
    throw new Error(
      `${cmd} ${args.join(" ")} failed (rc=${err.code ?? "?"}): ${err.stderr || err.message || "unknown"}`,
    );
  }
}

function readVersion(): string {
  const versionPath = resolve(SKILL_DIR, "../../VERSION");
  if (existsSync(versionPath)) {
    return readFileSync(versionPath, "utf8").trim();
  }
  try {
    const routing = JSON.parse(readFileSync(ROUTING_JSON, "utf8")) as { version?: string };
    return routing.version ?? "unknown";
  } catch {
    return "unknown";
  }
}

const server = new McpServer({
  name: "ohmyclaw",
  version: readVersion(),
});

// 헬퍼: 에러를 isError 응답으로 감싸기
function textResult(text: string) {
  return { content: [{ type: "text" as const, text }] };
}
function errorResult(msg: string) {
  return { content: [{ type: "text" as const, text: `ERROR: ${msg}` }], isError: true };
}

// ──────────────────────────────────────────────
// ohmyclaw_route
// ──────────────────────────────────────────────
server.registerTool(
  "ohmyclaw_route",
  {
    description:
      "ohmyclaw 라우팅 — 태스크 텍스트와 카테고리/플랜으로 적정 모델 ID 를 결정. JSON 결정 객체(model, category, complexity, fallbackChain) 반환.",
    inputSchema: {
      task: z.string().min(1, "task is required"),
      category: z
        .enum([
          "auto",
          "coding_general",
          "coding_arch",
          "reasoning",
          "debugging",
          "security",
          "korean_nlp",
          "content_creation",
          "data_analysis",
        ])
        .default("auto"),
      plan: z.enum(["lite", "pro", "max"]).default("pro"),
      codex: z.boolean().default(false),
    },
  },
  async ({ task, category, plan, codex }) => {
    try {
      const args = [task, category, `--plan=${plan}`, "--json"];
      if (codex) args.push("--codex");
      return textResult(await run(SELECT_MODEL, args));
    } catch (e) {
      return errorResult(e instanceof Error ? e.message : String(e));
    }
  },
);

// ──────────────────────────────────────────────
// ohmyclaw_pool_status
// ──────────────────────────────────────────────
server.registerTool(
  "ohmyclaw_pool_status",
  {
    description: "ohmyclaw 계정 풀 상태. provider 미지정 시 전체.",
    inputSchema: {
      provider: z.string().optional().describe("zai|codex|openrouter|claudecli"),
    },
  },
  async ({ provider }) => {
    try {
      const args = provider ? ["status", provider] : ["status"];
      return textResult(await run(POOL_SH, args));
    } catch (e) {
      return errorResult(e instanceof Error ? e.message : String(e));
    }
  },
);

// ──────────────────────────────────────────────
// ohmyclaw_engine_resolve
// ──────────────────────────────────────────────
server.registerTool(
  "ohmyclaw_engine_resolve",
  {
    description:
      "ACP 엔진 명령 결정. 모델·인증타입·역할로 acpx 실행 템플릿(`ENGINE|CMD_TEMPLATE`) 반환. omp 우선, 폴백 자동.",
    inputSchema: {
      model: z.string().min(1).describe("예: glm-5.1, gpt-5.4, openrouter-claude-opus-4"),
      authType: z
        .enum(["oauth_zai", "oauth_codex", "api_key", "oauth_claude_cli", ""])
        .default("")
        .describe("계정 인증 타입 (선택)"),
      role: z
        .enum([
          "reviewer",
          "planner",
          "critic",
          "verifier",
          "architect",
          "executor",
          "worker",
          "debugger",
          "team-executor",
        ])
        .default("executor"),
    },
  },
  async ({ model, authType, role }) => {
    try {
      return textResult(await run(ENGINE_SH, ["resolve", model, authType ?? "", role]));
    } catch (e) {
      return errorResult(e instanceof Error ? e.message : String(e));
    }
  },
);

// ──────────────────────────────────────────────
// ohmyclaw_doctor
// ──────────────────────────────────────────────
server.registerTool(
  "ohmyclaw_doctor",
  {
    description: "engine.sh doctor 출력 — acpx/omp/pi/codex/claude 가용성 + 스키마 검증.",
    inputSchema: {},
  },
  async () => {
    try {
      return textResult(await run(ENGINE_SH, ["doctor"]));
    } catch (e) {
      return errorResult(e instanceof Error ? e.message : String(e));
    }
  },
);

// ──────────────────────────────────────────────
// ohmyclaw_version
// ──────────────────────────────────────────────
server.registerTool(
  "ohmyclaw_version",
  {
    description: "ohmyclaw 버전 (VERSION 파일 또는 routing.json#version).",
    inputSchema: {},
  },
  async () => textResult(`ohmyclaw ${readVersion()}`),
);

// stdio 시작
const transport = new StdioServerTransport();
await server.connect(transport);
