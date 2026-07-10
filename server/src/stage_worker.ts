// 剧本沙箱 worker：在 node:vm 隔离上下文里执行 LLM 生成的剧本，
// 把 Stage SDK 调用翻译成消息发给宿主(ScriptRunner)，await 语义靠 ack 驱动。
// 沙箱内只暴露 stage/cast/console.log，无 require/process/timers。
// 设计文档: docs/script-runtime-design.md

import { parentPort, workerData } from 'node:worker_threads';
import vm from 'node:vm';
import type { HostToWorkerMsg, StageActorInfo, StageWorkerData, WorkerToHostMsg } from './stage_types.ts';

const port = parentPort;
if (!port) throw new Error('stage_worker 必须作为 worker 启动');
const { code, actors, maxCommands } = workerData as StageWorkerData;

let cmdSeq = 0;
let issued = 0;
let subSeq = 0;
let hudSeq = 0;
let mainResolved = false;
let finished = false;
const pendingCmds = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
const subs = new Map<string, (payload?: Record<string, unknown>) => void>();

function post(m: WorkerToHostMsg): void {
  port!.postMessage(m);
}

function finish(result?: Record<string, unknown>): void {
  if (finished) return;
  finished = true;
  post({ kind: 'done', result });
}

function fail(message: string): void {
  if (finished) return;
  finished = true;
  post({ kind: 'error', message });
}

/** 主函数已返回、无订阅、无在途命令 ⇒ 剧本自然收场（剧场型脚本不必显式 end）。 */
function maybeIdleFinish(): void {
  if (mainResolved && subs.size === 0 && pendingCmds.size === 0) finish();
}

function sendCmd(op: string, args: Record<string, unknown> = {}, actorId?: string): Promise<unknown> {
  if (++issued > maxCommands) {
    const msg = `命令预算用尽(上限 ${maxCommands} 条)`;
    fail(msg);
    return Promise.reject(new Error(msg));
  }
  const cmdId = ++cmdSeq;
  return new Promise((resolve, reject) => {
    pendingCmds.set(cmdId, { resolve, reject });
    post({ kind: 'cmd', cmdId, actorId, op, args });
  });
}

/** 设置型命令(follow/hud 等)：发出即忘，失败不炸脚本。 */
function fireCmd(op: string, args: Record<string, unknown> = {}, actorId?: string): void {
  sendCmd(op, args, actorId).catch(() => {});
}

function subscribe(ev: string, params: Record<string, unknown>, fn: (payload?: Record<string, unknown>) => void): () => void {
  const subId = `s${++subSeq}`;
  subs.set(subId, fn);
  post({ kind: 'subscribe', subId, ev, params });
  return () => {
    if (subs.delete(subId)) {
      post({ kind: 'unsubscribe', subId });
      setImmediate(maybeIdleFinish);
    }
  };
}

