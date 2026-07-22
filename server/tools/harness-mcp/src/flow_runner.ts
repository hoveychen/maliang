// Flow Registry 的 MCP/web 侧执行桥（Flow Registry P2）。
// 设计 §4 A2：MCP/web/CLI 三入口都经同一个 pilot_runner.py 子进程跑 flow——单一执行路径。
// 这里只做「拼 argv → spawn python → 解析回来的 JSON」，不重实现 flow 逻辑。
// 纯函数（buildRunnerArgs / parseRunnerJson）抽出来给 node:test 单测，spawn 那层薄到不用测。
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const PYTHON = process.env.MALIANG_PYTHON || "python3";
// src/ → harness-mcp → tools → server → repo 根 → test/e2e/pilot_runner.py
export const RUNNER_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..", "..", "..", "..", "test", "e2e", "pilot_runner.py",
);

export type RunnerOpts = { host: string; port: number };

// 拼 pilot_runner 的 argv（纯函数，可单测）。mode="list" 不连游戏；mode="flow" 带 --flow/--args/--port。
export function buildRunnerArgs(
  mode: "list" | "flow",
  opts: RunnerOpts,
  flow?: { name: string; args?: Record<string, unknown> },
): string[] {
  const argv = [RUNNER_PATH];
  if (mode === "list") {
    argv.push("--list");
    return argv;
  }
  if (!flow?.name) throw new Error("run_flow 需要 flow name");
  argv.push("--flow", flow.name, "--json", "--host", opts.host, "--port", String(opts.port));
  if (flow.args && Object.keys(flow.args).length > 0) {
    argv.push("--args", JSON.stringify(flow.args));
  }
  return argv;
}

// 从 runner stdout 里取最后一行能解析成 JSON 的行（runner 的结果是单行 JSON；前面可能混杂日志）。
export function parseRunnerJson(stdout: string): Record<string, unknown> {
  const lines = stdout.split("\n").map((l) => l.trim()).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const v = JSON.parse(lines[i]);
      if (v && typeof v === "object") return v as Record<string, unknown>;
    } catch {
      /* 非 JSON 行（日志）跳过 */
    }
  }
  throw new Error(`runner 未输出可解析 JSON;stdout=${stdout.slice(0, 500)}`);
}

type SpawnResult = { code: number; stdout: string; stderr: string };

function spawnRunner(argv: string[], timeoutMs: number): Promise<SpawnResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(PYTHON, argv, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    const to = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`flow runner 超时(${timeoutMs}ms);argv=${argv.join(" ")}`));
    }, timeoutMs);
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (e) => {
      clearTimeout(to);
      reject(new Error(`起 python 失败(${PYTHON}): ${e.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(to);
      resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}

// 列注册表全部 flow（子进程 --list，不连游戏）。返回 {ok, flows:[...]}。
export async function listFlows(): Promise<Record<string, unknown>> {
  const r = await spawnRunner(buildRunnerArgs("list", { host: "", port: 0 }), 15000);
  return parseRunnerJson(r.stdout);
}

// 按名跑 flow（子进程 --flow，连 opts 指定的游戏口）。回 runner 的 {ok,flow,ran,coverage,delta,duration} 或 {ok:false,error}。
// 超时给足：enter_world 冷启导航实测 ~26s,回归链更久 → 缺省 240s。
export async function runFlow(
  name: string,
  args: Record<string, unknown> | undefined,
  opts: RunnerOpts,
  timeoutMs = 240000,
): Promise<Record<string, unknown>> {
  const r = await spawnRunner(buildRunnerArgs("flow", opts, { name, args }), timeoutMs);
  const parsed = parseRunnerJson(r.stdout);
  // runner 失败(退出非 0)时也会打一行 {ok:false,error};原样透传让模型看到原因。
  return parsed;
}
