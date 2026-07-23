// Flow Registry 的 MCP/web 侧执行桥（Flow Registry P2）。
// 设计 §4 A2：MCP/web/CLI 三入口都经同一个 pilot_cli.py 子进程跑 flow——单一执行路径。
// 这里只做「拼 argv → spawn python → 解析回来的 JSON」，不重实现 flow 逻辑。
// 纯函数（buildRunnerArgs / parseRunnerJson）抽出来给 node:test 单测，spawn 那层薄到不用测。
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const PYTHON = process.env.MALIANG_PYTHON || "python3";
// src/ → harness-mcp → tools → server → repo 根 → test/e2e/pilot_cli.py
// flow 引擎已折进唯一 CLI pilot_cli.py（原 pilot_runner.py 删）——MCP/web/CLI 仍同一执行路径。
export const CLI_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..", "..", "..", "..", "test", "e2e", "pilot_cli.py",
);

export type RunnerOpts = { host: string; port: number };

// 拼 pilot_cli 的 argv（纯函数，可单测）。全局 --host/--port 必须在子命令**之前**（argparse subparser 规则）。
// mode="list" → `list-flows --with-availability`；mode="flow" → `run-flow <name> [--args ...]`。
export function buildRunnerArgs(
  mode: "list" | "flow",
  opts: RunnerOpts,
  flow?: { name: string; args?: Record<string, unknown> },
): string[] {
  const argv = [CLI_PATH, "--host", opts.host, "--port", String(opts.port)];
  if (mode === "list") {
    // 带可用性：连 opts 指定的游戏口取 state，给每条 flow 标 available{ok,reasons}（现在能不能跑）。
    argv.push("list-flows", "--with-availability");
    return argv;
  }
  if (!flow?.name) throw new Error("run_flow 需要 flow name");
  argv.push("run-flow", flow.name);
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

// 列注册表全部 flow（子进程 --list --with-availability）。连 opts 指定的游戏口取 state，
// 给每条标 available{ok,reasons}；游戏没连上则 available.ok=null。返回 {ok, flows:[...]}。
export async function listFlows(opts: RunnerOpts): Promise<Record<string, unknown>> {
  const r = await spawnRunner(buildRunnerArgs("list", opts), 15000);
  return parseRunnerJson(r.stdout);
}

// 把 listFlows 的完整回包压成 observe 首连要带的极简摘要（纯函数,给 node:test）。
// observe 是 agent 起手最先够到的工具,却只字不提 flow——这里把「有哪些现成 flow、现在哪条能跑」
// 直接推进 observe 回包,让 agent 在决定手搓前就看见「这事有现成流程」的信号。
export type FlowBrief = { name: string; kind: unknown; available: boolean | null; desc?: string };
export function compactFlows(listResult: Record<string, unknown> | null | undefined): FlowBrief[] {
  const flows = Array.isArray((listResult as Record<string, unknown>)?.flows)
    ? ((listResult as Record<string, unknown>).flows as Record<string, unknown>[])
    : [];
  return flows.map((f) => {
    const avail = (f?.available as Record<string, unknown> | undefined)?.ok;
    return {
      name: String(f?.name ?? ""),
      kind: f?.kind ?? null,
      available: avail === true ? true : avail === false ? false : null,
      desc: f?.desc ? String(f.desc) : undefined,
    };
  });
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