port.on('message', (m: HostToWorkerMsg) => {
  if (m.kind === 'ack') {
    const p = pendingCmds.get(m.cmdId);
    if (!p) return;
    pendingCmds.delete(m.cmdId);
    if (m.error) p.reject(new Error(m.error));
    else p.resolve(m.result);
    // 等脚本的微任务(后续 await/新命令)排空后再判定是否自然收场
    setImmediate(maybeIdleFinish);
  } else if (m.kind === 'event') {
    const fn = subs.get(m.subId);
    if (!fn) return;
    try {
      fn(m.payload);
    } catch (e) {
      fail(`事件回调异常: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
});

// ---- Stage SDK(沙箱内可见的对象) ----

interface SdkActor {
  readonly id: string;
  readonly name: string;
  readonly isPlayer: boolean;
  moveTo(target: unknown): Promise<unknown>;
  say(text: string, action?: string): Promise<unknown>;
  do(action: string): Promise<unknown>;
  follow(target: SdkActor): void;
  flee(from: SdkActor): void;
  stop(): void;
}

function makeActor(info: StageActorInfo): SdkActor {
  return {
    id: info.id,
    name: info.name,
    isPlayer: info.isPlayer,
    moveTo: (target) => sendCmd('move_to', { target }, info.id),
    say: (text, action) => sendCmd('say', action ? { text, action } : { text }, info.id),
    do: (action) => sendCmd('do_action', { action }, info.id),
    follow: (target) => fireCmd('follow', { target: target.id }, info.id),
    flee: (from) => fireCmd('flee', { target: from.id }, info.id),
    stop: () => fireCmd('stop', {}, info.id),
  };
}

const actorList = actors.map(makeActor);

function cast(...names: string[]): SdkActor[] {
  return names.map((n) => {
    const a = actorList.find((x) => x.name === n);
    if (!a) throw new Error(`找不到角色: ${n}`);
    return a;
  });
}

const stage = {
  actors: actorList,
  player: actorList.find((a) => a.isPlayer) ?? null,
  narrate: (text: string) => sendCmd('narrate', { text }),
  banner: (text: string) => fireCmd('banner', { text }),
  sleep: (sec: number) => new Promise<void>((r) => setTimeout(r, Math.max(0, sec) * 1000)),
  prompt: (actor: SdkActor, hint: string) => sendCmd('prompt', { hint }, actor.id),
  end: (result?: Record<string, unknown>) => finish(result),
  prop: {
    create: (desc: string, near: unknown) =>
      sendCmd('prop_create', { desc, near: typeof near === 'object' && near !== null && 'id' in near ? (near as SdkActor).id : near }),
    place: (id: string, at: unknown) => sendCmd('prop_place', { id, at }),
    remove: (id: string) => fireCmd('prop_remove', { id }),
  },
  hud: {
    score: (label: string) => {
      const id = `hud${++hudSeq}`;
      fireCmd('hud_score', { id, label });
      return { add: (n = 1) => fireCmd('hud_score_add', { id, n }) };
    },
    countdown: (sec: number) => {
      const id = `hud${++hudSeq}`;
      fireCmd('hud_countdown', { id, sec });
      return {
        onDone: (fn: () => void) => subscribe('timer', { id }, fn),
        cancel: () => fireCmd('hud_cancel', { id }),
      };
    },
    toast: (text: string) => fireCmd('hud_toast', { text }),
  },
  camera: {
    focus: (a: SdkActor) => fireCmd('camera', { mode: 'focus', actorId: a.id }),
    overview: () => fireCmd('camera', { mode: 'overview' }),
    dialog: (a: SdkActor, b: SdkActor) => fireCmd('camera', { mode: 'dialog', a: a.id, b: b.id }),
    reset: () => fireCmd('camera', { mode: 'reset' }),
  },
  on: (ev: string, ...rest: unknown[]): (() => void) => {
    if (ev === 'near') {
      const [a, b, dist, fn] = rest as [SdkActor, SdkActor, number, () => void];
      return subscribe('near', { a: a.id, b: b.id, dist }, fn);
    }
    if (ev === 'tap') {
      const [a, fn] = rest as [SdkActor, () => void];
      return subscribe('tap', { actorId: a.id }, fn);
    }
    throw new Error(`未知事件: ${ev}`);
  },
};

// ---- 在 vm 沙箱里跑剧本 ----

const sandbox = {
  stage,
  cast,
  console: { log: (...a: unknown[]) => post({ kind: 'log', text: a.map(String).join(' ') }) },
};
const ctx = vm.createContext(sandbox);

let main: (() => Promise<unknown>) | null = null;
try {
  main = vm.runInContext(`(async () => {\n${code}\n})`, ctx, { filename: 'screenplay.js' }) as () => Promise<unknown>;
} catch (e) {
  fail(`脚本语法错误: ${e instanceof Error ? e.message : String(e)}`);
}

if (main) {
  main().then(
    () => {
      mainResolved = true;
      setImmediate(maybeIdleFinish);
    },
    (e: unknown) => fail(`脚本运行异常: ${e instanceof Error ? e.message : String(e)}`),
  );
}
