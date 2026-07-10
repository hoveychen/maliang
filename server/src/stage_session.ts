// WS 舞台协议：把 ScriptRunner 的命令流桥接到 world 内的客户端。
// 下行: stage_begin / stage_cmd / stage_end / stage_abort (经 WorldHub 广播)
// 上行: stage_event { kind: 'ack' | 'abort' | ... } (P5 起扩 tap/timer/near)
// 一个世界同时只有一场演出；断连清空世界即杀 worker。
// 设计文档: docs/script-runtime-design.md

import { randomUUID } from 'node:crypto';
import { ScriptRunner } from './stage_runner.ts';
import type { StageActorInfo, StageBackend, StageCommand, StagePropMaker, StageRunResult, StageSubscription } from './stage_types.ts';
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
  /** near/tap/timer 规则触发时携带的订阅 id（关联脚本里的 on(...)/countdown.onDone）。 */
  subId?: string;
  /** 事件负载（如 tap 的角色、near 的实时距离），注回脚本回调。 */
  payload?: Record<string, unknown>;
}

/** 把命令广播给世界成员、把 ack 关联回 Promise 的舞台后端。 */
class WsStageBackend implements StageBackend {
  #hub: WorldHub;
  #worldId: string;
  #stageId: string;
  #propMaker?: StagePropMaker;
  #pending = new Map<number, { resolve: (v?: Record<string, unknown>) => void; reject: (e: Error) => void }>();

  constructor(hub: WorldHub, worldId: string, stageId: string, propMaker?: StagePropMaker) {
    this.#hub = hub;
    this.#worldId = worldId;
    this.#stageId = stageId;
    this.#propMaker = propMaker;
  }

  execCommand(cmd: StageCommand): Promise<Record<string, unknown> | void> {
    // prop.create 不下发客户端（客户端造不出 spec）：服务端跑造物管线出 spec，
    // 再以 prop_spawn 携规格广播让客户端落位，客户端 ack 后 resolve 回脚本。
    if (cmd.op === 'prop_create') return this.#createProp(cmd);
    // 倒计时打服务端起始时戳：客户端按 serverStartMs + 时间偏移算本地截止，双端读数一致。
    if (cmd.op === 'hud_countdown') cmd.args = { ...cmd.args, serverStartMs: Date.now() };
    return this.#dispatch(cmd.cmdId, cmd.op, cmd.actorId, cmd.args);
  }

  /** 广播一条命令给世界成员，登记 pending 等客户端 ack（首个生效）。世界空则立即回绝。 */
  #dispatch(cmdId: number, op: string, actorId: string | undefined, args: Record<string, unknown>): Promise<Record<string, unknown> | void> {
    return new Promise((resolve, reject) => {
      this.#pending.set(cmdId, { resolve, reject });
      const n = this.#hub.broadcast(this.#worldId, { type: 'stage_cmd', stageId: this.#stageId, cmdId, actorId, op, args });
      if (n === 0) {
        this.#pending.delete(cmdId);
        reject(new Error('世界里没有观众了'));
      }
    });
  }

  async #createProp(cmd: StageCommand): Promise<Record<string, unknown>> {
    const prop = this.#propMaker ? await this.#propMaker(this.#worldId, String(cmd.args.desc ?? '')) : null;
    if (!prop) throw new Error('造物失败');
    // 复用原 cmdId：客户端把 prop_spawn 落位后 ack cmdId，resolve 回脚本的 prop.create。
    const res = await this.#dispatch(cmd.cmdId, 'prop_spawn', undefined, { id: prop.id, spec: prop.spec, near: cmd.args.near });
    return { id: prop.id, ...(res ?? {}) };
  }

  /** 脚本订阅规则(near/tap/timer)：广播 watch 让客户端布置探测器（无 ack，cmdId=-1）。 */
  onSubscribe(sub: StageSubscription): void {
    this.#hub.broadcast(this.#worldId, {
      type: 'stage_cmd', stageId: this.#stageId, cmdId: -1, op: 'watch',
      args: { subId: sub.subId, ev: sub.ev, params: sub.params },
    });
  }

  onUnsubscribe(subId: string): void {
    this.#hub.broadcast(this.#worldId, { type: 'stage_cmd', stageId: this.#stageId, cmdId: -1, op: 'unwatch', args: { subId } });
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

  constructor(hub: WorldHub, worldId: string, propMaker?: StagePropMaker) {
    this.backend = new WsStageBackend(hub, worldId, this.stageId, propMaker);
    this.runner = new ScriptRunner(this.backend);
  }
}

/** 每个 world 至多一场演出的调度台。 */
export class StageDirector {
  #hub: WorldHub;
  #propMaker?: StagePropMaker;
  #active = new Map<string, StageSession>();

  constructor(hub: WorldHub, propMaker?: StagePropMaker) {
    this.#hub = hub;
    this.#propMaker = propMaker;
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
    const session = new StageSession(this.#hub, worldId, this.#propMaker);
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
    } else if ((ev.kind === 'near' || ev.kind === 'tap' || ev.kind === 'timer') && typeof ev.subId === 'string') {
      // 规则触发：客户端探测到（点角色/倒计时归零/靠近）→ 注回脚本对应订阅回调。
      session.runner.emitEvent(ev.subId, ev.payload);
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
