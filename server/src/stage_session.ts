// WS 舞台协议：把 ScriptRunner 的命令流桥接到 world 内的客户端。
// 下行: stage_begin / stage_cmd / stage_end / stage_abort (经 WorldHub 广播)
// 上行: stage_event { kind: 'ack' | 'abort' | ... } (P5 起扩 tap/timer/near)
// 一个世界同时只有一场演出；断连清空世界即杀 worker。
// 设计文档: docs/script-runtime-design.md

import { randomUUID } from 'node:crypto';
import { ScriptRunner } from './stage_runner.ts';
import type { StageActorInfo, StageBackend, StageCommand, StageRunResult } from './stage_types.ts';
import type { WorldHub } from './world_hub.ts';

export interface StageStartOpts {
  code: string;
  actors: StageActorInfo[];
  timeoutMs?: number;
  cmdTimeoutMs?: number;
  maxCommands?: number;
}

/** 客户端上行的舞台事件(handleWsMessage 解析后传入)。 */
export interface StageEventMsg {
  kind?: string;
  cmdId?: number;
  result?: Record<string, unknown>;
  error?: string;
}

/** 把命令广播给世界成员、把 ack 关联回 Promise 的舞台后端。 */
class WsStageBackend implements StageBackend {
  #hub: WorldHub;
  #worldId: string;
  #stageId: string;
  #pending = new Map<number, { resolve: (v?: Record<string, unknown>) => void; reject: (e: Error) => void }>();

  constructor(hub: WorldHub, worldId: string, stageId: string) {
    this.#hub = hub;
    this.#worldId = worldId;
    this.#stageId = stageId;
  }

  execCommand(cmd: StageCommand): Promise<Record<string, unknown> | void> {
    return new Promise((resolve, reject) => {
      this.#pending.set(cmd.cmdId, { resolve, reject });
      const n = this.#hub.broadcast(this.#worldId, {
        type: 'stage_cmd',
        stageId: this.#stageId,
        cmdId: cmd.cmdId,
        actorId: cmd.actorId,
        op: cmd.op,
        args: cmd.args,
      });
      if (n === 0) {
        this.#pending.delete(cmd.cmdId);
        reject(new Error('世界里没有观众了'));
      }
    });
  }

  /** 客户端回执；多客户端时首个 ack 生效，后续忽略。 */
  ack(cmdId: number, result?: Record<string, unknown>, error?: string): void {
    const p = this.#pending.get(cmdId);
    if (!p) return;
    this.#pending.delete(cmdId);
    if (error) p.reject(new Error(error));
    else p.resolve(result);
  }

  /** 演出结束：悬空的命令全部回绝，别让 runner 侧 Promise 泄漏。 */
  dispose(): void {
    for (const p of this.#pending.values()) p.reject(new Error('演出已结束'));
    this.#pending.clear();
  }
}

/** 一场进行中的演出。 */
class StageSession {
  readonly stageId = randomUUID();
  readonly runner: ScriptRunner;
  readonly backend: WsStageBackend;

  constructor(hub: WorldHub, worldId: string) {
    this.backend = new WsStageBackend(hub, worldId, this.stageId);
    this.runner = new ScriptRunner(this.backend);
  }
}

/** 每个 world 至多一场演出的调度台。 */
export class StageDirector {
  #hub: WorldHub;
  #active = new Map<string, StageSession>();

  constructor(hub: WorldHub) {
    this.#hub = hub;
  }

  activeIn(worldId: string): boolean {
    return this.#active.has(worldId);
  }

  /**
   * 开演：广播 stage_begin，跑完(自然收场/异常/超时/被杀)广播 stage_end 或 stage_abort。
   * 返回演出终局的 Promise(测试与上层可 await)；世界已有演出时返回 null。
   */
  startStage(worldId: string, opts: StageStartOpts): Promise<StageRunResult> | null {
    if (this.#active.has(worldId)) return null;
    const session = new StageSession(this.#hub, worldId);
    this.#active.set(worldId, session);
    this.#hub.broadcast(worldId, {
      type: 'stage_begin',
      stageId: session.stageId,
      actors: opts.actors,
    });
    return session.runner
      .run({
        code: opts.code,
        actors: opts.actors,
        timeoutMs: opts.timeoutMs,
        cmdTimeoutMs: opts.cmdTimeoutMs,
        maxCommands: opts.maxCommands,
      })
      .then((r) => {
        this.#finish(worldId, session, r);
        return r;
      });
  }

  /** 客户端上行 stage_event 分发：ack 关联命令，abort 终止演出。 */
  handleStageEvent(worldId: string, ev: StageEventMsg): void {
    const session = this.#active.get(worldId);
    if (!session) return;
    if (ev.kind === 'ack' && typeof ev.cmdId === 'number') {
      session.backend.ack(ev.cmdId, ev.result, ev.error);
    } else if (ev.kind === 'abort') {
      session.runner.kill(); // 终局广播走 run().then 的统一收尾
    }
  }

  /** 世界没人了(最后一个连接断开/离开)：演出没有观众，杀掉。 */
  onWorldEmpty(worldId: string): void {
    this.#active.get(worldId)?.runner.kill();
  }

  #finish(worldId: string, session: StageSession, r: StageRunResult): void {
    if (this.#active.get(worldId) !== session) return; // 已被后续演出顶替(理论不可达，防御)
    this.#active.delete(worldId);
    session.backend.dispose();
    if (r.status === 'done') {
      this.#hub.broadcast(worldId, { type: 'stage_end', stageId: session.stageId, result: r.result });
    } else {
      const reason = r.status === 'error' ? r.message : r.status === 'timeout' ? '演出超时' : '演出被终止';
      this.#hub.broadcast(worldId, { type: 'stage_abort', stageId: session.stageId, reason });
    }
  }
}
