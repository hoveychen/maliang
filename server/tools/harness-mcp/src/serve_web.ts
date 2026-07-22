// CDP 式双栏 web 控制面板的桥接（game-pilot 重写 P6）。零依赖：node:http 服务静态面板 + JSON API，
// 复用 tcp_client.ts 打客户端 debug TCP 口（TCP 客户端只写一次）。人可在浏览器里驱动 harness。
// 运行：node server/tools/harness-mcp/src/serve_web.ts [--web-port 8600]   （连的游戏口见 MALIANG_HARNESS_PORT）
// 单独入口（不与 mcp.ts 的 stdio 混，免得 HTTP 日志污染 JSON-RPC stdout）。
import http from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { TcpClient } from "./tcp_client.ts";
import { listFlows, runFlow } from "./flow_runner.ts";

function argOf(name: string, dflt: string): string {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const HOST = process.env.MALIANG_HARNESS_HOST || "127.0.0.1";
const PORT = Number(process.env.MALIANG_HARNESS_PORT || "8578");
const WEB_PORT = Number(argOf("--web-port", "8600"));
const client = new TcpClient(HOST, PORT);
const INDEX = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "web", "index.html");

async function ensure(): Promise<void> {
  if (!client.connected()) await client.connect(6000);
}

function sendJson(res: http.ServerResponse, code: number, obj: unknown): void {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "content-type": "application/json; charset=utf-8" });
  res.end(body);
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let b = "";
    req.on("data", (c) => (b += c));
    req.on("end", () => resolve(b));
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", "http://x");
    const p = url.pathname;
    if (req.method === "GET" && p === "/") {
      // no-store：面板 HTML/JS 迭代频繁，绝不让浏览器缓存旧版（否则改了面板刷新看不到，实测坑过）。
      res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store, must-revalidate" });
      res.end(readFileSync(INDEX));
      return;
    }
    if (p === "/api/observe") {
      await ensure();
      const state = await client.send({ op: "state" });
      const actions = await client.send({ op: "actions" });
      const access = await client.send({ op: "access" });
      return sendJson(res, 200, {
        ok: true,
        state,
        actions: actions.actions ?? [],
        elements: access.elements ?? [],
      });
    }
    if (p === "/api/shot.jpg") {
      await ensure();
      // max_dim=0 → 不降采样：图的自然尺寸 = 游戏视口，screen_rect 坐标 1:1 对得上（前端叠加框好算）。
      const r = await client.send({ op: "screencap", wire: true, max_dim: 0, quality: 0.7 });
      if (!r.ok || !r.jpg_b64) return sendJson(res, 200, r);
      const buf = Buffer.from(String(r.jpg_b64), "base64");
      res.writeHead(200, { "content-type": "image/jpeg", "cache-control": "no-store" });
      res.end(buf);
      return;
    }
    // Flow Registry 面（P3）：列注册流程 / 按名跑（经 pilot_runner 子进程，与 MCP/CLI 同一执行路径）。
    if (p === "/api/flows" && req.method === "GET") {
      return sendJson(res, 200, await listFlows({ host: HOST, port: PORT }));   // 带 available（连游戏取 state）
    }
    if (p === "/api/run_flow" && req.method === "POST") {
      const body = await readBody(req);
      const parsed = JSON.parse(body || "{}") as { name?: string; args?: Record<string, unknown> };
      if (!parsed.name) return sendJson(res, 400, { ok: false, error: "需要 flow name" });
      return sendJson(res, 200, await runFlow(parsed.name, parsed.args, { host: HOST, port: PORT }));
    }
    if (p === "/api/do" && req.method === "POST") {
      await ensure();
      const body = await readBody(req);
      const parsed = JSON.parse(body || "{}") as { action?: string; args?: Record<string, unknown> };
      if (!parsed.action) return sendJson(res, 400, { ok: false, error: "需要 action" });
      const cmd: Record<string, unknown> = { op: "do", action: parsed.action };
      if (parsed.args) cmd.args = parsed.args;
      return sendJson(res, 200, await client.send(cmd, 45000));
    }
    res.writeHead(404);
    res.end("not found");
  } catch (e) {
    sendJson(res, 500, { ok: false, error: String((e as Error).message) });
  }
});

server.listen(WEB_PORT, "127.0.0.1", () => {
  process.stderr.write(`[serve-web] http://127.0.0.1:${WEB_PORT}  → 客户端 ${HOST}:${PORT}\n`);
});
