// ScriptRunner(宿主侧)：把一段 LLM 写的 TS 剧本剥类型后丢进 stage_worker 沙箱执行，
// 命令路由给 StageBackend，事件由宿主注入；带整场超时/单命令 ack 超时/强杀。
// 设计文档: docs/script-runtime-design.md

import { Worker } from 'node:worker_threads';
import vm from 'node:vm';
import * as nodeModule from 'node:module';
import type {
  HostToWorkerMsg,
  StageActorInfo,
  StageBackend,
  StageRunResult,
  StageSubscription,
  StageWorkerData,
  WorkerToHostMsg,
} from './stage_types.ts';

// stripTypeScriptTypes 是 Node 22.13+/23+ 的实验 API，@types/node 可能尚未收录，做窄化访问。
const stripTypes = (nodeModule as unknown as { stripTypeScriptTypes?: (code: string) => string }).stripTypeScriptTypes;

/** 把 LLM 写的 TS 剧本剥成可执行 JS；语法/环境问题直接抛错。 */
export function stripStageScript(tsCode: string): string {
  if (!stripTypes) throw new Error('当前 Node 不支持 stripTypeScriptTypes(需 v23+)');
  return stripTypes(tsCode);
}

export interface StageRunOpts {
  /** LLM 生成的 TS 剧本源码(函数体，可用 await/stage/cast)。 */
  code: string;
  actors: StageActorInfo[];
  /** 整场墙钟超时，默认 10 分钟。 */
  timeoutMs?: number;
  /** 单条命令 ack 超时，默认 30s。 */
  cmdTimeoutMs?: number;
  /** 命令总数预算，默认 500。 */
  maxCommands?: number;
}

const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_CMD_TIMEOUT_MS = 30 * 1000;
const DEFAULT_MAX_COMMANDS = 500;

/** 一个 ScriptRunner 只跑一场剧本；跑完/被杀后丢弃。 */
export class ScriptRunner {
  #backend: StageBackend;
  #worker: Worker | null = null;
  #settled = false;
  #resolve: ((r: StageRunResult) => void) | null = null;
  #timeout: NodeJS.Timeout | null = null;
  #cmdTimeoutMs = DEFAULT_CMD_TIMEOUT_MS;
  #subs = new Map<string, StageSubscription>();
  #logs: string[] = [];

  constructor(backend: StageBackend) {
    this.#backend = backend;
  }

  /** 脚本 console.log 的输出(调试用)。 */
  get logs(): readonly string[] {
    return this.#logs;
  }

  /** 当前活跃订阅(供后端布置检测器/测试注入事件)。 */
  get subscriptions(): ReadonlyMap<string, StageSubscription> {
    return this.#subs;
  }

  get running(): boolean {
    return this.#worker !== null && !this.#settled;
  }

  async run(opts: StageRunOpts): Promise<StageRunResult> {
    if (this.#worker) throw new Error('ScriptRunner 只能 run 一次');
    let js: string;
    try {
      js = stripStageScript(opts.code);
      // 先在宿主侧做一次语法编译检查，垃圾脚本不值得起 worker
      new vm.Script(`(async () => {\n${js}\n})`, { filename: 'screenplay.js' });
    } catch (e) {
      return { status: 'error', message: `脚本语法错误: ${e instanceof Error ? e.message : String(e)}` };
    }
    this.#cmdTimeoutMs = opts.cmdTimeoutMs ?? DEFAULT_CMD_TIMEOUT_MS;
    const workerData: StageWorkerData = {
      code: js,
      actors: opts.actors,
      maxCommands: opts.maxCommands ?? DEFAULT_MAX_COMMANDS,
    };
    const worker = new Worker(new URL('./stage_worker.ts', import.meta.url), { workerData });
    this.#worker = worker;
    worker.on('message', (m: WorkerToHostMsg) => this.#onMessage(m));
    worker.on('error', (e) => this.#settle({ status: 'error', message: `沙箱异常: ${e.message}` }));
    worker.on('exit', () => {
      if (!this.#settled) this.#settle({ status: 'error', message: '沙箱意外退出' });
    });
    this.#timeout = setTimeout(() => this.#settle({ status: 'timeout' }), opts.timeoutMs ?? DEFAULT_TIMEOUT_MS);
    return new Promise<StageRunResult>((resolve) => {
      this.#resolve = resolve;
    });
  }

  /** 宿主注入事件(near/tap/timer 触发)。 */
  emitEvent(subId: string, payload?: Record<string, unknown>): void {
    this.#post({ kind: 'event', subId, payload });
  }

  /** 强杀(小朋友说不玩了/断连/异常兜底)。 */
  kill(): void {
    this.#settle({ status: 'killed' });
  }

  #post(m: HostToWorkerMsg): void {
    if (!this.#settled) this.#worker?.postMessage(m);
  }

  #onMessage(m: WorkerToHostMsg): void {
    if (m.kind === 'cmd') {
      let acked = false;
      const ack = (result?: Record<string, unknown>, error?: string) => {
        if (acked) return;
        acked = true;
        clearTimeout(timer);
        this.#post({ kind: 'ack', cmdId: m.cmdId, result, error });
      };
      const timer = setTimeout(() => ack(undefined, `命令超时: ${m.op}`), this.#cmdTimeoutMs);
      this.#backend.execCommand({ cmdId: m.cmdId, actorId: m.actorId, op: m.op, args: m.args }).then(
        (result) => ack(result ?? undefined),
        (e: unknown) => ack(undefined, e instanceof Error ? e.message : String(e)),
      );
    } else if (m.kind === 'subscribe') {
      const sub: StageSubscription = { subId: m.subId, ev: m.ev, params: m.params };
      this.#subs.set(m.subId, sub);
      this.#backend.onSubscribe?.(sub);
    } else if (m.kind === 'unsubscribe') {
      if (this.#subs.delete(m.subId)) this.#backend.onUnsubscribe?.(m.subId);
    } else if (m.kind === 'done') {
      this.#settle({ status: 'done', result: m.result });
    } else if (m.kind === 'error') {
      this.#settle({ status: 'error', message: m.message });
    } else if (m.kind === 'log') {
      this.#logs.push(m.text);
    }
  }

  #settle(r: StageRunResult): void {
    if (this.#settled) return;
    this.#settled = true;
    if (this.#timeout) clearTimeout(this.#timeout);
    const worker = this.#worker;
    this.#worker = null;
    if (worker) void worker.terminate();
    this.#resolve?.(r);
  }
}
