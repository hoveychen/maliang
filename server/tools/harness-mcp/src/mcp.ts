// maliang game-pilot 的 MCP 服务器（game-pilot 重写 P4）。
// 让 Claude 拿到原生工具驱动游戏——桥接到【客户端】的 debug TCP 命令口（非游戏服务器 8080）。
// 依赖零：MCP stdio 传输就是逐行 JSON-RPC 2.0，手写实现（stdin/stdout）+ node:net TCP 客户端。
// 运行：node server/tools/harness-mcp/src/mcp.ts   （Node ≥23 原生跑 .ts；端口见 MALIANG_HARNESS_PORT）
// 协议：stdout 只走 JSON-RPC，日志一律 stderr。
import { TcpClient, type Reply } from "./tcp_client.ts";
import { diffState, type State } from "./delta.ts";

const HOST = process.env.MALIANG_HARNESS_HOST || "127.0.0.1";
const PORT = Number(process.env.MALIANG_HARNESS_PORT || "8578");
const client = new TcpClient(HOST, PORT);
let lastState: State | null = null;

function log(...a: unknown[]): void {
  process.stderr.write("[harness-mcp] " + a.map((x) => String(x)).join(" ") + "\n");
}

async function ensureConnected(): Promise<void> {
  if (client.connected()) return;
  await client.connect(6000).catch((e) => {
    throw new Error(
      `连不上游戏客户端 ${HOST}:${PORT}（起了桌面 debug 实例吗？真机做了 adb forward 吗？）: ${e.message}`,
    );
  });
  log(`connected ${HOST}:${PORT}`);
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

// ── 工具处理器（返回 JSON 结果，tools/call 再包成 text content）────────────────
async function toolState(): Promise<Reply> {
  const s = await client.send({ op: "state" });
  lastState = s as State;
  return s;
}

async function toolDo(args: Record<string, unknown>): Promise<Reply> {
  const action = String(args.action || "");
  if (!action) throw new Error("do 需要 action");
  const cmd: Record<string, unknown> = { op: "do", action };
  if (args.args && typeof args.args === "object") cmd.args = args.args;
  const r = await client.send(cmd, 45000);
  const st = r.state;
  if (st && typeof st === "object") {
    r.delta = lastState ? diffState(lastState, st as State) : null;
    lastState = st as State;
  }
  return r;
}

function matches(s: Reply, args: Record<string, unknown>): boolean {
  const v = s[String(args.field)];
  if (args.truthy) return Boolean(v);
  if (args.gte !== undefined && args.gte !== null) return Number(v ?? 0) >= Number(args.gte);
  if (args.equals !== undefined && args.equals !== null) return String(v) === String(args.equals);
  return v !== undefined && v !== null;
}

async function toolWaitUntil(args: Record<string, unknown>): Promise<Reply> {
  const timeoutMs = Number(args.timeout ?? 30) * 1000;
  const deadline = Date.now() + timeoutMs;
  let last: Reply | null = null;
  while (Date.now() < deadline) {
    let s: Reply | null = null;
    try {
      s = await client.send({ op: "state" });
    } catch {
      s = null;
    }
    if (s) {
      last = s;
      if (matches(s, args)) {
        lastState = s as State;
        return { ok: true, matched: true, state: s };
      }
    }
    await sleep(1000);
  }
  return { ok: false, matched: false, timeout: true, state: last };
}

async function toolObserve(): Promise<Reply> {
  const state = await client.send({ op: "state" });
  lastState = state as State;
  const actions = await client.send({ op: "actions" });
  return { ok: true, state, actions: actions.actions ?? [] };
}

type Content = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };

async function callTool(name: string, args: Record<string, unknown>): Promise<Content[]> {
  await ensureConnected();
  switch (name) {
    case "observe":
      return [textContent(await toolObserve())];
    case "access":
      return [textContent(await client.send({ op: "access", texts: Boolean(args.texts) }))];
    case "actions":
      return [textContent(await client.send({ op: "actions" }))];
    case "state":
      return [textContent(await toolState())];
    case "do":
      return [textContent(await toolDo(args))];
    case "say":
      return [textContent(await toolDo({ action: "say", args: { text: String(args.text || "") } }))];
    case "wait_until":
      return [textContent(await toolWaitUntil(args))];
    case "screenshot": {
      const r = await client.send({
        op: "screencap",
        wire: true,
        max_dim: Number(args.max_dim ?? 960),
        quality: Number(args.quality ?? 0.75),
      });
      if (!r.ok || !r.jpg_b64) throw new Error(`截图失败: ${JSON.stringify(r)}`);
      return [{ type: "image", data: String(r.jpg_b64), mimeType: "image/jpeg" }];
    }
    default:
      throw new Error(`未知工具: ${name}`);
  }
}

function textContent(obj: unknown): Content {
  return { type: "text", text: JSON.stringify(obj, null, 1) };
}

// ── 工具清单（tools/list）────────────────────────────────────────────────────
const TOOLS = [
  {
    name: "observe",
    description: "感知当前状态 + 可用动作（一次读全再决策）。返回 {state, actions}。",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "access",
    description: "无障碍元素列表：3D 实体（NPC/仙子/POI/portal/道具）+ 2D 控件，各带稳定 id、屏幕矩形、可用动作。",
    inputSchema: {
      type: "object",
      properties: { texts: { type: "boolean", description: "附带可读 Label 文本" } },
      additionalProperties: false,
    },
  },
  {
    name: "actions",
    description: "当前可用动作扁平列表（按 action_id 挑一条交给 do）。",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "state",
    description: "结构化状态快照（fsm_state/player_tile/npcs/bag/phone/creation… 全量）。",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "do",
    description:
      "执行一个动作 id（真输入优先：tap 投影矩形/真走路/真长按，无真路径回退 handler）。回包含 execution(实际路径)/settled/delta/新 actions。",
    inputSchema: {
      type: "object",
      properties: {
        action: { type: "string", description: "action_id，如 talk:npc:pig_boss / press:btn:/root/… / enter_portal:…" },
        args: { type: "object", description: "动作参数（如 say 的 {text}）" },
      },
      required: ["action"],
      additionalProperties: false,
    },
  },
  {
    name: "say",
    description: "对当前对话对象说一句话（合成 PCM 喂真 VAD，门禁关着会 fed:false）。",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string" } },
      required: ["text"],
      additionalProperties: false,
    },
  },
  {
    name: "wait_until",
    description: "轮询 state 直到某字段满足条件（truthy / equals / gte）或超时。返回命中快照或 timeout。",
    inputSchema: {
      type: "object",
      properties: {
        field: { type: "string" },
        truthy: { type: "boolean" },
        equals: { type: "string" },
        gte: { type: "number" },
        timeout: { type: "number", description: "秒，缺省 30" },
      },
      required: ["field"],
      additionalProperties: false,
    },
  },
  {
    name: "screenshot",
    description: "截当前一帧回传（JPEG）。headless 实例无视口会报错。",
    inputSchema: {
      type: "object",
      properties: { max_dim: { type: "number" }, quality: { type: "number" } },
      additionalProperties: false,
    },
  },
];

// ── JSON-RPC over stdio ───────────────────────────────────────────────────────
function reply(id: unknown, result: unknown): void {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
function replyError(id: unknown, code: number, message: string): void {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n");
}

async function handle(msg: Record<string, unknown>): Promise<void> {
  const method = String(msg.method || "");
  const id = msg.id;
  const isNotification = id === undefined || id === null;
  try {
    switch (method) {
      case "initialize":
        reply(id, {
          protocolVersion: (msg.params as Record<string, unknown>)?.protocolVersion || "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "maliang-pilot", version: "0.1.0" },
        });
        return;
      case "notifications/initialized":
        return; // 通知，无需回
      case "ping":
        reply(id, {});
        return;
      case "tools/list":
        reply(id, { tools: TOOLS });
        return;
      case "tools/call": {
        const params = (msg.params || {}) as Record<string, unknown>;
        const name = String(params.name || "");
        const args = (params.arguments || {}) as Record<string, unknown>;
        try {
          const content = await callTool(name, args);
          reply(id, { content });
        } catch (e) {
          // 工具级错误：以 isError 内容返回，让模型看到失败原因而非中断会话
          reply(id, { content: [{ type: "text", text: String((e as Error).message) }], isError: true });
        }
        return;
      }
      default:
        if (!isNotification) replyError(id, -32601, `method not found: ${method}`);
        return;
    }
  } catch (e) {
    if (!isNotification) replyError(id, -32603, String((e as Error).message));
  }
}

function main(): void {
  log(`starting; target client TCP ${HOST}:${PORT}`);
  let buf = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk: string) => {
    buf += chunk;
    let nl = buf.indexOf("\n");
    while (nl >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      nl = buf.indexOf("\n");
      if (line.trim()) {
        let msg: Record<string, unknown> | null = null;
        try {
          msg = JSON.parse(line);
        } catch {
          log("bad json line dropped");
        }
        if (msg) void handle(msg);
      }
    }
  });
  process.stdin.on("end", () => {
    client.close();
    process.exit(0);
  });
}

main();
